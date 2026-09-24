import Foundation
import Darwin

/// A recording is journaled before it is sent to a provider. Metadata and finalized segment
/// transcripts survive app termination; the PCM length on disk is the authoritative byte count.
final class RecordingArchive {
    struct Configuration: Codable {
        var languages: [String]
        var prompt: String
        var keywords: [String]
        var delay: String
        var chineseVariant: String
        init(_ config: STTConfig) {
            languages = config.languages; prompt = config.prompt; keywords = config.keywords
            delay = config.delay.rawValue; chineseVariant = config.chineseVariant.rawValue
        }
        var stt: STTConfig {
            STTConfig(languages: languages, prompt: prompt, keywords: keywords,
                      delay: LiveDelay(rawValue: delay) ?? .low, chineseVariant: ChineseVariant(rawValue: chineseVariant) ?? .simplified)
        }
    }
    struct Manifest: Codable {
        var created = Date()
        var sampleRate: Double
        var engine: String
        var segmentBytes: Int
        var byteCount = 0
        var transcripts: [String: String] = [:]
        var lastError: String?
        var configuration: Configuration?
        var mode: String?
        var translationTarget: String?
        var segmentEnds: [Int]?
    }
    static let root = Keychain.directory.appendingPathComponent("Recovery", isDirectory: true)
    let directory: URL
    private(set) var manifest: Manifest
    private var writer: FileHandle?
    private var ownership: FileHandle?
    private var lastSync = Date.distantPast
    var audioURL: URL { directory.appendingPathComponent("audio.pcm") }
    var seconds: Double { Double(manifest.byteCount) / 2 / manifest.sampleRate }

    init(sampleRate: Double, engine: String, segmentSeconds: Double = 60, root: URL = RecordingArchive.root,
         configuration: Configuration? = nil, mode: String? = nil, translationTarget: String? = nil) throws {
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        manifest = Manifest(sampleRate: sampleRate, engine: engine, segmentBytes: Int(sampleRate * segmentSeconds) * 2)
        manifest.configuration = configuration
        manifest.mode = mode
        manifest.translationTarget = translationTarget
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        ownership = try Self.acquireOwnership(in: directory)
        guard FileManager.default.createFile(atPath: audioURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw STTError.connection("Could not create the recording recovery file")
        }
        writer = try FileHandle(forWritingTo: audioURL)
        try checkpoint()
    }

    init(directory: URL, acquireOwnership: Bool = false) throws {
        self.directory = directory
        if acquireOwnership { ownership = try Self.acquireOwnership(in: directory) }
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isReadableFile(atPath: audioURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              manifest.sampleRate.isFinite, manifest.sampleRate > 0,
              manifest.segmentBytes > 0, manifest.segmentBytes % 2 == 0, size % 2 == 0 else {
            throw STTError.connection("The saved recording has an invalid format")
        }
        var previous = 0
        for end in manifest.segmentEnds ?? [] {
            guard end > previous, end <= size, end % 2 == 0 else {
                throw STTError.connection("The saved recording has invalid section boundaries; the audio file was preserved")
            }
            previous = end
        }
        manifest.byteCount = size
    }

    deinit { try? writer?.close(); releaseOwnership() }

    func append(_ data: Data) throws {
        guard let writer else { throw STTError.connection("The recording file is closed") }
        try writer.write(contentsOf: data)
        manifest.byteCount += data.count
        if Date().timeIntervalSince(lastSync) >= 1 { try checkpoint() }
    }

    func checkpoint() throws {
        try writer?.synchronize()
        let data = try JSONEncoder().encode(manifest)
        let url = directory.appendingPathComponent("manifest.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lastSync = Date()
    }

    func close() throws {
        // A canceled/completed owner may be closed again after another process acquires
        // recovery. Once our writer and lease are gone, do not rewrite its manifest.
        if writer != nil || ownership != nil { try checkpoint() }
        try writer?.close()
        writer = nil
    }
    func recordTranscript(_ text: String, segment: Int) throws {
        manifest.transcripts[String(segment)] = text
        try checkpoint()
    }
    func recordFailure(_ message: String) { manifest.lastError = message; try? checkpoint() }
    func finishSegment(at byteOffset: Int) throws {
        if manifest.segmentEnds == nil { manifest.segmentEnds = [] }
        if byteOffset > (manifest.segmentEnds?.last ?? 0) { manifest.segmentEnds?.append(byteOffset) }
        try checkpoint()
    }
    var segmentRanges: [Range<Int>] {
        var ends = manifest.segmentEnds ?? Array(stride(from: manifest.segmentBytes, through: manifest.byteCount, by: manifest.segmentBytes))
        if (ends.last ?? 0) < manifest.byteCount { ends.append(manifest.byteCount) }
        var start = 0
        return ends.map { end in defer { start = end }; return start..<end }
    }
    func recordMode(_ mode: String, translationTarget: String?) {
        manifest.mode = mode
        manifest.translationTarget = translationTarget
        try? checkpoint()
    }
    func releaseOwnership() {
        try? ownership?.close()
        ownership = nil
    }
    func remove() {
        // cancel() releases ownership after checkpointing. If another process started
        // recovery since then, an explicit discard must not delete its active files.
        if ownership == nil {
            guard let lease = try? Self.acquireOwnership(in: directory) else { return }
            ownership = lease
        }
        try? writer?.close()
        writer = nil
        try? FileManager.default.removeItem(at: directory)
        releaseOwnership()
    }

    private static func acquireOwnership(in directory: URL) throws -> FileHandle {
        let path = directory.appendingPathComponent(".active.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw STTError.connection("Could not open the saved recording's ownership lock") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? handle.close()
            throw STTError.connection("This recording is still being used by another recording or recovery session")
        }
        return handle
    }

    static func discardPending(_ directory: URL) throws {
        let lease = try acquireOwnership(in: directory)
        defer { try? lease.close() }
        try FileManager.default.removeItem(at: directory)
    }
    func read(offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= manifest.byteCount, count <= manifest.byteCount - offset else {
            throw STTError.connection("The requested saved audio range is invalid")
        }
        let reader = try FileHandle(forReadingFrom: audioURL)
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(offset))
        let data = try reader.read(upToCount: count) ?? Data()
        guard data.count == count else { throw STTError.connection("Saved audio is incomplete: expected \(count) bytes, read \(data.count)") }
        return data
    }
    static func pending(root: URL = RecordingArchive.root) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        return urls.filter { directory in
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path),
                  let lease = try? acquireOwnership(in: directory) else { return false }
            try? lease.close()
            return true
        }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
    }
}
