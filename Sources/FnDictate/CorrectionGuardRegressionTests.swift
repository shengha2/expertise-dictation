import Foundation

/// Synthetic corrections and adversarial near-misses; never reads recordings or contacts a provider.
enum CorrectionGuardRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        let mixed = "这个 pilot 先跑六周，不对，八周；预算不是说要改，我刚才改的只是时长。Keep the budget at USD 20,000. Kickoff 是 Tuesday，sorry，Wednesday afternoon，但客户自己邮件里写的 Tuesday 还是要留在引用里。"
        let corrected = "这个 pilot 先跑八周；预算不是说要改，我刚才改的只是时长。Keep the budget at USD 20,000. Kickoff 是 Wednesday afternoon，但客户自己邮件里写的 Tuesday 还是要留在引用里。"
        check("correction: bilingual final corrections pass Light without losing the independent weekday",
              MeaningGuard.evaluate(raw: mixed, cleaned: corrected, threshold: 0.35).accepted &&
              MixedLanguageGuard.preservesEnglishWords(from: mixed, in: corrected), "")
        check("correction: bilingual final corrections pass Full basic checks",
              RewriteVerification.passesBasicChecks(raw: mixed, rewritten: corrected), "")
        let noSpaces = "Kickoff是Tuesday，sorry，Wednesday，但Tuesday会议仍保留。"
        check("correction: Latin repair does not swallow an adjacent Chinese prefix",
              MeaningGuard.resolveExplicitCorrections(noSpaces) == "Kickoff是Wednesday，但Tuesday会议仍保留。", "")
        for (raw, final) in [("Send it to Анна, sorry, Нина.", "Send it to Нина."),
                             ("Send it to Renée, sorry, Anaïs.", "Send it to Anaïs."),
                             ("提到Αλέξης，sorry，Νίκος。", "提到Νίκος。")] {
            check("correction: multilingual alphabetic names still support explicit corrections",
                  MeaningGuard.resolveExplicitCorrections(raw) == final, raw)
        }
        for (unit, from, to) in [("周", "六", "八"), ("天", "三", "五"), ("分鐘", "十", "十五"), ("个月", "两", "三")] {
            let raw = "试行\(from)\(unit)，不对，\(to)\(unit)，但旧的\(from)\(unit)计划仍保留。"
            check("correction: same-unit \(unit) repair preserves an independent duration",
                  MeaningGuard.resolveExplicitCorrections(raw) == "试行\(to)\(unit)，但旧的\(from)\(unit)计划仍保留。", "")
        }
        for raw in ["六周还是八周？", "六周不对吗，八周呢？", "六周，不对，八个月。", "这句“六周，不对，八周”要逐字保留。"] {
            if raw.contains("“") {
                check("correction: quoted correction cannot be applied as an instruction",
                      !RewriteVerification.passesBasicChecks(raw: raw, rewritten: "这句“八周”要逐字保留。"), "")
            } else {
                check("correction: ambiguous or different-unit duration is not repaired", MeaningGuard.resolveExplicitCorrections(raw) == raw, raw)
            }
        }
        for output in [corrected.replacingOccurrences(of: "USD 20,000", with: "USD 30,000"),
                       corrected.replacingOccurrences(of: "八周", with: "九周"),
                       corrected.replacingOccurrences(of: "不是说要改", with: "是说要改"),
                       corrected.replacingOccurrences(of: "Wednesday afternoon", with: "Thursday afternoon"),
                       corrected.replacingOccurrences(of: "Tuesday 还是", with: "还是")] {
            let accepted = MeaningGuard.evaluate(raw: mixed, cleaned: output, threshold: 0.35).accepted &&
                MixedLanguageGuard.preservesEnglishWords(from: mixed, in: output)
            check("correction: changed amount, negation, final day or independent day stays rejected", !accepted, output)
        }
        let durations = "这个 pilot 先跑六周，不对，八周，旧的六周计划仍保留，其他所有条件和预算不变。"
        for output in ["这个 pilot 先跑九周，旧的六周计划仍保留，其他所有条件和预算不变。",
                       "这个 pilot 先跑八周，旧的计划仍保留，其他所有条件和预算不变。",
                       "这个 pilot 先跑八天，旧的六周计划仍保留，其他所有条件和预算不变。"] {
            let rejected = MeaningGuard.evaluate(raw: durations, cleaned: output, threshold: 0.50)
            check("correction: final, independent and unit duration changes are hard failures even at loose threshold",
                  !rejected.accepted && !rejected.canVerifyFalseStart && rejected.reason == "a duration changed", output)
        }

        for prefix in ["One more thing: ", "Actually, one more thing: ", "We finished. One more thing: "] {
            let suffix = "Keep one backup and test two laptops before the three checks."
            let target = (prefix.hasPrefix("We") ? "We finished. " : "") + suffix
            check("correction: colon-delimited additional-point marker is not a quantity",
                  MeaningGuard.evaluate(raw: prefix + suffix, cleaned: target, threshold: 0.35).accepted, "")
            check("correction: marker removal cannot also drop an independent one quantity",
                  !MeaningGuard.evaluate(raw: prefix + suffix, cleaned: target.replacingOccurrences(of: "one backup", with: "backup"), threshold: 0.35).accepted, "")
        }
        for (raw, output) in [
            ("Buy one more thing: a spare cable.", "Buy a spare cable."),
            ("One more thing is missing: a spare cable.", "A spare cable is missing."),
            ("I need one more thing before the demo.", "I need something before the demo."),
            ("Keep two copies. One more thing: test three laptops.", "Keep copies. Test three laptops."),
        ] {
            check("correction: real quantities remain protected", !MeaningGuard.evaluate(raw: raw, cleaned: output, threshold: 0.35).accepted, raw)
        }
        let quantityPrefix = "We reviewed the release with Maya and kept all of the original notes. "
        let quantitySource = quantityPrefix + "One more thing: Keep one backup and test two laptops."
        for marker in ["One more thing, ", "One more thing—", "One more thing ", "One\nmore\nthing\n", "One last thing: ", "One final note: ", "One additional point: "] {
            let missing = quantityPrefix + marker + "Keep backup and test two laptops."
            let bad = MeaningGuard.evaluate(raw: quantitySource, cleaned: missing, threshold: 0.50)
            check("correction: retained or reworded discourse one cannot replace a missing quantity",
                  !bad.accepted && !bad.canVerifyFalseStart, marker)
        }
        for marker in ["One more thing, ", "One more thing—", "One more thing ", "One\nmore\nthing\n", ""] {
            let preserved = quantityPrefix + marker + "Keep one backup and test two laptops."
            check("correction: harmless marker punctuation or removal preserves real quantities",
                  MeaningGuard.evaluate(raw: quantitySource, cleaned: preserved, threshold: 0.35).accepted, marker)
        }

        let raw = "We reviewed the release with Maya and kept all of the original notes. The thing about the dictionary, I mean the important part, is that existing entries survived the upgrade. Keep the invoice at 250 dollars and do not publish before Friday. Preserve the appendix and bibliography."
        let repaired = "We reviewed the release with Maya and kept all of the original notes. The important part about the dictionary is that existing entries survived the upgrade. Keep the invoice at 250 dollars and do not publish before Friday. Preserve the appendix and bibliography."
        let verdict = MeaningGuard.evaluate(raw: raw, cleaned: repaired, threshold: 0.35)
        check("correction: small explicit false-start repair requires semantic approval, never local acceptance",
              !verdict.accepted && verdict.canVerifyFalseStart && verdict.ratio <= 0.22, verdict.reason)
        let ordinary = raw.replacingOccurrences(of: ", I mean the important part,", with: "")
        check("correction: ordinary small paraphrase without an explicit false start cannot request verification",
              !MeaningGuard.evaluate(raw: ordinary, cleaned: repaired, threshold: 0.35).canVerifyFalseStart, "")
        let literalMarker = ordinary + " The exact quote is `item, I mean the important part`."
        check("correction: a marker inside a quote cannot authorize unrelated rewording",
              !MeaningGuard.evaluate(raw: literalMarker, cleaned: repaired + " The exact quote is `item, I mean the important part`.", threshold: 0.35).canVerifyFalseStart, "")
        let broadRewrite = "We reviewed everything with Maya. The important dictionary entries survived, so keep the invoice at 250 dollars and do not publish before Friday. Preserve the appendix and bibliography."
        check("correction: a broad false-start rewrite is ineligible for Light verification",
              !MeaningGuard.evaluate(raw: raw, cleaned: broadRewrite, threshold: 0.35).canVerifyFalseStart, "")

        func evaluate(_ source: String, _ fixture: Fixture, cancelAtVerification: Bool = false) -> (LongTextProcessing.CleanupResult?, Bool) {
            var result: LongTextProcessing.CleanupResult?
            var cancelled = false, finished = false
            let context = CleanupContext(precedingText: nil, dictionary: [], chineseVariant: .simplified,
                                         allowFormatting: false, spokenCommands: false, cjkSpacing: true,
                                         customInstructions: "", rewriteStyle: .light)
            let task = Task { @MainActor in
                defer { finished = true }
                do {
                    result = try await LongTextProcessing.cleanup(source, context: context, settings: Settings.shared,
                                                                   client: fixture) { _, _ in }
                } catch is CancellationError { cancelled = true }
                catch { }
            }
            let deadline = Date().addingTimeInterval(5)
            while !finished && Date() < deadline {
                if cancelAtVerification && fixture.verifications > 0 { task.cancel() }
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            task.cancel()
            return (result, cancelled)
        }
        let approve = Fixture(repaired)
        let accepted = evaluate(raw, approve).0
        check("correction: bounded Light repair is accepted only after a semantic PASS",
              accepted?.text == repaired && accepted?.fallbackCount == 0 && approve.verifications == 1 && approve.usedLightPrompt, "")
        let withMarker = raw + " Actually, one more thing: Keep one backup and test two laptops."
        for marker in ["One more thing: ", ""] {
            let output = repaired + " " + marker + "Keep one backup and test two laptops."
            let eligibility = MeaningGuard.evaluate(raw: withMarker, cleaned: output, threshold: 0.35)
            check("correction: retained or removed discourse marker preserves the eligible comparison alternative",
                  !eligibility.accepted && eligibility.canVerifyFalseStart, marker)
            let fixture = Fixture(output)
            let result = evaluate(withMarker, fixture).0
            check("correction: retained or removed discourse marker reaches Light semantic approval",
                  result?.text == output && result?.fallbackCount == 0 && fixture.verifications == 1, marker)
            for wrong in [output.replacingOccurrences(of: "two laptops", with: "three laptops"),
                          output.replacingOccurrences(of: "one backup", with: "backup"),
                          output.replacingOccurrences(of: "250", with: "251")] {
                let verdict = MeaningGuard.evaluate(raw: withMarker, cleaned: wrong, threshold: 0.35)
                let unsafe = Fixture(wrong)
                let kept = evaluate(withMarker, unsafe).0
                check("correction: discourse alternatives cannot hide changed or missing real quantities",
                      !verdict.accepted && !verdict.canVerifyFalseStart && unsafe.verifications == 0 && kept?.text == withMarker, wrong)
            }
        }
        let reject = Fixture(repaired, verdict: "FAIL")
        let veto = evaluate(raw, reject).0
        check("correction: semantic FAIL preserves the exact complete source without recovery",
              veto?.text == raw && veto?.guardFallbackCount == 1 && veto?.requiresRecovery == false && reject.verifications == 1, "")
        let missingName = repaired.replacingOccurrences(of: "with Maya ", with: "")
        let lostName = Fixture(missingName, verdict: "FAIL")
        let retainedName = evaluate(raw, lostName).0
        check("correction: a critical unique detail omitted during a false-start repair remains rejected",
              retainedName?.text == raw && retainedName?.guardFallbackCount == 1, "")
        let failed = Fixture(repaired, failure: true)
        let recovered = evaluate(raw, failed).0
        check("correction: unavailable Light verifier retains raw and records provider recovery",
              recovered?.text == raw && recovered?.providerFallbackCount == 1 && recovered?.requiresRecovery == true && failed.verifications == 1, "")
        let suspended = Fixture(repaired, suspend: true)
        let cancellation = evaluate(raw, suspended, cancelAtVerification: true)
        check("correction: cancellation during Light verification propagates without delivering a result",
              cancellation.0 == nil && cancellation.1 && suspended.verifications == 1, "")
        for (source, output) in [
            (raw, repaired.replacingOccurrences(of: "250", with: "251")),
            (raw, repaired.replacingOccurrences(of: "dollars", with: "euros")),
            (raw, repaired.replacingOccurrences(of: "do not", with: "do")),
            (raw + " Keep `cache_key = false`.", repaired + " Keep `cache_key = true`."),
            (raw + " 这个 API may fail。", repaired + " 这个 API will fail。"),
            (ordinary, repaired),
        ] {
            let fixture = Fixture(output)
            let result = evaluate(source, fixture).0
            check("correction: protected fact or ordinary paraphrase rejection never reaches Light verifier",
                  fixture.verifications == 0 && result?.text == source && result?.guardFallbackCount == 1, output)
        }
    }

    private final class Fixture: LLMClient {
        let name = "offline-correction-guard"
        let output: String, verdict: String
        let failure: Bool, suspend: Bool
        var verifications = 0, usedLightPrompt = false
        init(_ output: String, verdict: String = "PASS", failure: Bool = false, suspend: Bool = false) {
            self.output = output; self.verdict = verdict; self.failure = failure; self.suspend = suspend
        }
        func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
            if system == RewriteVerification.lightFalseStartPrompt || system == RewriteVerification.systemPrompt {
                verifications += 1
                usedLightPrompt = system == RewriteVerification.lightFalseStartPrompt
                if suspend { try await Task.sleep(nanoseconds: 10_000_000_000) }
                if failure { throw LLMError.http(503, "synthetic unavailable verifier") }
                return verdict
            }
            return output
        }
    }
}
