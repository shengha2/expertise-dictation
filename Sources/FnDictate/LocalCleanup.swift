import Foundation

/// Deterministic, instant clean-up used for Light mode, for very short utterances, and as the
/// fallback whenever the LLM is slow, fails, or changes too much.
enum LocalCleanup {
    // This intentionally does not use the broader cleanup/skeleton rules: words such as
    // actually, 啊 and 就是, questions, and quoted sounds may be meaningful on their own.
    private static let hesitationOnly = try! NSRegularExpression(
        pattern: #"(?i)\A[\s,，.。;；]*(?:(?:um|uh|uhm|umm|erm|hmm|嗯+|呃+)(?:[\s,，.。;；]+|$))+\z"#)

    static func isEmptyOrHesitationOnly(_ text: String) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard DictationPunctuation.literalRanges(in: text).isEmpty else { return false }
        return hesitationOnly.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let englishFillers = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}'’-])(?:u+m+|u+h+|uhm|umm+|e+r+m*|hmm+|mm+|ah+)(?![\p{L}\p{N}'’-])[,，]?\s*"#)
    private static let englishPhrases = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}])(?:you know|i mean)[,，]\s*"#)
    // 嗯 and 呃 are never real words, so they go wherever they appear; 额 (forehead, quota) only when standalone.
    private static let cjkFillers = try! NSRegularExpression(
        pattern: #"(?:嗯+|呃+)[，,]?\s*|(?<![\p{Han}])额+(?![\p{Han}])[，,]?\s*"#)
    // 那个/这个 at the start of a clause are fillers when followed by a pause, a pronoun or another 那个/这个
    // ("那个我今天…"), but not when they determine a noun ("这个 feature 很好").
    private static let cjkLeadingFillers = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[，。！？；：,.!?;:]))\s*(?:那个|这个)+(?:[，,]\s*|\s+|(?=我|你|他|她|咱|大家))"#)
    private static let cjkLeadingConnectors = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[，。！？；：,.!?;:]))\s*(?:就是说|就是|然后)[，,]\s*"#)
    private static let repeatedWord = try! NSRegularExpression(
        pattern: #"(?i)\b(\p{L}{2,})(?:[,，]?\s+\1\b)+"#)
    // "this is this is a test" → "this is a test" (stutters of two to four words)
    private static let repeatedPhrase = try! NSRegularExpression(
        pattern: #"(?i)\b((?:\p{L}+\s+){1,3}\p{L}+)(?:[,，]?\s+\1\b)+"#)
    private static let repeatedCJK = try! NSRegularExpression(
        pattern: #"([\p{Han}]{2,4})[，,]?\1"#)
    private static let spaceBeforeCJKPunct = try! NSRegularExpression(pattern: #"\s+([，。！？、；：）」』”])"#)
    private static let spaceAfterCJKOpen = try! NSRegularExpression(pattern: #"([（「『“])\s+"#)
    private static let cjkSpaceCJK = try! NSRegularExpression(pattern: #"(?<=\p{Han})[ \t]+(?=\p{Han})"#)
    private static let cjkPunctSpace = try! NSRegularExpression(pattern: #"(?<=[，。！？、；：])[ \t]+(?=[\p{Han}\p{L}\p{N}])"#)
    private static let cjkThenLatin = try! NSRegularExpression(pattern: #"(?<=\p{Han})(?=[A-Za-z0-9])"#)
    private static let latinThenCJK = try! NSRegularExpression(pattern: #"(?<=[A-Za-z0-9%])(?=\p{Han})"#)
    private static let spaceBeforeLatinPunct = try! NSRegularExpression(pattern: #"\s+([,.!?;:])(?=\s|$)"#)
    private static let multiSpace = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)

    static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Filler removal + spacing normalisation. Conservative on purpose.
    static func light(_ text: String, cjkSpacing: Bool) -> String {
        DictationPunctuation.preservingLiterals(in: DictationPunctuation.formatSpokenAddresses(text)) {
            lightUnprotected($0, cjkSpacing: cjkSpacing)
        }
    }

    private static func lightUnprotected(_ text: String, cjkSpacing: Bool) -> String {
        var s = text
        s = replace(englishFillers, in: s, with: "")
        s = replace(englishPhrases, in: s, with: "")
        s = replace(cjkFillers, in: s, with: "")
        s = replace(cjkLeadingFillers, in: s, with: "")
        s = replace(cjkLeadingConnectors, in: s, with: "")
        s = replace(repeatedWord, in: s, with: "$1")
        s = replace(repeatedPhrase, in: s, with: "$1")
        s = replace(repeatedCJK, in: s, with: "$1")
        s = normalize(s, cjkSpacing: cjkSpacing)
        s = capitalizeSentenceStarts(s)
        return s
    }

    /// What `light` produces when there is nothing to remove: normalisation and sentence
    /// capitals only. `light(x) == presentation(x)` means the filler and repeat passes were idle.
    static func presentation(_ text: String, cjkSpacing: Bool) -> String {
        DictationPunctuation.preservingLiterals(in: DictationPunctuation.formatSpokenAddresses(text)) {
            capitalizeSentenceStarts(normalizeUnprotected($0, cjkSpacing: cjkSpacing))
        }
    }

    /// Spacing/punctuation normalisation only (Verbatim mode).
    static func normalize(_ text: String, cjkSpacing: Bool) -> String {
        DictationPunctuation.preservingLiterals(in: DictationPunctuation.formatSpokenAddresses(text)) {
            normalizeUnprotected($0, cjkSpacing: cjkSpacing)
        }
    }

    private static func normalizeUnprotected(_ text: String, cjkSpacing: Bool) -> String {
        var s = DictationPunctuation.normalizeChinese(text).replacingOccurrences(of: "\r\n", with: "\n")
        s = replace(cjkSpaceCJK, in: s, with: "")
        s = replace(spaceBeforeCJKPunct, in: s, with: "$1")
        s = replace(spaceAfterCJKOpen, in: s, with: "$1")
        s = replace(cjkPunctSpace, in: s, with: "")
        s = replace(spaceBeforeLatinPunct, in: s, with: "$1")
        if cjkSpacing {
            s = replace(cjkThenLatin, in: s, with: " ")
            s = replace(latinThenCJK, in: s, with: " ")
        }
        s = replace(multiSpace, in: s, with: " ")
        s = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func capitalizeSentenceStarts(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = ""
        var atStart = true
        for ch in text {
            if atStart, ch.isLetter, ch.isASCII {
                out.append(ch.uppercased())
                atStart = false
            } else {
                out.append(ch)
                if ".!?".contains(ch) || ch == "\n" { atStart = true }
                else if !ch.isWhitespace && !"\"'“(".contains(ch) { atStart = false }
            }
        }
        return out
    }

    /// True for utterances too short to be worth an LLM round-trip.
    static func isShort(_ text: String) -> Bool {
        let han = text.unicodeScalars.filter { $0.properties.isIdeographic }.count
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return han + words <= 3 && text.count <= 12
    }
}
