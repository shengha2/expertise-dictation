import Foundation

enum LLMError: LocalizedError {
    case notConfigured(String)
    case http(Int, String)
    case badResponse(String)
    case refused
    case outputLimit

    var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return s
        case .http(let code, let body): return LLMError.describe(code: code, body: body)
        case .badResponse(let s): return "Unexpected response: \(s.prefix(200))"
        case .refused: return "The model declined the request"
        case .outputLimit: return "The model reached its output limit; the complete original transcript was kept"
        }
    }
}

extension LLMError {
    /// Pull the human sentence out of a provider error body.
    static func describe(code: Int, body: String) -> String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String, !msg.isEmpty {
            return msg
        }
        switch code {
        case 401, 403: return "The API key was rejected (HTTP \(code))"
        case 429: return "Rate limited or out of credits (HTTP 429)"
        default: return "HTTP \(code): \(body.prefix(200))"
        }
    }
}

protocol LLMClient {
    var name: String { get }
    /// Opt in only when overlapping requests on the same client are independent and safe.
    var supportsConcurrentRequests: Bool { get }
    func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String
}

extension LLMClient {
    var supportsConcurrentRequests: Bool { false }
}

enum LLMFactory {
    static func make(model requested: CleanupModel, settings: Settings) throws -> LLMClient {
        if settings.usesHostedService {
            guard let base = HostedService.baseURL else {
                throw LLMError.notConfigured("The free service has not been connected to this build yet.")
            }
            return HostedLLMClient(baseURL: base)
        }
        let model = requested.resolved
        guard let key = Keychain.apiKey(model.keychainAccount) else {
            if requested == .auto {
                throw LLMError.notConfigured("Add an OpenAI or Anthropic API key in Preferences → More options → Connection")
            }
            throw LLMError.notConfigured("Add your \(model.providerName) API key in Preferences → More options → Connection, or set the clean-up model to Auto")
        }
        if model.isAnthropic {
            return AnthropicClient(apiKey: key, baseURL: settings.anthropicBaseURL, model: model.rawValue)
        }
        return OpenAIChatClient(apiKey: key, baseURL: settings.openAIBaseURL, model: model.rawValue,
                                priority: settings.openAIPriorityTier)
    }
}

private func jsonRequest(url: URL, headers: [String: String], body: [String: Any], timeout: TimeInterval) -> URLRequest {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = timeout
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    return req
}

private let llmSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.waitsForConnectivity = false
    cfg.httpMaximumConnectionsPerHost = 4
    return URLSession(configuration: cfg)
}()

/// Opens the HTTPS connection to the clean-up provider while the user is still speaking, so the
/// first request after idle does not pay for TLS and HTTP/2 setup (measured 150–200 ms). The
/// request carries no key; the provider answers 401 and the pooled connection stays open.
enum LLMWarmup {
    private static var last: Date?
    private static let minimumInterval: TimeInterval = 15

    static func prewarm(settings: Settings) {
        if settings.usesHostedService { return } // Never open unmetered idle hosted sessions.
        let now = Date()
        if let last, now.timeIntervalSince(last) < minimumInterval { return }
        last = now
        let base = settings.cleanupModel.isAnthropic ? settings.anthropicBaseURL : settings.openAIBaseURL
        guard let url = try? APIEndpoint.url(baseURL: base, path: "/v1/models") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        llmSession.dataTask(with: req) { _, _, _ in }.resume()
    }
}

/// Anthropic Messages API (raw HTTP). Thinking is disabled explicitly on Sonnet 5 so the reply
/// starts immediately; Haiku 4.5 has no thinking unless asked. No sampling parameters are sent
/// (Sonnet 5 rejects them).
struct AnthropicClient: LLMClient {
    let apiKey: String
    let baseURL: String
    let model: String
    var name: String { model }
    var supportsConcurrentRequests: Bool { true }

    func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        let url = try APIEndpoint.url(baseURL: baseURL, path: "/v1/messages")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": user]],
        ]
        if model.hasPrefix("claude-sonnet-5") || model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable") {
            body["thinking"] = ["type": "disabled"]
        }
        var headers = ["anthropic-version": "2023-06-01"]
        if let token = ProcessInfo.processInfo.environment["ANTHROPIC_AUTH_TOKEN"], !token.isEmpty, apiKey == token {
            headers["Authorization"] = "Bearer \(token)"
            headers["anthropic-beta"] = "oauth-2025-04-20"
        } else {
            headers["x-api-key"] = apiKey
        }
        let req = jsonRequest(url: url, headers: headers, body: body, timeout: timeout)
        let (data, resp) = try await llmSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.badResponse("not JSON") }
        if (obj["stop_reason"] as? String) == "refusal" { throw LLMError.refused }
        try Self.validateStopReason(obj["stop_reason"] as? String)
        guard let content = obj["content"] as? [[String: Any]] else { throw LLMError.badResponse(String(data: data, encoding: .utf8) ?? "") }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        return text
    }

    static func validateStopReason(_ reason: String?) throws {
        if reason == "max_tokens" || reason == "model_context_window_exceeded" { throw LLMError.outputLimit }
        guard reason == "end_turn" || reason == "stop_sequence" else { throw LLMError.badResponse("The provider did not return a completed text response") }
    }
}

/// OpenAI Chat Completions with reasoning turned off for lowest latency.
struct OpenAIChatClient: LLMClient {
    let apiKey: String
    let baseURL: String
    let model: String
    /// Priority processing: measured about a third faster on GPT-5.6 Luna, at a higher token price.
    var priority: Bool = false
    var session: URLSession = llmSession
    var name: String { model }
    var supportsConcurrentRequests: Bool { true }

    func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        let url = try APIEndpoint.url(baseURL: baseURL, path: "/v1/chat/completions")
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "max_completion_tokens": maxTokens,
            "reasoning_effort": "none",
        ]
        if priority { body["service_tier"] = "priority" }
        var req = jsonRequest(url: url, headers: ["Authorization": "Bearer \(apiKey)"], body: body, timeout: timeout)
        var (data, resp) = try await session.data(for: req)
        var code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if priority, !(200..<300).contains(code), (String(data: data, encoding: .utf8) ?? "").contains("service_tier") {
            // Account or model without priority processing: fall back to the default tier, once.
            Log.warn("OpenAI rejected service_tier=priority (HTTP \(code)); retrying on the default tier")
            body.removeValue(forKey: "service_tier")
            req = jsonRequest(url: url, headers: ["Authorization": "Bearer \(apiKey)"], body: body, timeout: timeout)
            (data, resp) = try await session.data(for: req)
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        }
        guard (200..<300).contains(code) else { throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw LLMError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }
        try Self.validateFinishReason(choice["finish_reason"] as? String)
        return text
    }

    static func validateFinishReason(_ reason: String?) throws {
        if reason == "length" { throw LLMError.outputLimit }
        guard reason == "stop" else { throw LLMError.badResponse("The provider did not return a completed text response") }
    }
}
