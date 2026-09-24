import Foundation

/// AssemblyAI Universal-3.5 Pro streaming (v3 WebSocket). 16 kHz PCM16 binary frames; the server
/// emits `Turn` messages (formatted, punctuated) and we join finalised turns in order.
final class AssemblyAISTT: STTSession {
    let sampleRate: Double = 16000
    var onPartial: ((String) -> Void)?
    var onFinal: ((Result<String, Error>) -> Void)?
    let engineName = "universal-3-5-pro"

    private enum Phase { case idle, connecting, ready, finishing, done }
    private let q = DispatchQueue(label: "com.hao.fndictate.assemblyai-stt")
    private var phase: Phase = .idle
    private var ws: STTSocket?
    private let socketFactory: (URL, [String: String]) -> STTSocket
    private let apiKey: String
    private let config: STTConfig
    private var pending = Data()
    private var accum = Data()
    private var audioSeconds: Double = 0
    private var finalTurns: [Int: String] = [:]
    private var currentTurn: (order: Int, text: String)?
    private var resolved = false
    private var finishRequestedAt: Date?
    private var finishTimer: DispatchWorkItem?
    private var finishRequested = false
    private var audioSendScheduled = false

    init(apiKey: String, config: STTConfig,
         socketFactory: @escaping (URL, [String: String]) -> STTSocket = { WebSocketClient(url: $0, headers: $1) }) {
        self.apiKey = apiKey
        self.config = config
        self.socketFactory = socketFactory
    }

    var isUsable: Bool { q.sync { phase == .connecting || phase == .ready } }

