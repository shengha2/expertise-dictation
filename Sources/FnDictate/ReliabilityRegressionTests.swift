import Foundation
import AVFoundation
import Darwin

enum ReliabilityRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FnDictate-reliability-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func isPending(_ directory: URL) -> Bool {
            RecordingArchive.pending(root: root).contains { $0.standardizedFileURL.path == directory.standardizedFileURL.path }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for frames in [24000, 25001] {
                let audioURL = root.appendingPathComponent("eof-\(frames).wav")
                let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
                var file: AVAudioFile? = try AVAudioFile(forWriting: audioURL, settings: format.settings)
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
                pcm.frameLength = AVAudioFrameCount(frames)
                for i in 0..<frames { pcm.floatChannelData![0][i] = sin(Float(i) * 0.1) * 0.2 }
                try file!.write(from: pcm)
                file = nil
                for rate: Double in [24000, 16000] {
                    let reader = try PCMFileReader(url: audioURL, sampleRate: rate)
                    var byteCount = 0
                    var chunks = 0
                    while let data = try reader.nextChunk(), chunks < 100 {
                        byteCount += data.count
                        chunks += 1
                    }
                    let expectedFrames = Double(frames) * rate / 24000
                    check("reliability: audio EOF flushes complete tail (\(frames) at \(Int(rate)) Hz)", abs(Double(byteCount / 2) - expectedFrames) <= 1 && chunks < 100, "frames=\(byteCount / 2)")
                    check("reliability: repeated audio EOF remains finished", try reader.nextChunk() == nil, "")
                }
            }
            let pool = ProviderPool(sampleRate: 24000)
            let thirtyMinutes = DurableSTTSession(first: pool.make(), archiveRoot: root, factory: { pool.make() })
            var longResult: Result<String, Error>?
            thirtyMinutes.onFinal = { longResult = $0 }
            thirtyMinutes.connect()
            // Actual 86.4 MB of PCM is written and fed through the production segmentation path.
            // This is a virtual-duration transport test, not a live-provider or microphone claim.
            let chunk = Data(repeating: 1, count: 48_000)
            for _ in 0..<1800 { thirtyMinutes.sendAudio(chunk) }
            thirtyMinutes.finish()
            waitUntil(timeout: 30) { longResult != nil }
            let result = try longResult?.get() ?? ""
            let expected = (0..<30).map { "section\($0)" }.joined(separator: " ")
            check("reliability: 30-minute recording returns every section in order", result == expected, "sections=\(result.split(separator: " ").count)")
            check("reliability: 30-minute PCM has no dropped or duplicate bytes", pool.totalReceived == 86_400_000, "received=\(pool.totalReceived)")
            check("reliability: every provider turn stays within 60 seconds", pool.largestReceived <= 2_880_000, "max=\(pool.largestReceived)")
            if let url = thirtyMinutes.recoveryURL {
                let saved = try RecordingArchive(directory: url)
                check("reliability: successful STT keeps ownership through cleanup", !isPending(url), "")
                check("reliability: all 30 minutes are recoverable from disk", saved.manifest.byteCount == 86_400_000 && saved.manifest.transcripts.count == 30, "")
                let permissions = (try FileManager.default.attributesOfItem(atPath: saved.audioURL.path)[.posixPermissions] as? NSNumber)?.intValue
                check("reliability: saved audio is owner-only", permissions == 0o600, "")
            } else { check("reliability: all 30 minutes are recoverable from disk", false, "archive missing") }
            thirtyMinutes.discardRecording()

            let tailPool = ProviderPool(sampleRate: 1000)
            let tinyTail = DurableSTTSession(first: tailPool.make(), segmentSeconds: 1, archiveRoot: root, factory: { tailPool.make() })
            var tailResult: Result<String, Error>?
            tinyTail.onFinal = { tailResult = $0 }
            tinyTail.connect()
            tinyTail.sendAudio(Data(repeating: 1, count: 2200))
            tinyTail.finish()
            waitUntil { tailResult != nil }
            check("reliability: a short final section is padded instead of discarded", tailPool.totalReceived == 2300 && (try? tailResult?.get()) == "section0 section1", "")
            check("reliability: transport padding never changes saved audio", tinyTail.capturedSeconds == 1.1, "")
            tinyTail.discardRecording()

