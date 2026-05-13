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

    init() {
        setupLocalService()
    }

    private func setupLocalService() {
        guard AppPreferences.shared.asrProvider != "online" else { return }
        guard isModelDownloaded(AppPreferences.shared.asrModel) else { return }
        let modelId = AppPreferences.shared.asrModel
        if modelId.hasPrefix("qwen3") {
            let size: QwenASRService.QwenASRModelSize = modelId.contains("1.7b") ? .large : .small
            let svc = QwenASRService(modelSize: size)
            try? svc.loadModel()
            transcriptionService = svc
        } else {
            transcriptionService = LocalTranscriptionService(modelId: modelId)
        }
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
            if modelId.hasPrefix("qwen3") { return "Qwen3-ASR (\(modelId))" }
            else { return "SenseVoice (\(modelId))" }
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
                    if size > AudioFileValidator.maxFileSize {
                        let mb = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                        let maxMB = ByteCountFormatter.string(fromByteCount: AudioFileValidator.maxFileSize, countStyle: .file)
                        state = .failed(error: TranscriptionError.transcriptionFailed("文件过大 (\(mb))，上限 \(maxMB)"))
                    } else {
                        state = .failed(error: TranscriptionError.invalidAudioFormat)
                    }
                    return
                }

                let files = [fileURL]
                state = .queued(files: files)

                var allResults: [TranscriptionResult] = []
                var engineDescs: [String] = []

                for (index, file) in files.enumerated() {
                    state = .preparing(ASR: transcriptionService?.serviceName ?? "ASR")

                    let isLocalService = transcriptionService is LocalTranscriptionService

                    state = .transcribing(
                        progress: isLocalService ? -1 : Double(index) / Double(files.count),
                        currentFile: index + 1,
                        totalFiles: files.count
                    )

                    guard let service = transcriptionService else {
                        let modelName = AppPreferences.shared.asrModel
                        state = .failed(error: TranscriptionError.transcriptionFailed(
                            "模型 \"\(modelName)\" 尚未下载。\n请前往设置 → ASR → 本地模型 下载后再试。"
                        ))
                        return
                    }

                    let engineDesc = engineDescription(for: service)

                    let result = try await service.transcribe(
                        file: file,
                        language: AppPreferences.shared.language
                    )

                    allResults.append(result)
                    if engineDescs.isEmpty || engineDescs.count <= index {
                        engineDescs.append(engineDesc)
                    }
                }

                state = .transcribing(progress: 1.0, currentFile: files.count, totalFiles: files.count)

                // Check if LLM refinement is needed
                if AppPreferences.shared.llmEnabled && !AppPreferences.shared.llmBaseURL().isEmpty {
                    // Trigger refinement after a short delay to show completion first
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

                    state = .refining

                    var refinedResults: [TranscriptionResult] = []
                    for result in allResults {
                        let prompt = AppPreferences.shared.refinePrompt
                    let refinedText = try await LLMClient.shared.refine(text: result.text, customPrompt: prompt.isEmpty ? nil : prompt)
                        refinedResults.append(TranscriptionResult(
                            text: refinedText,
                            timestamps: result.timestamps,
                            language: result.language,
                            confidence: result.confidence
                        ))
                    }

                    state = .completed(results: refinedResults, files: files)
                    saveResults(refinedResults, files: files, engineDescs: engineDescs)
                } else {
                    state = .completed(results: allResults, files: files)
                    saveResults(allResults, files: files, engineDescs: engineDescs)
                }

            } catch {
                if Task.isCancelled {
                    state = .cancelled
                } else {
                    state = .failed(error: error)
                }
            }
        }
    }

    func cancelTranscription() {
        currentTask?.cancel()
        currentTask = nil
    }

    func retryLastTranscription() {
        reset()
        startTranscription()
    }

    func reset() {
        droppedFileURL = nil
        state = .idle
        summaryText = nil
    }

    func summarize() {
        guard case .completed(let results, _) = state, !isSummarizing else { return }
        guard AppPreferences.shared.llmEnabled && !AppPreferences.shared.llmBaseURL().isEmpty else { return }

        let textToSummarize = results.map { $0.text }.joined(separator: "\n\n")
        guard !textToSummarize.isEmpty else { return }

        isSummarizing = true
        summaryText = nil

        Task {
            do {
                let prompt = AppPreferences.shared.summaryPrompt
                let result = try await LLMClient.shared.summarize(text: textToSummarize, customPrompt: prompt.isEmpty ? nil : prompt)
                summaryText = result
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

}