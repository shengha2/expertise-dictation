import Foundation
import Combine

enum HostedServiceState: Equatable {
    case checking
    case ready
    case unavailable(String)

    var message: String {
        switch self {
        case .checking: return "Checking the free service…"
        case .ready: return "Free to use. No account or API key needed."
        case .unavailable(let message): return message
        }
    }
}

enum HostedServiceError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

/// Only a public HTTPS origin goes into the app bundle. Provider credentials live
/// on the service. Development builds without a deployment fail visibly and closed.
final class HostedService: ObservableObject {
    static let shared = HostedService()
    @Published private(set) var state: HostedServiceState = .checking
    private let configuredBaseURL: String?
    private let session: URLSession
    private var refreshGeneration = 0 // Accessed only by the main-actor refresh method.
    private var publishedGeneration = 0

    init(baseURL: String? = nil, session: URLSession = HostedTransport.session) {
        configuredBaseURL = baseURL ?? Self.baseURL
        self.session = session
    }

    static var baseURL: String? {
        validatedOrigin(Bundle.main.object(forInfoDictionaryKey: "ExpertiseServiceURL") as? String)
    }

    static func validatedOrigin(_ value: String?) -> String? {
        guard let value, let c = URLComponents(string: value), c.scheme == "https",
              let host = c.host, !host.isEmpty, host != "localhost", !host.hasSuffix(".localhost"),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port == nil || c.port == 443, c.path.isEmpty || c.path == "/" else { return nil }
        return "https://\(host)"
    }

    @MainActor
    func refresh() async {
        guard !Task.isCancelled else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        if UITestEnvironment.active {
            publishedGeneration = generation
            state = .unavailable("Service requests are disabled in this UI preview.")
            return
        }
        guard let base = configuredBaseURL else {
            publishedGeneration = generation
            state = .unavailable("The free service has not been connected to this build yet.")
            return
        }
        do {
            var request = URLRequest(url: try APIEndpoint.url(baseURL: base, path: "/v1/status"))
            request.timeoutInterval = 8
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["ready"] as? Bool == true else {
                throw HostedServiceError.unavailable("The free service is temporarily unavailable. Please try again later.")
            }
            guard !Task.isCancelled, generation >= publishedGeneration else { return }
            publishedGeneration = generation
            state = .ready
        } catch {
            // SwiftUI cancels view tasks when a sheet closes. That is not a service
            // outage, and an older request must not overwrite a newer result.
            // A cancelled newer view request also must not suppress a pending
            // startup check: order publications, not merely request starts.
            guard !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled,
                  generation >= publishedGeneration else { return }
            publishedGeneration = generation
            state = .unavailable("Cannot reach the free service. Check your connection and try again.")
        }
    }
}

/// No redirect may take an installation credential or dictated content to a
/// different destination. Cookies and on-disk HTTP caches are not needed here.
private final class HostedRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum HostedTransport {
    private static let policy = HostedRedirectPolicy()
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: policy, delegateQueue: nil)
    }()
}

/// Short-lived anonymous installation access is separate from an OpenAI API key.
/// The token is kept only in memory. The random installation ID is not an account
/// and contains no device identifier, email address, or transcript.
actor HostedAccess {
    static let shared = HostedAccess()
    private let defaults: UserDefaults
    private let session: URLSession
    private var cached: (base: String, token: String, expiry: Date)?
    private var registration: (id: UUID, base: String, task: Task<(String, Date), Error>)?

    init(defaults: UserDefaults = .standard, session: URLSession = HostedTransport.session) {
        self.defaults = defaults
        self.session = session
    }

    func token(base: String) async throws -> String {
        if let cached, cached.base == base, cached.expiry.timeIntervalSinceNow > 60 { return cached.token }
        if let registration, registration.base == base { return try await registration.task.value.0 }
        let installation = defaults.string(forKey: "hostedInstallationID").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(installation.uuidString, forKey: "hostedInstallationID")
        let task = Task<(String, Date), Error> {
            var request = URLRequest(url: try APIEndpoint.url(baseURL: base, path: "/v1/installations"))
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["installation_id": installation.uuidString.lowercased()])
            let (data, response) = try await self.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = body["token"] as? String, !token.isEmpty, token.utf8.count < 4096,
                  let expiry = body["expires_at"] as? Double, expiry > Date().timeIntervalSince1970 + 60 else {
                throw HostedServiceError.unavailable("The free service could not connect. Please try again later. Your recording stays saved on this Mac.")
            }
            return (token, Date(timeIntervalSince1970: expiry))
        }
        let id = UUID()
        registration = (id, base, task)
        defer { if registration?.id == id { registration = nil } }
        let (token, expiry) = try await task.value
        cached = (base, token, expiry)
        return token
    }

    func invalidate() { cached = nil }
    func invalidate(base: String, rejectedToken: String) {
        guard cached?.base == base, cached?.token == rejectedToken else { return }
        cached = nil
    }
}

