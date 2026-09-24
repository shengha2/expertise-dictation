import Foundation

/// Fixed-size provider turns bound memory and provider output limits. The full audio is durable;
/// a failed turn never masquerades as a complete transcript or stops microphone capture.
final class DurableSTTSession: STTSession {
    let sampleRate: Double
    let engineName: String
    var onPartial: ((String) -> Void)?
    var onFinal: ((Result<String, Error>) -> Void)?
    var onProgress: ((String) -> Void)?
    private let q = DispatchQueue(label: "com.hao.fndictate.durable-stt")
    private let factory: () throws -> STTSession
    private let segmentSeconds: Double
    private let archiveRoot: URL
    private var configuration: RecordingArchive.Configuration?
    private var recoveryMode: String?
    private var recoveryTranslationTarget: String?
    private var archive: RecordingArchive?
    private var sessions: [Int: STTSession] = [:]
    private var partials: [Int: String] = [:]
    private var failures: [Int: String] = [:]
    private var recording = true
    private var cancelled = false
    private var resolved = false
    private var replaying = false
    private var replayIndices: [Int] = []
    private var replayOffset = 0
    private var replayGeneration = 0
    private var activeSegment = 0
    private var currentBytes = 0
    private var totalBytes = 0
    private var segmentByteLimit: Int { Int(sampleRate * segmentSeconds) * 2 }
    var isUsable: Bool { q.sync { !cancelled && !resolved && recording && failures.isEmpty && !sessions.isEmpty } }
    var recoveryURL: URL? { q.sync { archive?.directory } }
    var capturedSeconds: Double { q.sync { Double(totalBytes) / 2 / sampleRate } }

    init(first: STTSession, segmentSeconds: Double = 60, archiveRoot: URL = RecordingArchive.root,
         configuration: STTConfig? = nil,
         factory: @escaping () throws -> STTSession) {
        sampleRate = first.sampleRate
        engineName = first.engineName
        self.factory = factory
        self.segmentSeconds = segmentSeconds
        self.archiveRoot = archiveRoot
        self.configuration = configuration.map(RecordingArchive.Configuration.init)
        sessions[0] = first
    }

    init(recovering directory: URL, factory: @escaping () throws -> STTSession) throws {
        let saved = try RecordingArchive(directory: directory, acquireOwnership: true)
        archive = saved
        sampleRate = saved.manifest.sampleRate
        engineName = saved.manifest.engine
        segmentSeconds = Double(saved.manifest.segmentBytes) / 2 / sampleRate
        archiveRoot = directory.deletingLastPathComponent()
        totalBytes = saved.manifest.byteCount
        self.factory = factory
        recording = false
        replaying = true
    }

    func connect() {
        q.async {
            guard !self.cancelled, !self.resolved else { return }
            if self.replaying { self.startReplay(); return }
            if let first = self.sessions[0] { self.attach(first, index: 0); first.connect() }
        }
    }

    private func attach(_ session: STTSession, index: Int) {
        session.onPartial = { [weak self, weak session] text in
            self?.q.async {
                guard let self, let session, self.sessions[index] === session, !self.cancelled, !self.resolved else { return }
                self.partials[index] = text
                let transcript = self.joined(includePartial: true)
                DispatchQueue.main.async { self.onPartial?(transcript) }
            }
        }
        session.onFinal = { [weak self, weak session] result in
            self?.q.async {
                guard let self, let session, self.sessions[index] === session, !self.cancelled, !self.resolved else { return }
                self.sessions[index] = nil
                self.partials[index] = nil
                switch result {
                case .success(let text):
                    do { try self.archive?.recordTranscript(text, segment: index) }
                    catch { self.failures[index] = error.localizedDescription }
                case .failure(let error):
                    self.failures[index] = error.localizedDescription
                    self.archive?.recordFailure(error.localizedDescription)
                    self.progress(self.recording ? "Connection interrupted — recording continues locally" : "Transcription interrupted — recording saved for retry")
                    if self.recording && self.totalBytes == 0 { self.resolve(.failure(error)); return }
                }
                if self.replaying { self.advanceReplay() }
                else { self.resolveIfFinished() }
            }
        }
    }

