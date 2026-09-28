import Foundation

/// Splits a continuous 16 kHz mono sample stream into speech segments for the live preview.
///
/// Frame-based energy VAD with an adaptive noise floor and hysteresis. It only drives the
/// on-screen preview: the final decode still runs the offline pipeline with its own VAD, so
/// mis-segmentation here costs preview readability, never correctness.
///
/// Tuning follows the offline energy VAD in `Sources/CFunASREngine/funasr-nano-vad.cpp`
/// (25 ms window, 10 ms hop, 300 ms minimum speech, 500 ms minimum silence).
struct StreamingSegmenter {

    /// A speech segment expressed as absolute sample indices in the fed stream.
    struct Segment: Equatable {
        let startSample: Int
        let endSample: Int

        var sampleCount: Int { endSample - startSample }
    }

    static let sampleRate = 16_000

    private static let frameLength = 400            // 25 ms
    private static let hopLength = 160              // 10 ms
    private static let minimumSpeechFrames = 30     // 300 ms
    private static let minimumSilenceFrames = 50    // 500 ms
    private static let maximumSegmentFrames = 3_000 // 30 s
    private static let preRollFrames = 20           // 200 ms
    private static let postRollFrames = 20          // 200 ms
    private static let bootstrapFrames = 20         // 200 ms of lead-in noise estimation
    private static let floorRange: ClosedRange<Float> = 0.003...0.05

    private var pending: [Float] = []
    private var pendingStart = 0
    private var frameCount = 0
    private var bootstrapSum: Float = 0
    private var noiseFloor = StreamingSegmenter.floorRange.lowerBound
    private var inSpeech = false
    private var segmentStart = 0
    private var lastSpeechEnd = 0
    private var silenceFrames = 0

    /// Feeds samples and returns the segments that ended inside this batch.
    mutating func feed(_ samples: [Float]) -> [Segment] {
        guard !samples.isEmpty else { return [] }
        pending.append(contentsOf: samples)

        var segments: [Segment] = []
        while pending.count >= Self.frameLength {
            if let segment = advanceFrame() { segments.append(segment) }
            pending.removeFirst(Self.hopLength)
            pendingStart += Self.hopLength
        }
        return segments
    }

    /// Closes any open segment at the end of the stream.
    mutating func flush() -> Segment? {
        defer { resetDetection() }
        guard inSpeech else { return nil }
        let segment = Segment(startSample: segmentStart, endSample: pendingStart + pending.count)
        return isLongEnough(segment) ? segment : nil
    }

    mutating func reset() {
        pending.removeAll()
        pendingStart = 0
        frameCount = 0
        bootstrapSum = 0
        noiseFloor = Self.floorRange.lowerBound
        resetDetection()
    }

    // MARK: - Private

    private mutating func resetDetection() {
        inSpeech = false
        segmentStart = 0
        lastSpeechEnd = 0
        silenceFrames = 0
    }

    private func isLongEnough(_ segment: Segment) -> Bool {
        segment.sampleCount / Self.hopLength >= Self.minimumSpeechFrames
    }

    private mutating func advanceFrame() -> Segment? {
        let frameStart = pendingStart
        let rms = Self.rootMeanSquare(pending, count: Self.frameLength)

        frameCount += 1
        if frameCount <= Self.bootstrapFrames {
            bootstrapSum += rms
            noiseFloor = clampFloor(bootstrapSum / Float(frameCount))
            return nil
        }
        if !inSpeech {
            // Drop quickly to a quieter room, creep up slowly against a louder one.
            noiseFloor = clampFloor(rms < noiseFloor
                ? noiseFloor * 0.9 + rms * 0.1
                : noiseFloor * 0.995 + rms * 0.005)
        }

        let enterThreshold = max(noiseFloor * 4, Self.floorRange.lowerBound)
        let exitThreshold = max(noiseFloor * 2, Self.floorRange.lowerBound * 0.6)
        let isSpeech = rms >= (inSpeech ? exitThreshold : enterThreshold)

        if !inSpeech {
            guard isSpeech else { return nil }
            inSpeech = true
            segmentStart = max(0, frameStart - Self.preRollFrames * Self.hopLength)
            lastSpeechEnd = frameStart + Self.frameLength
            silenceFrames = 0
            return nil
        }

        if isSpeech {
            lastSpeechEnd = frameStart + Self.frameLength
            silenceFrames = 0
        } else {
            silenceFrames += 1
        }

        let lengthFrames = (frameStart + Self.frameLength - segmentStart) / Self.hopLength
        guard silenceFrames >= Self.minimumSilenceFrames || lengthFrames >= Self.maximumSegmentFrames else {
            return nil
        }

        let end = min(lastSpeechEnd + Self.postRollFrames * Self.hopLength, frameStart + Self.frameLength)
        let segment = Segment(startSample: segmentStart, endSample: end)
        resetDetection()
        return isLongEnough(segment) ? segment : nil
    }

    private func clampFloor(_ value: Float) -> Float {
        min(max(value, Self.floorRange.lowerBound), Self.floorRange.upperBound)
    }

    private static func rootMeanSquare(_ samples: [Float], count: Int) -> Float {
        var sum: Float = 0
        for i in 0..<count {
            let v = samples[i]
            sum += v * v
        }
        return (sum / Float(count)).squareRoot()
    }
}
