import Foundation
import CQwenASR

public final class QwenASRService: @unchecked Sendable, TranscriptionService {
    public let serviceName = "Qwen3-ASR"
    public let modelSize: QwenASRModelSize

    public enum QwenASRModelSize: String, CaseIterable, Sendable {
        case small = "0.6B"
        case large = "1.7B"
        var displayName: String { rawValue }
        var hfRepo: String {
            switch self {
            case .small: return "Qwen/Qwen3-ASR-0.6B"
            case .large: return "Qwen/Qwen3-ASR-1.7B"
            }
        }
    }

    private var ctx: UnsafeMutablePointer<qwen_ctx_t>?

    public init(modelSize: QwenASRModelSize) {
        self.modelSize = modelSize
    }

    public func loadModel() throws {
        let modelDir = modelsDirectory.appendingPathComponent("qwen3-asr-\(modelSize.rawValue.lowercased())")
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw TranscriptionError.transcriptionFailed("Qwen3-ASR 模型未下载: \(modelDir.path)")
        }
        guard let c = qwen_load(modelDir.path) else {
            throw TranscriptionError.transcriptionFailed("加载 Qwen3-ASR 模型失败")
        }
        ctx = c
    }

    public func transcribe(file: URL, language: String) async throws -> TranscriptionResult {
        guard let ctx = ctx else {
            try loadModel()
            return try await transcribe(file: file, language: language)
        }

        await Logger.shared.info("Qwen3-ASR 转写: file=\(file.lastPathComponent), lang=\(language)")

        // Convert to 16kHz WAV if needed
        let wavFile = try await AudioConverter.convertTo16kHzWav(file)

        // Set language
        let langStr = qwenLangCode(language)
        if !langStr.isEmpty {
            qwen_set_force_language(ctx, langStr)
        }

        // Transcribe (blocking call on a background thread)
        let ctxPtr = ctx
        let text: String = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                guard let result = qwen_transcribe(ctxPtr, wavFile.path) else {
                    continuation.resume(throwing: TranscriptionError.transcriptionFailed("Qwen3-ASR 转写返回空"))
                    return
                }
                let text = String(cString: result).trimmingCharacters(in: .whitespacesAndNewlines)
                free(result)
                continuation.resume(returning: text)
            }
        }

        await Logger.shared.info("Qwen3-ASR 转写完成: \(text.prefix(100))...")
        return TranscriptionResult(text: text, timestamps: nil, language: language, confidence: nil)
    }

    public func unload() {
        if let ctx = ctx {
            qwen_free(ctx)
            self.ctx = nil
        }
    }

    deinit {
        unload()
    }

    // MARK: - Helpers

    private var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("VoiceGum/Models")
    }

    private func qwenLangCode(_ lang: String) -> String {
        switch lang {
        case "zh-CN", "zh-TW": return "Chinese"
        case "en": return "English"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        default: return ""
        }
    }
}