            let failingPool = ProviderPool(sampleRate: 1000, failIndex: 1)
            let failureSession = DurableSTTSession(first: failingPool.make(), segmentSeconds: 1, archiveRoot: root, factory: { failingPool.make() })
            var failedResult: Result<String, Error>?
            failureSession.onFinal = { failedResult = $0 }
            failureSession.connect()
            for _ in 0..<22 { failureSession.sendAudio(Data(repeating: 1, count: 200)) }
            failureSession.finish()
            waitUntil { failedResult != nil }
            let didFail: Bool
            if case .failure? = failedResult { didFail = true } else { didFail = false }
            check("reliability: a missing middle section cannot become partial success", didFail, "")
            if let url = failureSession.recoveryURL {
                let saved = try RecordingArchive(directory: url)
                check("reliability: failed transcription releases ownership for retry", isPending(url), "")
                check("reliability: disconnect retains the full recording and completed sections", saved.manifest.byteCount == 4400 && saved.manifest.transcripts.count == 2, "")
                let recoveryPool = ProviderPool(sampleRate: 1000, prefix: "recovered")
                let recovered = try DurableSTTSession(recovering: url, factory: { recoveryPool.make() })
                var recoveryResult: Result<String, Error>?
                recovered.onFinal = { recoveryResult = $0 }
                recovered.connect()
                waitUntil(timeout: 3) { recoveryResult != nil }
                check("reliability: retry transcribes only the missing section", recoveryPool.totalReceived == 2000, "received=\(recoveryPool.totalReceived)")
                check("reliability: retry preserves order and both original endpoints", (try? recoveryResult?.get()) == "section0 recovered0 section2", "")
                recovered.discardRecording()
            } else { check("reliability: disconnect retains the full recording and completed sections", false, "archive missing") }

            let interruptedPool = ProviderPool(sampleRate: 1000)
            let configuration = STTConfig(languages: ["es", "ja"], prompt: "Original languages", keywords: ["Example"], delay: .low, chineseVariant: .traditional)
            let interrupted = DurableSTTSession(first: interruptedPool.make(), segmentSeconds: 1, archiveRoot: root,
                                                 configuration: configuration, factory: { interruptedPool.make() })
            interrupted.configureRecovery(mode: "verbatim", translationTarget: "fr")
            interrupted.connect()
            interrupted.sendAudio(Data(repeating: 1, count: 1400))
            interrupted.cancel()
            interrupted.checkpointRecording()
            if let url = interrupted.recoveryURL {
                let saved = try RecordingArchive(directory: url)
                check("reliability: interrupted capture retains the unfinished tail", saved.manifest.byteCount == 1400 && saved.segmentRanges == [0..<1400], "")
                check("reliability: recovery preserves language, mode and translation target", saved.manifest.configuration?.languages == ["es", "ja"] && saved.manifest.mode == "verbatim" && saved.manifest.translationTarget == "fr", "")
                let shortRead = try? saved.read(offset: 0, count: 1600)
                check("reliability: truncated archive reads fail instead of skipping bytes", shortRead == nil, "")
                interrupted.discardRecording()
                check("reliability: explicit discard removes saved audio", !FileManager.default.fileExists(atPath: url.path), "")
            } else { check("reliability: interrupted capture retains the unfinished tail", false, "archive missing") }

