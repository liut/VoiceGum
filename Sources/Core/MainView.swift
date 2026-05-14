import SwiftUI
import VoiceGumServices
import VoiceGumPreferences

public struct MainView: View {
    @StateObject private var viewModel = TranscriptionViewModel()

    public init() {}

    private func isLLMConfigured() -> Bool {
        let provider = AppPreferences.shared.llmProvider
        if provider == "ollama" { return true }
        return !AppPreferences.shared.llmAPIKey().isEmpty
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Drop zone / File info area
            DropZoneView(
                fileURL: $viewModel.droppedFileURL
            )
            .onChange(of: viewModel.droppedFileURL) { _, newValue in
                if newValue != nil {
                    viewModel.startTranscription()
                }
            }
            .frame(height: 120)

            Divider()

            // State content area
            Group {
                switch viewModel.state {
                case .idle:
                    Text("Select or drop an audio file to begin")
                        .foregroundColor(.secondary)

                case .validating(let url):
                    ValidatingView(fileName: url.lastPathComponent)

                case .queued(let files):
                    QueuedView(fileCount: files.count)

                case .preparing(let asrName):
                    PreparingView(asrName: asrName)

                case .transcribing(let progress, let currentFile, let totalFiles):
                    TranscriptionProgressView(
                        progress: progress,
                        currentFile: currentFile,
                        totalFiles: totalFiles,
                        onCancel: { viewModel.cancelTranscription() }
                    )

                case .refining:
                    RefiningView()

                case .completed(let results, _):
                    ResultView(
                        results: results,
                        onCopy: { viewModel.copyToClipboard() },
                        onNew: { viewModel.reset() },
                        onSummarize: isLLMConfigured() ? { viewModel.summarize() } : nil,
                        summaryText: viewModel.summaryText,
                        isSummarizing: viewModel.isSummarizing
                    )

                case .failed(let error):
                    ErrorView(error: error, onRetry: { viewModel.retryLastTranscription() })

                case .cancelled:
                    CancelledView(onReset: { viewModel.reset() })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}