    func sendAudio(_ pcm16: Data) {
        q.async {
            guard self.recording, !self.cancelled, !self.resolved, !pcm16.isEmpty else { return }
            do {
                if self.archive == nil {
                    self.archive = try RecordingArchive(sampleRate: self.sampleRate, engine: self.engineName,
                                                        segmentSeconds: self.segmentSeconds, root: self.archiveRoot,
                                                        configuration: self.configuration, mode: self.recoveryMode,
                                                        translationTarget: self.recoveryTranslationTarget)
                }
                try self.archive?.append(pcm16)
            } catch {
                self.archive?.recordFailure(error.localizedDescription)
                self.resolve(.failure(STTError.connection("Could not save microphone audio: \(error.localizedDescription)")))
                return
            }
            var offset = 0
            while offset < pcm16.count {
                let count = min(pcm16.count - offset, self.segmentByteLimit - self.currentBytes)
                let chunk = pcm16.subdata(in: offset..<(offset + count))
                self.sessions[self.activeSegment]?.sendAudio(chunk)
                self.currentBytes += count
                self.totalBytes += count
                offset += count
                let quietBoundary = self.currentBytes >= self.segmentByteLimit * 3 / 4 && Self.isQuiet(chunk)
                if self.currentBytes == self.segmentByteLimit || quietBoundary {
                    do { try self.archive?.finishSegment(at: self.totalBytes) }
                    catch { self.failures[self.activeSegment] = error.localizedDescription }
                    self.sessions[self.activeSegment]?.finish()
                    self.activeSegment += 1
                    self.currentBytes = 0
                    do {
                        let next = try self.factory()
                        self.sessions[self.activeSegment] = next
                        self.attach(next, index: self.activeSegment)
                        next.connect()
                    } catch { self.failures[self.activeSegment] = error.localizedDescription }
                    self.progress(self.failures.isEmpty ? "Recording — \(self.activeSegment) section\(self.activeSegment == 1 ? "" : "s") saved" : "Connection interrupted — recording continues locally")
                }
            }
        }
    }

    func finish() {
        q.async {
            guard self.recording, !self.cancelled, !self.resolved else { return }
            self.recording = false
            do {
                if self.currentBytes > 0 { try self.archive?.finishSegment(at: self.totalBytes) }
                try self.archive?.close()
            }
            catch { self.failures[self.activeSegment] = error.localizedDescription }
            if self.currentBytes > 0, let tail = self.sessions[self.activeSegment] {
                self.finishProvider(tail, index: self.activeSegment, bytes: self.currentBytes)
            }
            else { self.sessions.removeValue(forKey: self.activeSegment)?.cancel(); self.failures[self.activeSegment] = nil }
            self.progress("Finishing \(max(1, self.segmentCount)) recorded section\(self.segmentCount == 1 ? "" : "s")…")
            self.resolveIfFinished()
        }
    }

    private func finishProvider(_ session: STTSession, index: Int, bytes: Int) {
        // The provider's accidental-tap shortcut applies to a whole recording, never a
        // real tail after an earlier segment. Pad only the transport to its minimum duration;
        // the durable archive remains byte-exact to what the microphone captured.
        let minimumBytes = Int(sampleRate * 0.15) * 2
        if index > 0 && bytes > 0 && bytes < minimumBytes {
            session.sendAudio(Data(count: minimumBytes - bytes))
        }
        session.finish()
    }

