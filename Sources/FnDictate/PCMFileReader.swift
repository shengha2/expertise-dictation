import Foundation
import AVFoundation

/// Bounded-memory conversion used by the real-provider file harness. AVAudioFile may throw
/// at EOF instead of returning a zero-frame buffer, so check framePosition before reading.
final class PCMFileReader {
    let duration: Double
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let inputFrames: AVAudioFrameCount
    private var finished = false

    init(url: URL, sampleRate: Double) throws {
        file = try AVAudioFile(forReading: url)
        duration = Double(file.length) / file.processingFormat.sampleRate
        inputFrames = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inputFrames),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate / 10) + 512) else {
            throw STTError.connection("Cannot prepare input audio conversion")
        }
        self.converter = converter
        self.input = input
        self.output = output
    }

    func nextChunk() throws -> Data? {
        guard !finished else { return nil }
        let atEnd = file.framePosition >= file.length
        if !atEnd {
            do { try file.read(into: input, frameCount: min(inputFrames, AVAudioFrameCount(file.length - file.framePosition))) }
            catch { throw STTError.connection("Reading audio at frame \(file.framePosition) of \(file.length): \(error.localizedDescription)") }
        }
        output.frameLength = 0
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if atEnd { inputStatus.pointee = .endOfStream; return nil }
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return self.input
        }
        guard status != .error else {
            throw STTError.connection("Converting audio at frame \(file.framePosition) of \(file.length): \(error?.localizedDescription ?? "conversion failed")")
        }
        if status == .endOfStream || (atEnd && output.frameLength == 0) { finished = true }
        if output.frameLength > 0, let data = output.int16ChannelData {
            return Data(bytes: data[0], count: Int(output.frameLength) * 2)
        }
        return finished ? nil : Data()
    }
}
