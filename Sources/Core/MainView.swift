import SwiftUI
import VoiceGumServices
import VoiceGumPreferences

public struct MainView: View {
    @StateObject private var viewModel = TranscriptionViewModel()
    private let onOpenHistory: (() -> Void)?

    public init(onOpenHistory: (() -> Void)? = nil) {
        self.onOpenHistory = onOpenHistory
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            if let onOpenHistory {
                HStack {
                    Spacer()
                    Button(action: onOpenHistory) {
                        Label(String(localized: "历史"), systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

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

                case .transcribing:
                    TranscriptionProgressView(
                        statusMessage: viewModel.statusMessage,
                        onCancel: { viewModel.cancelTranscription() }
                    )

                case .refining:
                    RefiningView()

                case .completed(let results, _):
                    ResultView(
                        results: results,
                        onCopy: { viewModel.copyToClipboard() },
                        onNew: { viewModel.reset() },
                        onSummarize: AppPreferences.shared.summaryEnabled ? { viewModel.summarize() } : nil,
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