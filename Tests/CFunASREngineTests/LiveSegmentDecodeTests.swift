import AVFoundation
import XCTest
import CFunASREngine

/// U1 — single-utterance PCM decoding used by the live voice-input preview.
/// Model-dependent tests skip unless the models (and the sample audio) are present.
final class LiveSegmentDecodeTests: XCTestCase {

    // MARK: - Safety tests (no model needed)

    func testSenseVoicePCMWithNullHandleReturnsEmpty() {
        let samples = [Float](repeating: 0, count: 1_600)
        guard let result = sv_transcribe_pcm(nil, samples, Int32(samples.count), "zh", 1) else {
            XCTFail("null handle must still return an allocated empty string")
            return
        }
        XCTAssertEqual(String(cString: result), "")
        free(result)
    }

    func testNanoPCMWithNullHandleReturnsEmpty() {
        let samples = [Float](repeating: 0, count: 1_600)
        guard let result = nano_transcribe_pcm(nil, samples, Int32(samples.count), 1) else {
            XCTFail("null handle must still return an allocated empty string")
            return
        }
        XCTAssertEqual(String(cString: result), "")
        free(result)
    }

    // MARK: - End-to-end tests (model + audio required)

    func testSenseVoicePCMDecodesSpeechSlice() throws {
        let model = try senseVoiceModelPath()
        let audio = try loadSpeechSamples()
        guard let handle = sv_load_model(model, 0) else {
            XCTFail("failed to load \(model)")
            return
        }
        defer { sv_free(handle) }

        let samples = Array(audio.prefix(16_000 * 2))
        let result = try XCTUnwrap(sv_transcribe_pcm(
            handle, samples, Int32(samples.count), "zh", Int32(ProcessInfo.processInfo.activeProcessorCount)))
        XCTAssertFalse(String(cString: result).isEmpty)
        free(result)
    }

    func testNanoPCMDecodesSpeechSlice() throws {
        let encoder = try envPath("NANO_ENC", fallback: "/tmp/funasr-nano-models/funasr-encoder-f16.gguf")
        let decoder = try envPath("NANO_LLM", fallback: "/tmp/funasr-nano-models/Fun-ASR-Nano-Decoder.q8_0.gguf")
        let audio = try loadSpeechSamples()
        let threads = Int32(ProcessInfo.processInfo.activeProcessorCount)
        guard let handle = nano_load_model(encoder, decoder, threads) else {
            XCTFail("failed to load Nano models")
            return
        }
        defer { nano_free(handle) }

        let samples = Array(audio.prefix(16_000 * 2))
        let result = try XCTUnwrap(nano_transcribe_pcm(handle, samples, Int32(samples.count), threads))
        XCTAssertFalse(String(cString: result).isEmpty)
        free(result)
    }

    func testPCMWithEmptyInputReturnsEmptyText() throws {
        let model = try senseVoiceModelPath()
        guard let handle = sv_load_model(model, 0) else {
            XCTFail("failed to load \(model)")
            return
        }
        defer { sv_free(handle) }

        let result = try XCTUnwrap(sv_transcribe_pcm(handle, [], 0, "zh", 1))
        XCTAssertEqual(String(cString: result), "")
        free(result)
    }

    // MARK: - Helpers

    private func envPath(_ key: String, fallback: String) throws -> String {
        let path = ProcessInfo.processInfo.environment[key] ?? fallback
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "\(key) not found at \(path)")
        return path
    }

    private func senseVoiceModelPath() throws -> String {
        let modelsDir = ProcessInfo.processInfo.environment["OFFICIAL_MODEL_DIR"]
            ?? "\(NSHomeDirectory())/Library/Application Support/VoiceGum/Models"
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: modelsDir)) ?? []
        let modelDir = contents.first { $0.hasPrefix("sense-voice") } ?? contents.first { $0.contains("sense-voice") }
        let directory = modelDir.map { "\(modelsDir)/\($0)" } ?? modelsDir
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        guard let gguf = files.first(where: { $0.hasSuffix(".gguf") }) else {
            throw XCTSkip("no SenseVoice GGUF under \(directory)")
        }
        return "\(directory)/\(gguf)"
    }

    /// Reads the repository sample audio as 16 kHz mono float samples.
    private func loadSpeechSamples() throws -> [Float] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("example1.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "sample audio not found at \(url.path)")

        let file = try AVAudioFile(forReading: url)
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: outputFormat))
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)

        let ratio = outputFormat.sampleRate / file.processingFormat.sampleRate
        let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 64)!
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        let channel = try XCTUnwrap(output.floatChannelData?[0], "conversion failed: \(String(describing: error))")
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
