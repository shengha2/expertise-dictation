import Foundation

enum PersistenceRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FnDictate-history-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        func item(_ index: Int) -> HistoryItem {
            HistoryItem(id: "item-\(index)", date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                        raw: "Raw \(index) 中文", text: "Complete \(index) 中文", mode: "verbatim", engine: "fixture", app: nil,
                        seconds: 1800, latencyMs: 100)
        }
        let history = History(storageURL: file)
        for index in 0..<30 { history.append(item(index)) }
        history.flush()
        let restored = History(storageURL: file)
        check("history survives restart with ISO8601 dates and complete Unicode text", restored.items.count == 30 && restored.last?.text == item(29).text, "")
        for index in 30..<60 { history.append(item(index)) }
        history.clear()
        history.flush()
        check("clearing history cannot be undone by an older queued save", History(storageURL: file).items.isEmpty, "")
        do {
            let data = try JSONEncoder().encode([item(1)])
            try data.write(to: file, options: .atomic)
            check("legacy history date encoding remains readable", History(storageURL: file).items.count == 1, "")
        } catch { check("legacy history fixture can be written", false, error.localizedDescription) }
        check("language choices deduplicate while preserving user order", DictationLanguage.normalized(["ja", "en", "ja", "zh"]) == ["ja", "en", "zh"], "")
        check("empty language preference keeps at least one valid language", !DictationLanguage.normalized([]).isEmpty, "")
        check("unknown language preferences cannot enter provider requests", DictationLanguage.normalized(["not-a-language", "fr"]) == ["fr"], "")
        check("long recording default exceeds the former five-minute cap", Settings.shared.maxDurationSeconds == 7200, "")
    }
}