    func connect() {
        q.async {
            guard self.phase == .idle else { return }
            self.phase = .connecting
            var comps = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")!
            comps.queryItems = [
                URLQueryItem(name: "sample_rate", value: "16000"),
                URLQueryItem(name: "encoding", value: "pcm_s16le"),
                URLQueryItem(name: "speech_model", value: "universal-3-5-pro"),
                URLQueryItem(name: "inactivity_timeout", value: "120"),
            ]
            let ws = self.socketFactory(comps.url!, ["Authorization": self.apiKey])
            ws.onOpen = { [weak self] in self?.q.async { Log.info("AssemblyAI: socket open") } }
            ws.onText = { [weak self] t in self?.q.async { self?.didReceive(t) } }
            ws.onClose = { [weak self] e in self?.q.async { self?.didClose(e) } }
            self.ws = ws
            ws.connect()
            Log.info("AssemblyAI: connecting")
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        ws?.send(text: s)
    }

    private func didReceive(_ text: String) {
        guard phase != .done else { return }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let err = obj["error"] as? String {
            Log.error("AssemblyAI error: \(err)")
            resolve(.failure(STTError.server(err)))
            return
        }
        switch obj["type"] as? String {
        case "Begin":
            var update: [String: Any] = ["type": "UpdateConfiguration"]
            let langs = config.languages.map { $0.hasPrefix("zh") ? "zh" : $0 }
            update["language_codes"] = Array(Set(langs)).sorted()
            if !config.keywords.isEmpty { update["keyterms_prompt"] = Array(config.keywords.filter { $0.count <= 50 }.prefix(100)) }
            if !config.prompt.isEmpty { update["prompt"] = String(config.prompt.prefix(1500)) }
            send(update)
            phase = .ready
            Log.info("AssemblyAI: session ready")
            flushPending()
        case "Turn":
            let order = (obj["turn_order"] as? Int) ?? 0
            let transcript = (obj["transcript"] as? String) ?? ""
            let endOfTurn = (obj["end_of_turn"] as? Bool) ?? false
            if endOfTurn {
                // `utterance` is only the latest finalized fragment. `transcript` contains the
                // whole turn; preferring utterance drops earlier words in a long turn.
                if !transcript.trimmingCharacters(in: .whitespaces).isEmpty { finalTurns[order] = transcript }
                if currentTurn?.order == order { currentTurn = nil }
            } else {
                currentTurn = (order, transcript)
            }
            let p = joinedText()
            DispatchQueue.main.async { self.onPartial?(p) }
        case "Termination":
            if phase == .finishing {
                if let currentTurn, !currentTurn.text.isEmpty { resolve(.failure(STTError.connection("The provider ended before finalizing the last turn"))) }
                else { resolve(.success(joinedText())) }
            }
        default:
            break
        }
    }

    private func joinedText() -> String {
        var parts = finalTurns.keys.sorted().map { finalTurns[$0]! }
        if let cur = currentTurn, !cur.text.isEmpty { parts.append(cur.text) }
        return parts.joined(separator: " ")
    }

    private func didClose(_ error: Error?) {
        if phase == .done { return }
        let wasFinishing = phase == .finishing
        phase = .done
        if let error { Log.warn("AssemblyAI: closed with error: \(error.localizedDescription)") }
        if wasFinishing {
            resolve(.failure(error ?? STTError.connection("closed before final transcription")))
        } else if !resolved {
            resolved = true
            let e = error ?? STTError.connection("closed")
            DispatchQueue.main.async { self.onFinal?(.failure(e)) }
        }
    }

    func sendAudio(_ pcm16: Data) {
        q.async {
            switch self.phase {
            case .idle, .connecting:
                self.pending.append(pcm16)
            case .ready:
                guard !self.finishRequested else { return }
                self.accum.append(pcm16)
                self.audioSeconds += Double(pcm16.count) / 2 / self.sampleRate
                self.drainAudio()
            default:
                break
            }
        }
    }

    private func flushPending() {
        if !pending.isEmpty {
            accum.append(pending)
            audioSeconds += Double(pending.count) / 2 / sampleRate
            pending.removeAll()
        }
        drainAudio()
    }

    private func drainAudio() {
        guard phase == .ready, !audioSendScheduled else { return }
        guard finishRequested || accum.count >= 3200 else { return }
        guard !accum.isEmpty else {
            if finishRequested { finishSending() }
            return
        }
        let count = min(accum.count, 3200)
        let chunk = Self.paddedAudioFrame(Data(accum.prefix(count)))
        accum.removeFirst(count)
        ws?.send(data: chunk)
        // Include handshake backlog in the same paced stream. AssemblyAI rejects frames
        // outside 50–1000 ms and audio sent faster than real time.
        audioSendScheduled = true
        q.asyncAfter(deadline: .now() + Double(chunk.count) / 2 / self.sampleRate) {
            self.audioSendScheduled = false
            self.drainAudio()
        }
    }

    static func paddedAudioFrame(_ data: Data) -> Data {
        var frame = data
        if frame.count < 1600 { frame.append(Data(count: 1600 - frame.count)) }
        return frame
    }

    func finish() {
        q.async {
            if self.phase == .connecting || self.phase == .ready {
                let seconds = self.audioSeconds + Double(self.pending.count) / 2 / self.sampleRate
                if seconds < 0.15 {
                    if self.phase == .ready { self.send(["type": "Terminate"]) }
                    self.resolve(.success(""))
                    return
                }
            }
            switch self.phase {
            case .connecting:
                // Socket not ready yet: wait for it (briefly), then finish.
                if self.finishRequestedAt == nil { self.finishRequestedAt = Date() }
                if Date().timeIntervalSince(self.finishRequestedAt!) > 5.0 {
                    Log.warn("Transcription socket never became ready")
                    self.resolve(.failure(STTError.connection("could not reach the transcription service")))
                    return
                }
                self.q.asyncAfter(deadline: .now() + 0.25) { self.finish() }
                return
            case .ready:
                break
            default:
                return
            }
            self.finishRequested = true
            self.flushPending()
        }
    }

    private func finishSending() {
        if audioSeconds < 0.15 {
            send(["type": "Terminate"])
            resolve(.success(""))
            return
        }
        phase = .finishing
        // Terminate flushes the final transcript. Do not race it against ForceEndpoint.
        send(["type": "Terminate"])
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .finishing else { return }
            Log.warn("AssemblyAI: termination timed out; refusing an incomplete transcript")
            self.resolve(.failure(STTError.timeout))
        }
        finishTimer = item
        q.asyncAfter(deadline: .now() + 30, execute: item)
    }

    func cancel() {
        q.async {
            self.finishTimer?.cancel()
            if self.phase == .ready { self.send(["type": "Terminate"]) }
            self.phase = .done
            self.resolved = true
            self.ws?.close()
        }
    }

    private func resolve(_ result: Result<String, Error>) {
        guard !resolved else { return }
        resolved = true
        finishTimer?.cancel()
        phase = .done
        ws?.close()
        DispatchQueue.main.async { self.onFinal?(result) }
    }
}
