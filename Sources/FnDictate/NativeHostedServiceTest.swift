import Foundation

/// Runs the real Swift HTTP/WebSocket clients against service/test/native-fixture.mjs.
/// This checks the native-to-Worker contract, not recognition accuracy or deployment.
/// It requires loopback and isolated test storage; it never reads an operator key.
enum NativeHostedServiceTest {
    static func run(_ args: [String]) -> Bool {
        guard args.count > 2, args.contains("--ui-test"),
              let parts = URLComponents(string: args[2]), parts.scheme == "http",
              parts.host == "127.0.0.1", parts.port != nil, parts.user == nil,
              parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty else {
            print("usage: --hosted-selftest http://127.0.0.1:PORT --ui-test [--report PATH]")
            return false
        }
        let base = args[2]
        let suite = "ExpertiseDictation-native-hosted-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = HostedAccess(defaults: defaults)
        let config = STTConfig(languages: ["en", "zh"], prompt: "Synthetic fixture only.",
                               keywords: ["Expertise"], delay: .low, chineseVariant: .simplified)
        let engine = OpenAIRealtimeSTT(apiKey: "", baseURL: base, config: config, model: "gpt-live-transcribe",
            socketFactory: { url, _ in HostedSocket(url: url, base: base, access: access) })
        var checks: [(String, Bool)] = []
        var done = false
        var final: Result<String, Error>?
        var finals = 0
        var partials = 0
        var metrics: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(35)
        engine.onPartial = { _ in partials += 1 }
        engine.onFinal = { value in finals += 1; final = value }
        let task = Task { @MainActor in
            do {
                let before = try await fixtureStatus(base)
                guard before["fixture"] as? Bool == true,
                      before["upstreamConnections"] as? Int == 0,
                      before["chatRequests"] as? Int == 0 else {
                    throw HostedServiceError.unavailable("Start a fresh local fixture before this test.")
                }
                async let first = access.token(base: base)
                async let second = access.token(base: base)
                let pair = try await (first, second)
                checks.append(("anonymous access is shared by native clients", pair.0 == pair.1 && !pair.0.isEmpty))

                // Queue a full second before the WebSocket handshake; finish must wait
                // for registration, session readiness, buffered audio and the final event.
                engine.connect()
                engine.sendAudio(Data(repeating: 0, count: 48_000))
                engine.finish()
                let cleaned = try await HostedLLMClient(baseURL: base, access: access)
                    .complete(system: "Preserve the synthetic fixture.", user: "Synthetic text only.", maxTokens: 128, timeout: 10)
                checks.append(("native cleanup reaches the restricted Worker route", cleaned == "Gateway fixture cleaned text. 保留中文。"))
                while final == nil && Date() < deadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                let text = try final?.get()
                checks.append(("queued audio completes through native WebSocket and Worker", text == "Gateway fixture speech. 保留中文。"))
                checks.append(("partial and exactly one final reach the main queue", partials > 0 && finals == 1))
                engine.cancel()
                try await Task.sleep(nanoseconds: 350_000_000)
                metrics = try await fixtureStatus(base)
                checks.append(("fixture received all PCM bytes and one commit", metrics["audioBytes"] as? Int == 48_000 && metrics["commits"] as? Int == 1))
                checks.append(("one audio and one cleanup upstream operation", metrics["upstreamConnections"] as? Int == 1 && metrics["chatRequests"] as? Int == 1))
                checks.append(("completed socket closes its upstream", (metrics["closedUpstreams"] as? Int ?? 0) >= 1))
                checks.append(("no unexpected upstream destination", metrics["unexpectedUpstreams"] as? Int == 0))

                let cancelled = HostedSocket(url: try APIEndpoint.url(baseURL: base, path: "/v1/realtime", webSocket: true,
                    queryItems: [URLQueryItem(name: "intent", value: "transcription")]), base: base, access: access)
                cancelled.close()
                cancelled.connect()
                try await Task.sleep(nanoseconds: 150_000_000)
                let after = try await fixtureStatus(base)
                checks.append(("dismissed socket cannot create a later upstream connection", after["upstreamConnections"] as? Int == 1))

                // Reject a token already cached by a completed native session. A
                // user-initiated Retry must register again; no automatic auth loop.
                var arm = URLRequest(url: URL(string: base + "/__fixture/reject-next-handshake")!)
                arm.httpMethod = "POST"; arm.timeoutInterval = 5
                let (_, armedResponse) = try await HostedTransport.session.data(for: arm)
                guard (armedResponse as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let rejected = HostedSocket(url: try APIEndpoint.url(baseURL: base, path: "/v1/realtime", webSocket: true,
                    queryItems: [URLQueryItem(name: "intent", value: "transcription")]), base: base, access: access)
                var rejection: Error?
                var rejectedClosed = false
                var rejectedOpened = false
                rejected.onOpen = { DispatchQueue.main.async { rejectedOpened = true } }
                rejected.onClose = { error in DispatchQueue.main.async { rejection = error; rejectedClosed = true } }
                rejected.connect()
                while !rejectedClosed && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
                let unauthorized: Bool
                if let error = rejection as? WebSocketHandshakeError, case .rejected(statusCode: 401) = error {
                    unauthorized = true
                } else { unauthorized = false }
                checks.append(("real native WebSocket reports its cached-token HTTP401 rejection", rejectedClosed && !rejectedOpened && unauthorized))
                rejected.close()
                let rejectedStatus = try await fixtureStatus(base)
                checks.append(("authentication failure does not automatically retry", rejectedStatus["registrations"] as? Int == 1 && rejectedStatus["rejectedHandshakes"] as? Int == 1))

                let retry = OpenAIRealtimeSTT(apiKey: "", baseURL: base, config: config, model: "gpt-live-transcribe",
                    socketFactory: { url, _ in HostedSocket(url: url, base: base, access: access) })
                var retried: Result<String, Error>?
                retry.onFinal = { retried = $0 }
                retry.connect(); retry.sendAudio(Data(repeating: 0, count: 48_000)); retry.finish()
                while retried == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
                checks.append(("explicit retry reconnects and returns the full fixture transcript", (try? retried?.get()) == "Gateway fixture speech. 保留中文。"))
                retry.cancel()
                metrics = try await fixtureStatus(base)
                checks.append(("retry replaced the rejected cached access with one new registration", metrics["registrations"] as? Int == 2 && metrics["upstreamConnections"] as? Int == 2))
            } catch {
                // Keep reports free of remote bodies or installation credentials.
                checks.append(("native hosted contract completed without error", false))
                print("Hosted fixture failed: \(type(of: error))")
            }
            done = true
        }
        while !done && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        task.cancel()
        engine.cancel()
        checks.append(("test completes within 35 seconds", done))
        for (name, pass) in checks { print("\(pass ? "PASS" : "FAIL"): \(name)") }
        let success = checks.allSatisfy { $0.1 }
        if let index = args.firstIndex(of: "--report"), index + 1 < args.count {
            let report: [String: Any] = [
                "passed": success, "scope": "native Swift to local Worker with synthetic upstream; no live provider or microphone",
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "checks": checks.map { ["name": $0.0, "passed": $0.1] as [String: Any] }, "fixture_metrics": metrics
            ]
            do {
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
            } catch { print("FAIL: could not save hosted contract report"); return false }
        }
        return success
    }

    private static func fixtureStatus(_ base: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: base + "/__fixture/status")!)
        request.timeoutInterval = 5
        let (data, response) = try await HostedTransport.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["fixture"] as? Bool == true else {
            throw HostedServiceError.unavailable("A local synthetic fixture is required.")
        }
        return body
    }
}
