import SwiftUI
import AppKit

/// Native Home summary. History changes rebuild the linguistic word counts;
/// Home's once-per-second recording refresh only reads this cached snapshot.
struct UsageDashboardView: View {
    @EnvironmentObject private var history: History
    @EnvironmentObject private var settings: Settings
    @State private var period: UsageStatistics.Period = .last7Days
    @State private var statistics = UsageStatistics(items: [])
    @State private var showingMethod = false

    var body: some View {
        let summary = statistics.summary(for: period)
        let days = statistics.daily(for: period)
        HubCard(padding: 22) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your voice, at work")
                        .font(.hub(17, .semibold)).foregroundColor(Hub.ink)
                    Text("From the dictations saved on this Mac")
                        .font(.hub(12)).foregroundColor(Hub.helper)
                }
                Spacer(minLength: 12)
                Picker("Usage period", selection: $period) {
                    ForEach(UsageStatistics.Period.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .accessibilityIdentifier("usage-period")
            }

            HStack(alignment: .top, spacing: 14) {
                metric(title: (summary.estimatedSavedSeconds ?? 0) < 0 ? "Est. extra time" : "Est. time saved",
                       value: summary.estimatedSavedSeconds.map { timeText(abs($0)) } ?? "—",
                       color: (summary.estimatedSavedSeconds ?? 0) < 0 ? Hub.amber : Hub.green,
                       identifier: "usage-time-saved",
                       explanation: savingExplanation(summary))
                metric(title: "Words written", value: summary.wordCount.formatted(),
                       identifier: "usage-words",
                       explanation: "Words in the final output of your saved dictations, including results offered for copying. Language-aware counts are approximate.")
                metric(title: "Time dictating", value: summary.timedDictationCount > 0 ? timeText(summary.recordedSeconds) : "—",
                       identifier: "usage-recording-time",
                       explanation: "Recorded time for saved dictations with valid timing. It includes pauses during a recording.")
                metric(title: "Speaking pace", value: summary.speakingWordsPerMinute.map { "\($0.formatted(.number.precision(.fractionLength(0)))) wpm" } ?? "—",
                       identifier: "usage-speaking-rate",
                       explanation: "Original spoken words per minute of recording, including pauses. Rewrites do not inflate this number.")
            }
            .padding(.top, 12).padding(.bottom, 6)

            Divider().overlay(Hub.line).allowsHitTesting(false)
            if let error = history.persistenceError {
                Text(error).font(.hub(12)).foregroundColor(Hub.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text("Words by day").font(.hub(12, .medium)).foregroundColor(Hub.body)
                Spacer()
                Text(dictationCountText(summary.dictationCount))
                    .font(.hub(12)).foregroundColor(Hub.helper)
            }
            dayChart(days)
            HStack(alignment: .center, spacing: 10) {
                Text(coverageText(summary)).font(.hub(11)).foregroundColor(Hub.helper)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { showingMethod = true } label: {
                    Label("How estimated", systemImage: "info.circle")
                }
                .buttonStyle(PillButtonStyleHub(kind: .ghost, small: true))
                .accessibilityIdentifier("usage-methodology")
                .popover(isPresented: $showingMethod, arrowEdge: .bottom) {
                    methodology(summary)
                }
            }
        }
        .onReceive(history.$items) { items in
            statistics = UsageStatistics(items: items)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            statistics = UsageStatistics(items: history.items)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let calendar = Calendar.current
            if !calendar.isDate(statistics.now, inSameDayAs: Date()) || calendar.timeZone != statistics.calendar.timeZone {
                statistics = UsageStatistics(items: history.items)
            }
        }
    }

