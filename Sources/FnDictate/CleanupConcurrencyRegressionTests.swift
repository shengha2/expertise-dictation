import Foundation

/// Only synthetic text and actor-isolated provider fixtures; no credentials, audio or preferences.
enum CleanupConcurrencyRegressionTests {
    private struct Observation {
        var result: LongTextProcessing.CleanupResult?
        var cancelled = false
        var elapsed: TimeInterval = 0
        var inspected: [Int] = []
        var stats = Fixture.Stats()
    }

    private actor Fixture: LLMClient {
        nonisolated let name = "offline-cleanup-concurrency"
        nonisolated let supportsConcurrentRequests: Bool
        struct Stats {
            var active = 0
            var peak = 0
            var rewrites: [String] = []
            var completions: [String] = []
            var contexts: [String: String] = [:]
            var contextValues: [String] = []
            var verifications = 0
        }
        private var stats = Stats()
        private let fail: String?
        private let reject: String?
        private let paraphrase: Bool
        init(concurrent: Bool = true, fail: String? = nil, reject: String? = nil, paraphrase: Bool = false) {
            supportsConcurrentRequests = concurrent
            self.fail = fail; self.reject = reject; self.paraphrase = paraphrase
        }
        func snapshot() -> Stats { stats }
        func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
            stats.active += 1
            stats.peak = max(stats.peak, stats.active)
            defer { stats.active -= 1 }
            if system == RewriteVerification.systemPrompt {
                stats.verifications += 1
                try await Task.sleep(nanoseconds: 40_000_000)
                return reject.map { user.contains($0) } == true ? "FAIL" : "PASS"
            }
            guard let start = user.range(of: "<transcript>"),
                  let end = user.range(of: "</transcript>", range: start.upperBound..<user.endIndex) else { return "" }
            let raw = String(user[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tag = String(raw.prefix(while: { !$0.isWhitespace }))
            stats.rewrites.append(tag)
            if let contextStart = user.range(of: "<preceding_text>"),
               let contextEnd = user.range(of: "</preceding_text>", range: contextStart.upperBound..<user.endIndex) {
                stats.contexts[tag] = String(user[contextStart.upperBound..<contextEnd.lowerBound])
                stats.contextValues.append(String(user[contextStart.upperBound..<contextEnd.lowerBound]))
            }
            // The first paragraph deliberately finishes after its concurrent sibling.
            try await Task.sleep(nanoseconds: tag == "Alpha" ? 140_000_000 : 70_000_000)
            if tag == fail { throw LLMError.http(503, "synthetic section failure") }
            stats.completions.append(tag)
            return paraphrase || tag == reject ? raw.replacingOccurrences(of: "keep", with: "retain") : raw
        }
    }

    static func run(check: (String, Bool, String) -> Void) {
        func paragraph(_ tag: String) -> String {
            String(repeating: "\(tag) keep every recorded detail unchanged. ", count: 31) + "\n\n"
        }
        let tags = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"]
        let raw = tags.map(paragraph).joined()
        check("cleanup concurrency: fixture has five separate paragraph sections", LongTextProcessing.chunks(raw).count == 5, "")

        func evaluate(_ source: String, client: Fixture, cancel: Bool = false) -> Observation {
            var observed = Observation()
            var done = false
            let task = Task { @MainActor in
                let start = Date()
                defer { observed.elapsed = Date().timeIntervalSince(start); done = true }
                let context = CleanupContext(precedingText: "External insertion context.", dictionary: [], chineseVariant: .simplified,
                                             allowFormatting: false, spokenCommands: false, cjkSpacing: true,
                                             customInstructions: "", rewriteStyle: .full)
                do {
                    observed.result = try await LongTextProcessing.cleanup(source, context: context, settings: Settings.shared,
                                                                           client: client, inspectSection: { index, _, _, _, _ in
                        observed.inspected.append(index)
                    }) { _, _ in }
                } catch is CancellationError { observed.cancelled = true }
                catch { }
                observed.stats = await client.snapshot()
            }
            if cancel { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { task.cancel() } }
            let deadline = Date().addingTimeInterval(6)
            while !done && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
            task.cancel()
            check("cleanup concurrency: fixture completes within its deadline", done, "")
            return observed
        }

        let parallel = evaluate(raw, client: Fixture())
        check("cleanup concurrency: overlaps independent paragraphs with at most two requests", parallel.stats.peak == 2 && parallel.stats.rewrites.count == 5, "")
        check("cleanup concurrency: second section finishes first without reordering output", parallel.stats.completions.first == "Bravo" && parallel.result?.text == raw.trimmingCharacters(in: .whitespacesAndNewlines), "")
        check("cleanup concurrency: section evidence stays in source order", parallel.inspected == [1, 2, 3, 4, 5], "")
        check("cleanup concurrency: only first paragraph receives external insertion context", parallel.stats.contexts == ["Alpha": "External insertion context."], "")
        check("cleanup concurrency: all successful sections retain the ordinary integrity checks", parallel.result?.fallbackCount == 0 && parallel.result?.requiresRecovery == false, "")

        let serial = evaluate(raw, client: Fixture(concurrent: false))
        check("cleanup concurrency: custom clients stay serial unless they opt in", serial.stats.peak == 1 && serial.result?.text == parallel.result?.text, "")
        check("cleanup concurrency: overlapping requests reduce controlled fixture latency", parallel.elapsed < serial.elapsed * 0.85, "serial=\(serial.elapsed), parallel=\(parallel.elapsed)")

        let continuous = String(repeating: "Keep each detail in its original paragraph. ", count: 100)
        let continuation = evaluate(continuous, client: Fixture())
        check("cleanup concurrency: paragraph continuations remain strictly serial", continuation.stats.peak == 1 && continuation.result?.text == continuous.trimmingCharacters(in: .whitespacesAndNewlines), "")
        check("cleanup concurrency: paragraph continuations retain preceding output context", continuation.stats.contextValues.count == continuation.stats.rewrites.count && continuation.stats.contextValues.count > 1, "")

        let firstFailure = evaluate(raw, client: Fixture(fail: "Alpha"))
        check("cleanup concurrency: first provider failure retains the entire original and halts future batches", firstFailure.result?.text == raw && firstFailure.result?.providerFallbackCount == 5 && firstFailure.result?.requiresRecovery == true && firstFailure.stats.rewrites.count == 2, "")
        check("cleanup concurrency: completed sibling after an earlier failure is not delivered", firstFailure.inspected.isEmpty, "")
        let secondFailure = evaluate(raw, client: Fixture(fail: "Bravo"))
        check("cleanup concurrency: later provider failure preserves earlier accepted section and raw suffix", secondFailure.inspected == [1] && secondFailure.result?.providerFallbackCount == 4 && secondFailure.result?.requiresRecovery == true && secondFailure.stats.rewrites.count == 2, "")

        let rejection = evaluate(raw, client: Fixture(reject: "Bravo"))
        check("cleanup concurrency: semantic rejection keeps that section and continues later batches", rejection.result?.guardFallbackCount == 1 && rejection.result?.requiresRecovery == false && rejection.stats.rewrites.count == 5 && rejection.stats.verifications == 1 && rejection.inspected == [1, 2, 3, 4, 5], "")
        let paraphrases = evaluate(raw, client: Fixture(paraphrase: true))
        check("cleanup concurrency: meaning verification is retained for every paraphrased section", paraphrases.stats.verifications == 5 && paraphrases.result?.fallbackCount == 0 && paraphrases.stats.peak == 2, "")

        let cancellation = evaluate(raw, client: Fixture(), cancel: true)
        check("cleanup concurrency: cancellation stops both workers and delivers no partial output", cancellation.cancelled && cancellation.result == nil && cancellation.inspected.isEmpty && cancellation.stats.active == 0 && cancellation.stats.rewrites.count == 2, "")
    }
}
