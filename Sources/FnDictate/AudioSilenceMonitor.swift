import Foundation

/// A conservative inactivity timer, not a speech recognizer. It only asks the controller to
/// finish normally: every captured sample must still be transcribed, even when audio is quiet.
/// PCM arrives on the capture thread; transcript callbacks and polling can arrive elsewhere.
final class AudioSilenceMonitor {
    static let silenceSeconds: TimeInterval = 12

    private struct Frame {
        let time: TimeInterval
        let rms: Double
        let audible: Bool
    }

    private let lock = NSLock()
    private var sessionID: UUID?
    private var startedAt: TimeInterval = 0
    private var lastActivity: TimeInterval = 0
    private var lastObservation: TimeInterval = 0
    private var lastTranscript = ""
    private var sampleRate: Double = 0
    private var frameSamples = 0
    private var sum = 0.0
    private var squares = 0.0
    private var peak = 0.0
    private var frames: [Frame] = []

    func reset(sessionID: UUID, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        self.sessionID = now.isFinite ? sessionID : nil
        startedAt = now
        lastActivity = now
        lastObservation = now
        lastTranscript = ""
        sampleRate = 0
        clearAudioWindow()
    }

    /// Little-endian signed PCM16, mono, at the provider's capture sample rate.
    func observe(pcm16: Data, sampleRate: Double, sessionID: UUID, now: TimeInterval) {
        guard now.isFinite, sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 192_000,
              !pcm16.isEmpty, pcm16.count.isMultiple(of: 2) else { return }
        lock.lock(); defer { lock.unlock() }
        guard self.sessionID == sessionID, now >= lastObservation else { return }
        lastObservation = now
        if self.sampleRate != sampleRate {
            self.sampleRate = sampleRate
            clearAudioWindow()
        }

        let count = pcm16.count / 2
        let windowSamples = max(1, Int((sampleRate * 0.02).rounded()))
        let chunkStart = now - Double(count) / sampleRate
        pcm16.withUnsafeBytes { bytes in
            let pcm = bytes.bindMemory(to: UInt8.self)
            for index in 0..<count {
                let bits = UInt16(pcm[2 * index]) | (UInt16(pcm[2 * index + 1]) << 8)
                let value = Double(Int16(bitPattern: bits)) / 32_768
                sum += value
                squares += value * value
                peak = max(peak, abs(value))
                frameSamples += 1
                if frameSamples == windowSamples {
                    let mean = sum / Double(frameSamples)
                    let rms = sqrt(max(0, squares / Double(frameSamples) - mean * mean))
                    let time = max(startedAt, chunkStart + Double(index + 1) / sampleRate)
                    // About -54 dBFS. Transcript evidence also protects quiet speech below this
                    // threshold. A high crest factor rejects single-sample/very short clicks.
                    let audible = rms >= 0.002 && peak / max(rms, 0.000_001) < 12
                    frames.append(Frame(time: time, rms: rms, audible: audible))
                    frames.removeAll { time - $0.time > 0.6 }
                    // Keep storage/work bounded even if callers deliver identical timestamps
                    // or an oversized chunk whose early frames clamp to the session start.
                    if frames.count > 31 { frames.removeFirst(frames.count - 31) }
                    evaluateAudioWindow(at: time)
                    frameSamples = 0; sum = 0; squares = 0; peak = 0
                }
            }
        }
    }

    /// Prefer the text-taking overload, which rejects repeated/blank partials itself.
    /// This overload is for callers that already checked the partial changed and is nonempty.
    func noteTranscriptActivity(sessionID: UUID, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        recordTranscriptActivity(sessionID: sessionID, now: now)
    }

    func noteTranscriptActivity(_ transcript: String, sessionID: UUID, now: TimeInterval) {
        let normalized = transcript.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard self.sessionID == sessionID, now.isFinite, now >= startedAt,
              normalized != lastTranscript else { return }
        lastTranscript = normalized
        recordTranscriptActivity(sessionID: sessionID, now: now)
    }

    func shouldFinish(sessionID: UUID, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.sessionID == sessionID, now.isFinite, now >= startedAt else { return false }
        return now - lastActivity >= Self.silenceSeconds
    }

    private func recordTranscriptActivity(sessionID: UUID, now: TimeInterval) {
        guard self.sessionID == sessionID, now.isFinite, now >= startedAt else { return }
        lastActivity = max(lastActivity, now)
    }

    private func clearAudioWindow() {
        frameSamples = 0; sum = 0; squares = 0; peak = 0
        frames.removeAll(keepingCapacity: true)
    }

    private func evaluateAudioWindow(at time: TimeInterval) {
        // Require at least 120ms of audible material, with audible audio in this frame.
        // A solitary click cannot keep resetting the timer during otherwise silent capture.
        guard frames.last?.audible == true, frames.filter(\.audible).count >= 6 else { return }
        let energy = frames.map(\.rms).sorted()
        let low = energy[Int(Double(energy.count - 1) * 0.1)]
        let high = energy[Int(Double(energy.count - 1) * 0.9)]
        // Speech usually has a changing envelope. A stationary hum/fan may count once at
        // its onset, but cannot postpone finishing forever merely by being above the floor.
        guard high >= max(0.002, low * 1.8) else { return }
        lastActivity = max(lastActivity, time)
    }
}
