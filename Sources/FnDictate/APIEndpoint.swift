import Foundation

/// Accept either a provider origin or the usual origin + /v1 API base URL.
enum APIEndpoint {
    static func url(baseURL: String, path: String, webSocket: Bool = false,
                    queryItems: [URLQueryItem] = []) throws -> URL {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.contains(where: { $0.isWhitespace }),
              var components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw LLMError.notConfigured("Enter a valid API base URL, such as https://api.openai.com or https://api.openai.com/v1")
        }
        var prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if prefix.split(separator: "/").last == "v1", suffix.hasPrefix("v1/") {
            suffix = String(suffix.dropFirst(3))
        }
        if !prefix.isEmpty { prefix += "/" }
        components.path = "/" + prefix + suffix
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        if webSocket { components.scheme = scheme == "https" ? "wss" : "ws" }
        guard let url = components.url else { throw LLMError.notConfigured("The API base URL is invalid") }
        return url
    }
}