struct HostedLLMClient: LLMClient {
    let baseURL: String
    var access: HostedAccess = .shared
    var name: String { "gpt-6-luna" }

    func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        let token = try await access.token(base: baseURL)
        // This client uses the same strict result parser as the direct provider,
        // but the anonymous credential is only sent to our configured service.
        do {
            return try await OpenAIChatClient(apiKey: token, baseURL: baseURL, model: name,
                                         priority: false, session: HostedTransport.session)
            .complete(system: system, user: user, maxTokens: maxTokens, timeout: timeout)
        } catch LLMError.http(401, _) {
            await access.invalidate(base: baseURL, rejectedToken: token)
            throw HostedServiceError.unavailable("The free connection expired. Please retry your saved recording to reconnect.")
        }
    }
}

/// Delays the normal socket connection until anonymous registration finishes.
/// OpenAIRealtimeSTT owns the bounded audio buffer until onOpen; close cancels
/// registration and cannot open a late socket after a user has dismissed a session.
final class HostedSocket: STTSocket {
    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onClose: ((Error?) -> Void)?
    private let url: URL
    private let base: String
    private let access: HostedAccess
    private let lock = NSLock()
    private var closed = false
    private var socket: WebSocketClient?
    private var connecting: Task<Void, Never>?

    init(url: URL, base: String, access: HostedAccess = .shared) {
        self.url = url; self.base = base; self.access = access
    }
    func connect() {
        lock.lock()
        guard !closed, connecting == nil, socket == nil else { lock.unlock(); return }
        connecting = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await self.access.token(base: self.base)
                try Task.checkCancellation()
                self.open(token: token)
            } catch { self.fail(error) }
        }
        lock.unlock()
    }
    private func open(token: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let client = WebSocketClient(url: url, headers: ["Authorization": "Bearer \(token)"], refuseRedirects: true)
        client.onOpen = { [weak self] in self?.onOpen?() }
        client.onText = { [weak self] in self?.onText?($0) }
        client.onClose = { [weak self] in self?.fail($0, rejectedToken: token) }
        socket = client
        client.connect()
    }
    private func fail(_ error: Error?, rejectedToken: String? = nil) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let active = socket
        lock.unlock()
        active?.close()
        if let handshake = error as? WebSocketHandshakeError,
           case .rejected(statusCode: 401) = handshake,
           let rejectedToken {
            // Invalidate before notifying the owner so an explicit Retry cannot
            // race ahead and reuse this rejected token. A late old failure must
            // not remove access issued to a newer session.
            Task {
                await access.invalidate(base: base, rejectedToken: rejectedToken)
                onClose?(error)
            }
            return
        }
        onClose?(error ?? HostedServiceError.unavailable("The free service disconnected. Your recording is saved for retry."))
    }
    func send(text: String) { lock.lock(); let active = socket; lock.unlock(); active?.send(text: text) }
    func send(data: Data) { lock.lock(); let active = socket; lock.unlock(); active?.send(data: data) }
    func ping() { lock.lock(); let active = socket; lock.unlock(); active?.ping() }
    func close() {
        lock.lock(); closed = true; let task = connecting; let active = socket; lock.unlock()
        task?.cancel(); active?.close()
    }
}
