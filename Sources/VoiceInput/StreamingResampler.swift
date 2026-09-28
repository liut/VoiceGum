import AVFoundation

/// Converts microphone buffers to 16 kHz mono float samples with a persistent converter, so the
/// resampling state carries across buffers instead of restarting on every tap callback.
final class StreamingAudioResampler: @unchecked Sendable {

    static let sampleRate: Double = 16_000

    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init() {
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
    }

    /// Returns the 16 kHz mono samples produced from this buffer; empty when conversion fails.
    func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0, let converter = converter(for: buffer.format) else { return [] }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        var suppliedInput = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, status != .error, output.frameLength > 0,
              let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    func reset() {
        converter?.reset()
        converter = nil
        inputFormat = nil
    }

    private func converter(for format: AVAudioFormat) -> AVAudioConverter? {
        if let converter, inputFormat == format { return converter }
        guard let created = AVAudioConverter(from: format, to: outputFormat) else { return nil }
        converter = created
        inputFormat = format
        return created
    }
}