    private var segmentCount: Int { archive?.segmentRanges.count ?? 0 }
    private static func isQuiet(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            return samples.allSatisfy { abs(Int($0)) < 128 }
        }
    }
    private func joined(includePartial: Bool) -> String {
        (0..<max(segmentCount, 1)).compactMap { index in
            archive?.manifest.transcripts[String(index)] ?? (includePartial ? partials[index] : nil)
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    private func resolveIfFinished() {
        guard !recording, sessions.isEmpty, !resolved, !cancelled else { return }
        let missing = (0..<segmentCount).filter { archive?.manifest.transcripts[String($0)] == nil }
        if let index = missing.first ?? failures.keys.sorted().first {
            let error = failures[index] ?? "A section did not finish"
            archive?.recordFailure(error)
            resolve(.failure(STTError.connection("\(error). Your complete recording is saved. Use Retry saved recording.")))
        } else { resolve(.success(joined(includePartial: false))) }
    }

    private func startReplay() {
        replayIndices = (0..<segmentCount).filter { archive?.manifest.transcripts[String($0)] == nil }
        advanceReplay()
    }
    private func advanceReplay() {
        guard !cancelled, !resolved else { return }
        if !failures.isEmpty { resolveIfFinished(); return }
        guard !replayIndices.isEmpty else { resolveIfFinished(); return }
        let index = replayIndices.removeFirst()
        do {
            let next = try factory()
            guard next.sampleRate == sampleRate else { throw STTError.connection("Select the original transcription provider to retry this recording") }
            sessions[index] = next
            attach(next, index: index)
            next.connect()
            replayOffset = archive?.segmentRanges[index].lowerBound ?? index * segmentByteLimit
            replayGeneration += 1
            progress("Recovering section \(index + 1) of \(segmentCount)…")
            feedReplay(index: index, session: next, generation: replayGeneration)
        } catch { failures[index] = error.localizedDescription; resolveIfFinished() }
    }
    private func feedReplay(index: Int, session: STTSession, generation: Int) {
        guard !cancelled, !resolved, generation == replayGeneration, sessions[index] === session else { return }
        let end = archive?.segmentRanges[index].upperBound ?? min(totalBytes, (index + 1) * segmentByteLimit)
        guard replayOffset < end else {
            let start = archive?.segmentRanges[index].lowerBound ?? index * segmentByteLimit
            finishProvider(session, index: index, bytes: end - start)
            return
        }
        do {
            let data = try archive?.read(offset: replayOffset, count: min(Int(sampleRate / 10) * 2, end - replayOffset)) ?? Data()
            guard !data.isEmpty else { throw STTError.connection("The saved audio ended unexpectedly") }
            replayOffset += data.count
            session.sendAudio(data)
            let delay = engineName.hasPrefix("universal") ? 0.1 : 0.025
            q.asyncAfter(deadline: .now() + delay) { self.feedReplay(index: index, session: session, generation: generation) }
        } catch { sessions.removeValue(forKey: index)?.cancel(); failures[index] = error.localizedDescription; resolveIfFinished() }
    }

    func cancel() {
        q.async {
            self.cancelled = true
            self.recording = false
            self.sessions.values.forEach { $0.cancel() }
            self.sessions.removeAll()
            try? self.archive?.close()
            self.archive?.releaseOwnership()
        }
    }
    func releaseRecoveryOwnership() { q.sync { archive?.releaseOwnership() } }
    func discardRecording() { q.sync { archive?.remove(); archive = nil } }
    func checkpointRecording() { q.sync { if !cancelled { try? archive?.close() } } }
    func configureRecovery(mode: String, translationTarget: String?) {
        q.async {
            guard !self.cancelled, !self.resolved else { return }
            self.recoveryMode = mode
            self.recoveryTranslationTarget = translationTarget
            self.archive?.recordMode(mode, translationTarget: translationTarget)
        }
    }
    func injectDisconnect() {
        q.async {
            guard let current = self.sessions.removeValue(forKey: self.activeSegment) else { return }
            current.cancel()
            self.failures[self.activeSegment] = "Injected transport disconnect for reliability testing"
            self.archive?.recordFailure(self.failures[self.activeSegment]!)
            self.progress("Connection interrupted — recording continues locally")
        }
    }
    private func progress(_ text: String) { DispatchQueue.main.async { self.onProgress?(text) } }
    private func resolve(_ result: Result<String, Error>) {
        guard !resolved, !cancelled else { return }
        resolved = true
        recording = false
        sessions.values.forEach { $0.cancel() }
        sessions.removeAll()
        try? archive?.close()
        if case .failure = result { archive?.releaseOwnership() }
        Log.info("Recording finalized: seconds=\(String(format: "%.1f", Double(totalBytes) / 2 / sampleRate)) segments=\(segmentCount) complete=\((try? result.get()) != nil) archived=\(archive != nil)")
        DispatchQueue.main.async { self.onFinal?(result) }
    }
}
