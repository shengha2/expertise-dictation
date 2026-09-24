import Foundation

/// Synthetic addresses and injected providers only: no microphone, network, saved keys,
/// personal dictionary changes, clipboard writes or email delivery.
enum EmailAddressRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        let formatted: [(String, String)] = [
            ("E X A M P L E at gmail.com", "example@gmail.com"),
            ("My email is alice at gmail dot com.", "My email is alice@gmail.com."),
            ("My email is alice dot chen plus work at outlook dot com", "My email is alice.chen+work@outlook.com"),
            ("我的邮箱是 alice 艾特 gmail 点 com。", "我的邮箱是 alice@gmail.com。"),
            ("邮箱 a l i c e 下划线 w o r k 加号 2 at example 点 co 点 uk", "邮箱 alice_work+2@example.co.uk"),
            ("Email is A L E X at G M A I L dot C O M", "Email is alex@gmail.com"),
            ("Email is jane at G mail dot com", "Email is jane@gmail.com"),
            ("Email is jane at G-mail.com", "Email is jane@gmail.com"),
            ("发到 a l e x 艾特 example 点 com，谢谢", "发到 alex@example.com，谢谢"),
            ("Please use jane dot doe at example dot org", "Please use jane.doe@example.org"),
            ("Email is a at example dot com", "Email is a@example.com"),
            ("a h at example.com", "ah@example.com"),
            ("A A at example.com", "aa@example.com"),
            ("A 1 0 at example.com", "a10@example.com"),
            ("jane @ example dot com", "jane@example.com"),
            ("邮箱是 alice 艾特 example 点 com，email is bob at example dot net。", "邮箱是 alice@example.com，email is bob@example.net。"),
        ]
        for (index, pair) in formatted.enumerated() {
            let output = EmailAddressFormatting.format(pair.0)
            check("email: explicit spelling fixture \(index + 1)", output == pair.1, output)
            check("email: formatting is idempotent \(index + 1)", EmailAddressFormatting.format(output) == output, output)
        }
        let unchanged = [
            "Look at gmail.com", "We discussed email and looked at gmail.com", "Meet me at noon.",
            "The dot product uses A B C.", "Use G M A I L as an acronym.", "alice at gmail.com",
            "Email is alice at Gmail", "A B at gmail", "A B at gmail dot", "A B at .com",
            "A B\nat gmail.com", "A B at\ngmail.com", "A B at gmail..com",
            "Email is john..doe at gmail.com", "Email is john at gmail.com_extra",
            "Email is john at -gmail.com", "Email is john at gmail-.com",
            "Email is A L E X at gmail dot C O M I will send details",
            "Uh.Uh+Mm_01@EXAMPLE.com", "A.A@Example.COM", "I'm@example.com",
            "\"Fred Bloggs\"@example.com", "user@[127.0.0.1]", "Email is Alex@G-mail.com",
        ]
        for (index, input) in unchanged.enumerated() {
            let output = EmailAddressFormatting.format(input)
            check("email: literal/ambiguous/incomplete fixture \(index + 1) stays unchanged", output == input, output)
        }
        for address in ["Uh.Uh+Mm_01@EXAMPLE.com", "A.A@Example.COM", "I'm@example.com", "aa.aa@example.com", "\"Fred Bloggs\"@example.com"] {
            check("email: Light preserves literal address \(address)", LocalCleanup.light(address, cjkSpacing: true) == address, "")
            check("email: Verbatim preserves literal address \(address)", LocalCleanup.normalize(address, cjkSpacing: true) == address, "")
        }
        check("email: mixed Chinese spacing does not become part of address", LocalCleanup.light("发给Uh.Uh@EXAMPLE.com谢谢。", cjkSpacing: true) == "发给 Uh.Uh@EXAMPLE.com 谢谢。", "")
        check("email: filler-looking spelled username survives Light", LocalCleanup.light("a h at example.com", cjkSpacing: true) == "ah@example.com", "")
        check("email: formatted address survives Verbatim", LocalCleanup.normalize("E X A M P L E at gmail.com", cjkSpacing: true) == "example@gmail.com", "")
        var target = InsertionTarget()
        target.charBefore = "s"
        check("email: mid-sentence insertion keeps address case", TextInserter.applySpacing("Alex@Example.com", target: target, cjkSpacing: true) == " Alex@Example.com", "")
        let dictionary = Replacements.parse("um => okay\nexample => sample\nmy work email => um@example.com\nold@example.org => New@Example.net")
        check("email: dictionary words cannot modify an existing address", Replacements.apply(dictionary, to: "um@example.com") == "um@example.com", "")
        check("email: phrase-to-address dictionary result does not cascade into word rules", Replacements.apply(dictionary, to: "my work email") == "um@example.com", "")
        check("email: explicit complete-address dictionary rule remains authoritative", Replacements.apply(dictionary, to: "old@example.org") == "New@Example.net", "")
        check("email: dictionary still changes ordinary words around email", Replacements.apply(dictionary, to: "um use um@example.com as an example") == "okay use um@example.com as an sample", "")

        let original = "Send to Uh.Uh+01@Example.com and aa.aa@example.net."
        for changed in [
            "Send to Uh+01@Example.com and aa.aa@example.net.",
            "Send to Uh.Uh+01@example.com and aa.aa@example.net.",
            "Send to Uh.Uh+01@Example.com.",
            "Send to Uh.Uh+01@Example.com and aa.aa@example.net and extra@example.com.",
        ] {
            check("email: Light guard rejects changed or missing address", !MeaningGuard.evaluate(raw: original, cleaned: changed, threshold: 0.35).accepted, changed)
            check("email: Full guard rejects changed or missing address", !RewriteVerification.passesBasicChecks(raw: original, rewritten: changed), changed)
        }
        let spoken = "Email is A 1 0 at example dot com."
        let written = "Email is a10@example.com."
        check("email: Light guard accepts safe spelled-letter formatting", MeaningGuard.evaluate(raw: spoken, cleaned: written, threshold: 0.35).accepted, "")
        check("email: Full guard accepts safe spelled-digit formatting", RewriteVerification.passesBasicChecks(raw: spoken, rewritten: written), "")
        let duplicate = "aa@example.com and aa@example.com"
        check("email: guard counts duplicate addresses", !RewriteVerification.passesBasicChecks(raw: duplicate, rewritten: "aa@example.com"), "")

        let boundary = String(repeating: "Keep this text. ", count: 118) + "Uh.Uh+01@Example.com" + String(repeating: " Keep that text.", count: 125)
        let pieces = LongTextProcessing.chunks(boundary)
        check("email: chunks reproduce full input at address boundary", pieces.joined() == boundary, "")
        check("email: section boundary never splits email", pieces.flatMap { EmailAddressFormatting.addresses(in: $0) } == ["Uh.Uh+01@Example.com"], "")
        let oversizedIdentifier = String(repeating: "x", count: 10_000) + "@example.com"
        let bounded = LongTextProcessing.chunks(oversizedIdentifier)
        check("email: malformed oversized address does not bypass chunk budgets", bounded.joined() == oversizedIdentifier && bounded.allSatisfy { $0.count <= 1800 }, "")
        let prose = String(repeating: "Look at the report, then meet at noon. We discussed email and looked at gmail.com. ", count: 2000)
        let started = Date()
        let unchangedProse = EmailAddressFormatting.format(prose)
        let elapsed = Date().timeIntervalSince(started)
        print("Email prose stress: \(prose.count) characters, \(elapsed) seconds")
        check("email: long ordinary prose stays unchanged with bounded candidate scans", unchangedProse == prose && elapsed < 8, "elapsed=\(elapsed)s, characters=\(prose.count)")
        for limit in 1...24 {
            let chunks = LongTextProcessing.chunks("xx " + original + " yy", limit: limit)
            check("email: chunk limit \(limit) keeps whole addresses", chunks.joined() == "xx " + original + " yy" && chunks.flatMap { EmailAddressFormatting.addresses(in: $0) } == ["Uh.Uh+01@Example.com", "aa.aa@example.net"], "")
        }
        var context = CleanupContext(precedingText: nil, dictionary: [], chineseVariant: .simplified,
                                     allowFormatting: false, spokenCommands: false, cjkSpacing: true, customInstructions: "")
        check("email: recognition prompt includes letter and symbol hints", STTFactory.transcriptionPrompt(settings: Settings.shared).contains(EmailAddressFormatting.recognitionHint), "")
        check("email: Light prompt includes precise preservation rule", CleanupPrompt.system(context).contains(EmailAddressFormatting.cleanupRule), "")
        context.rewriteStyle = .full
        check("email: Full prompt includes precise preservation rule", CleanupPrompt.system(context).contains(EmailAddressFormatting.cleanupRule), "")
        check("email: translation prompt includes precise preservation rule", Translator.system(target: .find("zh-Hans"), dictionary: []).contains(EmailAddressFormatting.cleanupRule), "")

        for style: RewriteStyle in [.light, .full] {
            context.rewriteStyle = style
            let requestedContext = context
            for (name, client, fallback) in [
                ("echo", CleanupRegressionTests.Fixture(), false),
                ("provider failure", CleanupRegressionTests.Fixture(failure: .http(503, "fixture offline")), true),
                ("bad model output", CleanupRegressionTests.Fixture(response: "Email is changed@example.com."), true),
            ] {
                var result: LongTextProcessing.CleanupResult?
                let task = Task { @MainActor in
                    result = try? await LongTextProcessing.cleanup(spoken, context: requestedContext, settings: Settings.shared, client: client) { _, _ in }
                }
                wait { result != nil }
                task.cancel()
                check("email: \(style) \(name) retains complete formatted address", result?.text == written && (result?.fallbackCount == 1) == fallback, result?.text ?? "no result")
            }
        }
        for (response, shouldFail) in [("请发给 Alex+01@Example.com。", false), ("请发给 alex+01@example.com。", true), ("请发给某个人。", true)] {
            var finished = false
            var failed = false
            var output: String?
            let task = Task { @MainActor in
                do {
                    output = try await Translator.translate("Send to Alex+01@Example.com.", to: .find("zh-Hans"), settings: Settings.shared, timeout: 1,
                                                            client: CleanupRegressionTests.Fixture(response: response)).0
                } catch { failed = true }
                finished = true
            }
            wait { finished }
            task.cancel()
            check("email: translation preserves address or fails safely", finished && failed == shouldFail && (shouldFail || output == response), response)
        }
    }

    private static func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
}
