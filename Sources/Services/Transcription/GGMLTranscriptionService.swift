import Foundation
import CAsrEngine

public final class GGMLTranscriptionService: @unchecked Sendable, TranscriptionService {
    public let serviceName = "SenseVoice"
    public let modelId: String

    public var onProgress: ((Double) -> Void)?

    private nonisolated(unsafe) static weak var activeInstance: GGMLTranscriptionService?
    private nonisolated(unsafe) static var isTerminating = false

    private let stateLock = NSLock()
    private var svHandle: UnsafeMutableRawPointer?
    private var isTranscribing = false
    private let modelsDir: URL
    private var unloadWorkItem: DispatchWorkItem?

    public init(modelId: String) {
        self.modelId = modelId
        modelsDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("VoiceGum/Models")
    }

    public static func invalidateActiveModel() {
        activeInstance?.unload()
        activeInstance = nil
    }

    /// Mark the process as terminating so subsequent unload() calls skip sv_free.
    /// The OS reclaims all memory (including GPU) on process exit.
    public static func prepareForTermination() {
        isTerminating = true
        activeInstance?.cancelUnloadTimer()
        activeInstance = nil
    }

    public func loadModel() throws {
        cancelUnloadTimer()
        let modelDir = modelsDir.appendingPathComponent(modelId)

        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw TranscriptionError.modelNotFound("模型目录不存在: \(modelDir.path)")
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
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
    }

    public func transcribe(file: URL, language: String) async throws -> TranscriptionResult {
        if svHandle == nil {
            try loadModel()
        }

        setTranscribing(true)
        defer { setTranscribing(false) }

        await Logger.shared.info("SenseVoice 转写: model=\(modelId), file=\(file.lastPathComponent)")

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

                let result = sv_transcribe(h, wavFile.path, langCode, Int32(ProcessInfo.processInfo.activeProcessorCount), makeProgress, servicePtr)

                guard let r = result else {
                    continuation.resume(throwing: TranscriptionError.transcriptionFailed("SenseVoice 转写返回空"))
                    return
                }
                let t = String(cString: r)
                free(r)
                continuation.resume(returning: t)
            }
        }

        await Logger.shared.info("SenseVoice 完成: \(text.prefix(100))...")
        return TranscriptionResult(text: text, timestamps: nil, language: language, confidence: nil)
    }

    public func unload() {
        cancelUnloadTimer()
        stateLock.lock()
        let isActive = isTranscribing
        stateLock.unlock()
        guard !isActive, let h = svHandle else { return }
        // During process termination skip sv_free — the OS reclaims all
        // resources. Calling ggml Metal cleanup during teardown can crash
        // on some hardware (e.g. Intel MacBook Air) where the GPU driver
        // behaves differently during process exit.
        if Self.isTerminating { return }
        sv_free(h)
        self.svHandle = nil
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

    func cancelUnloadTimer() {
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
