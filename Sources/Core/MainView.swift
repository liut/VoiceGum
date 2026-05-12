import SwiftUI
import VoiceGumServices

public struct MainView: View {
    @StateObject private var viewModel = TranscriptionViewModel()

    public init() {}

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

                case .transcribing(let progress, let current, let total):
                    TranscriptionProgressView(
                        progress: progress,
                        currentFile: current,
                        totalFiles: total,
                        statusMessage: viewModel.statusMessage,
                        onCancel: { viewModel.cancelTranscription() }
                    )

                case .refining:
                    RefiningView()

                case .completed(let results, _):
                    ResultView(
                        results: results,
                        onCopy: { viewModel.copyToClipboard() },
                        onNew: { viewModel.reset() }
                    )

                case .failed(let error):
                    ErrorView(error: error, onRetry: { viewModel.retryLastTranscription() })

                case .cancelled:
                    CancelledView(onReset: { viewModel.reset() })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480, height: 420)
    }
}