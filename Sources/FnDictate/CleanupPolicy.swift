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

    static func decide(raw: String, cjkSpacing: Bool, spokenCommands allowCommands: Bool) -> Decision {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return Decision(needsModel: false, reason: "empty") }
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
