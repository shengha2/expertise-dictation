import Foundation

/// Full rewriting needs a semantic check; lexical edit distance intentionally rejects paraphrases.
/// Fail closed: an unavailable verifier keeps the complete original transcript for recovery.
enum RewriteVerification {
    private static let digits = try! NSRegularExpression(pattern: #"[+-]?[0-9]+(?:[.,:/-][0-9]+)*"#)
    private static func numericTokens(_ text: String) -> [String] {
        let value = text as NSString
        return digits.matches(in: text, range: NSRange(location: 0, length: value.length))
            .map { value.substring(with: $0.range) }
    }

    static func passesBasicChecks(raw: String, rewritten: String) -> Bool {
        if rewritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LocalCleanup.isEmptyOrHesitationOnly(raw)
        }
        let formatted = DictationPunctuation.formatSpokenAddresses(raw)
        guard EmailAddressFormatting.preservesAddresses(from: formatted, in: rewritten) else { return false }
        guard DictationPunctuation.preservesLiterals(from: formatted, in: rewritten) else { return false }
        guard MixedLanguageGuard.preservesEnglishWords(from: formatted, in: rewritten) else { return false }
        // Reordering is allowed, changing or dropping a numeric token is not. Ambiguous
        // number formatting/corrections safely retain the original instead of guessing.
        return numericTokens(formatted).sorted() == numericTokens(rewritten).sorted()
    }

    static let systemPrompt = PublicPromptDefaults.rewriteVerifier

    /// Skip the second request only for ordered content-token equality. An edit ratio or
    /// token set can hide a deleted Chinese qualifier or a swapped owner in a long passage.
    /// Punctuation, casing, layout and recognized fillers still take this fast path.
    static func isNearVerbatim(raw: String, rewritten: String, replacements: [Replacement] = []) -> Bool {
        let source = DictationPunctuation.formatSpokenAddresses(Replacements.apply(replacements, to: raw))
        guard passesBasicChecks(raw: source, rewritten: rewritten),
              MeaningGuard.evaluate(raw: raw, cleaned: rewritten, threshold: GuardStrictness.strict.threshold, replacements: replacements).accepted else {
            return false
        }
        // Context-dependent words such as actually/so/啊 are not always fillers. Their
        // removal still needs semantic judgment rather than the broader lexical skeleton.
        let sounds: Set<String> = ["um", "uh", "uhm", "umm", "erm", "hmm", "嗯", "呃"]
        let repaired = MeaningGuard.resolveExplicitCorrections(source)
        return MeaningGuard.tokens(repaired).filter { !sounds.contains($0) } ==
            MeaningGuard.tokens(rewritten).filter { !sounds.contains($0) }
    }

    static func accepts(raw: String, rewritten: String, client: LLMClient, timeout: TimeInterval) async throws -> Bool {
        guard passesBasicChecks(raw: raw, rewritten: rewritten) else { return false }
        if rewritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines) == rewritten.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        let payload = try JSONSerialization.data(withJSONObject: ["original": raw, "rewrite": rewritten], options: [.sortedKeys])
        let response = try await client.complete(system: systemPrompt, user: String(decoding: payload, as: UTF8.self), maxTokens: 16, timeout: timeout)
        try Task.checkCancellation()
        return response.trimmingCharacters(in: .whitespacesAndNewlines) == "PASS"
    }
}
