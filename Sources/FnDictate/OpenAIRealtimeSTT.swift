import Foundation

/// OpenAI Realtime API in transcription mode (`gpt-live-transcribe` streams deltas while you talk;
/// `gpt-transcribe` returns the text after commit). Audio is 24 kHz PCM16, sent as base64 in
/// ~100 ms chunks; turn detection is off so the whole hold is one item that we commit on release.
final class OpenAIRealtimeSTT: STTSession {
    let sampleRate: Double = 24000
    var onPartial: ((String) -> Void)?
    var onFinal: ((Result<String, Error>) -> Void)?
    var engineName: String { model }

    private enum Phase { case idle, connecting, ready, finishing, done }
    private let q = DispatchQueue(label: "com.hao.fndictate.openai-stt")
    private var phase: Phase = .idle
    private var ws: STTSocket?
    private let socketFactory: (URL, [String: String]) -> STTSocket
    private let apiKey: String
    private let baseURL: String
    private let config: STTConfig
    private let model: String
    private var pending = Data()        // audio waiting for the socket
    private var accum = Data()          // coalescing buffer
    private var audioSeconds: Double = 0
    private var partial = ""
    private var retriedMinimal = false
    private var finishTimer: DispatchWorkItem?
    private var pingTimer: DispatchSourceTimer?
    private let createdAt = Date()
    private var resolved = false
    private var finishRequestedAt: Date?
    private var lastServerError: String?

