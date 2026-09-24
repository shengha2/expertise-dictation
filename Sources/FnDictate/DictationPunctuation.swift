import Foundation

/// Standardizes punctuation already present beside Chinese prose. It never invents a
/// sentence boundary. Literal values are protected before local cleanup or punctuation work.
enum DictationPunctuation {
    private static let literalPatterns: [NSRegularExpression] = [
        // Delimited code and quoted literals can contain arbitrary punctuation and whitespace.
        try! NSRegularExpression(pattern: #"(?s)```.*?```|`[^`\r\n]+`|\"(?:[^\"\\]|\\.)*\"|“[^”]*”|「[^」]*」|『[^』]*』|(?<![A-Za-z0-9])'(?:[^'\\\r\n]|\\.)*'(?![A-Za-z0-9])"#),
        try! NSRegularExpression(pattern: #"(?i)(?<![a-z0-9+.-])(?:[a-z][a-z0-9+.-]*://|www\.)[^\s<>\"`，。！？；：）」』]+"#),
        // Bare domains and dotted identifiers, including filenames. Exclude trailing marks.
        try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+(?:/[^\s<>\"`，。！？；：）」』]*)?"#),
        try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_-])[\p{L}\p{N}_-]+\.(?:swift|py|js|ts|tsx|jsx|json|md|txt|csv|pdf|html|css|sh)\b"#),
        try! NSRegularExpression(pattern: #"(?<![0-9])[+-]?[0-9]+(?:[.,:/-][0-9]+)+"#),
        try! NSRegularExpression(pattern: #"(?:~?/|[A-Za-z]:\\)[^\s<>\"`，。！？；：）」』]+"#),
    ]

    static func literalRanges(in text: String) -> [NSRange] {
        let whole = NSRange(text.startIndex..., in: text)
        var ranges = EmailAddressFormatting.ranges(in: text)
        for expression in literalPatterns { ranges += expression.matches(in: text, range: whole).map(\.range) }
        ranges.sort { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, range.location < NSMaxRange(last) {
                merged[merged.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else { merged.append(range) }
        }
        return merged
    }

    static func preservingLiterals(in text: String, transform: (String) -> String) -> String {
        let ranges = literalRanges(in: text)
        guard !ranges.isEmpty else { return transform(text) }
        var prefix: String
        repeat { prefix = "XQLITERAL" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        while text.contains(prefix)
        let source = text as NSString
        var masked = text
        var originals: [(String, String)] = []
        for (index, range) in ranges.enumerated().reversed() {
            let token = prefix + String(index) + "QX"
            originals.append((token, source.substring(with: range)))
            if let swiftRange = Range(range, in: masked) { masked.replaceSubrange(swiftRange, with: token) }
        }
        var output = transform(masked)
        for (token, original) in originals { output = output.replacingOccurrences(of: token, with: original) }
        return output
    }

    /// A quoted string or code example may intentionally contain spoken address words.
    /// Process only the gaps around those spans, without masking ordinary domains needed
    /// to recognize an actual dictated address. No temporary marker reaches the formatter.
    static func formatSpokenAddresses(_ text: String) -> String {
        let ranges = literalPatterns[0].matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
        guard !ranges.isEmpty else { return EmailAddressFormatting.format(text) }
        let source = text as NSString
        var offset = 0
        var output = ""
        for range in ranges {
            output += EmailAddressFormatting.format(source.substring(with: NSRange(location: offset, length: range.location - offset)))
            output += source.substring(with: range)
            offset = NSMaxRange(range)
        }
        output += EmailAddressFormatting.format(source.substring(from: offset))
        return output
    }

    static func preservesLiterals(from source: String, in output: String) -> Bool {
        func values(_ text: String) -> [String] {
            let string = text as NSString
            return literalRanges(in: text).map { string.substring(with: $0) }.sorted()
        }
        return values(source) == values(output)
    }

    /// Used only for deciding whether punctuation exists in prose. A dot in 3.14, an email,
    /// or a URL must not cause an otherwise unpunctuated passage to skip model cleanup.
    static func proseWithoutLiterals(_ text: String) -> String {
        var result = text
        for range in literalRanges(in: text).reversed() {
            if let swiftRange = Range(range, in: result) { result.replaceSubrange(swiftRange, with: " ") }
        }
        return result
    }

    static func normalizeChinese(_ text: String) -> String {
        preservingLiterals(in: text) { value in
            let characters = Array(value)
            let marks: [Character: Character] = [",": "，", ".": "。", "?": "？", "!": "！", ";": "；", ":": "："]
            var result = ""
            var offset = 0
            func isHan(_ character: Character) -> Bool { character.unicodeScalars.contains { $0.properties.isIdeographic } }
            while offset < characters.count {
                guard marks[characters[offset]] != nil else { result.append(characters[offset]); offset += 1; continue }
                let start = offset
                while offset < characters.count && marks[characters[offset]] != nil { offset += 1 }
                let run = characters[start..<offset]
                // Keep ellipses and punctuation combinations with dots intact; their semantics
                // are not equivalent to a run of Chinese full stops.
                if run.count > 1 && run.contains(".") { result += String(run); continue }
                var left = start - 1
                while left >= 0 && (characters[left] == " " || characters[left] == "\t") { left -= 1 }
                var right = offset
                while right < characters.count && (characters[right] == " " || characters[right] == "\t") { right += 1 }
                // A following Chinese sentence must not change the English sentence's final
                // period/question/exclamation mark. Commas and clause separators can connect
                // a protected literal to the following Chinese clause.
                let chinese = (left >= 0 && isHan(characters[left])) ||
                    (run.allSatisfy { ",;:".contains($0) } && right < characters.count && isHan(characters[right]))
                result += String(run.map { chinese ? marks[$0]! : $0 })
            }
            return result
        }
    }
}
