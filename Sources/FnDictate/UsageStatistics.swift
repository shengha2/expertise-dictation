import Foundation

/// A read-only estimate from the history still saved on this Mac, not lifetime
/// usage or a measurement of the user's typing speed. No transcript is persisted
/// or sent anywhere by this model.
struct UsageStatistics {
    static let defaultTypingWordsPerMinute = 45.0

    enum Period: String, CaseIterable, Identifiable {
        case today, last7Days, last30Days, allHistory
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: return "Today"
            case .last7Days: return "Last 7 days"
            case .last30Days: return "Last 30 days"
            case .allHistory: return "Saved history"
            }
        }
    }

    struct Summary {
        var wordCount = 0
        var dictationCount = 0
        var timedWordCount = 0
        var timedDictationCount = 0
        var recordedSeconds = 0.0
        var processingSeconds = 0.0
        var estimatedTypingSeconds = 0.0
        /// Signed total: slow dictations reduce the total instead of being
        /// clamped individually. Nil means there is no valid timing evidence.
        var estimatedSavedSeconds: Double?
        var speakingWordsPerMinute: Double?
        var firstDate: Date?
        var lastDate: Date?
        var excludedTimingCount: Int { dictationCount - timedDictationCount }
    }

    struct Day: Identifiable {
        var date: Date
        var summary: Summary
        var id: Date { date }
        var wordCount: Int { summary.wordCount }
        var dictationCount: Int { summary.dictationCount }
        var estimatedSavedSeconds: Double? { summary.estimatedSavedSeconds }
    }

    let typingWordsPerMinute: Double
    let now: Date
    let calendar: Calendar
    let sourceItemCount: Int
    let excludedEntryCount: Int
    private let entries: [Entry]

    private struct Entry {
        var date: Date
        var words: Int
        var rawWords: Int
        var seconds: Double
        var latencyMs: Int
    }

    init(items: [HistoryItem], now: Date = Date(), calendar: Calendar = .current,
         typingWordsPerMinute: Double = UsageStatistics.defaultTypingWordsPerMinute) {
        self.now = now.timeIntervalSinceReferenceDate.isFinite ? now : Date()
        self.calendar = calendar
        self.typingWordsPerMinute = typingWordsPerMinute.isFinite && typingWordsPerMinute > 0
            ? typingWordsPerMinute : Self.defaultTypingWordsPerMinute
        sourceItemCount = items.count
        var seen = Set<String>()
        var accepted: [Entry] = []
        // History is append ordered. For repeated IDs, the latest eligible
        // stored entry wins; a duplicate never becomes a second dictation.
        for item in items.reversed() {
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, item.date.timeIntervalSinceReferenceDate.isFinite,
                  item.date <= self.now, Self.isUsageEngine(item.engine) else { continue }
            let words = Self.wordCount(item.text)
            guard words > 0, seen.insert(id).inserted else { continue }
            accepted.append(Entry(date: item.date, words: words, rawWords: Self.wordCount(item.raw),
                                  seconds: item.seconds, latencyMs: item.latencyMs))
        }
        entries = accepted.sorted { $0.date < $1.date }
        excludedEntryCount = items.count - entries.count
    }

    func summary(for period: Period) -> Summary {
        let start = startDate(for: period)
        return summarize(entries.filter { $0.date >= start })
    }

    /// Fixed periods include every calendar day. Saved history returns only days
    /// with entries, keeping an arbitrary old timestamp from generating years
    /// of empty bars. Zero does not prove no dictation happened: history can be
    /// disabled, cleared or capped.
    func daily(for period: Period) -> [Day] {
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        if period == .allHistory {
            return grouped.keys.sorted().map { Day(date: $0, summary: summarize(grouped[$0] ?? [])) }
        }
        let first = calendar.startOfDay(for: startDate(for: period))
        let today = calendar.startOfDay(for: now)
        var date = first
        var days: [Day] = []
        while date <= today {
            days.append(Day(date: date, summary: summarize(grouped[date] ?? [])))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = next
        }
        return days
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0
        // Foundation's linguistic boundaries segment Chinese and other text
        // without spaces; splitting on whitespace counts a whole paragraph as 1.
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) {
            _, _, _, _ in count += 1
        }
        return count
    }

    private func startDate(for period: Period) -> Date {
        let today = calendar.startOfDay(for: now)
        switch period {
        case .today: return today
        case .last7Days: return calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .last30Days: return calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .allHistory: return entries.first?.date ?? today
        }
    }

    private func summarize(_ values: [Entry]) -> Summary {
        var result = Summary()
        var timedRawWords = 0
        for value in values {
            result.wordCount += value.words
            result.dictationCount += 1
            result.firstDate = result.firstDate.map { min($0, value.date) } ?? value.date
            result.lastDate = result.lastDate.map { max($0, value.date) } ?? value.date
            // Bad timing does not erase genuine output words, but cannot support
            // a time-saved claim. Latency is release-to-result, after recording.
            guard value.seconds.isFinite, value.seconds > 0, value.latencyMs >= 0 else { continue }
            let nextRecording = result.recordedSeconds + value.seconds
            let nextProcessing = result.processingSeconds + Double(value.latencyMs) / 1_000
            let nextTyping = result.estimatedTypingSeconds + Double(value.words) / typingWordsPerMinute * 60
            let nextSaved = nextTyping - nextRecording - nextProcessing
            guard nextRecording.isFinite, nextProcessing.isFinite, nextTyping.isFinite, nextSaved.isFinite else { continue }
            result.timedWordCount += value.words
            result.timedDictationCount += 1
            timedRawWords += value.rawWords
            result.recordedSeconds = nextRecording
            result.processingSeconds = nextProcessing
            result.estimatedTypingSeconds = nextTyping
            result.estimatedSavedSeconds = nextSaved
        }
        if result.recordedSeconds > 0 && timedRawWords > 0 {
            let speed = Double(timedRawWords) / result.recordedSeconds * 60
            if speed.isFinite { result.speakingWordsPerMinute = speed }
        }
        return result
    }

    private static func isUsageEngine(_ value: String) -> Bool {
        let engine = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard engine.contains(where: { $0.isLetter }) else { return false }
        let labels = engine.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let testLabels: Set<String> = ["test", "selftest", "fixture", "mock", "diagnostic", "benchmark"]
        return testLabels.isDisjoint(with: labels)
    }
}
