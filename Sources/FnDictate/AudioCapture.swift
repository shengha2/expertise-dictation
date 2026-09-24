import Foundation
import AVFoundation
import CoreAudio

enum AudioError: LocalizedError {
    case noInputDevice
    var errorDescription: String? { "No microphone is available" }
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

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat?
    private var tapInstalled = false
    private var capturing = false
    private let stateLock = NSLock()
    private var observer: NSObjectProtocol?
    private(set) var currentSampleRate: Double = 24000
    private(set) var capturedSeconds: Double = 0
    var preferBuiltInMic = true

    init() {
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.stateLock.lock()
            let wasCapturing = self.capturing
            let previousSeconds = self.capturedSeconds
            self.stateLock.unlock()
            guard wasCapturing else { return }
            Log.warn("Audio configuration changed mid-recording; restarting capture")
            let rate = self.currentSampleRate
            self.stop(keepWarm: false)
            do {
                try self.start(sampleRate: rate)
                self.stateLock.lock(); self.capturedSeconds += previousSeconds; self.stateLock.unlock()
                self.onInterruption?("Microphone changed — capture resumed; audio during the device change could not be recorded")
            }
            catch { self.onError?(error) }
        }
    }

    /// Pre-allocates the engine so the first `start()` is fast.
    func prepare() {
        _ = engine.inputNode
        engine.prepare()
    }

    func start(sampleRate: Double) throws {
        stateLock.lock(); capturing = false; stateLock.unlock()
        currentSampleRate = sampleRate
        capturedSeconds = 0
        let input = engine.inputNode
        let requestedDevice = preferBuiltInMic ? AudioDevices.builtInInputDeviceID() : AudioDevices.defaultInputDeviceID()
        if let id = requestedDevice, input.auAudioUnit.deviceID != id {
            // A prior explicit selection survives start/stop. Restore the system device when
            // the user changes from Built-in Microphone to System Default.
            if tapInstalled { input.removeTap(onBus: 0); tapInstalled = false }
            engine.stop()
            do {
                try input.auAudioUnit.setDeviceID(id)
                Log.info("Using selected microphone (device \(id))")
            } catch {
                Log.warn("Could not select microphone: \(error)")
            }
        }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw AudioError.noInputDevice }
        Log.info("Audio input: \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch, device \(AudioDevices.defaultInputDeviceID() ?? 0), mic permission \(Permissions.microphoneStatus.rawValue)")
        guard let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            throw AudioError.noInputDevice
        }
        converter = AVAudioConverter(from: fmt, to: out)
        outFormat = out
        if tapInstalled { input.removeTap(onBus: 0) }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        tapInstalled = true
        stateLock.lock(); capturing = true; stateLock.unlock()
        if !engine.isRunning {
            do { try engine.start() }
            catch {
                stop(keepWarm: false)
                throw error
            }
        }
    }

    /// Stops forwarding audio. With `keepWarm` the engine keeps running (the mic indicator stays on)
    /// so the next start is instant.
    func stop(keepWarm: Bool) {
        // Wait for the last tap callback to finish forwarding its PCM before finish() commits
        // the STT buffer. Otherwise the tail of a word can arrive after the provider commit.
        stateLock.lock(); capturing = false; stateLock.unlock()
        if !keepWarm {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            tapInstalled = false
            engine.stop()
        }
    }

    var isEngineRunning: Bool { engine.isRunning }

    private func process(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard capturing, let converter, let outFormat else { return }
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
            let callback = onError
            DispatchQueue.main.async { callback?(failure) }
            return
        }
        guard let data = out.int16ChannelData, out.frameLength > 0 else { return }
        capturedSeconds += Double(out.frameLength) / outFormat.sampleRate
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
