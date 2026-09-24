import Foundation

/// UI previews get a private data directory as well as a separate test bundle ID.
/// Launching a preview must never load somebody's real keys, history or recovery.
enum UITestEnvironment {
    static let active = CommandLine.arguments.contains("--ui-test")
    static let storageRoot: URL? = {
        guard active else { return nil }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExpertiseDictation-UIPreview-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        return root
    }()
}
