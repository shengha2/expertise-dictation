import Foundation
import os

/// Lightweight logger: unified logging + an append-only file in ~/Library/Logs/FnDictate.
enum Log {
    private static let shortcutDiagnostics = CommandLine.arguments.contains("--diagnose-shortcuts")
    private static let logger = Logger(subsystem: "com.hao.fndictate", category: "app")
    private static let queue = DispatchQueue(label: "com.hao.fndictate.log", qos: .utility)
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static let directoryURL: URL = {
        if let test = UITestEnvironment.storageRoot { return test.appendingPathComponent("Logs") }
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/FnDictate", isDirectory: true)
    }()
    static let fileURL = directoryURL.appendingPathComponent("fndictate.log")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    /// Opt-in metadata for reproducing shortcut issues; never pass typed text here.
    static func shortcut(_ message: @autoclosure () -> String) {
        guard shortcutDiagnostics else { return }
        info(message())
    }

    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        write("WARN", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                   let size = attrs[.size] as? NSNumber, size.intValue > 5_000_000 {
                    try? fm.removeItem(at: fileURL)
                }
                if !fm.fileExists(atPath: fileURL.path) {
                    fm.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                // Logging must never take the app down.
            }
        }
    }
}
