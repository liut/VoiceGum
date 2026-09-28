import XCTest
@testable import VoiceGumVoiceInput

final class StreamingSegmenterTests: XCTestCase {

    // MARK: - Helpers

    private var sampleRate: Int { AudioFixtures.sampleRate }

    private func speech(seconds: Double) -> [Float] { AudioFixtures.speech(seconds: seconds) }

    private func silence(seconds: Double) -> [Float] { AudioFixtures.silence(seconds: seconds) }

    private func noise(seconds: Double, rms: Float) -> [Float] {
        AudioFixtures.noise(seconds: seconds, rms: rms)
    }

    // MARK: - Happy path

    func testTwoUtterancesSeparatedByLongPause() {
        var segmenter = StreamingSegmenter()
        let firstSpeech = speech(seconds: 1)
        let pause = silence(seconds: 0.8)
        let secondSpeech = speech(seconds: 1)

        let closed = segmenter.feed(firstSpeech + pause + secondSpeech)
        XCTAssertEqual(closed.count, 1, "the pause is long enough to close the first utterance")

        guard let first = closed.first else { return }
        XCTAssertLessThanOrEqual(first.startSample, 2 * 1_600)
        XCTAssertGreaterThanOrEqual(first.endSample, firstSpeech.count)
        XCTAssertLessThanOrEqual(first.endSample, firstSpeech.count + pause.count)

        guard let second = segmenter.flush() else {
            XCTFail("the trailing utterance must be flushed at the end of the stream")
            return
        }
        // The onset is detected inside the pause; pre-roll must not reach back into the first utterance.
        XCTAssertGreaterThanOrEqual(second.startSample, firstSpeech.count)
        XCTAssertLessThanOrEqual(second.startSample, firstSpeech.count + pause.count)
        XCTAssertEqual(second.endSample, firstSpeech.count + pause.count + secondSpeech.count)
    }

    // MARK: - Edge cases

    func testShortPauseDoesNotSplitUtterance() {
        var segmenter = StreamingSegmenter()
        let samples = speech(seconds: 1) + silence(seconds: 0.3) + speech(seconds: 1)

        XCTAssertTrue(segmenter.feed(samples).isEmpty, "a 300 ms pause is below the 500 ms split threshold")

        guard let segment = segmenter.flush() else {
            XCTFail("the unsplit utterance must be flushed at the end of the stream")
            return
        }
        XCTAssertLessThanOrEqual(segment.startSample, 2 * 1_600)
        XCTAssertEqual(segment.endSample, samples.count)
    }

    func testThreeUtterancesProduceThreeSegments() {
        var segmenter = StreamingSegmenter()
        let utterance = speech(seconds: 1)
        let pause = silence(seconds: 0.8)

        var segments = segmenter.feed(utterance + pause)   // closes the first utterance
        segments += segmenter.feed(utterance + pause)      // closes the second
        segments += segmenter.feed(utterance)              // opens the third
        if let trailing = segmenter.flush() { segments.append(trailing) }

        XCTAssertEqual(segments.count, 3)
    }

    func testLongUtteranceIsCutAtMaximumLength() {
        var segmenter = StreamingSegmenter()
        let samples = speech(seconds: 35)

        let closed = segmenter.feed(samples)
        XCTAssertEqual(closed.count, 1, "a 35 s utterance is cut once at the 30 s cap")

        guard let cut = closed.first else { return }
        XCTAssertEqual(cut.startSample, 0)
        XCTAssertEqual(Double(cut.sampleCount) / Double(sampleRate), 30.0, accuracy: 0.2)
        XCTAssertNotNil(segmenter.flush(), "the remaining speech is still flushed")
    }

    func testSilenceOnlyProducesNoSegments() {
        var segmenter = StreamingSegmenter()
        XCTAssertTrue(segmenter.feed(silence(seconds: 2)).isEmpty)
        XCTAssertNil(segmenter.flush())
    }

    func testSteadyNoiseIsNotSpeech() {
        var segmenter = StreamingSegmenter()
        XCTAssertTrue(segmenter.feed(noise(seconds: 3, rms: 0.02)).isEmpty)
        XCTAssertNil(segmenter.flush())
    }

    func testIncrementalAndBulkFeedingAgree() {
        let samples = speech(seconds: 0.8) + silence(seconds: 0.7) + speech(seconds: 0.8)

        var bulk = StreamingSegmenter()
        let bulkSegments = bulk.feed(samples)
        let bulkFlush = bulk.flush()

        var incremental = StreamingSegmenter()
        var incrementalSegments: [StreamingSegmenter.Segment] = []
        for start in stride(from: 0, to: samples.count, by: 160) {
            let end = min(start + 160, samples.count)
            incrementalSegments += incremental.feed(Array(samples[start..<end]))
        }
        let incrementalFlush = incremental.flush()

        XCTAssertEqual(bulkSegments, incrementalSegments)
        XCTAssertEqual(bulkFlush, incrementalFlush)
        XCTAssertFalse(bulkSegments.isEmpty)
    }
}
