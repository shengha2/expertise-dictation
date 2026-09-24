import Foundation

/// Layout checks use synthetic text and injected model responses. No provider or user-data writes.
enum ReadabilityRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        func evaluate(_ raw: String, client: Fixture = Fixture(), style: RewriteStyle = .full) -> LongTextProcessing.CleanupResult? {
            let context = CleanupContext(precedingText: nil, dictionary: [], chineseVariant: .simplified,
                                         allowFormatting: false, spokenCommands: false, cjkSpacing: true,
                                         customInstructions: "", rewriteStyle: style)
            var result: LongTextProcessing.CleanupResult?
            let task = Task { @MainActor in
                result = try? await LongTextProcessing.cleanup(raw, context: context, settings: Settings.shared,
                                                               client: client) { _, _ in }
            }
            let deadline = Date().addingTimeInterval(5)
            while result == nil && Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            task.cancel()
            return result
        }

        // Both prefixes end exactly at the normal 1,800-character section boundary.
        let english = String(repeating: "Keep this detail. ", count: 100)
        let chinese = String(repeating: "请保留这条记录。", count: 225)
        let next = "Preserve the next item."
        let en = evaluate(english + next)
        check("readability: approved bullets stay on separate lines across an English section boundary",
              en?.text == "- " + english.trimmingCharacters(in: .whitespacesAndNewlines) + "\n- " + next && en?.fallbackCount == 0, "")
        let zh = evaluate(chinese + "请保留下一项。")
        check("readability: CJK sentence boundary starts the next approved bullet on a new line",
              zh?.text == "- " + chinese + "\n- 请保留下一项。" && zh?.fallbackCount == 0, "")

        let existingBreak = String(repeating: "Keep this detail. ", count: 99) + String(repeating: "a", count: 16) + "\n\n"
        let preserved = evaluate(existingBreak + next)
        check("readability: existing paragraph separator is preserved exactly once",
              preserved?.text == "- " + existingBreak.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n- " + next, "")

        let light = evaluate(english + next, style: .light)
        check("readability: light cleanup retains its existing section-join behavior",
              light?.text == "- " + english.trimmingCharacters(in: .whitespacesAndNewlines) + " - " + next, "")
        let prose = evaluate(english + next, client: Fixture(bullets: false))
        check("readability: full rewrite does not force a paragraph at every prose section",
              prose?.text == english + next, "")

        for fragment in ["- 20 units.", "* factor."] {
            let inline = english + fragment
            let echo = evaluate(inline, client: Fixture(bullets: false))
            check("readability: original inline operator retains its space: \(fragment)",
                  echo?.text == inline && echo?.fallbackCount == 0, "")
        }
        let crlfPrefix = String(repeating: "Keep this detail. ", count: 99) + String(repeating: "a", count: 16) + "\r\n\r\n"
        let crlf = evaluate(crlfPrefix + next)
        check("readability: original CRLF paragraph separator survives section joining",
              crlf?.text == "- " + crlfPrefix.trimmingCharacters(in: .whitespacesAndNewlines) + "\r\n\r\n- " + next, "")

        let identifier = String(repeating: "x", count: 3601)
        let unbroken = evaluate(identifier)
        check("readability: forced mid-word cuts do not invent line breaks or drop characters",
              unbroken?.text.contains("\n") == false && unbroken?.text.filter({ $0 == "x" }).count == 3601, "")

        let fallbackSource = english + "- Keep this raw fragment intact."
        let veto = evaluate(fallbackSource, client: Fixture(rejectSection: 2))
        check("readability: a raw vetoed section keeps its original join even if it starts with a dash",
              veto?.text == "- " + fallbackSource && veto?.guardFallbackCount == 1 && veto?.requiresRecovery == false, "")
        let failed = evaluate(fallbackSource, client: Fixture(failSection: 2))
        check("readability: provider fallback retains raw boundaries and still requests recovery",
              failed?.text == "- " + fallbackSource && failed?.providerFallbackCount == 1 && failed?.requiresRecovery == true, "")

        let raw = "Mira reviews 12 cases by 4:30; Chen checks the installer."
        check("readability: flat bullets preserve substantive numbers",
              RewriteVerification.passesBasicChecks(raw: raw, rewritten: "- Mira reviews 12 cases by 4:30.\n- Chen checks the installer."), "")
        check("readability: invented ordinal numbers still fail the numeric safeguard",
              !RewriteVerification.passesBasicChecks(raw: raw, rewritten: "1. Mira reviews 12 cases by 4:30.\n2. Chen checks the installer."), "")
    }

    final class Fixture: LLMClient {
        let name = "offline-readability-layout"
        let bullets: Bool
        let rejectSection: Int?
        let failSection: Int?
        private var section = 0
        init(bullets: Bool = true, rejectSection: Int? = nil, failSection: Int? = nil) {
            self.bullets = bullets; self.rejectSection = rejectSection; self.failSection = failSection
        }
        func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
            if system == RewriteVerification.systemPrompt { return section == rejectSection ? "FAIL" : "PASS" }
            section += 1
            if section == failSection { throw LLMError.http(503, "synthetic readability provider failure") }
            guard let start = user.range(of: "<transcript>"),
                  let end = user.range(of: "</transcript>", range: start.upperBound..<user.endIndex) else { return "" }
            let source = String(user[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            // A section meant to be vetoed must reach the semantic check, so give it a rephrasing
            // that the local near-verbatim test cannot accept on its own.
            if section == rejectSection { return "- Definitely, " + source }
            return (bullets ? "- " : "") + source
        }
    }
}
