import Foundation

/// "When I say X, type Y" rules. Applied by the LLM (as explicit rules) and again locally after any
/// clean-up, so they also work in Light and Verbatim modes and when the model misses one.
struct Replacement: Equatable, Identifiable {
    var id = UUID()
    var spoken: String
    var written: String
    static func == (a: Replacement, b: Replacement) -> Bool { a.spoken == b.spoken && a.written == b.written }
}

enum Replacements {
    /// One rule per line: `spoken => written` (also accepts `->`, `→`, `=`).
    static func parse(_ text: String) -> [Replacement] {
        var out: [Replacement] = []
        var seen = Set<String>()
        for rawLine in text.split(whereSeparator: { $0 == "\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var parts: [String] = []
            for sep in ["=>", "->", "→", "="] {
                if let r = line.range(of: sep) {
                    parts = [String(line[..<r.lowerBound]), String(line[r.upperBound...])]
                    break
                }
            }
            guard parts.count == 2 else { continue }
            let spoken = parts[0].trimmingCharacters(in: .whitespaces)
            let written = parts[1].trimmingCharacters(in: .whitespaces)
            guard !spoken.isEmpty, !written.isEmpty, !spoken.contains("<"), !written.contains("<"),
                  seen.insert(spoken.lowercased()).inserted else { continue }
            out.append(Replacement(spoken: spoken, written: written))
        }
        return out
    }

    static func serialize(_ rules: [Replacement]) -> String {
        rules.map { "\($0.spoken) => \($0.written)" }.joined(separator: "\n")
    }

    private static var cache: [String: NSRegularExpression] = [:]

    private static func regex(for spoken: String) -> NSRegularExpression? {
        if let r = cache[spoken] { return r }
        let hasCJK = spoken.unicodeScalars.contains { $0.properties.isIdeographic }
        // Tolerate the transcriber's spacing and hyphenation inside multi-word phrases.
        let tokens = spoken.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        // Latin words must stay separated ("my email" never matches "myemail"); CJK needs no separator.
        let body = tokens.joined(separator: hasCJK ? #"[\s\-]*"# : #"[\s\-]+"#)
        let pattern = hasCJK ? body : #"(?i)(?<![\p{L}\p{N}])"# + body + #"(?![\p{L}\p{N}])"#
        guard let r = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache[spoken] = r
        return r
    }

    /// Longest spoken forms first so "expertise ai live" wins over "expertise ai".
    static func apply(_ rules: [Replacement], to text: String) -> String {
        guard !rules.isEmpty else { return text }
        var s = text
        for rule in rules.sorted(by: { $0.spoken.count > $1.spoken.count }) {
            guard let re = regex(for: rule.spoken) else { continue }
            let emails = EmailAddressFormatting.ranges(in: s)
            let matches = re.matches(in: s, range: NSRange(s.startIndex..., in: s)).filter { match in
                // A dictionary word must not replace a username/domain fragment. An
                // explicit rule covering the complete address remains authoritative.
                !emails.contains { email in
                    NSIntersectionRange(match.range, email).length > 0 &&
                        !(match.range.location <= email.location && NSMaxRange(match.range) >= NSMaxRange(email))
                }
            }
            for match in matches.reversed() {
                if let range = Range(match.range, in: s) { s.replaceSubrange(range, with: rule.written) }
            }
        }
        return s
    }

    /// Lines for the clean-up prompt.
    static func promptRules(_ rules: [Replacement]) -> String {
        rules.map { "- when the transcript says “\($0.spoken)”, write “\($0.written)”" }.joined(separator: "\n")
    }
}
