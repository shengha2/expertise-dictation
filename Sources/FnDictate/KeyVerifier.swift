import Foundation

/// Read-only authentication checks. Model access and available credits require a real dictation test.
enum KeyVerifier {
    static func verify(account: String, key: String, settings: Settings) async -> Result<String, Error> {
        guard !UITestEnvironment.active else { return .failure(LLMError.notConfigured("Provider requests are disabled in this UI preview.")) }
        let trimmed = Keychain.sanitize(key)
        guard !trimmed.isEmpty else { return .failure(LLMError.notConfigured("No key entered")) }
        var req: URLRequest
        do {
        switch account {
        case "openai":
            req = URLRequest(url: try APIEndpoint.url(baseURL: settings.openAIBaseURL, path: "/v1/models"))
            req.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        case "anthropic":
            req = URLRequest(url: try APIEndpoint.url(baseURL: settings.anthropicBaseURL, path: "/v1/models"))
            req.setValue(trimmed, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case "assemblyai":
            req = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript?limit=1")!)
            req.setValue(trimmed, forHTTPHeaderField: "Authorization")
        default:
            return .failure(LLMError.notConfigured("Unknown provider"))
        }
        } catch { return .failure(error) }
        req.timeoutInterval = 12
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200..<300:
                return .success("Key accepted. Use the dictation test to check model access and credits.")
            case 401, 403:
                return .failure(LLMError.notConfigured("The key was rejected. Check that you copied the whole key."))
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure(LLMError.http(code, body))
            }
        } catch {
            return .failure(error)
        }
    }

}
