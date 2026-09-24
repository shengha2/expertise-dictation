import Foundation

/// Synthetic offline cases covering Chinese glyph normalization, literal integrity and the
/// verifier shortcut. Missing sentence boundaries belong to model evaluation, not regex guesses.
enum PunctuationRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        let examples: [(String, String)] = [
            ("今天先测试,明天再发布.", "今天先测试，明天再发布。"),
            ("今天先測試,明天再發布.", "今天先測試，明天再發布。"),
            ("可以吗?! 先别发布;原因如下:还没测完.", "可以吗？！ 先别发布；原因如下：还没测完。"),
            ("我同意, but keep it simple. 明天再讨论.", "我同意， but keep it simple. 明天再讨论。"),
            ("这个问题...我还没想好", "这个问题...我还没想好"),
            ("先测试然后发布", "先测试然后发布"),
            ("Plain English, with a question?", "Plain English, with a question?"),
            ("版本是3.14,明天再测.", "版本是3.14，明天再测。"),
            ("请打开中文.swift,不要修改.", "请打开中文.swift，不要修改。"),
            ("请看https://example.com/a?x=3.14&y=2，稍后回复.", "请看https://example.com/a?x=3.14&y=2，稍后回复。"),
            ("邮箱是Alex+notes@Example.com,请保留大小写.", "邮箱是Alex+notes@Example.com，请保留大小写。"),
            ("保留 `print(\"你好,世界.\")`，然后退出.", "保留 `print(\"你好,世界.\")`，然后退出。"),
            ("他说\"原文,不要修改.\"，我同意.", "他说\"原文,不要修改.\"，我同意。"),
            ("路径是 /Users/alex/notes.txt，别改.", "路径是 /Users/alex/notes.txt，别改。"),
            ("代码如下：\n```swift\nlet s = \"你好,世界.\"\n```\n请保留.", "代码如下：\n```swift\nlet s = \"你好,世界.\"\n```\n请保留。"),
        ]
        for (index, example) in examples.enumerated() {
            let output = DictationPunctuation.normalizeChinese(example.0)
            check("punctuation: protected normalization example \(index + 1)", output == example.1, output)
            check("punctuation: normalization is idempotent example \(index + 1)", DictationPunctuation.normalizeChinese(output) == output, "")
        }
        let literal = "https://example.com/um/um?x=3.14&y=2"
        let local = LocalCleanup.light("um 请看 " + literal + "，保留 `let n = 3.14; // 嗯`。", cjkSpacing: true)
        check("punctuation: local filler cleanup preserves URL and delimited code", local.contains(literal) && local.contains("`let n = 3.14; // 嗯`"), local)
        check("punctuation: quoted literal spaces remain exact", LocalCleanup.normalize("原文是 \"中 文  A, B.\"。", cjkSpacing: true).contains("\"中 文  A, B.\""), "")
        for literal in ["`email is A L E X at gmail dot com`", "\"email is A L E X at gmail dot com\"", "“email is A L E X at gmail dot com”", "'email is A L E X at gmail dot com'", "```text\nemail is A L E X at gmail dot com\n```"] {
            let raw = "保留 " + literal + "。 My email is B O B at gmail.com."
            let formatted = DictationPunctuation.formatSpokenAddresses(raw)
            check("email: spoken words inside a literal remain while an outside address formats", formatted.contains(literal) && formatted.contains("bob@gmail.com"), formatted)
            check("email: local cleanup keeps the literal example exact", LocalCleanup.normalize(raw, cjkSpacing: true).contains(literal), "")
        }
        check("email: a quoted username is not substituted with a mask token", DictationPunctuation.formatSpokenAddresses("email \"alex\" at gmail.com") == "email \"alex\" at gmail.com", "")

        for raw in ["", " \n\t", "嗯 um 呃", "Um, uh。", "嗯嗯，呃呃。", "hmm; erm"] {
            check("filler-only: strictly recognized hesitation can produce empty text", LocalCleanup.isEmptyOrHesitationOnly(raw) && RewriteVerification.passesBasicChecks(raw: raw, rewritten: ""), raw)
        }
        for raw in ["actually", "就是", "啊", "嗯？", "hmm?", "um actually", "额", "umbrella", "umum", "嗯我同意", "。", "1", "um@example.com", "um.swift", "`um`", "\"嗯\"", "“呃”"] {
            check("filler-only: meaningful, uncertain or literal content cannot be erased", !LocalCleanup.isEmptyOrHesitationOnly(raw) && !RewriteVerification.passesBasicChecks(raw: raw, rewritten: ""), raw)
        }
        let filenameSource = "请打开 中文.swift 看看配置"
        check("literal boundaries: punctuation around a separated Chinese filename is safe", DictationPunctuation.preservesLiterals(from: filenameSource, in: "请打开 中文.swift，看看配置。"), "")
        check("literal boundaries: never guess a Chinese prefix is prose rather than a renamed file", !DictationPunctuation.preservesLiterals(from: filenameSource, in: "请打开 修改中文.swift，看看配置。"), "")
        check("literal boundaries: public prompt preserves filename whitespace", PublicPromptDefaults.punctuation.contains("Preserve existing whitespace that separates an unquoted filename or path from prose"), "")

        let paragraph = String(repeating: "甲", count: 950) + "\n\n"
        let paragraphs = paragraph + String(repeating: "乙", count: 1100)
        let paragraphChunks = LongTextProcessing.chunks(paragraphs)
        check("chunking: prefer an existing paragraph to a later arbitrary cut", paragraphChunks.first == paragraph && paragraphChunks.joined() == paragraphs && paragraphChunks.allSatisfy { $0.count <= 1800 }, "")
        let sentence = String(repeating: "甲", count: 1000) + "。"
        let sentences = sentence + String(repeating: "乙", count: 1100)
        check("chunking: Chinese sentence boundaries work without spaces", LongTextProcessing.chunks(sentences).first == sentence, "")
        for literal in [
            "https://Example.com/" + String(repeating: "path", count: 40) + "?x=3.14",
            "/Users/Ivy/" + String(repeating: "folder/", count: 24) + "notes.json",
            "“" + String(repeating: "quoted words. ", count: 15) + "”",
            "```swift\n" + String(repeating: "let n = 3.14;\n", count: 14) + "```",
        ] {
            let source = String(repeating: "甲", count: 1698) + "👩🏽‍💻 " + literal + " 结尾" + String(repeating: "乙", count: 1800)
            let pieces = LongTextProcessing.chunks(source)
            check("chunking: bounded literal stays whole with Unicode offsets", pieces.contains { $0.contains(literal) } && pieces.joined() == source && pieces.allSatisfy { $0.count <= 1800 }, literal.prefix(30).description)
        }
        for literal in ["```\n" + String(repeating: "x", count: 6000) + "\n```", "\"" + String(repeating: "字", count: 6000) + "\"", "https://example.com/" + String(repeating: "a", count: 6000)] {
            let pieces = LongTextProcessing.chunks(literal)
            check("chunking: oversized literals never bypass provider bounds", pieces.count >= 4 && pieces.joined() == literal && pieces.allSatisfy { $0.count <= 1800 }, "")
        }
        let smallLimitURL = "https://example.com/" + String(repeating: "a", count: 120)
        check("chunking: small explicit limits do not exempt long URLs", LongTextProcessing.chunks(smallLimitURL, limit: 40).allSatisfy { $0.count <= 40 }, "")
        let lineEnding = String(repeating: "a", count: 960) + "\r\n\r\n"
        let lineSource = lineEnding + String(repeating: "b", count: 1300)
        check("chunking: existing CRLF paragraphs and exact source bytes survive", LongTextProcessing.chunks(lineSource).first == lineEnding && LongTextProcessing.chunks(lineSource).joined().utf8.elementsEqual(lineSource.utf8), "")

        func inspectContexts(_ raw: String) -> [String?] {
            let fixture = ContextFixture()
            let requested = CleanupContext(precedingText: "External unfinished sentence", dictionary: [], chineseVariant: .simplified,
                                           allowFormatting: false, spokenCommands: false, cjkSpacing: true, customInstructions: "")
            var done = false
            let task = Task { @MainActor in
                _ = try? await LongTextProcessing.cleanup(raw, context: requested, settings: Settings.shared, client: fixture) { _, _ in }
                done = true
            }
            let end = Date().addingTimeInterval(5)
            while !done && Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            task.cancel()
            return fixture.contexts
        }
        for separator in ["\n\n", "\r\n", "\n  "] {
            let contexts = inspectContexts(String(repeating: "a", count: 1000) + separator + String(repeating: "b", count: 1100))
            check("chunk context: first external context stays, a new paragraph receives none", contexts.count == 2 && contexts[0] == "External unfinished sentence" && contexts[1] == nil, separator.debugDescription)
        }
        let continuationContexts = inspectContexts(String(repeating: "a", count: 1000) + " " + String(repeating: "b", count: 1100))
        check("chunk context: real mid-sentence continuation retains preceding output", continuationContexts.count == 2 && continuationContexts[0] == "External unfinished sentence" && continuationContexts[1] == String(repeating: "a", count: 300), "")

        let cases: [(String, Bool)] = [
            ("请先检查 https://example.com 然后把修改结果发给同事再决定是否发布", true),
            ("当前版本是 1.2.3 请先测试所有功能然后把结果发给同事", true),
            ("请发邮件到 Alex@Example.com 然后告诉我测试是否已经全部通过", true),
            ("你今天去吗", true),
            ("已经确认。" + String(repeating: "我们仍需继续检查所有细节", count: 6), true),
            ("检查已完成，请发给同事。", false),
            ("See https://example.com for details.", false),
        ]
        for (index, fixture) in cases.enumerated() {
            let decision = CleanupPolicy.decide(raw: fixture.0, cjkSpacing: true, spokenCommands: false)
            check("punctuation: cleanup policy example \(index + 1)", decision.needsModel == fixture.1, decision.reason)
        }

        let unchanged = "嗯，我们可能明天发布，但是如果测试失败就不要发布。"
        check("verification: punctuation and obvious filler keep the fast path", RewriteVerification.isNearVerbatim(raw: unchanged, rewritten: "我们可能明天发布，但是如果测试失败就不要发布。"), "")
        let long = String(repeating: "我们会认真检查所有记录，然后再讨论下一步。", count: 12)
        check("verification: missing Chinese uncertainty cannot skip semantic checking", !RewriteVerification.isNearVerbatim(raw: long + "我们可能明天发布。", rewritten: long + "我们明天发布。"), "")
        check("verification: added Chinese certainty cannot skip semantic checking", !RewriteVerification.isNearVerbatim(raw: long + "我们明天发布。", rewritten: long + "我们肯定明天发布。"), "")
        let prefix = String(repeating: "Keep all these original details. ", count: 15)
        check("verification: swapped owners cannot skip semantic checking", !RewriteVerification.isNearVerbatim(raw: prefix + "Mira reviews and Chen tests.", rewritten: prefix + "Chen reviews and Mira tests."), "")
        for (raw, changed) in [
            ("I may ship tomorrow.", "I ship tomorrow."),
            ("I actually liked this version.", "I liked this version."),
            ("Do not publish 12 cases.", "Do publish 12 cases."),
            ("请不要发布。", "请发布。"),
            ("Keep 12 cases.", "Keep 13 cases."),
            ("Send Alex@Example.com the file.", "Send alex@example.com the file."),
        ] {
            check("verification: changed value or qualifier remains checked: \(raw)", !RewriteVerification.isNearVerbatim(raw: raw, rewritten: changed), "")
        }
        for (raw, changed) in [
            ("Open https://Example.com/A?q=1.", "Open https://example.com/A?q=1."),
            ("Keep `let active = false`.", "Keep `let active = true`."),
            ("打开 /Users/Alex/notes.txt。", "打开 /Users/Alex/Notes.txt。"),
        ] {
            check("verification: literal change is rejected before the model", !RewriteVerification.passesBasicChecks(raw: raw, rewritten: changed), "")
        }
        for (source, output, expected) in [
            ("请在 by 5 pm 发给我", "请在下午 5 点发给我", false),
            ("如果 if the tests pass 我们再发布", "如果测试通过我们再发布", false),
            ("这个 API may fail 所以先测试", "这个 API will fail，所以先测试。", false),
            ("我们需要 review before lunch 然后再 merge", "我们需要 review，然后在午饭前 merge。", false),
            ("这个 actually 很重要", "这个很重要。", false),
            ("这个 um API 是新的", "这个 API 是新的。", true),
            ("这个 API may fail 所以先测试", "这个 API may fail，所以先测试。", true),
            ("I think we should wait.", "We should wait, I think.", true),
        ] {
            check("languages: mixed-language word integrity \(source)", MixedLanguageGuard.preservesEnglishWords(from: source, in: output) == expected, "")
        }
        let repairedWeekday = "我们周二不对周三去测试但周二的会议还保留"
        let correctedWeekday = "我们周三去测试，但周二的会议还保留。"
        check("correction: unpunctuated explicit weekday repair preserves a later weekday", MeaningGuard.resolveExplicitCorrections(repairedWeekday) == "我们周三去测试但周二的会议还保留", "")
        check("correction: narrow weekday repair passes Light guard", MeaningGuard.evaluate(raw: repairedWeekday, cleaned: correctedWeekday, threshold: 0.35).accepted, "")
        check("correction: narrow weekday repair is eligible for the ordered-content fast path", RewriteVerification.isNearVerbatim(raw: repairedWeekday, rewritten: correctedWeekday), "")
        for day in ["一", "二", "三", "四", "五", "六", "日"] {
            let raw = "我们周\(day)不对周天去测试，但周\(day)会议保留。"
            check("correction: weekday \(day) retains its later independent mention", MeaningGuard.resolveExplicitCorrections(raw) == "我们周天去测试，但周\(day)会议保留。", "")
        }
        for raw in ["周二不对吗？周三也可以。", "周二或者周三去测试。", "不要把周二改成周三。", "周二不对周三的安排也有问题。", "不是周二不对周三去测试。"] {
            check("correction: unresolved or negative weekday wording remains intact", MeaningGuard.resolveExplicitCorrections(raw) == raw, raw)
        }
        var context = CleanupContext(precedingText: "because", dictionary: [], chineseVariant: .traditional,
                                     allowFormatting: false, spokenCommands: false, cjkSpacing: true,
                                     customInstructions: "No bullets.", rewriteStyle: .full)
        check("prompts: Full uses public style and shared punctuation with dynamic preferences",
              CleanupPrompt.system(context).contains(PublicPromptDefaults.fullRewrite) &&
              CleanupPrompt.system(context).contains(PublicPromptDefaults.punctuation) &&
              CleanupPrompt.system(context).contains("Traditional") && CleanupPrompt.system(context).contains("No bullets."), "")
        context.rewriteStyle = .light
        for compact in [false, true] {
            context.compact = compact
            let prompt = CleanupPrompt.system(context)
            check("prompts: Light uses the public contract and punctuation, compact=\(compact)",
                  prompt.contains(PublicPromptDefaults.lightCleanup) && prompt.contains(PublicPromptDefaults.punctuation) &&
                  !prompt.contains(PublicPromptDefaults.fullRewrite) && prompt.contains("Do not paraphrase"), "")
        }
        func crossSection(_ raw: String, failSection: Int? = nil) -> LongTextProcessing.CleanupResult? {
            let fixture = BoundaryFixture(failSection: failSection)
            let requested = CleanupContext(precedingText: nil, dictionary: [], chineseVariant: .simplified,
                                           allowFormatting: false, spokenCommands: false, cjkSpacing: true,
                                           customInstructions: "", rewriteStyle: .full)
            var result: LongTextProcessing.CleanupResult?
            let task = Task { @MainActor in
                result = try? await LongTextProcessing.cleanup(raw, context: requested, settings: Settings.shared,
                                                               client: fixture) { _, _ in }
            }
            let end = Date().addingTimeInterval(5)
            while result == nil && Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            task.cancel()
            return result
        }
        let code = "```\n" + String(repeating: "Keep these literal words. ", count: 150) + "\n```"
        let language = "请保留。" + String(repeating: "Keep these original words. ", count: 150)
        for (label, source) in [("fenced code", code), ("mixed-language words", language)] {
            let result = crossSection(source)
            check("integrity: cross-section \(label) alteration keeps complete original",
                  result?.text == source && result?.usedLLM == false && result?.guardFallbackCount == LongTextProcessing.chunks(source).count &&
                  result?.providerFallbackCount == 0 && result?.requiresRecovery == false, "")
        }
        let failure = crossSection(code, failSection: 3)
        check("integrity: aggregate veto preserves provider-failure counters and recovery",
              failure?.text == code && failure?.guardFallbackCount == 2 && failure?.providerFallbackCount == 1 && failure?.requiresRecovery == true, "")
    }

    private final class BoundaryFixture: LLMClient {
        let name = "offline-cross-section-integrity"
        let failSection: Int?
        private var section = 0
        init(failSection: Int?) { self.failSection = failSection }
        func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
            if system == RewriteVerification.systemPrompt { return "PASS" }
            section += 1
            if section == failSection { throw LLMError.http(503, "synthetic boundary failure") }
            guard let start = user.range(of: "<transcript>"), let end = user.range(of: "</transcript>", range: start.upperBound..<user.endIndex) else { return "" }
            var value = String(user[start.upperBound..<end.lowerBound])
            if section == 2, let range = value.range(of: "Keep") { value.replaceSubrange(range, with: "Retain") }
            return value
        }
    }

    private final class ContextFixture: LLMClient {
        let name = "offline-paragraph-context"
        var contexts: [String?] = []
        func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
            if let start = user.range(of: "<preceding_text>"), let end = user.range(of: "</preceding_text>", range: start.upperBound..<user.endIndex) {
                contexts.append(String(user[start.upperBound..<end.lowerBound]))
            } else { contexts.append(nil) }
            guard let start = user.range(of: "<transcript>"), let end = user.range(of: "</transcript>", range: start.upperBound..<user.endIndex) else { return "" }
            return String(user[start.upperBound..<end.lowerBound])
        }
    }
}
