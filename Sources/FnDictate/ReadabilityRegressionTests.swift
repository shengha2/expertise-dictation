import Foundation

/// Layout checks use synthetic text and injected model responses. No provider or user-data writes.
enum ReadabilityRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        func evaluate(_ raw: String, client: LLMClient = Fixture(), style: RewriteStyle = .full) -> LongTextProcessing.CleanupResult? {
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
        check("readability: approved Light list items stay on separate lines across sections",
              light?.text == "- " + english.trimmingCharacters(in: .whitespacesAndNewlines) + "\n- " + next && light?.fallbackCount == 0, "")
        let prose = evaluate(english + next, client: Fixture(bullets: false))
        check("readability: full rewrite does not force a paragraph at every prose section",
              prose?.text == english + next, "")

        let numberedPrefix = "1. " + String(repeating: "Keep this detail. ", count: 99) + "Keep this item. "
        for style in [RewriteStyle.light, .full] {
            let numbered = evaluate(numberedPrefix + "2. Preserve the next item.", client: Fixture(bullets: false), style: style)
            check("readability: consecutive numbered items retain their line break across \(style) sections",
                  numbered?.text == numberedPrefix.trimmingCharacters(in: .whitespacesAndNewlines) + "\n2. Preserve the next item." && numbered?.fallbackCount == 0, "")
            let dated = evaluate(english + "2026. The version remains current.", client: Fixture(bullets: false), style: style)
            check("readability: a numeric prose continuation does not start a numbered list in \(style)",
                  dated?.text == english + "2026. The version remains current." && dated?.fallbackCount == 0, "")
        }

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

        let lists: [(String, String)] = [
            ("First check the microphone. Second test Fn.", "- First, check the microphone.\n- Second, test Fn."),
            ("第一检查麦克风第二测试快捷键", "- 第一，检查麦克风。\n- 第二，测试快捷键。"),
            ("一是保留中文二是保留 English", "- 一是保留中文。\n- 二是保留 English。"),
            ("Item one keep alpha. Item two keep alpha.", "- Item one, keep alpha.\n- Item two, keep alpha."),
            ("If approved first Mira checks 12 cases second Chen must not publish before 4:30.", "If approved:\n- First, Mira checks 12 cases.\n- Second, Chen must not publish before 4:30."),
            ("第一 Mira 在 3:30 review 第二 Chen 不要 publish", "- 第一，Mira 在 3:30 review。\n- 第二，Chen 不要 publish。"),
            ("1. Open https://example.com/a. 2. Keep report.txt.", "1. Open https://example.com/a.\n2. Keep report.txt."),
        ]
        for (index, pair) in lists.enumerated() {
            check("readability: explicit list \(index + 1) requests formatting even with existing punctuation",
                  CleanupPolicy.decide(raw: pair.0, cjkSpacing: true, spokenCommands: false).reason == "explicit list", "")
            let scoped = RewriteVerification.requiresLayoutVerification(raw: pair.0, rewritten: pair.1)
            check("readability: list \(index + 1) uses the fast path only when layout cannot rescope a qualifier",
                  RewriteVerification.isNearVerbatim(raw: pair.0, rewritten: pair.1) == !scoped, "")
            for style in [RewriteStyle.light, .full] {
                let fixture = CleanupRegressionTests.RewriteFixture(response: pair.1)
                let result = evaluate(pair.0, client: fixture, style: style)
                check("readability: list \(index + 1) retains all lines and content in \(style)",
                      result?.text == pair.1 && result?.fallbackCount == 0 && result?.requiresRecovery == false &&
                      fixture.cleanupCalls == 1 && fixture.verificationCalls == (style == .full && scoped ? 1 : 0), "")
            }
        }
        for literal in ["Use `first alpha second beta`.", "Open https://example.com/first/second.", "Keep the clear sentence.", "Compare version 1.15 with version 2.15."] {
            check("readability: literals and ordinary prose do not trigger enumeration detection",
                  !CleanupPolicy.hasExplicitEnumeration(literal), literal)
        }
        for counted in ["Two separate asks for tomorrow's handoff: export the numbers, and send a screenshot.",
                        "Three checks: inspect the audio; test Fn; verify the installer.",
                        "2 requests: keep the draft and send the screenshot.",
                        "两个要求：导出数据，并发送截图。", "兩項要求：保留字典，檢查快捷鍵。"] {
            check("readability: counted request introductions cannot be skipped by native Light policy",
                  CleanupPolicy.hasExplicitEnumeration(counted) &&
                  CleanupPolicy.decide(raw: counted, cjkSpacing: true, spokenCommands: false).reason == "explicit list", counted)
        }
        for prose in ["We discussed two requests yesterday and agreed to wait.",
                      "My two visits were different: short yesterday and longer today.",
                      "One request: keep the draft and its title.",
                      "Two requests: keep the draft.",
                      "Keep `two asks: export data and send a screenshot` unchanged.",
                      "我两次出门：昨天很早，今天很晚。"] {
            check("readability: narrative counts, single requests and literal instructions are not counted-list cues",
                  !CleanupPolicy.hasExplicitEnumeration(prose), prose)
        }
        let originalList = "First keep 12 cases. Second do not publish."
        for changedList in ["- First, keep 13 cases.\n- Second, do not publish.", "- First, keep 12 cases."] {
            for style in [RewriteStyle.light, .full] {
                let result = evaluate(originalList, client: CleanupRegressionTests.RewriteFixture(response: changedList, verdict: "FAIL"), style: style)
                check("readability: unsafe list edit retains every original item in \(style)",
                      result?.text == originalList && result?.guardFallbackCount == 1 && result?.requiresRecovery == false, "")
            }
        }
        var listContext = CleanupContext(precedingText: nil, dictionary: [], chineseVariant: .simplified,
                                         allowFormatting: false, spokenCommands: false, cjkSpacing: true,
                                         customInstructions: "")
        for compact in [false, true] {
            listContext.compact = compact
            let prompt = CleanupPrompt.system(listContext)
            check("readability: Light \(compact ? "compact" : "detailed") allows explicit lists with the legacy toggle off",
                  prompt.contains(PublicPromptDefaults.lightCleanup) && !prompt.contains("No bullet points or lists") &&
                  !prompt.contains("Keep prose; do not add lists"), "")
        }
        listContext.rewriteStyle = .full
        listContext.rewritePromptOverride = "Preserve words and use prose only. Never use bullets."
        let overridden = CleanupPrompt.system(listContext)
        check("readability: saved Full prose override replaces the automatic-list default",
              overridden.contains(listContext.rewritePromptOverride!) && !overridden.contains(PublicPromptDefaults.fullRewrite), "")

