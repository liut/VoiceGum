import Foundation
import AVFoundation
import AppKit
import VoiceGumServices
import VoiceGumPreferences
import VoiceGumKeychain

@MainActor
final class TranscriptionViewModel: ObservableObject {
    @Published var state: TranscriptionState = .idle
    @Published var droppedFileURL: URL?
    @Published var statusMessage: String = ""
    @Published var summaryText: String?
    @Published var isSummarizing = false

    private var transcriptionService: TranscriptionService?
    private var currentTask: Task<Void, Never>?
    private var summarizeTask: Task<Void, Never>?
    private var lastHistoryEntryIds: [String] = []
    private var transcriptionDuration: TimeInterval?
    private var targetProgress: Double = 0
    private var displayTimer: Timer?
    private var transcriptionStartTime: Date?

    init() {
        setupLocalService()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenFile),
            name: .voiceGumOpenFile, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillTerminate),
            name: .voiceGumWillTerminate, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleWillTerminate(_ notification: Notification) {
        stopProgressTimer()
        currentTask?.cancel()
        summarizeTask?.cancel()
    }

    @objc private func handleOpenFile(_ notification: Notification) {
        guard let url = notification.object as? URL else { return }
        reset()
        droppedFileURL = url
    }

    private func setupLocalService() {
        guard AppPreferences.shared.asrProvider != "online" else { return }
        let savedId = AppPreferences.shared.asrModel
        // Validate the saved model is still in the catalog — prevents crash
        // when a removed model (e.g. Qwen3-ASR) lingers in UserDefaults
        guard let model = model(for: savedId) else {
            AppPreferences.shared.asrModel = "sense-voice-fp16"
            return
        }
        guard isModelDownloaded(model.id) else { return }
        let svc = GGMLTranscriptionService(modelId: model.id)
        try? svc.loadModel()
        transcriptionService = svc
    }

    private func setupTranscriptionService() async {
        let provider = AppPreferences.shared.asrProvider
        switch provider {
        case "online":
            let service = AppPreferences.shared.onlineASRService
            switch service {
            case "volcengine":
                let appId = AppPreferences.shared.volcAppId
                let token = AppPreferences.shared.volcAccessToken
                let resourceId = AppPreferences.shared.volcResourceId
                transcriptionService = VolcanoEngineASR(appId: appId, accessToken: token, resourceId: resourceId)
            default:
                let baseURL = URL(string: AppPreferences.shared.asrAPIURL) ?? URL(string: "https://api.openai.com/v1")!
                let apiKey = (try? await KeychainManager.shared.readASRAPIKey()).flatMap { $0.isEmpty ? nil : $0 }
                transcriptionService = OnlineAPITranscription(baseURL: baseURL, apiKey: apiKey, model: AppPreferences.shared.asrModel)
            }
        default:
            setupLocalService()
        }
    }

    private func isModelDownloaded(_ modelId: String) -> Bool {
        ModelDownloadManager.shared.isModelDownloaded(modelId)
    }

    private func engineDescription(for service: TranscriptionService) -> String {
        let serviceName = service.serviceName
        let provider = AppPreferences.shared.asrProvider
        switch provider {
        case "online":
            let onlineService = AppPreferences.shared.onlineASRService
            switch onlineService {
            case "volcengine": return "火山引擎 (流式识别)"
            default: return "OpenAI (Whisper)"
            }
        case "local":
            let modelId = AppPreferences.shared.asrModel
            if modelId.hasPrefix("sense-voice") { return "SenseVoice (\(modelId))" }
            else { return serviceName }
        default:
            return serviceName
        }
    }

    func startTranscription() {
        guard let fileURL = droppedFileURL else { return }

        currentTask = Task {
            // Re-setup service so freshly downloaded models are detected
            await setupTranscriptionService()
            do {
                state = .validating(file: fileURL)

                guard AudioFileValidator.isValid(file: fileURL) else {
                    let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                    let limit = AudioFileValidator.maxFileSize(for: fileURL)
                    if size > limit {
                        let mb = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                        let maxMB = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
                        state = .failed(error: TranscriptionError.transcriptionFailed("文件过大 (\(mb))，上限 \(maxMB)"))
                    } else {
                        state = .failed(error: TranscriptionError.invalidAudioFormat)
                    }
                    return
                }

                let files = [fileURL]
                state = .queued(files: files)

                let duration = await captureDuration(fileURL)

                var allResults: [TranscriptionResult] = []
                var engineDescs: [String] = []

                for (index, file) in files.enumerated() {
                    try Task.checkCancellation()
                    state = .preparing(ASR: transcriptionService?.serviceName ?? "ASR")

                    state = .transcribing(
                        progress: 0,
                        currentFile: index + 1,
                        totalFiles: files.count
                    )

                    guard let service = transcriptionService else {
                        stopProgressTimer()
                        let modelName = AppPreferences.shared.asrModel
                        state = .failed(error: TranscriptionError.transcriptionFailed(
                            "模型 \"\(modelName)\" 尚未下载。\n请前往设置 → ASR → 本地模型 下载后再试。"
                        ))
                        return
                    }

                    let engineDesc = engineDescription(for: service)

                    let ggmlService = transcriptionService as? GGMLTranscriptionService

                    // Start smooth progress timer for local ASR only
                    if ggmlService != nil, let dur = duration {
                        transcriptionDuration = dur
                        targetProgress = 0
                        transcriptionStartTime = Date()
                        startProgressTimer()
                    }

                    ggmlService?.onProgress = { [self] pct in
                        targetProgress = max(targetProgress, pct)
                        if pct >= 1.0 {
                            stopProgressTimer()
                            state = .transcribing(
                                progress: 1.0,
                                currentFile: index + 1,
                                totalFiles: files.count)
                        }
                    }

                    let result = try await service.transcribe(
                        file: file,
                        language: AppPreferences.shared.language
                    )

                    ggmlService?.onProgress = nil
                    stopProgressTimer()

                    allResults.append(result)
                    if engineDescs.isEmpty || engineDescs.count <= index {
                        engineDescs.append(engineDesc)
                    }
                }

                state = .transcribing(progress: 1.0, currentFile: files.count, totalFiles: files.count)

                // Schedule model unload to free memory after idle
                (transcriptionService as? GGMLTranscriptionService)?.scheduleUnload()

                // Save raw transcription to history first
                await saveToHistory(results: allResults, files: files, engineDescs: engineDescs, duration: duration)

                // Configure LLM once for all subsequent calls (refine + summarize)
                let llmConfigured = !AppPreferences.shared.llmBaseURL().isEmpty
                if llmConfigured { await configureLLMClient() }

                // Refine — hand off to a background task so the @MainActor task ends here.
                // Keeping the @MainActor task alive across the LLM call causes macOS
                // to flag the process as "not responding" during long API requests.
                if AppPreferences.shared.autoRefineEnabled && llmConfigured {
                    try? await Task.sleep(nanoseconds: 500_000_000)

                    state = .refining

                    let capturedResults = allResults
                    let capturedFiles = files
                    let capturedEngineDescs = engineDescs
                    let capturedEntryIds = lastHistoryEntryIds
                    let capturedSummaryEnabled = AppPreferences.shared.autoSummaryEnabled

                    Task.detached(priority: .userInitiated) { [weak self] in
                        guard let self else { return }
                        do {
                            var refined: [TranscriptionResult] = []
                            for (index, result) in capturedResults.enumerated() {
                                let prompt = AppPreferences.shared.refinePrompt
                                let text = try await LLMClient.shared.refine(
                                    text: result.text,
                                    customPrompt: prompt.isEmpty ? nil : prompt)
                                refined.append(TranscriptionResult(
                                    text: text,
                                    timestamps: result.timestamps,
                                    language: result.language,
                                    confidence: result.confidence))
                                let id = capturedEntryIds.indices.contains(index) ? capturedEntryIds[index] : nil
                                if let id {
                                    await HistoryManager.shared.updateRefinedText(id: id, refinedText: text)
                                }
                            }
                            await MainActor.run { [weak self] in
                                self?.state = .completed(results: refined, files: capturedFiles)
                                self?.saveResults(refined, files: capturedFiles, engineDescs: capturedEngineDescs)
                                if capturedSummaryEnabled { self?.summarize() }
                            }
                        } catch {
                            await MainActor.run { [weak self] in
                                self?.state = .failed(error: error)
                            }
                        }
                    }
                    // @MainActor task ends here — main RunLoop stays free
                    return
                }

                state = .completed(results: allResults, files: files)
                saveResults(allResults, files: files, engineDescs: engineDescs)

                if AppPreferences.shared.autoSummaryEnabled && llmConfigured { summarize() }

            } catch {
                stopProgressTimer()
                if Task.isCancelled {
                    state = .cancelled
                } else {
                    state = .failed(error: error)
                }
            }
        }
    }

    func cancelTranscription() {
        stopProgressTimer()
        currentTask?.cancel()
        state = .cancelled
    }

    func retryLastTranscription() {
        reset()
        startTranscription()
    }

    func reset() {
        stopProgressTimer()
        droppedFileURL = nil
        state = .idle
        summaryText = nil
    }

    func summarize() {
        guard case .completed(let results, _) = state, !isSummarizing else { return }
        let provider = AppPreferences.shared.llmProvider
        let baseURL = AppPreferences.shared.llmBaseURL()
        guard !baseURL.isEmpty else {
            summaryText = "摘要失败: Base URL 为空 provider=\(provider)"
            return
        }

        let textToSummarize = results.map { $0.text }.joined(separator: "\n\n")
        guard !textToSummarize.isEmpty else { return }

        isSummarizing = true
        summaryText = nil

        summarizeTask = Task {
            do {
                let prompt = AppPreferences.shared.summaryPrompt
                let result = try await Task.detached(priority: .userInitiated) {
                    try await LLMClient.shared.summarize(text: textToSummarize, customPrompt: prompt.isEmpty ? nil : prompt)
                }.value
                summaryText = result
                if let id = lastHistoryEntryIds.first {
                    await HistoryManager.shared.updateSummary(id: id, summaryText: result)
                }
            } catch {
                summaryText = "摘要失败: \(error.localizedDescription)"
            }
            isSummarizing = false
        }
    }

    func copyToClipboard() {
        if case .completed(let results, _) = state {
            let text = results.map { $0.text }.joined(separator: "\n\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func saveResults(_ results: [TranscriptionResult], files: [URL], engineDescs: [String]) {
        let resultDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("VoiceGum/Result")
        try? FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = dateFormatter.string(from: Date())

        for (index, result) in results.enumerated() {
            let fileName = files.indices.contains(index)
                ? files[index].deletingPathExtension().lastPathComponent
                : "unknown"
            let outputFile = resultDir.appendingPathComponent("\(timestamp)_\(fileName).txt")

            let engineInfo = engineDescs.indices.contains(index) ? engineDescs[index] : ""

            let header = """
            VoiceGum 转写结果
            引擎: \(engineInfo)
            时间: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))
            文件: \(files.indices.contains(index) ? files[index].lastPathComponent : "unknown")
            语言: \(result.language ?? "auto")
            置信度: \(result.confidence.map { String(format: "%.2f", $0) } ?? "N/A")
            ---

            """
            try? (header + result.text).write(to: outputFile, atomically: true, encoding: .utf8)
        }
    }

    private func saveToHistory(results: [TranscriptionResult], files: [URL], engineDescs: [String], duration: TimeInterval?) async {
        lastHistoryEntryIds = []
        for (index, result) in results.enumerated() {
            let fileName = files.indices.contains(index)
                ? files[index].lastPathComponent
                : "unknown"
            let engineDesc = engineDescs.indices.contains(index) ? engineDescs[index] : ""
            let entry = HistoryEntry(
                sourceFileName: fileName,
                timestamp: Date(),
                engineDescription: engineDesc,
                language: result.language,
                duration: duration,
                rawText: result.text
            )
            lastHistoryEntryIds.append(entry.id)
            await HistoryManager.shared.add(entry)
        }
    }

    private func configureLLMClient() async {
        guard let baseURL = URL(string: AppPreferences.shared.llmBaseURL()) else { return }
        let provider: LLMProvider = switch AppPreferences.shared.llmProvider {
        case "anthropic": .anthropic
        case "ollama": .ollama
        default: .openai
        }
        let apiKey = AppPreferences.shared.llmAPIKey()
        await LLMClient.shared.configure(provider: provider, baseURL: baseURL, apiKey: apiKey.isEmpty ? nil : apiKey, model: AppPreferences.shared.llmModel())
    }

    private func captureDuration(_ fileURL: URL) async -> TimeInterval? {
        let asset = AVAsset(url: fileURL)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite && seconds > 0 ? seconds : nil
        } catch {
            return nil
        }
    }

    private func startProgressTimer() {
        stopProgressTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickProgress()
            }
        }
    }

    private func stopProgressTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func tickProgress() {
        guard let start = transcriptionStartTime,
              let duration = transcriptionDuration,
              duration > 0 else { return }

        let elapsed = Date().timeIntervalSince(start)
        let estimatedTotal = max(duration * 0.05, 1.0)
        let elapsedRatio = min(elapsed / estimatedTotal, 0.99)

        guard case .transcribing(let current, let file, let total) = state else { return }

        let step = 0.02
        let smoothed = max(current + step, elapsedRatio)
        let displayProgress = min(smoothed, targetProgress + 0.03, 0.99)

        if displayProgress > current {
            state = .transcribing(progress: displayProgress, currentFile: file, totalFiles: total)
        }
    }

}