import Foundation
import CFunASREngine

public final class FunASRNanoTranscriptionService: @unchecked Sendable, TranscriptionService {
    public let serviceName = "FunASR-Nano"
    public let modelId: String

    public var onProgress: ((Double) -> Void)?

    private nonisolated(unsafe) static weak var activeInstance: FunASRNanoTranscriptionService?

    private let stateLock = NSLock()
    private var nanoHandle: UnsafeMutableRawPointer?
    private var isTranscribing = false
    private let modelsDir: URL
    private var unloadWorkItem: DispatchWorkItem?

    public init(modelId: String) {
        self.modelId = modelId
        modelsDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("VoiceGum/Models")
    }

    public static var isTranscribingActive: Bool {
        guard let instance = activeInstance else { return false }
        return instance.syncIsTranscribing
    }

    public static func invalidateActiveModel() {
        activeInstance?.unload()
        activeInstance = nil
    }

    public static func waitForTranscriptionCompletion(timeout: TimeInterval) async -> Bool {
        guard let instance = activeInstance else { return true }
        let deadline = ContinuousClock.now + .seconds(timeout)
        while instance.syncIsTranscribing {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    private var syncIsTranscribing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isTranscribing
    }

    public func loadModel() throws {
        cancelUnloadTimer()
        let modelDir = modelsDir.appendingPathComponent(modelId)

        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw TranscriptionError.modelNotFound("模型目录不存在: \(modelDir.path)")
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
        let ggufFiles = contents.filter { $0.hasSuffix(".gguf") }

        // Nano needs two GGUF files: encoder + decoder (LLM)
        let encFile = ggufFiles.first { $0.lowercased().contains("encoder") }
        let decFile = ggufFiles.first { $0.lowercased().contains("decoder") }

        guard let enc = encFile, let dec = decFile else {
            throw TranscriptionError.modelNotFound(
                "需要 encoder + decoder 两个 GGUF 文件, 找到: \(contents.joined(separator: ", "))")
        }

        let encPath = modelDir.appendingPathComponent(enc).path
        let decPath = modelDir.appendingPathComponent(dec).path
        let nThreads = Int32(ProcessInfo.processInfo.activeProcessorCount)

        guard let h = nano_load_model(encPath, decPath, nThreads) else {
            throw TranscriptionError.transcriptionFailed("加载 FunASR-Nano 模型失败")
        }
        nanoHandle = h
        Self.activeInstance = self
    }

    public func transcribe(file: URL, language: String) async throws -> TranscriptionResult {
        if nanoHandle == nil {
            try loadModel()
        }

        setTranscribing(true)
        defer { setTranscribing(false) }

        await Logger.shared.info("FunASR-Nano 转写: model=\(modelId), file=\(file.lastPathComponent)")

        let wavFile = try await AudioConverter.convertTo16kHzWav(file)
        defer { try? FileManager.default.removeItem(at: wavFile) }

        let transcriptionResult: TranscriptionResult = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                guard let h = self.nanoHandle else {
                    continuation.resume(throwing: TranscriptionError.transcriptionFailed("模型未加载"))
                    return
                }
                let nThreads = Int32(ProcessInfo.processInfo.activeProcessorCount)
                guard let cText = nano_transcribe(h, wavFile.path, nThreads) else {
                    continuation.resume(throwing: TranscriptionError.transcriptionFailed("FunASR-Nano 转写返回空"))
                    return
                }
                let text = String(cString: cText)
                free(cText)
                continuation.resume(returning: TranscriptionResult(text: text, language: language))
            }
        }

        await Logger.shared.info("FunASR-Nano 完成: \(transcriptionResult.text)")
        return transcriptionResult
    }

    public func unload() {
        cancelUnloadTimer()
        stateLock.lock()
        let isActive = isTranscribing
        let h: UnsafeMutableRawPointer?
        if !isActive {
            h = nanoHandle
            nanoHandle = nil
        } else {
            h = nil
        }
        stateLock.unlock()
        guard let h else { return }
        nano_free(h)
    }

    public func scheduleUnload(after seconds: TimeInterval = 5) {
        cancelUnloadTimer()
        let workItem = DispatchWorkItem { [weak self] in
            self?.unload()
        }
        unloadWorkItem = workItem
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: workItem)
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