        let sharedSource = "If approved first Mira checks the installer second Chen updates the guide."
        let narrowed = "- If approved, first Mira checks the installer.\n- Second, Chen updates the guide."
        check("readability: identical ordered words cannot skip verification when a shared condition enters one bullet",
              MeaningGuard.tokens(sharedSource) == MeaningGuard.tokens(narrowed) &&
              !RewriteVerification.isNearVerbatim(raw: sharedSource, rewritten: narrowed), "")
        let rejection = CleanupRegressionTests.RewriteFixture(response: narrowed, verdict: "FAIL")
        let rejected = evaluate(sharedSource, client: rejection)
        check("readability: a scoped-list verifier veto keeps the complete original quietly",
              rejection.verificationCalls == 1 && rejected?.text == sharedSource && rejected?.guardFallbackCount == 1 && rejected?.requiresRecovery == false, "")
        for (source, output) in [
            ("如果批准第一检查安装包第二更新指南", "- 如果批准，第一检查安装包。\n- 第二更新指南。"),
            ("Do not first delete alpha second delete beta.", "- Do not first delete alpha.\n- Second, delete beta."),
            ("If approved:\n- First, check alpha.\n- Second, check beta.", "- If approved, first check alpha.\n- Second, check beta."),
            ("如果批准第一检查安装包第二更新指南", "如果批准，第一检查安装包。\n第二更新指南。"),
            ("If approved first check alpha second check beta.", "If approved, first check alpha.\nSecond, check beta."),
            ("只有测试通过一是更新安装包二是更新指南", "只有测试通过，一是更新安装包。\n二是更新指南。"),
            ("If approved item one checks alpha item two checks beta.", "If approved item one checks alpha.\nItem two checks beta."),
        ] {
            check("readability: Chinese, negated and existing-list scope changes require semantic verification",
                  RewriteVerification.requiresLayoutVerification(raw: source, rewritten: output) &&
                  !RewriteVerification.isNearVerbatim(raw: source, rewritten: output), "")
        }
        let existing = "If approved:\n- First check alpha.\n- Second check beta."
        check("readability: punctuation-only edits to an unchanged conditional list retain the fast path",
              RewriteVerification.isNearVerbatim(raw: existing, rewritten: existing.replacingOccurrences(of: "First check", with: "First, check")), "")
        let chineseOrdinals = "如果批准：\n第一检查安装包。\n第二更新指南。"
        check("readability: punctuation-only edits to unchanged Chinese ordinal lines retain the fast path",
              RewriteVerification.isNearVerbatim(raw: chineseOrdinals, rewritten: chineseOrdinals.replacingOccurrences(of: "第一检查", with: "第一，检查")), "")
        check("readability: plain ordinal lists without scoped language retain the fast path",
              RewriteVerification.isNearVerbatim(raw: "First check alpha second check beta.", rewritten: "First, check alpha.\nSecond, check beta."), "")
        let ordinalNarrowed = "If approved, first Mira checks the installer.\nSecond, Chen updates the guide."
        let ordinalRejection = CleanupRegressionTests.RewriteFixture(response: ordinalNarrowed, verdict: "FAIL")
        let ordinalRejected = evaluate(sharedSource, client: ordinalRejection)
        check("readability: a verifier veto of unbulleted ordinal scope preserves the full source",
              ordinalRejection.verificationCalls == 1 && ordinalRejected?.text == sharedSource &&
              ordinalRejected?.guardFallbackCount == 1 && ordinalRejected?.requiresRecovery == false, "")
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
