import Foundation
import CFunASREngine

public final class FunASRTranscriptionService: @unchecked Sendable, TranscriptionService {
    public let serviceName = "FunASR (SenseVoice)"
    public let modelId: String

    public var onProgress: ((Double) -> Void)?

    private nonisolated(unsafe) static weak var activeInstance: FunASRTranscriptionService?

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
        guard let ggufFile = ggufFiles.first else {
            throw TranscriptionError.modelNotFound(
                "需要 SenseVoice GGUF 文件, 找到: \(contents.joined(separator: ", "))")
        }

        let ggufPath = modelDir.appendingPathComponent(ggufFile).path
        // Phase 1 CPU-only: use_gpu = 0
        guard let h = sv_load_model(ggufPath, 0) else {
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

        await Logger.shared.info("FunASR 转写: model=\(modelId), file=\(file.lastPathComponent)")

        let wavFile = try await AudioConverter.convertTo16kHzWav(file)
        defer { try? FileManager.default.removeItem(at: wavFile) }

        let servicePtr = Unmanaged.passUnretained(self).toOpaque()

        let makeProgress: (@convention(c) (Float, UnsafeMutableRawPointer?) -> Void) = { pct, userdata in
            guard let ptr = userdata else { return }
            let svc = Unmanaged<FunASRTranscriptionService>.fromOpaque(ptr).takeUnretainedValue()
            DispatchQueue.main.async {
                svc.onProgress?(Double(pct))
            }
        }

        let transcriptionResult: TranscriptionResult = try await withCheckedThrowingContinuation { continuation in
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

                let segResult = sv_transcribe_segments(h, wavFile.path, langCode, Int32(ProcessInfo.processInfo.activeProcessorCount), makeProgress, servicePtr)

                if segResult.count > 0, let segsPtr = segResult.segments {
                    let detectedLanguage = segResult.language.map { String(cString: $0) } ?? language
                    var segments: [SubtitleSegment] = []
                    var textParts: [String] = []
                    for i in 0..<Int(segResult.count) {
                        let cSeg = segsPtr[i]
                        let text = cSeg.text.map { String(cString: $0) } ?? ""
                        segments.append(SubtitleSegment(text: text, startMs: cSeg.t0_ms, endMs: cSeg.t1_ms, language: detectedLanguage))
                        textParts.append(text)
                    }
                    let combinedText = textParts.joined(separator: " ")
                    sv_free_result(segResult)
                    continuation.resume(returning: TranscriptionResult(text: combinedText, language: detectedLanguage, segments: segments))
                } else {
                    sv_free_result(segResult)
                    let result = sv_transcribe(h, wavFile.path, langCode, Int32(ProcessInfo.processInfo.activeProcessorCount), makeProgress, servicePtr)
                    guard let r = result else {
                        continuation.resume(throwing: TranscriptionError.transcriptionFailed("FunASR 转写返回空"))
                        return
                    }
                    let t = String(cString: r)
                    free(r)
                    continuation.resume(returning: TranscriptionResult(text: t, language: language))
                }
            }
        }

        await Logger.shared.info("FunASR 完成: \(transcriptionResult.text)")
        return transcriptionResult
    }

    public func unload() {
        cancelUnloadTimer()
        stateLock.lock()
        let h: UnsafeMutableRawPointer?
        if !isTranscribing {
            h = svHandle
            svHandle = nil
        } else {
            h = nil
        }
        stateLock.unlock()
        guard let h else { return }
        sv_free(h)
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
