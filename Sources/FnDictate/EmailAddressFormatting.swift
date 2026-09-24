import Foundation

/// Email spelling is a formatting operation, not a rewrite. Only join explicitly spelled
/// characters and punctuation around a complete domain; never infer missing letters or a TLD.
enum EmailAddressFormatting {
    static let recognitionHint = "Email addresses may be dictated letter by letter. Keep every letter and digit, including repeats. In a clearly dictated address, at/艾特 means @ and dot/点 means a dot; preserve plus tags, hyphens and underscores. Gmail is the provider name. Never guess missing characters or an unspoken domain."
    static let cleanupRule = "Preserve existing email addresses character-for-character, including case, repeated characters, dots, plus tags and underscores. In an explicitly dictated email address, join individually spelled letters and render spoken at/艾特 as @ and dot/点 as . only when the full domain was spoken. Example: email is A L E X at gmail dot com → email is alex@gmail.com. Never infer missing letters, a provider or .com. Ordinary prose containing at, dot, or acronyms stays prose."
    private static let atom = #"[A-Za-z0-9!#$%&'*+/=?^_`{|}~\-]+"#
    private static let address = try! NSRegularExpression(pattern:
        #"(?<![A-Za-z0-9._%+\-])(?:"# + atom + #"(?:\."# + atom + #")*|"(?:[^"\\\r\n]|\\.)+")@(?:[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)+|\[[^\]\r\n]+\])(?![A-Za-z0-9_@\-])"#)
    private static let separator = try! NSRegularExpression(pattern: #"@|(?i)(?<![A-Za-z0-9])at(?![A-Za-z0-9])|艾特"#)
    private static let token = try! NSRegularExpression(pattern: #"[A-Za-z0-9]+(?:[._+\-][A-Za-z0-9]+)*|[._+\-]|下划线|下劃線|加号|加號|横杠|橫槓|点|點"#)
    private static let cue = try! NSRegularExpression(pattern: #"(?i)(?:\be-?mail(?:\s+address)?\b|邮箱|郵箱|电邮|電郵|邮件地址|郵件地址)(?:[ \t:：]*(?:is|to|at|是|为|為|地址))*[ \t:：]*$"#)
    private static let punctuation: [String: String] = [
        "dot": ".", "period": ".", ".": ".", "点": ".", "點": ".",
        "underscore": "_", "_": "_", "下划线": "_", "下劃線": "_",
        "plus": "+", "+": "+", "加号": "+", "加號": "+",
        "dash": "-", "hyphen": "-", "-": "-", "横杠": "-", "橫槓": "-",
    ]

    static func ranges(in text: String) -> [NSRange] {
        let source = text as NSString
        return address.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let value = source.substring(with: match.range)
            guard value.utf8.count <= 254, let at = value.lastIndex(of: "@"), value[..<at].utf8.count <= 64 else { return nil }
            return match.range
        }
    }

    static func addresses(in text: String) -> [String] {
        let source = text as NSString
        return ranges(in: text).map { source.substring(with: $0) }
    }

    static func preservesAddresses(from source: String, in output: String) -> Bool {
        addresses(in: source).sorted() == addresses(in: output).sorted()
    }

    /// Protect literal addresses from filler removal, repetition repair and capitalisation.
    /// The temporary tokens are local only and are never sent to a model or inserted.
    static func preservingAddresses(in text: String, transform: (String) -> String) -> String {
        let matches = ranges(in: text)
        guard !matches.isEmpty else { return transform(text) }
        var prefix: String
        repeat { prefix = "XQEMAIL" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        while text.contains(prefix)
        let source = text as NSString
        var masked = text
        var replacements: [(String, String)] = []
        for (index, match) in matches.enumerated().reversed() {
            let placeholder = prefix + String(index) + "QX"
            replacements.append((placeholder, source.substring(with: match)))
            if let range = Range(match, in: masked) { masked.replaceSubrange(range, with: placeholder) }
        }
        var result = transform(masked)
        for (placeholder, value) in replacements { result = result.replacingOccurrences(of: placeholder, with: value) }
        return result
    }

    private struct Token {
        let text: String
        let range: NSRange
        var isCharacter: Bool { text.count == 1 && text.first?.isLetter == true || text.count == 1 && text.first?.isNumber == true }
        var symbol: String? { punctuation[text.lowercased()] }
    }

    private static func tokens(in text: String) -> [Token] {
        let source = text as NSString
        return token.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            Token(text: source.substring(with: $0.range), range: $0.range)
        }
    }

    private static func onlySpace(_ text: NSString, from start: Int, to end: Int) -> Bool {
        guard start <= end else { return false }
        // Do not join across a paragraph or sentence boundary.
        return text.substring(with: NSRange(location: start, length: end - start)).allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func format(_ text: String) -> String {
        let source = text as NSString
        let protected = ranges(in: text)
        var protectedIndex = 0
        var edits: [(NSRange, String)] = []
        for marker in separator.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            while protectedIndex < protected.count, NSMaxRange(protected[protectedIndex]) <= marker.range.location { protectedIndex += 1 }
            if protectedIndex < protected.count, NSIntersectionRange(protected[protectedIndex], marker.range).length > 0 { continue }
            // A long dictation can contain thousands of ordinary uses of "at". Keep each
            // candidate scan bounded instead of re-tokenizing the entire prefix/suffix.
            let proposedStart = max(0, marker.range.location - 2048)
            let leftStart = proposedStart == 0 ? 0 : source.rangeOfComposedCharacterSequence(at: proposedStart).location
            let left = source.substring(with: NSRange(location: leftStart, length: marker.range.location - leftStart))
            let rightStart = NSMaxRange(marker.range)
            let proposedEnd = min(source.length, rightStart + 2048)
            let rightEnd = proposedEnd == source.length ? proposedEnd : source.rangeOfComposedCharacterSequence(at: proposedEnd).location
            let right = source.substring(with: NSRange(location: rightStart, length: rightEnd - rightStart))
            let lhs = left as NSString
            let rhs = right as NSString
            let before = tokens(in: left)
            let after = tokens(in: right)
            guard var index = before.indices.last, !after.isEmpty,
                  onlySpace(lhs, from: NSMaxRange(before[index].range), to: lhs.length),
                  onlySpace(rhs, from: 0, to: after[0].range.location),
                  before[index].symbol == nil || before[index].text.count > 1 else { continue }

            var local = before[index].text
            var spelledCharacters = before[index].isCharacter ? 1 : 0
            var startsWithSpelling = before[index].isCharacter
            while index > 0 {
                let previous = before[index - 1]
                guard onlySpace(lhs, from: NSMaxRange(previous.range), to: before[index].range.location) else { break }
                if let symbol = previous.symbol, index >= 2 {
                    let part = before[index - 2]
                    guard part.symbol == nil,
                          onlySpace(lhs, from: NSMaxRange(part.range), to: previous.range.location) else { break }
                    local = part.text + symbol + local
                    index -= 2
                    startsWithSpelling = part.isCharacter
                    if part.isCharacter { spelledCharacters += 1 }
                } else if startsWithSpelling && previous.isCharacter {
                    local = previous.text + local
                    spelledCharacters += 1
                    index -= 1
                } else { break }
            }

            // A domain needs an explicit dot, at least two complete labels and a final
            // alphabetic label. "at Gmail" stays unchanged because .com was not spoken.
            func domainPart(start: Int) -> (value: String, end: Int, next: Int, spelled: Bool) {
                var value = after[start].text
                var end = NSMaxRange(after[start].range)
                var next = start + 1
                var spelled = false
                if value.lowercased() == "g", next < after.count, after[next].text.lowercased() == "mail",
                   onlySpace(rhs, from: end, to: after[next].range.location) {
                    value = "gmail"; end = NSMaxRange(after[next].range); next += 1
                } else if after[start].isCharacter {
                    while next < after.count, after[next].isCharacter,
                          onlySpace(rhs, from: end, to: after[next].range.location) {
                        value += after[next].text; end = NSMaxRange(after[next].range); next += 1
                        spelled = true
                    }
                }
                if value.lowercased() == "g-mail" { value = "gmail" }
                if value.lowercased().hasPrefix("g-mail.") { value = "gmail" + value.dropFirst(6) }
                return (value, end, next, spelled)
            }
            var (domain, end, next, spelledEnding) = domainPart(start: 0)
            while next + 1 < after.count, after[next].symbol == ".",
                  after[next + 1].symbol == nil,
                  onlySpace(rhs, from: end, to: after[next].range.location),
                  onlySpace(rhs, from: NSMaxRange(after[next].range), to: after[next + 1].range.location) {
                let part = domainPart(start: next + 1)
                domain += "." + part.0
                end = part.1
                next = part.2
                spelledEnding = part.spelled
            }
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2,
                  labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }),
                  let last = labels.last, last.count >= 2, last.allSatisfy({ $0.isASCII && $0.isLetter }),
                  local.count <= 64, domain.count <= 253 else { continue }
            // Without a pause, "dot C O M I will…" cannot tell us whether I is part of
            // the address or the next sentence. Keep the ambiguous source for review.
            if spelledEnding, next < after.count,
               onlySpace(rhs, from: end, to: after[next].range.location) { continue }

            // A token clipped by the scan window is incomplete, so do not format it.
            if leftStart > 0 && before[index].range.location == 0 { continue }
            if rightEnd < source.length && end == rhs.length { continue }
            let localStart = leftStart + before[index].range.location
            let range = NSRange(location: localStart, length: rightStart + end - localStart)
            let prefixStart = max(0, localStart - 160)
            let prefix = source.substring(with: NSRange(location: prefixStart, length: localStart - prefixStart))
            let suffix = source.substring(with: NSRange(location: NSMaxRange(range), length: min(2, source.length - NSMaxRange(range))))
            if let previous = prefix.last, previous.isASCII && (previous.isLetter || previous.isNumber || "._%+-@".contains(previous)) { continue }
            if suffix.hasPrefix("."), let next = suffix.dropFirst().first, next.isASCII && (next.isLetter || next.isNumber || next == ".") { continue }
            // A bare "look at gmail.com" is ordinary prose. Single-word usernames need
            // an email cue, an actual @, or explicit local punctuation; spelling is explicit.
            let hasCue = cue.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) != nil
            let explicitPunctuation = local.contains { "._+-".contains($0) }
            guard spelledCharacters >= 2 || source.substring(with: marker.range) == "@" || hasCue || explicitPunctuation else { continue }
            let candidate = local.lowercased() + "@" + domain.lowercased()
            guard addresses(in: candidate) == [candidate],
                  !(protectedIndex < protected.count && NSIntersectionRange(protected[protectedIndex], range).length > 0),
                  !(protectedIndex > 0 && NSIntersectionRange(protected[protectedIndex - 1], range).length > 0),
                  edits.last.map({ NSMaxRange($0.0) <= range.location }) ?? true else { continue }
            edits.append((range, candidate))
        }
        guard !edits.isEmpty else { return text }
        var result = ""
        var position = 0
        for (range, value) in edits {
            result += source.substring(with: NSRange(location: position, length: range.location - position)) + value
            position = NSMaxRange(range)
        }
        return result + source.substring(from: position)
    }
}
