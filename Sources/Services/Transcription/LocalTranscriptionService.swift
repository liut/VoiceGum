import Foundation
import AVFoundation

public struct LocalTranscriptionService: TranscriptionService {
    public let serviceName = "SenseVoice"
    public let modelId: String

    private let modelsBaseDir: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("VoiceGum/Models")
    }()

    private func findSenseVoiceBinDir() -> URL? {
        // Check main bundle Resources (for app bundle)
        if let resourceURL = Bundle.main.resourceURL {
            let direct = resourceURL.appendingPathComponent("sense-voice")
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
            let nested = resourceURL.appendingPathComponent("VoiceGum_VoiceGum.bundle/sense-voice")
            if FileManager.default.fileExists(atPath: nested.path) {
                return nested
            }
        }

        // SPM build dir: bundle next to executable
        let exeDir = Bundle.main.bundleURL
        let spmBundle = exeDir.appendingPathComponent("VoiceGum_VoiceGum.bundle/sense-voice")
        if FileManager.default.fileExists(atPath: spmBundle.path) {
            return spmBundle
        }

        // Check all loaded bundles
        for bundle in Bundle.allBundles {
            if let p = bundle.resourceURL?.appendingPathComponent("sense-voice"),
               FileManager.default.fileExists(atPath: p.path) {
                return p
            }
        }

        return nil
    }

    public init(modelId: String) {
        self.modelId = modelId
    }

    public func transcribe(file: URL, language: String) async throws -> TranscriptionResult {
        let modelDir = modelsBaseDir.appendingPathComponent(modelId)

        await Logger.shared.info("本地转写: modelId=\(modelId), file=\(file.lastPathComponent), lang=\(language)")
        await Logger.shared.debug("模型目录: \(modelDir.path)")

        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            await Logger.shared.error("模型目录不存在: \(modelDir.path)")
            throw TranscriptionError.transcriptionFailed("模型目录不存在: \(modelDir.path)")
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
        await Logger.shared.debug("模型目录内容: \(contents.joined(separator: ", "))")

        guard let ggufFile = contents.first(where: { $0.hasSuffix(".gguf") }) else {
            await Logger.shared.error("未找到 .gguf: \(modelDir.path) 内容=\(contents)")
            throw TranscriptionError.transcriptionFailed("模型目录中未找到 .gguf 文件")
        }
        let modelPath = modelDir.appendingPathComponent(ggufFile)
        await Logger.shared.info("模型文件: \(modelPath.path)")

        guard let binDir = findSenseVoiceBinDir() else {
            await Logger.shared.error("""
            转写引擎未找到!
              Bundle.main.resourceURL: \(Bundle.main.resourceURL?.path ?? "nil")
              allBundles: \(Bundle.allBundles.map { $0.resourceURL?.path ?? "nil" })
            """)
            throw TranscriptionError.transcriptionFailed("转写引擎未找到，请重新安装应用")
        }

        let binary = binDir.appendingPathComponent("bin/sense-voice-main")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            await Logger.shared.error("二进制不存在: \(binary.path), binDir=\(binDir.path)")
            throw TranscriptionError.transcriptionFailed("转写引擎未找到: \(binary.path)")
        }

        await Logger.shared.info("引擎路径: \(binary.path)")

        // Convert to 16kHz WAV if needed
        let wavFile = try await convertToWavIfNeeded(file)

        // FP32 too large for GPU; flash-attn degrades quality on Small model (4 heads)
        let useGPU = !modelId.contains("fp32")
        var args = [
            "-m", modelPath.path,
            "-l", langCode(language),
            "-t", "4",
            "-bs", "8",
            "-bo", "8",
            "-tp", "0.0",
            "-itn",
            "-np",
        ]
        if !useGPU { args.append("-ng") }
        args.append(wavFile.path)
        await Logger.shared.debug("启动进程: \(binary.lastPathComponent) \(args.dropFirst().joined(separator: " "))")

        let process = Process()
        process.executableURL = binary
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()

                let output = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errOutput = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                if process.terminationStatus != 0 {
                    let msg = "转写失败 (exit \(process.terminationStatus)): \(errOutput)"
                    Task { await Logger.shared.error(msg) }
                    continuation.resume(throwing: TranscriptionError.transcriptionFailed(msg))
                    return
                }

                let text = output
                    .components(separatedBy: "\n")
                    .map { line -> String in
                        var content = line
                        // Strip timestamp prefix [mm:ss-ss]
                        if let bracketEnd = line.range(of: "] ") {
                            content = String(line[bracketEnd.upperBound...])
                        }
                        // Strip special tokens: <|lang|>, <|EMO_*|>, <|Speech|>, <|withitn|>, etc.
                        let tokenPattern = try? NSRegularExpression(pattern: "<\\|[^|]+\\|>")
                        let range = NSRange(content.startIndex..., in: content)
                        content = tokenPattern?.stringByReplacingMatches(in: content, range: range, withTemplate: "") ?? content
                        return content.trimmingCharacters(in: .whitespaces)
                    }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if text.isEmpty {
                    let msg = "转写无输出, stderr: \(errOutput.prefix(200))"
                    Task { await Logger.shared.error(msg) }
                    continuation.resume(throwing: TranscriptionError.transcriptionFailed(msg))
                    return
                }

                Task { await Logger.shared.info("转写完成: \(text.prefix(100))...") }
                continuation.resume(returning: TranscriptionResult(
                    text: text,
                    timestamps: nil,
                    language: language,
                    confidence: nil
                ))
            }
        }
    }

    func convertToWavIfNeeded(_ file: URL) async throws -> URL {
        let ext = file.pathExtension.lowercased()

        // Always go through normalize path so VAD can detect soft speech
        guard ext != "wav" else {
            return try await normalizeWavVolume(file)
        }

        await Logger.shared.info("转换音频格式: \(ext) → wav")

        // Read with AVAssetReader, write raw PCM to WAV file
        let asset = AVAsset(url: file)

        // Use async loading API
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw TranscriptionError.invalidAudioFormat
        }

        // Use AVAssetReader to decode to PCM
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

        let wavFile = FileManager.default.temporaryDirectory.appendingPathComponent("voicegum_\(UUID().uuidString).wav")

        // Write as 16kHz 16-bit mono WAV
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

        // Normalize volume so VAD can detect soft speech
        let normalized = normalizeVolume(samples)
        try writeWAVFile(normalized, to: wavFile)

        await Logger.shared.info("转换完成: \(wavFile.path) (\(samples.count) bytes PCM)")
        return wavFile
    }

    private func writeWAVFile(_ pcmData: Data, to url: URL) throws {
        let sampleRate: UInt32 = 16000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)

        var wav = Data()
        // RIFF header
        wav.append("RIFF".data(using: .ascii)!)
        var riffSize = UInt32(36 + pcmData.count).littleEndian
        wav.append(Data(bytes: &riffSize, count: 4))
        wav.append("WAVE".data(using: .ascii)!)
        // fmt chunk
        wav.append("fmt ".data(using: .ascii)!)
        var fmtSize = UInt32(16).littleEndian
        wav.append(Data(bytes: &fmtSize, count: 4))
        var formatTag = UInt16(1).littleEndian  // PCM
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
        // data chunk
        wav.append("data".data(using: .ascii)!)
        var ds = dataSize.littleEndian
        wav.append(Data(bytes: &ds, count: 4))
        // PCM data
        wav.append(pcmData)

        try wav.write(to: url)
    }

    // RMS-based volume normalization so ggml's energy VAD can detect soft speech
    private func normalizeVolume(_ pcm: Data) -> Data {
        let samples = pcm.count / 2
        guard samples > 0 else { return pcm }

        // Calculate RMS
        var sumSq: Double = 0
        var peak: Int16 = 0
        pcm.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let int16 = ptr.bindMemory(to: Int16.self)
            for i in 0..<samples {
                let s = int16[i]
                sumSq += Double(s) * Double(s)
                peak = max(peak, abs(s))
            }
        }
        let rms = sqrt(sumSq / Double(samples))

        // Target RMS so ggml's energy-based VAD can detect soft/fast speech
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

    private func normalizeWavVolume(_ file: URL) async throws -> URL {
        let data = try Data(contentsOf: file)
        // Skip 44-byte WAV header to get raw PCM
        guard data.count > 44 else { return file }
        let pcm = data.subdata(in: 44..<data.count)
        let normalized = normalizeVolume(pcm)
        guard normalized != pcm else { return file }
        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("voicegum_\(UUID().uuidString).wav")
        try writeWAVFile(normalized, to: outFile)
        return outFile
    }

    private func langCode(_ lang: String) -> String {
        switch lang {
        case "zh-CN", "zh-TW": return "zh"
        case "yue": return "yue"
        case "ja": return "ja"
        case "ko": return "ko"
        case "en": return "en"
        default: return "zh"
        }
    }
}
