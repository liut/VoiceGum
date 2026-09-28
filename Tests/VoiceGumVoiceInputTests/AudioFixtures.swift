@preconcurrency import AVFoundation
@testable import VoiceGumVoiceInput

/// Deterministic audio fixtures shared by the live-preview tests.
enum AudioFixtures {

    static let sampleRate = StreamingSegmenter.sampleRate

    /// 220 Hz sine at the given amplitude (RMS = amplitude / √2).
    static func speech(seconds: Double, amplitude: Float = 0.5, sampleRate: Int = AudioFixtures.sampleRate) -> [Float] {
        let count = Int(seconds * Double(sampleRate))
        return (0..<count).map { i in
            amplitude * Float(sin(2 * Double.pi * 220 * Double(i) / Double(sampleRate)))
        }
    }

    static func silence(seconds: Double, sampleRate: Int = AudioFixtures.sampleRate) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
    }

    /// Deterministic uniform noise with the requested RMS.
    static func noise(seconds: Double, rms: Float, sampleRate: Int = AudioFixtures.sampleRate) -> [Float] {
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        let peak = rms * Float(3.0).squareRoot()
        return (0..<Int(seconds * Double(sampleRate))).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float((state >> 40) & 0xFF_FFFF) / Float(0xFF_FFFF)
            return (unit * 2 - 1) * peak
        }
    }

    static func buffer(_ samples: [Float], sampleRate: Double = Double(AudioFixtures.sampleRate)) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
