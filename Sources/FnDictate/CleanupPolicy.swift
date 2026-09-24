import Foundation

/// Decides whether a Light clean-up transcript needs the model at all. The transcriber already
/// punctuates and capitalises, so most sentences come back with nothing to fix; sending those to
/// the model adds about a second of latency for a reply that repeats the input. Measured on 53
/// real dictations: 87 % came back with at most 5 % of content words changed.
enum CleanupPolicy {
    struct Decision: Equatable {
        let needsModel: Bool
        let reason: String
    }

    private static let spokenCommands = [
        "new line", "new paragraph", "question mark", "exclamation mark",
        "换行", "下一段", "新段落", "句号", "问号", "感叹号", "逗号",
    ]
    private static let spelledAddress = try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}])(at|@)\s+\S+\s+(dot|点|點)\s+\S+"#)

    // These cues request a formatting decision, not a local text rewrite. The model
    // still distinguishes actual items from a narrative and honors a prose preference.
    // Strip protected literals before looking for markers so a URL or code example
    // cannot accidentally enable a rewrite request on an otherwise clean sentence.
    private static let enumerationCues = [
        #"(?i)\bfirst(?:ly)?\b[\s\S]+\bsecond(?:ly)?\b"#,
        #"(?i)\b(?:item|number)\s+one\b[\s\S]+\b(?:item|number)\s+two\b"#,
        #"第\s*[一1１][\s\S]+第\s*[二2２]"#,
        #"一是[\s\S]+二是"#,
        #"(?i)\b(?:two|three|four|five|six|seven|eight|nine|ten|[2-9]|10)\s+(?:separate\s+)?(?:asks|requests|items|steps|checks|tasks|points)\b[^.!?\r\n:：]{0,100}[:：][\s\S]+(?:\band\b|[;；])"#,
        #"(?:[两兩二三四五六七八九十]|[2-9]|10)\s*(?:个|個|项|項|条|條)\s*(?:要求|请求|請求|事项|事項|步骤|步驟|任务|任務|检查|檢查|要点|要點)[^。！？\r\n:：]{0,50}[:：][\s\S]+[、，,;；]"#,
        #"(?:^|[\s:：])1[.、)）:](?![0-9])\s*[\p{L}\p{N}][\s\S]+(?:\s|[;；])2[.、)）:](?![0-9])\s*[\p{L}\p{N}]"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func hasExplicitEnumeration(_ raw: String) -> Bool {
        let prose = DictationPunctuation.proseWithoutLiterals(raw)
        let range = NSRange(prose.startIndex..., in: prose)
        return enumerationCues.contains { $0.firstMatch(in: prose, range: range) != nil }
    }

    static func decide(raw: String, cjkSpacing: Bool, spokenCommands allowCommands: Bool) -> Decision {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return Decision(needsModel: false, reason: "empty") }
        if hasExplicitEnumeration(trimmed) {
            return Decision(needsModel: true, reason: "explicit list")
        }
        // Anything the local pass would change (fillers, stutters, repeats) is a sign the model has work.
        if LocalCleanup.light(trimmed, cjkSpacing: cjkSpacing) != LocalCleanup.presentation(trimmed, cjkSpacing: cjkSpacing) {
            return Decision(needsModel: true, reason: "fillers or repeats")
        }
        let lower = trimmed.lowercased()
        if allowCommands, spokenCommands.contains(where: { lower.contains($0) }) {
            return Decision(needsModel: true, reason: "spoken command")
        }
        if spelledAddress.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return Decision(needsModel: true, reason: "spelled address")
        }
        // A longer utterance with no sentence punctuation: the transcriber left the formatting to us.
        let prose = DictationPunctuation.proseWithoutLiterals(trimmed)
        let hasTerminal = prose.unicodeScalars.contains { ".!?。！？".unicodeScalars.contains($0) }
        let latinWords = prose.split(whereSeparator: { $0.isWhitespace }).count
        let hanChars = prose.unicodeScalars.filter { $0.properties.isIdeographic }.count
        if !hasTerminal && (latinWords + hanChars > 8 || hanChars >= 4) {
            return Decision(needsModel: true, reason: "no sentence punctuation")
        }
        // An early full stop does not punctuate a later wall of text.
        let runs = prose.split(whereSeparator: { ".!?。！？\n".contains($0) })
        if runs.contains(where: { run in
            run.unicodeScalars.filter { $0.properties.isIdeographic }.count > 48 ||
            run.split(whereSeparator: { $0.isWhitespace }).count > 40
        }) { return Decision(needsModel: true, reason: "long unpunctuated passage") }
        return Decision(needsModel: false, reason: "already clean")
    }
}
