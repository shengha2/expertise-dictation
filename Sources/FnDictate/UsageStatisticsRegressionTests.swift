import Foundation

/// Pure synthetic history; never reads or changes the user's saved dictation.
enum UsageStatisticsRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        func expect(_ name: String, _ passed: Bool) { check("usage statistics: " + name, passed, "") }
        func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.000_001 } ?? false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        func date(_ year: Int = 2026, _ month: Int = 9, _ day: Int = 24, _ hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let now = date()
        func item(_ id: String = UUID().uuidString, at: Date? = nil, words: Int = 45,
                  seconds: Double = 10, latency: Int = 2_000, engine: String = "gpt-live-transcribe") -> HistoryItem {
            let output = Array(repeating: "word", count: words).joined(separator: " ")
            return HistoryItem(id: id, date: at ?? now, raw: output, text: output,
                               mode: "clean", engine: engine, app: nil, seconds: seconds, latencyMs: latency)
        }
        func stats(_ items: [HistoryItem], at: Date? = nil, wpm: Double = 45) -> UsageStatistics {
            UsageStatistics(items: items, now: at ?? now, calendar: calendar, typingWordsPerMinute: wpm)
        }

        let empty = stats([])
        expect("empty history has no claim of saved time", empty.summary(for: .allHistory).estimatedSavedSeconds == nil)
        expect("empty history has zero words and dictations", empty.summary(for: .today).wordCount == 0 && empty.summary(for: .today).dictationCount == 0)
        expect("empty seven-day chart includes seven zero dates", empty.daily(for: .last7Days).count == 7 && empty.daily(for: .last7Days).allSatisfy { $0.wordCount == 0 })
        expect("empty thirty-day chart includes thirty dates", empty.daily(for: .last30Days).count == 30)
        expect("empty saved-history chart has no invented days", empty.daily(for: .allHistory).isEmpty)

        let one = stats([item()]).summary(for: .today)
        expect("final words and one dictation are counted", one.wordCount == 45 && one.dictationCount == 1)
        expect("estimate subtracts recording plus release-to-result latency", close(one.estimatedSavedSeconds, 48))
        expect("timing inputs remain inspectable", close(one.recordedSeconds, 10) && close(one.processingSeconds, 2) && close(one.estimatedTypingSeconds, 60))
        expect("sixty-WPM sensitivity uses same elapsed costs", close(stats([item()], wpm: 60).summary(for: .today).estimatedSavedSeconds, 33))
        expect("negative total remains negative", close(stats([item(seconds: 70)]).summary(for: .today).estimatedSavedSeconds, -12))
        let combined = stats([item(seconds: 10, latency: 0), item(seconds: 80, latency: 0)]).summary(for: .today)
        expect("slow dictation reduces combined gain without per-item clamping", close(combined.estimatedSavedSeconds, 30))

        var rewritten = item(words: 30, seconds: 15, latency: 0)
        rewritten.raw = Array(repeating: "spoken", count: 60).joined(separator: " ")
        let rewrittenSummary = stats([rewritten]).summary(for: .today)
        expect("words and typing estimate use final output rather than raw speech", rewrittenSummary.wordCount == 30 && close(rewrittenSummary.estimatedSavedSeconds, 25))
        expect("speaking rate uses raw words and recording time only", close(rewrittenSummary.speakingWordsPerMinute, 240))
        expect("Chinese paragraph has multiple linguistic words", UsageStatistics.wordCount("今天我们一起讨论产品更新和客户反馈。") > 1)
        expect("mixed language counts English and Chinese words", UsageStatistics.wordCount("Hello 今天讨论 product updates") > 4)
        expect("punctuation and emoji do not invent output words", UsageStatistics.wordCount("🙂，。？！\n — ") == 0)
        expect("word counting handles multiline lists", UsageStatistics.wordCount("- Send report\n- Call team") == 4)

        let badTimings = [item(seconds: 0), item(seconds: -1), item(seconds: .nan),
                          item(seconds: .infinity), item(latency: -1)]
        let invalid = stats(badTimings).summary(for: .today)
        expect("invalid timing retains real output usage", invalid.wordCount == 225 && invalid.dictationCount == 5)
        expect("invalid timing cannot claim savings or speaking speed", invalid.estimatedSavedSeconds == nil && invalid.speakingWordsPerMinute == nil && invalid.excludedTimingCount == 5)
        let partial = stats(badTimings + [item()]).summary(for: .today)
        expect("partial timing uses only matched valid words and durations", close(partial.estimatedSavedSeconds, 48) && partial.timedWordCount == 45 && partial.timedDictationCount == 1 && partial.excludedTimingCount == 5)
        let invalidBaselines = [0.0, -1.0, Double.nan, Double.infinity]
        expect("invalid typing baselines fall back to documented 45 WPM", invalidBaselines.allSatisfy { stats([item()], wpm: $0).typingWordsPerMinute == 45 })

        var badDate = item()
        badDate.date = Date(timeIntervalSinceReferenceDate: .nan)
        let ignored = stats([item(at: now.addingTimeInterval(1)), badDate, item(words: 0),
                             item(engine: ""), item(engine: "0"), item(engine: "fixture"),
                             item(engine: "offline-controller-fixture"), item(engine: "mock-provider"),
                             item(engine: "SELFTEST"), item("  ")])
        expect("future, invalid, empty and diagnostic records are excluded", ignored.summary(for: .allHistory).dictationCount == 0 && ignored.excludedEntryCount == 10)
        let duplicate = stats([item("same", words: 90), item("same", words: 45), item("other", words: 30)])
        expect("duplicate IDs count once using latest eligible saved entry", duplicate.summary(for: .today).wordCount == 75 && duplicate.summary(for: .today).dictationCount == 2 && duplicate.excludedEntryCount == 1)
        let duplicateBad = stats([item("same"), item("same", at: now.addingTimeInterval(60))])
        expect("invalid future duplicate does not erase an earlier valid entry", duplicateBad.summary(for: .today).dictationCount == 1)

        let dayStart = calendar.startOfDay(for: now)
        let sevenStart = calendar.date(byAdding: .day, value: -6, to: dayStart)!
        let thirtyStart = calendar.date(byAdding: .day, value: -29, to: dayStart)!
        let boundaries = stats([item(at: dayStart), item(at: dayStart.addingTimeInterval(-1)),
                                item(at: sevenStart), item(at: sevenStart.addingTimeInterval(-1)),
                                item(at: thirtyStart), item(at: thirtyStart.addingTimeInterval(-1))])
        expect("today begins at local midnight", boundaries.summary(for: .today).dictationCount == 1)
        expect("last seven calendar days include boundary and exclude prior second", boundaries.summary(for: .last7Days).dictationCount == 3)
        expect("last thirty calendar days include boundary and exclude prior second", boundaries.summary(for: .last30Days).dictationCount == 5)
        expect("saved-history scope includes earlier available records", boundaries.summary(for: .allHistory).dictationCount == 6)
        expect("daily and period totals reconcile", boundaries.daily(for: .last7Days).reduce(0) { $0 + $1.wordCount } == boundaries.summary(for: .last7Days).wordCount)
        expect("coverage describes actual available timestamps", boundaries.summary(for: .allHistory).firstDate == thirtyStart.addingTimeInterval(-1) && boundaries.summary(for: .allHistory).lastDate == dayStart)

        let spring = stats([], at: date(2026, 3, 10))
        let springDays = spring.daily(for: .last7Days)
        expect("spring DST chart uses seven local dates", springDays.count == 7 && Set(springDays.map { calendar.component(.day, from: $0.date) }).count == 7)
        expect("spring DST respects the 23-hour calendar day", zip(springDays, springDays.dropFirst()).contains { $1.date.timeIntervalSince($0.date) == 23 * 3_600 })
        let fallDays = stats([], at: date(2026, 11, 3)).daily(for: .last7Days)
        expect("fall DST respects the 25-hour calendar day", fallDays.count == 7 && zip(fallDays, fallDays.dropFirst()).contains { $1.date.timeIntervalSince($0.date) == 25 * 3_600 })
        let ancient = stats([item(at: .distantPast), item()])
        expect("sparse saved history does not generate centuries of empty days", ancient.daily(for: .allHistory).count == 2)
    }
}
