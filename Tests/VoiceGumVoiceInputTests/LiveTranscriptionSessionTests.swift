@preconcurrency import AVFoundation
import XCTest
@testable import VoiceGumVoiceInput

final class LiveTranscriptionSessionTests: XCTestCase {

    // MARK: - Helpers

    private final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Value] = []

        func append(_ value: Value) {
            lock.lock(); defer { lock.unlock() }
            values.append(value)
        }

        var all: [Value] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    /// Three utterances, each closed by a pause long enough to end the segment.
    private func threeUtterances() -> [AVAudioPCMBuffer] {
        [
            AudioFixtures.buffer(AudioFixtures.speech(seconds: 1)),
            AudioFixtures.buffer(AudioFixtures.silence(seconds: 0.8)),
            AudioFixtures.buffer(AudioFixtures.speech(seconds: 1)),
            AudioFixtures.buffer(AudioFixtures.silence(seconds: 0.8)),
            AudioFixtures.buffer(AudioFixtures.speech(seconds: 1)),
        ]
    }

    // MARK: - Happy path

    func testSegmentsDecodeInOrderAndAccumulate() async {
        let recorder = Recorder<String>()
        let counter = Counter()
        let session = LiveTranscriptionSession(
            language: "zh-CN",
            decoder: { _, _ in "段\(counter.next())" },
            onText: { recorder.append($0) })

        for buffer in threeUtterances() {
            await session.append(buffer)
            try? await Task.sleep(for: .milliseconds(50))
        }
        let finalText = await session.finish()

        XCTAssertEqual(finalText, "段1 段2 段3")
        XCTAssertEqual(recorder.all, ["段1", "段1 段2", "段1 段2 段3"])
    }

    // MARK: - Edge cases

    func testSlowDecoderDropsIntermediateSegments() async {
        let recorder = Recorder<String>()
        let lengths = Recorder<Int>()
        let session = LiveTranscriptionSession(
            language: "zh-CN",
            decoder: { samples, _ in
                try? await Task.sleep(for: .milliseconds(300))
                lengths.append(samples.count)
                return String(repeating: "字", count: samples.count)
            },
            onText: { recorder.append($0) })

        let buffers = [
            AudioFixtures.buffer(AudioFixtures.speech(seconds: 1)),
            AudioFixtures.buffer(AudioFixtures.silence(seconds: 0.8)),
            AudioFixtures.buffer(AudioFixtures.speech(seconds: 0.6)),  // dropped while the first decode runs
            AudioFixtures.buffer(AudioFixtures.silence(seconds: 0.8)),
            AudioFixtures.buffer(AudioFixtures.speech(seconds: 2)),    // survives as the newest segment
        ]
        for buffer in buffers {
            await session.append(buffer)
        }
        let finalText = await session.finish()

        XCTAssertEqual(recorder.all.count, 2, "preview keeps only the first and the newest segment")
        XCTAssertEqual(finalText.split(separator: " ").count, 2)
        XCTAssertEqual(lengths.all.count, 2)
        XCTAssertLessThanOrEqual(lengths.all[0], 25_000)
        XCTAssertGreaterThanOrEqual(lengths.all[1], 30_000, "the surviving segment is the trailing one")
    }

    func testEmptyDecodeProducesNoText() async {
        let recorder = Recorder<String>()
        let session = LiveTranscriptionSession(
            language: "zh-CN",
            decoder: { _, _ in "" },
            onText: { recorder.append($0) })

        for buffer in threeUtterances() {
            await session.append(buffer)
            try? await Task.sleep(for: .milliseconds(50))
        }

        let finalText = await session.finish()
        XCTAssertEqual(finalText, "")
        XCTAssertTrue(recorder.all.isEmpty)
    }

    func testDecoderReceivesSessionLanguage() async {
        let recorder = Recorder<String>()
        let languages = Recorder<String>()
        let session = LiveTranscriptionSession(
            language: "ja",
            decoder: { _, language in
                languages.append(language)
                return "ok"
            },
            onText: { recorder.append($0) })

        for buffer in threeUtterances() {
            await session.append(buffer)
            try? await Task.sleep(for: .milliseconds(50))
        }
        _ = await session.finish()

        XCTAssertEqual(languages.all, ["ja", "ja", "ja"])
    }

    func testSessionSegmentsHardwareRateInput() async {
        let recorder = Recorder<String>()
        let lengths = Recorder<Int>()
        let counter = Counter()
        let session = LiveTranscriptionSession(
            language: "zh-CN",
            decoder: { samples, _ in
                lengths.append(samples.count)
                return "段\(counter.next())"
            },
            onText: { recorder.append($0) })

        let buffers = [
            AudioFixtures.buffer(AudioFixtures.speech(seconds: 1, sampleRate: 48_000), sampleRate: 48_000),
            AudioFixtures.buffer(AudioFixtures.silence(seconds: 0.8, sampleRate: 48_000), sampleRate: 48_000),
            AudioFixtures.buffer(AudioFixtures.speech(seconds: 1, sampleRate: 48_000), sampleRate: 48_000),
        ]
        for buffer in buffers {
            await session.append(buffer)
            try? await Task.sleep(for: .milliseconds(50))
        }
        let finalText = await session.finish()

        XCTAssertEqual(finalText, "段1 段2")
        XCTAssertEqual(lengths.all.count, 2)
        for length in lengths.all {
            XCTAssertGreaterThan(length, 16_000)
            XCTAssertLessThan(length, 25_000, "segments are cut at 16 kHz, not at the capture rate")
        }
    }

    func testCancelledSessionStopsProducingText() async {
        let recorder = Recorder<String>()
        let session = LiveTranscriptionSession(
            language: "zh-CN",
            decoder: { _, _ in
                try? await Task.sleep(for: .milliseconds(300))
                return "迟到的文本"
            },
            onText: { recorder.append($0) })

        for buffer in threeUtterances() {
            await session.append(buffer)
        }
        await session.cancel()
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertTrue(recorder.all.isEmpty, "a cancelled session must not publish text")
        let finalText = await session.finish()
        XCTAssertEqual(finalText, "")
    }

    // MARK: - Resampling

    func testResamplerConverts48kInputTo16k() {
        let resampler = StreamingAudioResampler()
        let input = AudioFixtures.speech(seconds: 1, sampleRate: 48_000)

        let output = resampler.resample(AudioFixtures.buffer(input, sampleRate: 48_000))

        XCTAssertLessThanOrEqual(abs(output.count - 16_000), 64)
        let rms = (output.reduce(Float(0)) { $0 + $1 * $1 } / Float(output.count)).squareRoot()
        XCTAssertEqual(rms, 0.354, accuracy: 0.05)
    }

    func testResamplerCarriesStateAcrossBuffers() {
        let resampler = StreamingAudioResampler()
        let half = AudioFixtures.speech(seconds: 0.5, sampleRate: 48_000)

        var output: [Float] = []
        for _ in 0..<2 {
            output += resampler.resample(AudioFixtures.buffer(half, sampleRate: 48_000))
        }

        XCTAssertLessThanOrEqual(abs(output.count - 16_000), 64)
    }
}
