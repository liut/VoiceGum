import Foundation
import AVFoundation

public enum AudioConverter {
    public static func convertTo16kHzWav(_ file: URL) async throws -> URL {
        await Logger.shared.info("转换音频格式: \(file.pathExtension.lowercased()) → wav")

        let asset = AVAsset(url: file)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw TranscriptionError.invalidAudioFormat
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw TranscriptionError.invalidAudioFormat
        }
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw TranscriptionError.transcriptionFailed("无法读取音频")
        }

        var samples = Data()
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            guard let blockBuffer = sampleBuffer.dataBuffer else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &dataPointer)
            if let ptr = dataPointer {
                samples.append(UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: length)
            }
        }

        guard reader.status == .completed else {
            throw TranscriptionError.transcriptionFailed("音频读取不完整")
        }

        let normalized = normalizeVolume(samples)
        let wavFile = FileManager.default.temporaryDirectory.appendingPathComponent("voicegum_\(UUID().uuidString).wav")
        try writeWAVFile(normalized, to: wavFile)

        await Logger.shared.info("转换完成: \(wavFile.path) (\(samples.count) bytes PCM)")
        return wavFile
    }

    // MARK: - Private helpers

    private static func writeWAVFile(_ pcmData: Data, to url: URL) throws {
        let sampleRate: UInt32 = 16000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)

        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        var riffSize = UInt32(36 + pcmData.count).littleEndian
        wav.append(Data(bytes: &riffSize, count: 4))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        var fmtSize = UInt32(16).littleEndian
        wav.append(Data(bytes: &fmtSize, count: 4))
        var formatTag = UInt16(1).littleEndian
        wav.append(Data(bytes: &formatTag, count: 2))
        var channels = numChannels.littleEndian
        wav.append(Data(bytes: &channels, count: 2))
        var sr = sampleRate.littleEndian
        wav.append(Data(bytes: &sr, count: 4))
        var br = byteRate.littleEndian
        wav.append(Data(bytes: &br, count: 4))
        var ba = blockAlign.littleEndian
        wav.append(Data(bytes: &ba, count: 2))
        var bps = bitsPerSample.littleEndian
        wav.append(Data(bytes: &bps, count: 2))
        wav.append("data".data(using: .ascii)!)
        var ds = dataSize.littleEndian
        wav.append(Data(bytes: &ds, count: 4))
        wav.append(pcmData)

        try wav.write(to: url)
    }

    private static func normalizeVolume(_ pcm: Data) -> Data {
        let samples = pcm.count / 2
        guard samples > 0 else { return pcm }

        var sumSq: Double = 0
        pcm.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let int16 = ptr.bindMemory(to: Int16.self)
            for i in 0..<samples {
                let s = Double(int16[i])
                sumSq += s * s
            }
        }
        let rms = sqrt(sumSq / Double(samples))

        let targetRMS: Double = 7000
        let maxGain: Double = 8.0
        let gain = rms > 0 ? min(targetRMS / rms, maxGain) : 1.0
        guard gain > 1.05 else { return pcm }

        var result = Data(capacity: pcm.count)
        pcm.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let int16 = ptr.bindMemory(to: Int16.self)
            for i in 0..<samples {
                let v = Double(int16[i]) * gain
                let clamped = max(Double(Int16.min), min(Double(Int16.max), v))
                var s = Int16(clamped)
                result.append(Data(bytes: &s, count: 2))
            }
        }
        return result
    }
}