            let corrupt = try RecordingArchive(sampleRate: 1000, engine: "offline-fixture", root: root)
            try corrupt.append(Data(count: 2000))
            try corrupt.finishSegment(at: 1000)
            try corrupt.close()
            let corruptManifest = corrupt.directory.appendingPathComponent("manifest.json")
            var corruptJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: corruptManifest)) as! [String: Any]
            corruptJSON["segmentEnds"] = [1600, 1000]
            try JSONSerialization.data(withJSONObject: corruptJSON).write(to: corruptManifest)
            check("reliability: malformed recovery boundaries fail without crashing", throwsError { _ = try RecordingArchive(directory: corrupt.directory) }, "")
            check("reliability: corrupt metadata leaves captured PCM intact", (try? Data(contentsOf: corrupt.audioURL).count) == 2000, "")
            corrupt.remove()

            let leased = try RecordingArchive(sampleRate: 1000, engine: "offline-fixture", root: root)
            try leased.append(Data(count: 2000))
            try leased.close()
            check("reliability: active recording is excluded from pending recovery", !isPending(leased.directory), "")
            check("reliability: concurrent recovery cannot take an active recording", throwsError { _ = try RecordingArchive(directory: leased.directory, acquireOwnership: true) }, "")
            check("reliability: discard cannot remove an active recording", throwsError { try RecordingArchive.discardPending(leased.directory) } && FileManager.default.fileExists(atPath: leased.audioURL.path), "")
            leased.releaseOwnership()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let ready = root.appendingPathComponent("lease-child-ready")
            child.arguments = ["--archive-lease-fixture", leased.directory.path, ready.path]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
            waitUntil(timeout: 3) { FileManager.default.fileExists(atPath: ready.path) || !child.isRunning }
            let childReady = FileManager.default.fileExists(atPath: ready.path)
            check("reliability: another process exclusively owns the saved recording", childReady && !isPending(leased.directory), "")
            check("reliability: cross-process recovery and discard both reject active ownership", childReady && throwsError { _ = try RecordingArchive(directory: leased.directory, acquireOwnership: true) } && throwsError { try RecordingArchive.discardPending(leased.directory) }, "")
            try leased.close()
            let childCheckpoint = try RecordingArchive(directory: leased.directory).manifest.lastError
            check("reliability: stale-owner close cannot overwrite a new owner checkpoint", childCheckpoint == "cross-process fixture owns this checkpoint", "")
            leased.remove()
            check("reliability: stale-owner removal cannot delete another process recording", childReady && FileManager.default.fileExists(atPath: leased.audioURL.path), "")
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            check("reliability: process death automatically releases recording ownership", child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL && isPending(leased.directory), "")
            let resumed = try RecordingArchive(directory: leased.directory, acquireOwnership: true)
            check("reliability: saved audio can be recovered after owner death", resumed.manifest.byteCount == 2000, "")
            resumed.releaseOwnership()
            try RecordingArchive.discardPending(leased.directory)
            check("reliability: unowned recording can be explicitly discarded", !FileManager.default.fileExists(atPath: leased.directory.path), "")

            let blockedRoot = root.appendingPathComponent("not-a-directory")
            try Data([1]).write(to: blockedRoot)
            let diskPool = ProviderPool(sampleRate: 1000)
            let diskFailure = DurableSTTSession(first: diskPool.make(), archiveRoot: blockedRoot, factory: { diskPool.make() })
            var diskResult: Result<String, Error>?
            diskFailure.onFinal = { diskResult = $0 }
            diskFailure.connect()
            diskFailure.sendAudio(Data(repeating: 1, count: 200))
            waitUntil { diskResult != nil }
            let failedSave: Bool
            if case .failure? = diskResult { failedSave = true } else { failedSave = false }
            check("reliability: an unwritable recovery location produces a visible failure", failedSave && diskPool.totalReceived == 0, "")

            let longText = (0..<12000).map { "checkpoint\($0) 日本語 español العربية" }.joined(separator: " ")
            let pieces = LongTextProcessing.chunks(longText)
            check("reliability: long multilingual chunking preserves every character", pieces.joined() == longText, "")
            check("reliability: long cleanup work stays bounded per request", pieces.allSatisfy { $0.count <= 1800 } && pieces.count > 100, "chunks=\(pieces.count)")
            check("reliability: cleanup budgets cover each full multilingual section", pieces.allSatisfy { CleanupPrompt.maxTokens(for: $0) >= $0.count * 3 }, "")
            let cleanupText = (0..<500).map { "checkpoint\($0) 日本語 español العربية" }.joined(separator: " ")
            let cleanupPieces = LongTextProcessing.chunks(cleanupText)
            let context = CleanupContext(precedingText: nil, dictionary: [], chineseVariant: .simplified,
                                         allowFormatting: false, spokenCommands: false, cjkSpacing: true, customInstructions: "")
            let failingCleanup = CleanupFixture(failAt: 2)
            var cleanupResult: LongTextProcessing.CleanupResult?
            Task { @MainActor in
                cleanupResult = try? await LongTextProcessing.cleanup(cleanupText, context: context, settings: Settings.shared, client: failingCleanup) { _, _ in }
            }
            waitUntil(timeout: 10) { cleanupResult != nil }
            check("reliability: long cleanup preserves all content after a middle failure", MeaningGuard.tokens(cleanupResult?.text ?? "") == MeaningGuard.tokens(cleanupText), "")
            check("reliability: cleanup failure avoids one timeout per remaining section", failingCleanup.calls == 2 && cleanupResult?.fallbackCount == cleanupPieces.count - 1, "")
            let truncatedCleanup = CleanupFixture(failAt: 1)
            var truncatedResult: LongTextProcessing.CleanupResult?
            Task { @MainActor in
                truncatedResult = try? await LongTextProcessing.cleanup(cleanupText, context: context, settings: Settings.shared, client: truncatedCleanup) { _, _ in }
            }
            waitUntil(timeout: 10) { truncatedResult != nil }
            check("reliability: all-fallback cleanup keeps the original exactly", truncatedResult?.text == cleanupText && truncatedResult?.fallbackCount == cleanupPieces.count, "")
            check("reliability: OpenAI output-limit response is rejected", throwsError { try OpenAIChatClient.validateFinishReason("length") }, "")
            check("reliability: Anthropic output-limit response is rejected", throwsError { try AnthropicClient.validateStopReason("max_tokens") }, "")
            check("reliability: completed provider responses remain accepted", !throwsError { try OpenAIChatClient.validateFinishReason("stop"); try AnthropicClient.validateStopReason("end_turn") }, "")
            print("RELIABILITY EVIDENCE: virtualDurationSeconds=1800 pcmBytes=86400000 provider=offline-fixture; real provider coverage is reported separately")
        } catch { check("reliability fixtures completed", false, error.localizedDescription) }
    }

    private static func throwsError(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    private static func waitUntil(timeout: TimeInterval = 2, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    private final class CleanupFixture: LLMClient {
        let name = "offline-cleanup-fixture"
        let failAt: Int
        var calls = 0
        init(failAt: Int) { self.failAt = failAt }
        func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
            calls += 1
            if calls == failAt { throw LLMError.outputLimit }
            guard let start = user.range(of: "<transcript>"), let end = user.range(of: "</transcript>", range: start.upperBound..<user.endIndex) else { return "" }
            return String(user[start.upperBound..<end.lowerBound])
        }
    }
    private final class ProviderPool {
        private let lock = NSLock()
        private var providers: [Provider] = []
        let sampleRate: Double
        let failIndex: Int?
        let prefix: String
        init(sampleRate: Double, failIndex: Int? = nil, prefix: String = "section") {
            self.sampleRate = sampleRate; self.failIndex = failIndex; self.prefix = prefix
        }
        func make() -> STTSession {
            lock.lock(); defer { lock.unlock() }
            let index = providers.count
            let provider = Provider(sampleRate: sampleRate, text: "\(prefix)\(index)", fail: index == failIndex)
            providers.append(provider)
            return provider
        }
        var totalReceived: Int { lock.lock(); defer { lock.unlock() }; return providers.reduce(0) { $0 + $1.receivedBytes } }
        var largestReceived: Int { lock.lock(); defer { lock.unlock() }; return providers.map(\.receivedBytes).max() ?? 0 }
    }
    private final class Provider: STTSession {
        let sampleRate: Double
        let engineName = "offline-fixture"
        var onPartial: ((String) -> Void)?
        var onFinal: ((Result<String, Error>) -> Void)?
        var isUsable: Bool { true }
        private let lock = NSLock()
        private var bytes = 0
        var receivedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
        let text: String
        let fail: Bool
        init(sampleRate: Double, text: String, fail: Bool) { self.sampleRate = sampleRate; self.text = text; self.fail = fail }
        func connect() {}
        func sendAudio(_ data: Data) { lock.lock(); bytes += data.count; lock.unlock() }
        func finish() {
            DispatchQueue.main.async {
                self.onPartial?("incomplete partial")
                self.onFinal?(self.fail ? .failure(STTError.connection("fixture disconnect")) : .success(self.text))
            }
        }
        func cancel() {}
    }
}
