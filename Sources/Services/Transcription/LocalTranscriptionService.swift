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
        let wavFile = try await AudioConverter.convertTo16kHzWav(file)

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
                    let cmd = "sense-voice-main \(args.dropFirst().joined(separator: " "))"
                    let msg = """
                    转写无输出 — VAD 未检测到语音段
                    建议: 尝试 FP16/Q8_0 模型，或音频超过60秒建议换用 Qwen3-ASR
                    命令行: \(cmd)
                    stderr: \(errOutput)
                    """
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
