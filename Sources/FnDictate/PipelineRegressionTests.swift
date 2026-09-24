import Foundation
import ApplicationServices

/// Offline protocol fixtures: these never read credentials or connect to a provider.
enum PipelineRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        let origin = try? APIEndpoint.url(baseURL: "https://api.openai.com", path: "/v1/models")
        let versioned = try? APIEndpoint.url(baseURL: " https://api.openai.com/v1/ \n", path: "/v1/models")
        check("API base URL accepts origin or /v1 without duplication", origin == versioned && origin?.path == "/v1/models", "")
        let socketURL = try? APIEndpoint.url(baseURL: "https://api.openai.com/v1", path: "/v1/realtime", webSocket: true,
                                             queryItems: [URLQueryItem(name: "intent", value: "transcription")])
        check("Realtime endpoint uses wss and preserves transcription intent", socketURL?.absoluteString == "wss://api.openai.com/v1/realtime?intent=transcription", "")
        for invalid in ["", "not a url", "api.openai.com", "file:///tmp/test", "https://", "https://api.openai.com?other=1"] {
            check("invalid API base URL rejected: \(invalid)", (try? APIEndpoint.url(baseURL: invalid, path: "/v1/models")) == nil, "")
        }
        check("STT invalid keyword characters are filtered", STTFactory.validKeywords(["Acme", "<output>", "one\rtwo", "one\ntwo"]) == ["Acme"], "")
        var caret = InsertionTarget()
        caret.charAfter = "w"
        check("spacing separates text inserted at start of a word", TextInserter.applySpacing("Hello", target: caret, cjkSpacing: true) == "Hello ", "")
        caret.subrole = "AXSecureTextField"
        check("password fields identified by Accessibility subrole", caret.isSecure, "")
        var original = InsertionTarget()
        original.processIdentifier = 100
        var current = InsertionTarget()
        current.processIdentifier = 200
        check("insertion refuses a different app after transcription", !TextInserter.matchesOriginalTarget(original, current: current), "")
        current.processIdentifier = 100
        check("insertion preserves text for manual paste when the original field is unknown", !TextInserter.matchesOriginalTarget(original, current: current), "")
        original.element = AXUIElementCreateApplication(100)
        current.element = AXUIElementCreateApplication(200)
        check("insertion refuses a different focused element", !TextInserter.matchesOriginalTarget(original, current: current), "")
        current.element = original.element
        check("insertion accepts the original focused element", TextInserter.matchesOriginalTarget(original, current: current), "")
        check("empty dictation is a silent outcome", DictationController.isEmptyRecording(.success("")), "")
        check("whitespace-only dictation is a silent outcome", DictationController.isEmptyRecording(.success(" \n\t")), "")
        check("no captured audio is a silent outcome", DictationController.isEmptyRecording(.failure(STTError.noAudio)), "")
        check("provider billing failure is not mistaken for no speech", !DictationController.isEmptyRecording(.failure(STTError.server("No audio credits remaining"))), "")
        check("transcription timeout remains a genuine failure", !DictationController.isEmptyRecording(.failure(STTError.timeout)), "")

        let config = STTConfig(languages: ["en", "zh-cn"], prompt: "Bilingual dictation", keywords: ["Acme"],
                               delay: .low, chineseVariant: .simplified)
        let shortSocket = FixtureSocket()
        let shortSession = OpenAIRealtimeSTT(apiKey: "fixture", baseURL: "https://api.openai.com", config: config,
                                            model: "gpt-live-transcribe", socketFactory: { _, _ in shortSocket })
        var shortResult: Result<String, Error>?
        shortSession.onFinal = { shortResult = $0 }
        shortSession.connect()
        shortSession.sendAudio(Data(count: 480))
        shortSession.finish()
        waitUntil { shortResult != nil }
        check("short OpenAI recording completes silently before handshake", shortResult.map(DictationController.isEmptyRecording) == true, "")
        check("short OpenAI recording never commits an empty buffer", !shortSocket.messages.contains { $0["type"] as? String == "input_audio_buffer.commit" }, "")
        let shortAssemblySocket = FixtureSocket()
        let shortAssembly = AssemblyAISTT(apiKey: "fixture", config: config, socketFactory: { _, _ in shortAssemblySocket })
        var shortAssemblyResult: Result<String, Error>?
        shortAssembly.onFinal = { shortAssemblyResult = $0 }
        shortAssembly.connect()
        shortAssembly.finish()
        waitUntil { shortAssemblyResult != nil }
        check("empty AssemblyAI recording completes silently before handshake", shortAssemblyResult.map(DictationController.isEmptyRecording) == true, "")

        for code in ["input_audio_buffer_commit_empty", "insufficient_quota"] {
            let socket = FixtureSocket()
            let session = OpenAIRealtimeSTT(apiKey: "fixture", baseURL: "https://api.openai.com", config: config,
                                            model: "gpt-live-transcribe", socketFactory: { _, _ in socket })
            var result: Result<String, Error>?
            session.onFinal = { result = $0 }
            session.connect()
            waitUntil { socket.isConnected }
            socket.receive(["type": "session.updated"])
            session.sendAudio(Data(count: 9600))
            session.finish()
            waitUntil { socket.messages.contains { $0["type"] as? String == "input_audio_buffer.commit" } }
            socket.receive(["type": "error", "error": ["code": code, "message": "fixture \(code)"]])
            waitUntil { result != nil }
            if code == "input_audio_buffer_commit_empty" {
                check("provider empty-buffer response becomes a silent outcome", result.map(DictationController.isEmptyRecording) == true, "")
            } else {
                let failed: Bool
                if case .failure? = result { failed = true } else { failed = false }
                check("provider quota failure is still reported", failed && result.map(DictationController.isEmptyRecording) == false, "")
            }
        }
        let openAISocket = FixtureSocket()
        let openAI = OpenAIRealtimeSTT(apiKey: "fixture", baseURL: "https://api.openai.com/v1", config: config,
                                       model: "gpt-live-transcribe", socketFactory: { _, _ in openAISocket })
        var openAIFinal: Result<String, Error>?
        var openAIFinalCount = 0
        openAI.onFinal = { openAIFinal = $0; openAIFinalCount += 1 }
        openAI.connect()
        waitUntil { openAISocket.messages.contains { $0["type"] as? String == "session.update" } }
        openAI.sendAudio(Data(repeating: 1, count: 9600))
        openAISocket.receive(["type": "session.updated"])
        waitUntil { openAISocket.messages.contains { $0["type"] as? String == "input_audio_buffer.append" } }
        openAI.finish()
        waitUntil { openAISocket.messages.contains { $0["type"] as? String == "input_audio_buffer.commit" } }
        let messages = openAISocket.messages.compactMap { $0["type"] as? String }
        check("OpenAI sends buffered audio before committing", messages == ["session.update", "input_audio_buffer.append", "input_audio_buffer.commit"], "\(messages)")
        openAISocket.receive(["type": "conversation.item.input_audio_transcription.completed", "transcript": "Hello 世界"])
        waitUntil { openAIFinal != nil }
        check("OpenAI final transcript returned", (try? openAIFinal?.get()) == "Hello 世界", "")
        openAISocket.receive(["type": "error", "error": ["message": "late failure"]])
        waitUntil(timeout: 0.05) { false }
        check("OpenAI ignores events after completion", openAIFinalCount == 1, "")

        let assemblySocket = FixtureSocket()
        let assembly = AssemblyAISTT(apiKey: "fixture", config: config, socketFactory: { _, _ in assemblySocket })
        var assemblyFinal: Result<String, Error>?
        assembly.onFinal = { assemblyFinal = $0 }
        assembly.connect()
        waitUntil { assemblySocket.isConnected }
        // More than one second of handshake backlog, with a short final fragment.
        assembly.sendAudio(Data(repeating: 1, count: 35_400))
        assemblySocket.receive(["type": "Begin"])
        assembly.finish()
        waitUntil(timeout: 3) { assemblySocket.messages.contains { $0["type"] as? String == "Terminate" } }
        let frames = assemblySocket.frames
        check("AssemblyAI backlog obeys frame-size limits", frames.count > 1 && frames.allSatisfy { (1600...32000).contains($0.count) }, "\(frames.map(\.count))")
        check("AssemblyAI backlog preserves every audio byte", frames.reduce(0) { $0 + $1.filter { $0 == 1 }.count } == 35_400, "")
        let dates = assemblySocket.frameDates
        check("AssemblyAI backlog is paced in real time", dates.count > 1 && dates.last!.timeIntervalSince(dates.first!) >= 0.9, "")
        assemblySocket.receive(["type": "Turn", "turn_order": 0, "end_of_turn": true,
                                "transcript": "All the words in the turn.", "utterance": "the turn."])
        assemblySocket.receive(["type": "Termination"])
        waitUntil { assemblyFinal != nil }
        check("AssemblyAI retains the whole turn, not only its final utterance", (try? assemblyFinal?.get()) == "All the words in the turn.", "")

        let errorSocket = FixtureSocket()
        let errorSession = AssemblyAISTT(apiKey: "fixture", config: config, socketFactory: { _, _ in errorSocket })
        var receivedFailure = false
        errorSession.onFinal = { if case .failure = $0 { receivedFailure = true } }
        errorSession.connect()
        waitUntil { errorSocket.isConnected }
        errorSocket.receive(["type": "Begin"])
        errorSocket.receive(["error": "fixture provider error"])
        waitUntil { receivedFailure }
        check("AssemblyAI surfaces errors during recording", receivedFailure, "")
        errorSession.cancel()
    }

    private static func waitUntil(timeout: TimeInterval = 1, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private final class FixtureSocket: STTSocket {
        var onOpen: (() -> Void)?
        var onText: ((String) -> Void)?
        var onClose: ((Error?) -> Void)?
        private let lock = NSLock()
        private var storedMessages: [[String: Any]] = []
        private var storedFrames: [Data] = []
        private var storedFrameDates: [Date] = []
        private var connected = false
        var messages: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return storedMessages }
        var frames: [Data] { lock.lock(); defer { lock.unlock() }; return storedFrames }
        var frameDates: [Date] { lock.lock(); defer { lock.unlock() }; return storedFrameDates }
        var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }
        func connect() {
            lock.lock(); connected = true; lock.unlock()
            onOpen?()
        }
        func send(text: String) {
            guard let data = text.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            lock.lock(); storedMessages.append(message); lock.unlock()
        }
        func send(data: Data) {
            lock.lock(); storedFrames.append(data); storedFrameDates.append(Date()); lock.unlock()
        }
        func ping() {}
        func close() {}
        func receive(_ event: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: event), let text = String(data: data, encoding: .utf8) else { return }
            onText?(text)
        }
    }
}