    init(apiKey: String, baseURL: String, config: STTConfig, model: String,
         socketFactory: @escaping (URL, [String: String]) -> STTSocket = { WebSocketClient(url: $0, headers: $1) }) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.config = config
        self.model = model
        self.socketFactory = socketFactory
    }

    var isUsable: Bool {
        q.sync { (phase == .connecting || phase == .ready) && Date().timeIntervalSince(createdAt) < 20 * 60 }
    }

    func connect() {
        q.async {
            guard self.phase == .idle else { return }
            self.phase = .connecting
            let url: URL
            do {
                url = try APIEndpoint.url(baseURL: self.baseURL, path: "/v1/realtime", webSocket: true,
                                          queryItems: [URLQueryItem(name: "intent", value: "transcription")])
            } catch {
                self.resolve(.failure(error))
                return
            }
            let ws = self.socketFactory(url, ["Authorization": "Bearer \(self.apiKey)"])
            ws.onOpen = { [weak self] in self?.q.async { self?.didOpen() } }
            ws.onText = { [weak self] text in self?.q.async { self?.didReceive(text) } }
            ws.onClose = { [weak self] err in self?.q.async { self?.didClose(err) } }
            self.ws = ws
            ws.connect()
            Log.info("OpenAI realtime: connecting (\(self.model))")
        }
    }

    private func didOpen() {
        guard phase == .connecting else { return }
        sendSessionUpdate(minimal: false)
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in self?.ws?.ping() }
        timer.resume()
        pingTimer = timer
    }

    private func sendSessionUpdate(minimal: Bool) {
        var transcription: [String: Any] = ["model": model]
        if !minimal {
            if !config.prompt.isEmpty { transcription["prompt"] = config.prompt }
            if !config.keywords.isEmpty { transcription["keywords"] = Array(config.keywords.prefix(100)) }
            if !config.languages.isEmpty { transcription["languages"] = config.languages }
            if model == "gpt-live-transcribe" { transcription["delay"] = config.delay.rawValue }
        }
        let session: [String: Any] = [
            "type": "transcription",
            "audio": ["input": [
                "format": ["type": "audio/pcm", "rate": 24000],
                "transcription": transcription,
                "noise_reduction": ["type": "near_field"],
                "turn_detection": NSNull(),
            ]],
        ]
        send(["type": "session.update", "session": session])
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        ws?.send(text: s)
    }

    private func didReceive(_ text: String) {
        guard phase != .done else { return }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "session.updated", "transcription_session.updated":
            if phase == .connecting {
                phase = .ready
                Log.info("OpenAI realtime: session ready")
                flushPending()
            }
        case "session.created", "transcription_session.created", "input_audio_buffer.committed", "input_audio_buffer.cleared":
            break
        case "conversation.item.input_audio_transcription.delta":
            if let delta = obj["delta"] as? String, phase == .ready || phase == .finishing {
                partial += delta
                let p = partial
                DispatchQueue.main.async { self.onPartial?(p) }
            }
        case "conversation.item.input_audio_transcription.completed":
            let transcript = (obj["transcript"] as? String) ?? partial
            if phase == .finishing {
                resolve(.success(transcript))
            } else {
                partial = transcript
            }
        case "conversation.item.input_audio_transcription.failed":
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "transcription failed"
            Log.error("OpenAI realtime: \(msg)")
            resolve(.failure(STTError.server(msg)))
        case "error":
            let err = obj["error"] as? [String: Any]
            let msg = (err?["message"] as? String) ?? text
            if phase == .finishing, err?["code"] as? String == "input_audio_buffer_commit_empty" {
                resolve(.success(""))
                return
            }
            Log.error("OpenAI realtime error: \(msg)")
            lastServerError = "OpenAI: \(msg)"
            let lower = msg.lowercased()
            let fatal = lower.contains("credit") || lower.contains("api key") || lower.contains("quota")
                || lower.contains("billing") || lower.contains("unauthorized")
            if phase == .connecting, !retriedMinimal, !fatal {
                // Most likely an optional field this account/model does not accept: retry bare.
                retriedMinimal = true
                sendSessionUpdate(minimal: true)
            } else if phase == .finishing {
                resolve(.failure(STTError.server(lastServerError!)))
            } else {
                resolve(.failure(STTError.server(lastServerError!)))
            }
        default:
            break
        }
    }

    private func didClose(_ error: Error?) {
        pingTimer?.cancel()
        pingTimer = nil
        if phase == .done { return }
        let wasFinishing = phase == .finishing
        phase = .done
        if let error {
            Log.warn("OpenAI realtime: closed with error: \(error.localizedDescription)")
        } else {
            Log.info("OpenAI realtime: closed")
        }
        let failure: Error = lastServerError.map { STTError.server($0) } ?? error ?? STTError.connection("closed")
        if wasFinishing {
            resolve(.failure(failure))
        } else if !resolved {
            // Closed while idle/warm: report so the controller can build a fresh session.
            resolved = true
            DispatchQueue.main.async { self.onFinal?(.failure(failure)) }
        }
    }

    func sendAudio(_ pcm16: Data) {
        q.async {
            switch self.phase {
            case .idle, .connecting:
                self.pending.append(pcm16)
            case .ready:
                self.accum.append(pcm16)
                self.audioSeconds += Double(pcm16.count) / 2 / self.sampleRate
                if self.accum.count >= 4800 { self.flushAccum() } // 100 ms
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
        flushAccum()
    }

    private func flushAccum() {
        guard !accum.isEmpty else { return }
        send(["type": "input_audio_buffer.append", "audio": accum.base64EncodedString()])
        accum.removeAll(keepingCapacity: true)
    }

    func finish() {
        q.async {
            // A quick accidental press may end before the handshake. It does not need a
            // provider response, and should never turn into a connection timeout banner.
            if self.phase == .connecting || self.phase == .ready {
                let seconds = self.audioSeconds + Double(self.pending.count) / 2 / self.sampleRate
                if seconds < 0.15 {
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
            self.flushPending()
            self.phase = .finishing
            self.send(["type": "input_audio_buffer.commit"])
            let timeout = max(30.0, min(120.0, self.audioSeconds * 0.75))
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .finishing else { return }
                Log.warn("OpenAI realtime: final transcript timed out; refusing an incomplete transcript")
                self.resolve(.failure(STTError.timeout))
            }
            self.finishTimer = item
            self.q.asyncAfter(deadline: .now() + timeout, execute: item)
        }
    }

    func cancel() {
        q.async {
            self.finishTimer?.cancel()
            self.pingTimer?.cancel()
            self.pingTimer = nil
            if self.phase == .ready { self.send(["type": "input_audio_buffer.clear"]) }
            self.phase = .done
            self.resolved = true
            self.ws?.close()
        }
    }

    private func resolve(_ result: Result<String, Error>) {
        guard !resolved else { return }
        resolved = true
        finishTimer?.cancel()
        pingTimer?.cancel()
        pingTimer = nil
        phase = .done
        ws?.close()
        DispatchQueue.main.async { self.onFinal?(result) }
    }
}
