import SwiftUI
import VoiceGumServices

struct IdleContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(String(localized: "选择或拖放音频文件开始"))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ValidatingView: View {
    let fileName: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
            Text(String(localized: "Validating \(fileName)..."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct QueuedView: View {
    let fileCount: Int

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
            Text(String(localized: "Queued \(fileCount) file(s)"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PreparingView: View {
    let asrName: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
            Text(String(localized: "Preparing \(asrName)..."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TranscriptionProgressView: View {
    let progress: Double
    let currentFile: Int
    let totalFiles: Int
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.0)

            VStack(spacing: 8) {
                ProgressView(value: max(progress, 0), total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                Text("\(Int(max(progress, 0) * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            Text(String(localized: "转写中..."))
                .font(.caption)
                .foregroundColor(.secondary)

            if totalFiles > 1 {
                Text("文件 \(currentFile) / \(totalFiles)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button(String(localized: "取消"), action: onCancel)
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RefiningView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
            Text(String(localized: "正在润色中..."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ResultView: View {
    let results: [TranscriptionResult]
    let onCopy: () -> Void
    let onNew: () -> Void
    let onSummarize: (() -> Void)?
    let summaryText: String?
    let isSummarizing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "转写结果"))
                    .font(.headline)
                Spacer()
                if onSummarize != nil {
                    if isSummarizing {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.6)
                            Text(String(localized: "摘要中...")).font(.caption).foregroundColor(.secondary)
                        }
                    } else {
                        Button(action: { onSummarize?() }) {
                            Label(String(localized: "摘要"), systemImage: "text.quote")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Button(action: onCopy) {
                    Label(String(localized: "拷贝"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Button(action: onNew) {
                    Label(String(localized: "新文件"), systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let summary = summaryText {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "摘要"))
                                .font(.headline)
                                .foregroundColor(.accentColor)
                            Text(summary)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.05)))
                        .padding(.horizontal, 4)

                        Divider()
                    }

                    Text(results.map { $0.text }.joined(separator: "\n\n"))
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(16)
            }
        }
    }
}

struct ErrorView: View {
    let error: Error
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.orange)

            ScrollView {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)

            HStack(spacing: 8) {
                Button(String(localized: "拷贝")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error.localizedDescription, forType: .string)
                }
                .buttonStyle(.bordered)
                Button(String(localized: "重试"), action: onRetry)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CancelledView: View {
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text(String(localized: "Transcription cancelled"))
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button(String(localized: "重新开始"), action: onReset)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
