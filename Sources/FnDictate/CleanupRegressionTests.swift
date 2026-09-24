import Foundation

/// Synthetic text only: no network, credentials, microphone, clipboard, or personal history.
enum CleanupRegressionTests {
    static let disfluent = "And can you call this actually a can you call this actually expertise dictate or dictation? Or expert dictator? No, no, not dictator, dictation"

    static func run(check: (String, Bool, String) -> Void) {
        EmailAddressRegressionTests.run(check: check)
        ReadabilityRegressionTests.run(check: check)
        CorrectionGuardRegressionTests.run(check: check)
        let faithful: [(String, String)] = [
            ("Um, please please send the draft to Mira.", "Please send the draft to Mira."),
            ("Can you can you call this Expertise Dictation?", "Can you call this Expertise Dictation?"),
            ("Call it Expert Dictator—no, not Dictator, Dictation.", "Call it Expert Dictation."),
            ("Send it to Mira—sorry, Nia.", "Send it to Nia."),
            ("Schedule it for four—no, make that five.", "Schedule it for five."),
            ("我周二，不对，周三去。", "我周三去。"),
            (disfluent, "And can you call this Expertise Dictate or Dictation? Or Expert Dictation?"),
            ("Please send the draft and address the three open questions.", "Please send the draft and address the 3 open questions."),
            ("Do not authorize payment above 250 dollars.", "Do not authorize payment above $250."),
        ]
        for (index, pair) in faithful.enumerated() {
            let verdict = MeaningGuard.evaluate(raw: pair.0, cleaned: pair.1, threshold: 0.35)
            check("cleanup: faithful stutter/correction fixture \(index + 1)", verdict.accepted, verdict.reason)
        }
        let longPrefix = String(repeating: "We reviewed the draft and discussed the schedule with the team. ", count: 50)
        let unsafe: [(String, String)] = [
            ("Send it to Mira at 4:30, not Nia at 5.", "Send it to Nia at 5."),
            ("The amount is 12.50 dollars.", "The amount is 1250 dollars."),
            ("Do not call it Expert Dictator.", "Call it Expert Dictator."),
            ("I like the name Know Your Rights.", "I like the name Your Rights."),
            ("这个方案不是最终方案。", "这个方案是最终方案。"),
            ("Send the draft to Mira, keep the appendix, and do not publish it.", "Send the draft to Mira."),
            (longPrefix + "Reference code QZ47. Do not publish.", longPrefix),
            (longPrefix + "We do not authorize payment until inspection is complete.", longPrefix + "We authorize payment until inspection is complete."),
            (longPrefix + "Keep the appendix and bibliography.", longPrefix),
            ("First item is alpha. Second item is beta. First item is alpha. Second item is beta.", "First item is alpha. Second item is beta."),
            (disfluent, "Call it Expertise Dictation."),
            ("Do not authorize payment above 250 dollars.", "Do not authorize payment above €250."),
            ("Do not authorize payment above 250 dollars.", "Do not authorize payment above $251."),
        ]
        for (index, pair) in unsafe.enumerated() {
            let verdict = MeaningGuard.evaluate(raw: pair.0, cleaned: pair.1, threshold: 0.35)
            check("cleanup: missing/changed meaning fixture \(index + 1) keeps raw", !verdict.accepted, verdict.reason)
        }
        let context = CleanupContext(precedingText: nil, dictionary: [], chineseVariant: .simplified,
                                     allowFormatting: false, spokenCommands: false, cjkSpacing: true, customInstructions: "")
        func evaluate(_ raw: String, _ fixture: LLMClient, style: RewriteStyle = .light) -> LongTextProcessing.CleanupResult? {
            var result: LongTextProcessing.CleanupResult?
            var requestedContext = context
            requestedContext.rewriteStyle = style
            let task = Task { @MainActor in
                result = try? await LongTextProcessing.cleanup(raw, context: requestedContext, settings: Settings.shared, client: fixture) { _, _ in }
            }
            let deadline = Date().addingTimeInterval(5)
            while result == nil && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            task.cancel()
            return result
        }
        let veto = evaluate(disfluent, Fixture(response: "Call it Expertise Dictation."))
        check("cleanup: guard veto preserves exact original without an error or recovery request", veto?.text == disfluent && veto?.guardFallbackCount == 1 && veto?.providerFallbackCount == 0 && veto?.requiresRecovery == false, "")
        for style in [RewriteStyle.full, .light] {
            let silent = RewriteFixture(response: "")
            let omitted = evaluate("嗯 um 呃", silent, style: style)
            check("cleanup: hesitation-only empty completion is accepted without a verifier in \(style)", omitted?.text == "" && omitted?.fallbackCount == 0 && silent.cleanupCalls == 1 && silent.verificationCalls == 0, "")
            for source in ["actually", "就是", "嗯？", "`um`", "Keep 12 cases."] {
                let empty = RewriteFixture(response: "")
                let retained = evaluate(source, empty, style: style)
                check("cleanup: empty completion preserves non-hesitation text in \(style)", retained?.text == source && retained?.guardFallbackCount == 1 && retained?.requiresRecovery == false && empty.verificationCalls == 0, source)
            }
        }
        let long = String(repeating: "Please retain all discussion points and keep the complete appendix. ", count: 100)
        let provider = Fixture(response: "Unrelated response.", onlyFirst: true)
        let continued = evaluate(long, provider)
        check("cleanup: guard veto continues processing later sections", provider.calls == LongTextProcessing.chunks(long).count && continued?.guardFallbackCount == 1 && continued?.usedLLM == true && continued?.requiresRecovery == false, "calls=\(provider.calls)")
        check("cleanup: continued sections preserve the complete transcript", MeaningGuard.tokens(continued?.text ?? "") == MeaningGuard.tokens(long), "")
        for failure in [LLMError.outputLimit, LLMError.http(503, "offline provider unavailable")] {
            let failed = evaluate(long, Fixture(failure: failure))
            check("cleanup: actual provider failure retains raw and requires recovery", failed?.text == long && failed?.requiresRecovery == true && failed?.guardFallbackCount == 0 && failed?.providerFallbackCount == LongTextProcessing.chunks(long).count, "")
        }
        let original = "We reviewed the draft and decided to wait until the inspection is complete before publishing it."
        let rewritten = "After reviewing the draft, we decided to publish it only once the inspection is complete."
        let acceptedRewrite = RewriteFixture(response: rewritten)
        let full = evaluate(original, acceptedRewrite, style: .full)
        check("rewrite: semantic approval permits a faithful paraphrase", full?.text == rewritten && full?.fallbackCount == 0 && full?.usedLLM == true && acceptedRewrite.cleanupCalls == 1 && acceptedRewrite.verificationCalls == 1, "")
        let disfluentRewrite = "um so we should uh we should ship it on thursday, no wait, friday"
        let tidied = RewriteFixture(response: "So we should ship it on Friday.")
        let tidiedResult = evaluate(disfluentRewrite, tidied, style: .full)
        check("rewrite: a changed correction receives semantic verification", tidiedResult?.text == "So we should ship it on Friday." && tidiedResult?.fallbackCount == 0 && tidied.cleanupCalls == 1 && tidied.verificationCalls == 1, "calls=\(tidied.verificationCalls)")
        let punctuationOnly = RewriteFixture(response: "So we should ship it on Friday.")
        let punctuationResult = evaluate("um so we should uh ship it on Friday", punctuationOnly, style: .full)
        check("rewrite: punctuation and obvious fillers still skip the semantic round trip", punctuationResult?.text == "So we should ship it on Friday." && punctuationResult?.fallbackCount == 0 && punctuationOnly.cleanupCalls == 1 && punctuationOnly.verificationCalls == 0, "calls=\(punctuationOnly.verificationCalls)")
        let qualified = RewriteFixture(response: "So we should definitely ship it on Friday.")
        _ = evaluate(disfluentRewrite, qualified, style: .full)
        check("rewrite: an inserted qualifier still goes through the semantic check", qualified.verificationCalls == 1, "calls=\(qualified.verificationCalls)")
        let negated = "Do not publish the draft before the inspection is complete."
        let semanticVeto = evaluate(negated, RewriteFixture(response: "Publish the draft before the inspection is complete.", verdict: "FAIL"), style: .full)
        check("rewrite: semantic negation veto quietly preserves original text", semanticVeto?.text == negated && semanticVeto?.guardFallbackCount == 1 && semanticVeto?.requiresRecovery == false, "")
        for error in [LLMError.outputLimit, LLMError.http(503, "offline verifier unavailable")] {
            let verificationFailure = evaluate(original, RewriteFixture(response: rewritten, failure: error), style: .full)
            check("rewrite: unavailable or truncated verification retains original and requests recovery", verificationFailure?.text == original && verificationFailure?.providerFallbackCount == 1 && verificationFailure?.requiresRecovery == true, "")
        }
        for (name, text) in [
            ("unbroken identifier", String(repeating: "abcdef", count: 700)),
            ("continuous Chinese", String(repeating: "保持完整内容不要添加空格", count: 350)),
            ("English spacing", String(repeating: "Keep the complete original wording and its spacing. ", count: 100).trimmingCharacters(in: .whitespaces)),
            ("newline boundary", String(repeating: "a", count: 1799) + "\n\n" + String(repeating: "b", count: 2000)),
        ] {
            let echoed = evaluate(text, Fixture())
            check("cleanup: section joins preserve \(name) exactly", echoed?.text == text && echoed?.fallbackCount == 0, "")
        }
    }

    final class Fixture: LLMClient {
        let name = "offline-cleanup-regression"
        let response: String?
        let failure: LLMError?
        let onlyFirst: Bool
        var calls = 0
        init(response: String? = nil, onlyFirst: Bool = false, failure: LLMError? = nil) {
            self.response = response; self.failure = failure; self.onlyFirst = onlyFirst
        }
        func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
            calls += 1
            if let failure { throw failure }
            if let response, !onlyFirst || calls == 1 { return response }
            guard let start = user.range(of: "<transcript>"), let end = user.range(of: "</transcript>", range: start.upperBound..<user.endIndex) else { return "" }
            return String(user[start.upperBound..<end.lowerBound])
        }
    }

    final class RewriteFixture: LLMClient {
        let name = "offline-rewrite-regression"
        let response: String
        let verdict: String
        let failure: LLMError?
        var cleanupCalls = 0
        var verificationCalls = 0
        init(response: String, verdict: String = "PASS", failure: LLMError? = nil) {
            self.response = response; self.verdict = verdict; self.failure = failure
        }
        func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
            if system == RewriteVerification.systemPrompt {
                verificationCalls += 1
                if let failure { throw failure }
                return verdict
            }
            cleanupCalls += 1
            return response
        }
    }
}
