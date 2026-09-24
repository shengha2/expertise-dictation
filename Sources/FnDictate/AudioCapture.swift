import Foundation
import AVFoundation
import CoreAudio

enum AudioError: LocalizedError {
    case noInputDevice
    var errorDescription: String? { "No microphone is available" }
}

/// Keeps hardware access replaceable so lifecycle races can be tested with real PCM
/// conversion, without opening a microphone or writing to the user's profile.
protocol AudioCaptureEngine: AnyObject {
    var isRunning: Bool { get }
    var deviceID: AudioDeviceID { get }
    var inputFormat: AVAudioFormat { get }
    var onConfigurationChange: (() -> Void)? { get set }
    func prepare()
    func selectDevice(_ id: AudioDeviceID) throws
    func installTap(_ receive: @escaping (AVAudioPCMBuffer) -> Void, format: AVAudioFormat)
    func removeTap()
    func start() throws
    func stop()
}

private final class MicrophoneCaptureEngine: AudioCaptureEngine {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    var onConfigurationChange: (() -> Void)?
    var isRunning: Bool { engine.isRunning }
    var deviceID: AudioDeviceID { engine.inputNode.auAudioUnit.deviceID }
    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    init() {
        // Snapshot capture generation on the posting thread, before a delayed main-
        // queue delivery could make an old setup/stop event look like a new recording.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                           object: engine, queue: nil) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func prepare() { _ = engine.inputNode; engine.prepare() }
    func selectDevice(_ id: AudioDeviceID) throws { try engine.inputNode.auAudioUnit.setDeviceID(id) }
    func installTap(_ receive: @escaping (AVAudioPCMBuffer) -> Void, format: AVAudioFormat) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in receive(buffer) }
    }
    func removeTap() { engine.inputNode.removeTap(onBus: 0) }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }
}

/// Microphone capture that delivers 16-bit mono PCM at the sample rate the transcription
/// engine wants (24 kHz for OpenAI, 16 kHz for AssemblyAI) plus a smoothed level for the waveform.
final class AudioCapture {
    /// PCM16 chunk (little endian mono). Called on the audio thread.
    var onChunk: ((Data) -> Void)?
    /// Level 0…1. Called on the audio thread.
    var onLevel: ((Float) -> Void)?
    /// Capture errors after an input device changes. Delivered on the main thread.
    var onError: ((Error) -> Void)?
    var onInterruption: ((String) -> Void)?

