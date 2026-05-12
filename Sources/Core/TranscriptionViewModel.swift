import Foundation
import AVFoundation
import AppKit
import VoiceGumServices
import VoiceGumPreferences

@MainActor
final class TranscriptionViewModel: ObservableObject {
    @Published var state: TranscriptionState = .idle
    @Published var droppedFileURL: URL?
    @Published var statusMessage: String = ""

    private var transcriptionService: TranscriptionService?
    private var currentTask: Task<Void, Never>?

    init() {
        setupTranscriptionService()
    }

    private func setupTranscriptionService() {
        let provider = AppPreferences.shared.asrProvider
        switch provider {
        case "online":
            let baseURL = URL(string: AppPreferences.shared.asrAPIURL) ?? URL(string: "https://api.openai.com/v1")!
            let apiKey = AppPreferences.shared.asrAPIKey.isEmpty ? nil : AppPreferences.shared.asrAPIKey
            transcriptionService = OnlineAPITranscription(baseURL: baseURL, apiKey: apiKey, model: AppPreferences.shared.asrModel)
        default:
            // Local model - check if downloaded then use local transcription
            if isModelDownloaded(AppPreferences.shared.asrModel) {
                transcriptionService = LocalTranscriptionService(modelId: AppPreferences.shared.asrModel)
            } else {
                transcriptionService = nil
            }
        }
    }

    private func isModelDownloaded(_ modelId: String) -> Bool {
        let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("VoiceGum/Models/\(modelId)")
        guard FileManager.default.fileExists(atPath: modelsDir.path) else { return false }
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path) {
            return !contents.isEmpty
        }
        return false
    }

    func startTranscription() {
        guard let fileURL = droppedFileURL else { return }

        // Re-setup service so freshly downloaded models are detected
        setupTranscriptionService()

        currentTask = Task {
            do {
                state = .validating(file: fileURL)

                guard AudioFileValidator.isValid(file: fileURL) else {
                    state = .failed(error: TranscriptionError.invalidAudioFormat)
                    return
                }

                let files = [fileURL]
                state = .queued(files: files)

                var allResults: [TranscriptionResult] = []

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

                    let result = try await service.transcribe(
                        file: file,
                        language: AppPreferences.shared.language
                    )

                    allResults.append(result)
                }

                state = .transcribing(progress: 1.0, currentFile: files.count, totalFiles: files.count)

                // Check if LLM refinement is needed
                if AppPreferences.shared.llmEnabled && AppPreferences.shared.llmBaseURL.isEmpty == false {
                    // Trigger refinement after a short delay to show completion first
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

                    state = .refining

                    var refinedResults: [TranscriptionResult] = []
                    for result in allResults {
                        let refinedText = try await LLMClient.shared.refine(text: result.text)
                        refinedResults.append(TranscriptionResult(
                            text: refinedText,
                            timestamps: result.timestamps,
                            language: result.language,
                            confidence: result.confidence
                        ))
                    }

                    state = .completed(results: refinedResults, files: files)
                    saveResults(refinedResults, files: files)
                } else {
                    state = .completed(results: allResults, files: files)
                    saveResults(allResults, files: files)
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
    }

    func copyToClipboard() {
        if case .completed(let results, _) = state {
            let text = results.map { $0.text }.joined(separator: "\n\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func saveResults(_ results: [TranscriptionResult], files: [URL]) {
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

            let header = """
            VoiceGum 转写结果
            时间: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))
            文件: \(files.indices.contains(index) ? files[index].lastPathComponent : "unknown")
            语言: \(result.language ?? "auto")
            置信度: \(result.confidence.map { String(format: "%.2f", $0) } ?? "N/A")
            ---

            """
            try? (header + result.text).write(to: outputFile, atomically: true, encoding: .utf8)
        }
    }

    func triggerRefinement() {
        // This can be called when Fn key is released
        // Currently refinement is automatic after transcription
        // This method exists for potential manual trigger
    }
}