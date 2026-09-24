import Foundation

/// API key store. Keys live in ~/Library/Application Support/FnDictate/keys.json, readable only by
/// this user (directory 0700, file 0600). The macOS Keychain was tried first, but an ad-hoc-signed
/// app's Keychain items are tied to the exact binary, so every update produced a "enter your login
/// keychain password" prompt. Environment variables (OPENAI_API_KEY, ANTHROPIC_API_KEY,
/// ASSEMBLYAI_API_KEY) remain a fallback for development.
enum Keychain {
    private static let envNames: [String: String] = [
        "openai": "OPENAI_API_KEY",
        "anthropic": "ANTHROPIC_API_KEY",
        "assemblyai": "ASSEMBLYAI_API_KEY",
    ]

    static let directory: URL = {
        if let test = UITestEnvironment.storageRoot { return test }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FnDictate", isDirectory: true)
    }()
    static let fileURL = directory.appendingPathComponent("keys.json")

    private static let lock = NSLock()
    private static var cache: [String: String]?

    private static func load() -> [String: String] {
        if let cache { return cache }
        var dict: [String: String] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            dict = obj
        }
        cache = dict
        return dict
    }

    private static func persist(_ dict: [String: String]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            cache = dict
            return true
        } catch {
            Log.error("Key store write failed: \(error)")
            return false
        }
    }

    /// API keys are ASCII: drop whitespace, control characters and invisible Unicode (zero-width
    /// spaces, BOMs, smart quotes) that sneak in from chat apps, PDFs and terminals.
    static func sanitize(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars where (0x21...0x7E).contains(scalar.value) {
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    static func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let v = load()[account], !v.isEmpty else { return nil }
        return v
    }

    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var dict = load()
        let clean = sanitize(value)
        if clean.isEmpty { dict.removeValue(forKey: account) } else { dict[account] = clean }
        return persist(dict)
    }

    /// Stored key first, then environment (handy when launched from a terminal during development).
    static func apiKey(_ account: String) -> String? {
        if let v = get(account) { return v }
        if UITestEnvironment.active { return nil }
        if let env = envNames[account], let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        return nil
    }
}
