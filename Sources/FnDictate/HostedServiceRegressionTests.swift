import Foundation

/// Isolated defaults and an in-process HTTP fixture. No real registration, key,
/// provider request, microphone access, or persistent user preference is used.
enum HostedServiceRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        let suite = "FnDictate-hosted-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = Settings(defaults: defaults, serviceDistributionMode: .hosted)
        check("hosted: fresh setup uses free service and Full rewrite", fresh.usesHostedService && fresh.dictationMode == .rewrite, "")
        check("hosted: unfinished fresh setup retains free service after restart", Settings(defaults: defaults, serviceDistributionMode: .hosted).usesHostedService, "")
        fresh.hasCompletedSetup = true
        check("hosted: completing fresh setup retains no-key routing after restart", Settings(defaults: defaults, serviceDistributionMode: .hosted).usesHostedService, "")
        fresh.sttEngine = .assemblyAI
        fresh.cleanupModel = .auto
        check("hosted: provider preferences cannot reinterpret a migrated free-service choice", Settings(defaults: defaults, serviceDistributionMode: .hosted).usesHostedService, "")

        // This must be a genuinely pre-migration installation, not the fresh
        // instance above after it completes setup.
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "hasCompletedSetup")
        defaults.set("verbatim", forKey: "dictationMode")
        let existing = Settings(defaults: defaults, serviceDistributionMode: .hosted)
        check("hosted: upgrade preserves personal connection and No rewrite", !existing.usesHostedService && existing.dictationMode == .verbatim, "")
        defaults.removeObject(forKey: "hasCompletedSetup")
        check("hosted: migrated personal connection remains personal after setup is reset", !Settings(defaults: defaults, serviceDistributionMode: .hosted).usesHostedService, "")
        existing.usesHostedService = true
        check("hosted: explicit free-service choice survives relaunch", Settings(defaults: defaults, serviceDistributionMode: .hosted).usesHostedService, "")
        existing.usesHostedService = false
        check("hosted: explicit personal-key choice survives relaunch", !Settings(defaults: defaults, serviceDistributionMode: .hosted).usesHostedService, "")

        // A personal distribution must work independently of the hosted deployment.
        // Its override never deletes keys or rewrites existing provider settings.
        defaults.removePersistentDomain(forName: suite)
        let personal = Settings(defaults: defaults, serviceDistributionMode: .personal)
        check("personal release: fresh setup selects API-key routing without a free-service option",
              !personal.usesHostedService && !personal.offersHostedService, "")
        check("personal release: fresh choice remains personal after restart",
              !Settings(defaults: defaults, serviceDistributionMode: .personal).usesHostedService, "")
        personal.hasCompletedSetup = true
        personal.sttEngine = .assemblyAI
        personal.cleanupModel = .sonnet5
        personal.openAIBaseURL = "https://api.example.com"
        let retained = Settings(defaults: defaults, serviceDistributionMode: .personal)
        check("personal release: existing provider choices, endpoint and completed setup survive",
              retained.sttEngine == .assemblyAI && retained.cleanupModel == .sonnet5 &&
              retained.openAIBaseURL == "https://api.example.com" && retained.hasCompletedSetup, "")
        personal.usesHostedService = true
        check("personal release: stale bindings cannot enable the unavailable hosted route",
              !personal.usesHostedService && !defaults.bool(forKey: "usesHostedService"), "")
        check("personal release: upgrading later to hosted does not replace an explicit personal choice",
              !Settings(defaults: defaults, serviceDistributionMode: .hosted).usesHostedService, "")

        defaults.set(true, forKey: "usesHostedService")
        let hostedChoiceInPersonalBuild = Settings(defaults: defaults, serviceDistributionMode: .personal)
        check("personal release: a previous hosted choice is inactive without destroying its preference",
              !hostedChoiceInPersonalBuild.usesHostedService && defaults.bool(forKey: "usesHostedService"), "")
        hostedChoiceInPersonalBuild.usesHostedService = true
        check("personal release: a rejected hosted selection does not erase the dormant saved choice",
              !hostedChoiceInPersonalBuild.usesHostedService && defaults.bool(forKey: "usesHostedService"), "")
        check("personal release: a later hosted distribution restores the dormant connection choice",
              Settings(defaults: defaults, serviceDistributionMode: .hosted).usesHostedService, "")
        check("personal release: bundle mode selects the explicit personal distribution",
              ServiceDistributionMode.resolve("personal") == .personal, "")
        check("hosted release: hosted and legacy bundles retain their distribution behavior",
              ServiceDistributionMode.resolve("hosted") == .hosted && ServiceDistributionMode.resolve(nil) == .hosted, "")

        for value in ["http://api.example.com", "https://user:pass@api.example.com", "https://api.example.com/v1", "https://api.example.com/?secret=x", "https://localhost", "https://api.example.com#fragment", "https://api.example.com:8443"] {
            check("hosted: rejects unsafe service origin \(value)", HostedService.validatedOrigin(value) == nil, "")
        }
        check("hosted: accepts a public HTTPS origin", HostedService.validatedOrigin("https://api.example.com/") == "https://api.example.com", "")
        let transportError = URLError(.badServerResponse)
        let deniedResponse = HTTPURLResponse(url: URL(string: "https://hosted.test/v1/realtime")!,
                                            statusCode: 401, httpVersion: nil, headerFields: nil)!
        let hostedFailure = WebSocketClient.reportedError(transportError, response: deniedResponse, refuseRedirects: true)
        if let handshake = hostedFailure as? WebSocketHandshakeError,
           case .rejected(statusCode: 401) = handshake {
            check("hosted: handshake rejection retains HTTP401 for recovery", true, "")
        } else { check("hosted: handshake rejection retains HTTP401 for recovery", false, "") }
        let directFailure = WebSocketClient.reportedError(transportError, response: deniedResponse, refuseRedirects: false)
        check("hosted: direct-provider transport errors keep their previous behavior", (directFailure as? URLError)?.code == .badServerResponse, "")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HostedRegistrationFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let access = HostedAccess(defaults: defaults, session: session)
        HostedRegistrationFixture.reset()
        var done = false
        var results: [(String, Bool)] = []
        let task = Task { @MainActor in
            do {
                async let a = access.token(base: "https://hosted.test")
                async let b = access.token(base: "https://hosted.test")
                let pair = try await (a, b)
                results.append(("concurrent transcription/cleanup share one registration", pair.0 == pair.1 && HostedRegistrationFixture.requestCount == 1))
                let cached = try await access.token(base: "https://hosted.test")
                results.append(("unexpired access reuses its token", cached == pair.0 && HostedRegistrationFixture.requestCount == 1))
                await access.invalidate()
                let renewed = try await access.token(base: "https://hosted.test")
                results.append(("invalidating access reconnects on next retry", HostedRegistrationFixture.requestCount == 2))
                await access.invalidate(base: "https://hosted.test", rejectedToken: pair.0)
                let afterOldRejection = try await access.token(base: "https://hosted.test")
                results.append(("a late rejected old token cannot invalidate newer access", afterOldRejection == renewed && renewed != pair.0 && HostedRegistrationFixture.requestCount == 2))
                await access.invalidate(base: "https://another.test", rejectedToken: renewed)
                _ = try await access.token(base: "https://hosted.test")
                results.append(("token rejection cannot invalidate another service origin", HostedRegistrationFixture.requestCount == 2))
                await access.invalidate(base: "https://hosted.test", rejectedToken: renewed)
                let afterRejection = try await access.token(base: "https://hosted.test")
                results.append(("retry registers fresh access after its cached token is rejected", afterRejection != renewed && HostedRegistrationFixture.requestCount == 3))
                let id = defaults.string(forKey: "hostedInstallationID")
                results.append(("reconnect preserves a random installation identity", id.flatMap(UUID.init(uuidString:)) != nil && HostedRegistrationFixture.installations.count == 1))
                for base in ["https://expired.test", "https://malformed.test", "https://denied.test"] {
                    do {
                        _ = try await access.token(base: base)
                        results.append(("rejects \(base)", false))
                    } catch { results.append(("rejects \(base)", true)) }
                }
                results.append(("registration carries no API authorization or user content", HostedRegistrationFixture.safeRequests))

                let statusConfig = URLSessionConfiguration.ephemeral
                statusConfig.protocolClasses = [HostedStatusFixture.self]
                let statusSession = URLSession(configuration: statusConfig)
                defer { statusSession.invalidateAndCancel() }
                let service = HostedService(baseURL: "https://status.test", session: statusSession)
                HostedStatusFixture.reset()
                HostedStatusFixture.enqueue(delay: 0, status: 200)
                await service.refresh()
                results.append(("a successful status request makes the service ready", service.state == .ready))

                HostedStatusFixture.enqueue(delay: 0.15, status: 503)
                let staleFailure = Task { await service.refresh() }
                try await waitForStatusRequests(2)
                HostedStatusFixture.enqueue(delay: 0.01, status: 200)
                await service.refresh()
                await staleFailure.value
                results.append(("an older delayed failure cannot overwrite newer readiness", service.state == .ready))

                HostedStatusFixture.enqueue(delay: 0.15, status: 200)
                let staleSuccess = Task { await service.refresh() }
                try await waitForStatusRequests(4)
                HostedStatusFixture.enqueue(delay: 0.01, status: 503)
                await service.refresh()
                await staleSuccess.value
                if case .unavailable = service.state {
                    results.append(("an older success cannot hide a newer service failure", true))
                } else { results.append(("an older success cannot hide a newer service failure", false)) }

                HostedStatusFixture.enqueue(delay: 0, status: 200)
                await service.refresh()
                HostedStatusFixture.enqueue(delay: 0.15, status: 503)
                let dismissedView = Task { await service.refresh() }
                try await waitForStatusRequests(7)
                dismissedView.cancel()
                await dismissedView.value
                results.append(("cancelling a view status check preserves existing readiness", service.state == .ready))

                let startupService = HostedService(baseURL: "https://status.test", session: statusSession)
                HostedStatusFixture.enqueue(delay: 0.15, status: 200)
                let startupCheck = Task { await startupService.refresh() }
                try await waitForStatusRequests(8)
                HostedStatusFixture.enqueue(delay: 0.15, status: 503)
                let temporaryView = Task { await startupService.refresh() }
                try await waitForStatusRequests(9)
                temporaryView.cancel()
                await temporaryView.value
                await startupCheck.value
                results.append(("cancelled newer view does not suppress pending startup readiness", startupService.state == .ready))
            } catch { results.append(("registration fixture completes", false)) }
            done = true
        }
        let end = Date().addingTimeInterval(8)
        while !done && Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        task.cancel()
        check("hosted: registration checks finish within deadline", done, "")
        for result in results { check("hosted: " + result.0, result.1, "") }
    }

    private static func waitForStatusRequests(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(1)
        while HostedStatusFixture.requestCount < count {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Controlled response order exercises actual URLSession cancellation, without a
/// live service or making timing depend on DNS/network availability.
private final class HostedStatusFixture: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [(delay: TimeInterval, status: Int)] = []
    private static var count = 0
    private let deliveryLock = NSLock()
    private var stopped = false
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset() { lock.lock(); count = 0; responses = []; lock.unlock() }
    static func enqueue(delay: TimeInterval, status: Int) {
        lock.lock(); responses.append((delay, status)); lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "status.test" && request.url?.path == "/v1/status"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let response = Self.responses.isEmpty ? (delay: 0.0, status: 500) : Self.responses.removeFirst()
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { [self] in
            deliveryLock.lock(); defer { deliveryLock.unlock() }
            guard !stopped else { return }
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"ready\":true}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { deliveryLock.lock(); stopped = true; deliveryLock.unlock() }
}

private final class HostedRegistrationFixture: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    private static var ids = Set<String>()
    private static var safe = true
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static var installations: Set<String> { lock.lock(); defer { lock.unlock() }; return ids }
    static var safeRequests: Bool { lock.lock(); defer { lock.unlock() }; return safe }
    static func reset() { lock.lock(); count = 0; ids = []; safe = true; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        Self.lock.lock()
        Self.count += 1
        let sequence = Self.count
        if let id = obj?["installation_id"] as? String { Self.ids.insert(id) }
        Self.safe = Self.safe && request.value(forHTTPHeaderField: "Authorization") == nil && obj?.keys.count == 1 && request.url?.path == "/v1/installations"
        Self.lock.unlock()
        let host = request.url!.host!
        let response = HTTPURLResponse(url: request.url!, statusCode: host == "denied.test" ? 429 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let data = host == "malformed.test" ? Data("{}".utf8) : try! JSONSerialization.data(withJSONObject: ["token": "synthetic-installation-token-\(sequence)", "expires_at": Date().timeIntervalSince1970 + (host == "expired.test" ? -10 : 3600)])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
