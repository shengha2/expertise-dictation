import Foundation
import AVFoundation
import CoreAudio

/// Exercises the production lifecycle and PCM converter using an injected engine.
/// No microphone, network, global audio route, or user preferences are modified.
enum AudioCaptureRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        func expect(_ name: String, _ passed: Bool) { check("audio capture: " + name, passed, "") }
        guard Thread.isMainThread else {
            check("audio capture: fixtures run on the main thread", false, "Run this suite from the main thread.")
            return
        }

        func scenario(_ name: String, _ body: (Fixture) throws -> Void) {
            let fixture = Fixture()
            defer { fixture.capture.stop(keepWarm: false); drainMainQueue() }
            do { try body(fixture) }
            catch { check("audio capture: " + name, false, error.localizedDescription) }
        }

        scenario("cold setup") { f in
            f.requestedID = 2
            f.engine.noticeOnPrepare = true
            f.engine.noticeOnSelection = true
            f.engine.noticeOnStart = true
            f.capture.prepare()
            try f.capture.start(sampleRate: 24_000)
            f.engine.feed(frames: 240)
            drainMainQueue()
            expect("cold prepare, selection, and start notices do not restart healthy capture",
                   f.engine.startCount == 1 && f.engine.selectionCount == 1 && f.engine.installCount == 1)
            expect("cold setup notices do not create an interruption or error", f.warnings.isEmpty && f.errors.isEmpty)
            expect("first-recording PCM is delivered once despite setup notices", f.bytes.count == 480 && close(f.capture.capturedSeconds, 0.01))
        }

        scenario("delayed benign notice") { f in
            try f.capture.start(sampleRate: 24_000)
            f.engine.feed(frames: 480)
            let before = f.bytes
            f.engine.notify()
            drainMainQueue()
            f.engine.feed(frames: 240)
            expect("a delayed notice for the same live route keeps the tap and converter", f.engine.startCount == 1 && f.engine.installCount == 1 && f.engine.removeCount == 0)
            expect("benign notices preserve all existing PCM and accept later PCM", f.bytes.prefix(before.count) == before && f.bytes.count == 1_440 && close(f.capture.capturedSeconds, 0.03))
            expect("healthy duplicate notices stay silent", f.warnings.isEmpty && f.errors.isEmpty)
        }

        scenario("warm reuse") { f in
            try f.capture.start(sampleRate: 24_000)
            f.engine.feed(frames: 240)
            let oldTap = f.engine.tap
            f.capture.stop(keepWarm: true)
            oldTap?(FakeEngine.buffer(frames: 240, format: f.engine.inputFormat))
            expect("warm stop stops PCM delivery while leaving the engine running", f.bytes.count == 480 && f.engine.isRunning && f.engine.stopCount == 0)
            f.bytes.removeAll()
            try f.capture.start(sampleRate: 24_000)
            oldTap?(FakeEngine.buffer(frames: 240, format: f.engine.inputFormat))
            f.engine.notify()
            drainMainQueue()
            f.engine.feed(frames: 480)
            expect("warm reuse does not restart the engine or flag a microphone change", f.engine.startCount == 1 && f.warnings.isEmpty && f.errors.isEmpty)
            expect("a new warm session resets duration and rejects the old tap", f.bytes.count == 960 && close(f.capture.capturedSeconds, 0.02))
        }

        scenario("immediate true interruption") { f in
            try f.capture.start(sampleRate: 24_000)
            // No audio has arrived yet: real failures must not be hidden by a startup grace period.
            f.engine.isRunning = false
            f.engine.notify()
            drainMainQueue()
            f.engine.feed(frames: 240)
            expect("an engine stopped before the first audio frame is recovered", f.engine.startCount == 2 && f.engine.isRunning && f.bytes.count == 480)
            expect("a true first-recording interruption is reported once", f.warnings.count == 1 && f.errors.isEmpty)
        }

        scenario("same format device switch") { f in
            try f.capture.start(sampleRate: 24_000)
            f.engine.feed(frames: 240)
            f.engine.deviceID = 99
            f.engine.notify()
            drainMainQueue()
            f.engine.feed(frames: 480)
            expect("a changed device restarts even when its format and running state match", f.engine.startCount == 2 && f.engine.installCount == 2 && f.engine.deviceID == 99)
            expect("a device switch retains earlier PCM and cumulative duration", f.bytes.count == 1_440 && close(f.capture.capturedSeconds, 0.03) && f.warnings.count == 1)
        }

        for (name, rate, channels) in [("sample rate", 48_000.0, AVAudioChannelCount(1)), ("channel count", 24_000.0, AVAudioChannelCount(2))] {
            scenario("changed " + name) { f in
                try f.capture.start(sampleRate: 24_000)
                f.engine.feed(frames: 240)
                f.engine.inputFormat = FakeEngine.format(rate: rate, channels: channels)
                f.engine.notify()
                drainMainQueue()
                f.engine.feed(frames: AVAudioFrameCount(rate / 100))
                expect("a changed " + name + " rebuilds the converter and tap", f.engine.startCount == 2 && f.engine.installCount == 2 && f.warnings.count == 1 && f.errors.isEmpty)
                expect("PCM remains available after a changed " + name, f.bytes.count > 480 && f.capture.capturedSeconds > 0.01 && f.capture.currentSampleRate == 24_000)
                expect("duration matches delivered PCM after a changed " + name, close(f.capture.capturedSeconds, Double(f.bytes.count) / 48_000))
            }
        }

        scenario("duplicate real interruption") { f in
            try f.capture.start(sampleRate: 24_000)
            f.engine.feed(frames: 240)
            f.engine.isRunning = false
            for _ in 0..<5 { f.engine.notify() }
            f.engine.noticeOnStart = true
            drainMainQueue()
            f.engine.feed(frames: 240)
            expect("duplicate queued notices cause only one recovery", f.engine.startCount == 2 && f.engine.installCount == 2 && f.warnings.count == 1)
            expect("recovery's own startup notice does not recurse or duplicate PCM", f.bytes.count == 960 && close(f.capture.capturedSeconds, 0.02) && f.errors.isEmpty)
        }

        scenario("stop before queued delivery") { f in
            try f.capture.start(sampleRate: 24_000)
            f.engine.isRunning = false
            f.engine.notify()
            f.capture.stop(keepWarm: false)
            drainMainQueue()
            expect("a queued interruption cannot restart a stopped recording", f.engine.startCount == 1 && !f.engine.isRunning && f.warnings.isEmpty && f.errors.isEmpty)
        }

        scenario("old event and tap after new session") { f in
            try f.capture.start(sampleRate: 24_000)
            let oldTap = f.engine.tap
            f.engine.feed(frames: 240)
            f.engine.isRunning = false
            f.engine.notify()
            f.capture.stop(keepWarm: false)
            f.bytes.removeAll()
            try f.capture.start(sampleRate: 24_000)
            // Make the new engine unhealthy without emitting a new event. The old
            // event must not be allowed to operate on this later recording.
            f.engine.isRunning = false
            drainMainQueue()
            oldTap?(FakeEngine.buffer(frames: 240, format: f.engine.inputFormat))
            expect("a queued previous-generation event cannot recover the next session", f.engine.startCount == 2 && !f.engine.isRunning && f.warnings.isEmpty)
            expect("a previous-generation tap cannot feed the next session", f.bytes.isEmpty && f.capture.capturedSeconds == 0)
            f.engine.notify()
            drainMainQueue()
            f.engine.feed(frames: 240)
            expect("the new session's own event still recovers normally", f.engine.startCount == 3 && f.warnings.count == 1 && f.bytes.count == 480 && close(f.capture.capturedSeconds, 0.01))
        }

        scenario("multiple recoveries preserve duration") { f in
            try f.capture.start(sampleRate: 24_000)
            for _ in 0..<3 {
                f.engine.feed(frames: 240)
                f.engine.isRunning = false
                f.engine.notify()
                drainMainQueue()
            }
            f.engine.feed(frames: 240)
            expect("several recoveries preserve every delivered PCM chunk and duration", f.bytes.count == 1_920 && close(f.capture.capturedSeconds, 0.04) && f.warnings.count == 3)
            f.capture.stop(keepWarm: false)
            f.bytes.removeAll()
            try f.capture.start(sampleRate: 16_000)
            expect("an independent session resets duration and accepts a different output rate", f.capture.capturedSeconds == 0 && f.capture.currentSampleRate == 16_000)
            f.engine.feed(frames: 2_400)
            expect("the new output rate is reflected in delivered PCM duration", !f.bytes.isEmpty && close(f.capture.capturedSeconds, Double(f.bytes.count) / 32_000))
        }

        scenario("recovery failure") { f in
            try f.capture.start(sampleRate: 24_000)
            f.engine.feed(frames: 240)
            let oldTap = f.engine.tap
            f.engine.failStarts = 1
            f.engine.isRunning = false
            for _ in 0..<3 { f.engine.notify() }
            drainMainQueue()
            oldTap?(FakeEngine.buffer(frames: 240, format: f.engine.inputFormat))
            expect("a failed recovery reports one error and no success warning", f.errors.count == 1 && f.warnings.isEmpty && f.engine.startCount == 2)
            expect("failed recovery stops capture and retains the already delivered recording", !f.engine.isRunning && f.engine.tap == nil && f.bytes.count == 480 && close(f.capture.capturedSeconds, 0.01))
            expect("recovery errors are delivered on the main thread", f.callbacksOnMain)
            try f.capture.start(sampleRate: 24_000)
            f.bytes.removeAll()
            f.engine.feed(frames: 240)
            expect("capture can start a fresh session after recovery failure", f.engine.isRunning && f.bytes.count == 480 && close(f.capture.capturedSeconds, 0.01))
        }

        scenario("off-main event") { f in
            try f.capture.start(sampleRate: 24_000)
            f.engine.isRunning = false
            let notice = f.engine.onConfigurationChange
            let posted = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async { notice?(); posted.signal() }
            let delivered = posted.wait(timeout: .now() + 2) == .success
            expect("an off-main notification returns without blocking for the main thread", delivered && f.engine.startCount == 1)
            drainMainQueue()
            expect("off-main events marshal engine recovery and callbacks to the main thread", f.engine.startCount == 2 && f.warnings.count == 1 && f.callbacksOnMain && f.engine.operationsOnMain)
        }

        scenario("selection fallback") { f in
            f.requestedID = 2
            f.engine.failSelection = true
            try f.capture.start(sampleRate: 24_000)
            f.engine.notify()
            drainMainQueue()
            f.engine.feed(frames: 240)
            expect("failed device selection can use the actual available input without a restart loop", f.engine.deviceID == 1 && f.engine.startCount == 1 && f.engine.selectionCount == 1 && f.warnings.isEmpty && f.errors.isEmpty && f.bytes.count == 480)
        }
    }

    private static func close(_ left: Double, _ right: Double) -> Bool { abs(left - right) < 0.000_000_1 }

    /// Two barriers also allow a notice emitted during recovery to settle. RunLoop
    /// pumping is bounded and only services synthetic engine callbacks in this suite.
    private static func drainMainQueue() {
        for _ in 0..<2 {
            var drained = false
            DispatchQueue.main.async { drained = true }
            let deadline = Date().addingTimeInterval(2)
            while !drained && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            }
        }
    }

    private final class Fixture {
        let engine = FakeEngine()
        var requestedID: AudioDeviceID?
        lazy var capture = AudioCapture(engine: engine, requestedDevice: { [weak self] _ in self?.requestedID })
        var bytes = Data()
        var warnings: [String] = []
        var errors: [Error] = []
        var callbacksOnMain = true

        init() {
            capture.onChunk = { [weak self] in self?.bytes.append($0) }
            capture.onInterruption = { [weak self] message in
                guard let self else { return }
                self.warnings.append(message)
                self.callbacksOnMain = self.callbacksOnMain && Thread.isMainThread
            }
            capture.onError = { [weak self] error in
                guard let self else { return }
                self.errors.append(error)
                self.callbacksOnMain = self.callbacksOnMain && Thread.isMainThread
            }
        }
    }

    private final class FakeEngine: AudioCaptureEngine {
        var isRunning = false
        var deviceID: AudioDeviceID = 1
        var inputFormat = format(rate: 24_000, channels: 1)
        var onConfigurationChange: (() -> Void)?
        var tap: ((AVAudioPCMBuffer) -> Void)?
        var noticeOnPrepare = false
        var noticeOnSelection = false
        var noticeOnStart = false
        var failSelection = false
        var failStarts = 0
        var startCount = 0
        var stopCount = 0
        var selectionCount = 0
        var installCount = 0
        var removeCount = 0
        var operationsOnMain = true

        func prepare() { noteOperation(); if noticeOnPrepare { notify() } }
        func selectDevice(_ id: AudioDeviceID) throws {
            noteOperation(); selectionCount += 1
            if failSelection { throw syntheticFailure }
            deviceID = id
            if noticeOnSelection { notify() }
        }
        func installTap(_ receive: @escaping (AVAudioPCMBuffer) -> Void, format: AVAudioFormat) {
            noteOperation(); installCount += 1; tap = receive
        }
        func removeTap() { noteOperation(); removeCount += 1; tap = nil }
        func start() throws {
            noteOperation(); startCount += 1
            if failStarts > 0 { failStarts -= 1; throw syntheticFailure }
            isRunning = true
            if noticeOnStart { notify() }
        }
        func stop() { noteOperation(); stopCount += 1; isRunning = false }
        func notify() { onConfigurationChange?() }
        func feed(frames: AVAudioFrameCount) { tap?(Self.buffer(frames: frames, format: inputFormat)) }
        private func noteOperation() { operationsOnMain = operationsOnMain && Thread.isMainThread }
        private var syntheticFailure: NSError { NSError(domain: "ExpertiseDictation.AudioCaptureFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic engine failure"]) }

        static func format(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        }
        static func buffer(frames: AVAudioFrameCount, format: AVAudioFormat) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = 0.25 }
            }
            return buffer
        }
    }
}