    private let engine: AudioCaptureEngine
    private let requestedDevice: (Bool) -> AudioDeviceID?
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat?
    private var tapInstalled = false
    private var capturing = false
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var configuredDevice: AudioDeviceID?
    private var configuredFormat: AVAudioFormat?
    private(set) var currentSampleRate: Double = 24000
    private var totalCapturedSeconds: Double = 0
    var capturedSeconds: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return totalCapturedSeconds
    }
    var preferBuiltInMic = true

    init(engine: AudioCaptureEngine? = nil, requestedDevice: @escaping (Bool) -> AudioDeviceID? = {
        $0 ? AudioDevices.builtInInputDeviceID() : AudioDevices.defaultInputDeviceID()
    }) {
        self.engine = engine ?? MicrophoneCaptureEngine()
        self.requestedDevice = requestedDevice
        self.engine.onConfigurationChange = { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let eventGeneration = self.generation
            self.stateLock.unlock()
            // AVAudioEngine posts from an internal queue. Do not tear down or restart
            // it there, and never block that queue waiting for the main thread.
            DispatchQueue.main.async { [weak self] in self?.configurationChanged(generation: eventGeneration) }
        }
    }

    private func configurationChanged(generation eventGeneration: UInt64) {
        stateLock.lock()
        let active = capturing && generation == eventGeneration
        stateLock.unlock()
        guard active else { return }
        if engine.isRunning, engine.deviceID == configuredDevice,
           let configuredFormat, engine.inputFormat.isEqual(configuredFormat) {
            Log.info("Audio configuration notice: input unchanged and engine running; continuing capture")
            return
        }
        Log.warn("Audio configuration requires capture restart (running=\(engine.isRunning), device=\(engine.deviceID))")
        let rate = currentSampleRate
        stop(keepWarm: false)
        // stop waits for the final tap callback. Take the duration afterward so that
        // the last chunk before the interruption remains included exactly once.
        let previousSeconds = capturedSeconds
        do {
            try startCapture(sampleRate: rate, previousSeconds: previousSeconds)
            onInterruption?("Audio input restarted — recording resumed. A brief gap may be missing.")
        } catch { onError?(error) }
    }

    /// Pre-allocates the engine so the first `start()` is fast.
    func prepare() {
        engine.prepare()
    }

    func start(sampleRate: Double) throws {
        try startCapture(sampleRate: sampleRate, previousSeconds: 0)
    }

    private func startCapture(sampleRate: Double, previousSeconds: Double) throws {
        var started = false
        defer { if !started { stop(keepWarm: false) } }
        stateLock.lock()
        capturing = false
        generation &+= 1
        let tapGeneration = generation
        totalCapturedSeconds = previousSeconds
        stateLock.unlock()
        currentSampleRate = sampleRate
        if let id = requestedDevice(preferBuiltInMic), engine.deviceID != id {
            // A prior explicit selection survives start/stop. Restore the system device when
            // the user changes from Built-in Microphone to System Default.
            if tapInstalled { engine.removeTap(); tapInstalled = false }
            engine.stop()
            do {
                try engine.selectDevice(id)
                Log.info("Using selected microphone (device \(id))")
            } catch {
                Log.warn("Could not select microphone: \(error)")
            }
        }
        let fmt = engine.inputFormat
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw AudioError.noInputDevice }
        Log.info("Audio input: \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch, device \(engine.deviceID), mic permission \(Permissions.microphoneStatus.rawValue)")
        guard let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            throw AudioError.noInputDevice
        }
        guard let newConverter = AVAudioConverter(from: fmt, to: out) else { throw AudioError.noInputDevice }
        converter = newConverter
        outFormat = out
        configuredDevice = engine.deviceID
        configuredFormat = fmt
        if tapInstalled { engine.removeTap() }
        engine.installTap({ [weak self] buffer in
            self?.process(buffer, generation: tapGeneration)
        }, format: fmt)
        tapInstalled = true
        stateLock.lock(); capturing = true; stateLock.unlock()
        if !engine.isRunning {
            try engine.start()
        }
        started = true
    }

    /// Stops forwarding audio. With `keepWarm` the engine keeps running (the mic indicator stays on)
    /// so the next start is instant.
    func stop(keepWarm: Bool) {
        // Wait for the last tap callback to finish forwarding its PCM before finish() commits
        // the STT buffer. Otherwise the tail of a word can arrive after the provider commit.
        stateLock.lock(); capturing = false; generation &+= 1; stateLock.unlock()
        if !keepWarm {
            if tapInstalled { engine.removeTap() }
            tapInstalled = false
            engine.stop()
        }
    }

    var isEngineRunning: Bool { engine.isRunning }

    private func process(_ buffer: AVAudioPCMBuffer, generation tapGeneration: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard capturing, generation == tapGeneration, let converter, let outFormat else { return }
        // Level meter from the raw float samples.
        if let ch = buffer.floatChannelData, buffer.frameLength > 0 {
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            let p = ch[0]
            for i in 0..<n { sum += p[i] * p[i] }
            let rms = sqrt(sum / Float(n))
            let db = 20 * log10(max(rms, 1e-7))
            let level = min(1, max(0, (db + 52) / 42)) // -52 dB → 0, -10 dB → 1
            onLevel?(level)
        }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            capturing = false
            let failure = error ?? NSError(domain: "FnDictate.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone audio conversion failed"])
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let current = self.generation == tapGeneration
                self.stateLock.unlock()
                if current { self.onError?(failure) }
            }
            return
        }
        guard let data = out.int16ChannelData, out.frameLength > 0 else { return }
        totalCapturedSeconds += Double(out.frameLength) / outFormat.sampleRate
        let bytes = Data(bytes: data[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        onChunk?(bytes)
    }
}

/// Minimal CoreAudio helpers for picking the built-in microphone.
enum AudioDevices {
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    static func builtInInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var transport: UInt32 = 0
            var tsize = UInt32(MemoryLayout<UInt32>.size)
            var taddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            if inputChannelCount(id) > 0 { return id }
        }
        return nil
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
