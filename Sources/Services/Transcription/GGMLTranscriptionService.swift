import Foundation
import CAsrEngine

public final class GGMLTranscriptionService: @unchecked Sendable, TranscriptionService {
    public let serviceName: String
    public let modelId: String

    public var onProgress: ((Double) -> Void)?

    private nonisolated(unsafe) static weak var activeInstance: GGMLTranscriptionService?

    private let stateLock = NSLock()
    private var ctx: OpaquePointer?
    private var svHandle: UnsafeMutableRawPointer?
    private var isTranscribing = false
    private let modelsDir: URL
    private var unloadWorkItem: DispatchWorkItem?

    public init(modelId: String) {
        self.modelId = modelId
        self.serviceName = Self.nameForModel(modelId)
        modelsDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("VoiceGum/Models")
    }

    private static func nameForModel(_ modelId: String) -> String {
        if modelId.hasPrefix("qwen") { return "Qwen3-ASR" }
        if modelId.hasPrefix("sense-voice") { return "SenseVoice" }
        return "GGML-ASR"
    }

    private var isQwenModel: Bool { modelId.hasPrefix("qwen") }
    private var isSenseVoiceModel: Bool { modelId.hasPrefix("sense-voice") }

    public static func invalidateActiveModel() {
        activeInstance?.unload()
        activeInstance = nil
    }

    public func loadModel() throws {
        cancelUnloadTimer()
        let modelDir = modelsDir.appendingPathComponent(modelId)

        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw TranscriptionError.modelNotFound("模型目录不存在: \(modelDir.path)")
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []

        if isQwenModel {
            let decoderFiles = contents.filter { $0.hasSuffix(".gguf") && !$0.contains("mmproj") }
            let mmprojFiles  = contents.filter { $0.hasSuffix(".gguf") && $0.contains("mmproj") }

            guard let decoderFile = decoderFiles.first,
                  let mmprojFile  = mmprojFiles.first else {
                throw TranscriptionError.modelNotFound(
                    "需要 decoder + mmproj 两个 GGUF 文件, 找到: \(contents.joined(separator: ", "))")
            }

            let decoderPath = modelDir.appendingPathComponent(decoderFile).path
            let mmprojPath  = modelDir.appendingPathComponent(mmprojFile).path

            guard let c = asr_context_create(decoderPath, mmprojPath, 1) else {
                throw TranscriptionError.transcriptionFailed("加载 Qwen3-ASR 模型失败")
            }
            ctx = c
            Self.activeInstance = self
        } else if isSenseVoiceModel {
            let ggufFiles = contents.filter { $0.hasSuffix(".gguf") }
            guard let ggufFile = ggufFiles.first else {
                throw TranscriptionError.modelNotFound(
                    "需要 SenseVoice GGUF 文件, 找到: \(contents.joined(separator: ", "))")
            }

            let ggufPath = modelDir.appendingPathComponent(ggufFile).path
            guard let h = sv_load_model(ggufPath, 1) else {
                throw TranscriptionError.transcriptionFailed("加载 SenseVoice 模型失败")
            }
            svHandle = h
            Self.activeInstance = self
        } else {
            throw TranscriptionError.transcriptionFailed("不支持的模型: \(modelId)")
        }
    }

    public func transcribe(file: URL, language: String) async throws -> TranscriptionResult {
        if (isQwenModel && ctx == nil) || (isSenseVoiceModel && svHandle == nil) {
            try loadModel()
        }

        setTranscribing(true)
        defer { setTranscribing(false) }

        let isQwen = isQwenModel
        let engineName = serviceName

        await Logger.shared.info("\(engineName) 转写: model=\(modelId), file=\(file.lastPathComponent)")

        let wavFile = try await AudioConverter.convertTo16kHzWav(file)
        defer { try? FileManager.default.removeItem(at: wavFile) }

        let servicePtr = Unmanaged.passUnretained(self).toOpaque()

        let makeProgress: (@convention(c) (Float, UnsafeMutableRawPointer?) -> Void) = { pct, userdata in
            guard let ptr = userdata else { return }
            let svc = Unmanaged<GGMLTranscriptionService>.fromOpaque(ptr).takeUnretainedValue()
            DispatchQueue.main.async {
                svc.onProgress?(Double(pct))
            }
        }

        let text: String = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let result: UnsafeMutablePointer<CChar>?

                if isQwen {
                    guard let c = self.ctx else {
                        continuation.resume(throwing: TranscriptionError.transcriptionFailed("模型未加载"))
                        return
                    }
                    let prompt: String? = {
                        switch language {
                        case "zh-CN", "zh-TW": return "将音频转写为中文。"
                        case "en": return "Transcribe the audio to English."
                        case "ja": return "音声を日本語で文字起こししてください。"
                        default: return nil
                        }
                    }()
                    result = asr_transcribe_file(c, wavFile.path, prompt, makeProgress, servicePtr)
                } else if self.isSenseVoiceModel {
                    guard let h = self.svHandle else {
                        continuation.resume(throwing: TranscriptionError.transcriptionFailed("模型未加载"))
                        return
                    }
                    let langCode: String = {
                        switch language {
                        case "zh-CN", "zh-TW": return "zh"
                        case "en": return "en"
                        case "ja": return "ja"
                        case "ko": return "ko"
                        default: return "auto"
                        }
                    }()
                    result = sv_transcribe(h, wavFile.path, langCode, Int32(ProcessInfo.processInfo.activeProcessorCount), makeProgress, servicePtr)
                } else {
                    continuation.resume(throwing: TranscriptionError.transcriptionFailed("不支持的模型: \(self.modelId)"))
                    return
                }

                guard let r = result else {
                    continuation.resume(throwing: TranscriptionError.transcriptionFailed("\(engineName) 转写返回空"))
                    return
                }
                let t = String(cString: r)
                free(r)
                continuation.resume(returning: t)
            }
        }

        await Logger.shared.info("\(engineName) 完成: \(text.prefix(100))...")
        return TranscriptionResult(text: text, timestamps: nil, language: language, confidence: nil)
    }

    public func unload() {
        cancelUnloadTimer()
        if let ctx = ctx {
            asr_context_free(ctx)
            self.ctx = nil
        }
        if let h = svHandle {
            sv_free(h)
            self.svHandle = nil
        }
    }

    public func scheduleUnload(after seconds: TimeInterval = 5) {
        cancelUnloadTimer()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            if self.isTranscribing { return }
            self.unload()
        }
        unloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    private func cancelUnloadTimer() {
        unloadWorkItem?.cancel()
        unloadWorkItem = nil
    }

    private func setTranscribing(_ active: Bool) {
        stateLock.lock()
        isTranscribing = active
        stateLock.unlock()
        if active { cancelUnloadTimer() }
    }

    deinit {
        cancelUnloadTimer()
        unload()
        if Self.activeInstance === self {
            Self.activeInstance = nil
        }
    }
}
