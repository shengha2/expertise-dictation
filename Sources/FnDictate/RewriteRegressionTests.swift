import Foundation

enum RewriteRegressionTests {
    private final class Client: LLMClient {
        let name = "rewrite-verification-fixture"
        var response: String
        var failure: Error?
        var calls = 0
        init(_ response: String, failure: Error? = nil) { self.response = response; self.failure = failure }
        func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
            calls += 1
            if let failure { throw failure }
            return response
        }
    }
    static func run(check: (String, Bool, String) -> Void) {
        let source = "Please do not cancel the meeting for 12 people at 3 p.m."
        let faithful = "Keep the 3 p.m. meeting for 12 people; please do not cancel it."
        check("rewrite: reordered numeric details remain eligible", RewriteVerification.passesBasicChecks(raw: source, rewritten: faithful), "")
        check("rewrite: changed number is rejected before verification", !RewriteVerification.passesBasicChecks(raw: source, rewritten: faithful.replacingOccurrences(of: "12", with: "13")), "")
        check("rewrite: omitted amount is rejected before verification", !RewriteVerification.passesBasicChecks(raw: source, rewritten: "Keep the meeting at 3 p.m."), "")
        check("rewrite: empty output is rejected", !RewriteVerification.passesBasicChecks(raw: source, rewritten: " \n"), "")
        var context = CleanupContext(precedingText: nil, dictionary: [], chineseVariant: .simplified,
                                     allowFormatting: false, spokenCommands: true, cjkSpacing: true, customInstructions: "")
        check("rewrite: light prompt preserves wording", CleanupPrompt.system(context).contains("Do not paraphrase"), "")
        context.rewriteStyle = .full
        check("rewrite: full prompt permits rewording without answering", CleanupPrompt.system(context).contains("Improve grammar, wording") && CleanupPrompt.system(context).contains("Do not summarize, invent, answer"), "")
        for (response, expected) in [("PASS", true), (" PASS\n", true), ("FAIL", false), ("PASS because", false), ("<output>PASS</output>", false), ("", false)] {
            let client = Client(response)
            var finished = false
            var accepted = false
            Task { @MainActor in
                accepted = (try? await RewriteVerification.accepts(raw: source, rewritten: faithful, client: client, timeout: 1)) ?? false
                finished = true
            }
            wait { finished }
            check("rewrite: exact verifier protocol \(response.debugDescription)", finished && accepted == expected && client.calls == 1, "")
        }
        let failed = Client("PASS", failure: LLMError.outputLimit)
        var completed = false
        var propagated = false
        Task { @MainActor in
            do { _ = try await RewriteVerification.accepts(raw: source, rewritten: faithful, client: failed, timeout: 1) }
            catch { propagated = true }
            completed = true
        }
        wait { completed }
        check("rewrite: verifier output-limit propagates for recovery", completed && propagated, "")
        check("rewrite: persisted legacy modes remain compatible", DictationMode(rawValue: "clean") == .clean && DictationMode(rawValue: "light") == .light && DictationMode(rawValue: "rewrite") == .rewrite, "")
    }
    private static func wait(_ predicate: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while !predicate() && Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
}