    private func metric(title: String, value: String, color: Color = Hub.ink,
                        identifier: String, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.hub(12)).foregroundColor(Hub.helper)
                .lineLimit(2).frame(minHeight: 29, alignment: .topLeading)
            Text(value).font(.hub(25, .semibold)).foregroundColor(color)
                .tracking(-0.6).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityHint(explanation)
        .accessibilityIdentifier(identifier)
        .help(explanation)
    }

    private func dayChart(_ days: [UsageStatistics.Day]) -> some View {
        let peak = max(days.map(\.wordCount).max() ?? 0, 1)
        return GeometryReader { geometry in
            let width = max(geometry.size.width, CGFloat(days.count) * 22)
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        VStack(spacing: 7) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(day.wordCount > 0 ? Hub.green.opacity(0.85) : Hub.line2)
                                .frame(width: min(28, max(8, width / CGFloat(max(days.count, 1)) - 8)),
                                       height: day.wordCount > 0 ? max(3, CGFloat(day.wordCount) / CGFloat(peak) * 60) : 2)
                            Text(dayLabel(day.date, index: index, count: days.count))
                                .font(.hub(10)).foregroundColor(Hub.helper)
                                .lineLimit(1).frame(height: 14)
                        }
                        .frame(maxWidth: .infinity).frame(height: 88)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(day.date.formatted(date: .complete, time: .omitted)): \(day.wordCount.formatted()) saved words, \(dictationCountText(day.dictationCount))")
                        .help("\(day.date.formatted(date: .abbreviated, time: .omitted)) · \(day.wordCount.formatted()) words · \(dictationCountText(day.dictationCount))")
                    }
                }
                .frame(width: width, height: 88, alignment: .bottom)
            }
            .scrollIndicators(.automatic)
            .overlay(alignment: .center) {
                if days.allSatisfy({ $0.wordCount == 0 }) {
                    Text("No saved dictations in this period")
                        .font(.hub(12)).foregroundColor(Hub.helper)
                        .padding(.bottom, 26).allowsHitTesting(false)
                }
            }
        }
        .frame(height: 104)
        .accessibilityIdentifier("usage-daily-chart")
    }

    private func methodology(_ summary: UsageStatistics.Summary) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("An estimate, made clear").font(.hub(16, .semibold)).foregroundColor(Hub.ink)
                Spacer()
                Button { showingMethod = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(PillButtonStyleHub(kind: .ghost, small: true))
                    .accessibilityLabel("Close estimate explanation")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text("We compare your output with typing at an assumed 45 words per minute, then subtract the time spent recording and waiting for the result.")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Time to type the final words at 45 wpm")
                        Text("− recording time − processing time")
                    }
                    .font(.hub(12, .medium)).foregroundColor(Hub.green)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Hub.radius).fill(Hub.greenSoft))
                    Text("45 wpm is a comparison, not a measurement of your typing speed. Slower dictations reduce the total. If the total is negative, we show estimated extra time instead of a saving.")
                    Text("Words use language-aware boundaries, including Chinese. Multilingual counts and the typing comparison are approximate. Speaking pace uses the original speech before rewriting and includes pauses.")
                    if summary.excludedTimingCount > 0 {
                        Text("\(dictationCountText(summary.excludedTimingCount)) in this period \(summary.excludedTimingCount == 1 ? "has" : "have") no usable timing. Their words are counted, but they are excluded from the time estimate.")
                            .foregroundColor(Hub.amber)
                    }
                    Text("Only the history still saved on this Mac is included, up to \(History.maxItems.formatted()) dictations. Cleared history, failed attempts, later editing and manual copy-and-paste time are not included. Zero on a date means no entry was saved for that date.")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: 360)
        }
        .font(.hub(12)).foregroundColor(Hub.helper)
        .padding(20).frame(width: 370)
        .background(Hub.card)
    }

    private func coverageText(_ summary: UsageStatistics.Summary) -> String {
        if !settings.saveHistory { return "History is off. Only earlier saved dictations appear." }
        guard let first = summary.firstDate, let last = summary.lastDate else {
            return "Your saved dictations will appear here."
        }
        let firstLabel = first.formatted(.dateTime.month(.abbreviated).day())
        let lastLabel = last.formatted(.dateTime.month(.abbreviated).day())
        let dates = statistics.calendar.isDate(first, inSameDayAs: last) ? firstLabel : "\(firstLabel)–\(lastLabel)"
        return "Saved activity: \(dates)"
    }

    private func savingExplanation(_ summary: UsageStatistics.Summary) -> String {
        guard let seconds = summary.estimatedSavedSeconds else { return "No saved dictations with valid timing in this period." }
        if seconds < 0 { return "Estimated additional time compared with typing at 45 words per minute, including recording and processing." }
        return "Estimated time saved compared with typing at 45 words per minute, after recording and processing. Open How estimated for the assumptions."
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        if seconds > 0 && seconds < 1 { return "<1 s" }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        if seconds < 3_600 { return "\(Int((seconds / 60).rounded())) min" }
        return String(format: "%.1f h", seconds / 3_600)
    }

    private func dictationCountText(_ count: Int) -> String {
        "\(count.formatted()) saved \(count == 1 ? "dictation" : "dictations")"
    }

    private func dayLabel(_ date: Date, index: Int, count: Int) -> String {
        if period == .last7Days { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if period == .today { return "Today" }
        if index == 0 || index == count - 1 || index % 7 == 0 {
            return date.formatted(.dateTime.day())
        }
        return " "
    }
}
