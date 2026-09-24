import Foundation

struct HistoryItem: Codable, Identifiable {
    var id: String
    var date: Date
    var raw: String
    var text: String
    var mode: String
    var engine: String
    var app: String?
    var seconds: Double
    var latencyMs: Int
}

final class History: ObservableObject {
    static let shared = History()
    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var persistenceError: String?
    static let maxItems = 500
    private let storageURL: URL
    private let persistenceQueue = DispatchQueue(label: "com.hao.fndictate.history", qos: .utility)

    static let directory: URL = {
        if let test = UITestEnvironment.storageRoot { return test }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FnDictate", isDirectory: true)
    }()
    static let fileURL = directory.appendingPathComponent("history.json")

    init(storageURL: URL = History.fileURL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([HistoryItem].self, from: data) {
                items = Array(decoded.suffix(Self.maxItems))
            } else if let legacy = try? JSONDecoder().decode([HistoryItem].self, from: data) {
                items = Array(legacy.suffix(Self.maxItems))
            } else {
                persistenceError = "Saved history could not be read. The existing file has been kept."
            }
        }
    }

    func append(_ item: HistoryItem) {
        items.append(item)
        if items.count > Self.maxItems { items.removeFirst(items.count - Self.maxItems) }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    var last: HistoryItem? { items.last }

    func flush() { persistenceQueue.sync {} }

    private func persist() {
        let snapshot = items
        let destination = storageURL
        persistenceQueue.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let enc = JSONEncoder()
                enc.dateEncodingStrategy = .iso8601
                let data = try enc.encode(snapshot)
                try data.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                DispatchQueue.main.async { self?.persistenceError = nil }
            } catch {
                Log.error("History write failed: \(error)")
                DispatchQueue.main.async { self?.persistenceError = "History could not be saved: \(error.localizedDescription)" }
            }
        }
    }
}
