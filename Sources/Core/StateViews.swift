import SwiftUI
import VoiceGumServices

struct IdleContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Select or drop an audio file to begin")
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
            Text("Validating \(fileName)...")
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
            Text("Queued \(fileCount) file(s)")
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
            Text("Preparing \(asrName)...")
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
    let statusMessage: String
    let onCancel: () -> Void

    var isIndeterminate: Bool { progress < 0 }

    var body: some View {
        VStack(spacing: 16) {
            if isIndeterminate {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)

                Text("SenseVoice 正在转写...")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("本地推理中，请耐心等待")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)

                Text(statusMessage.isEmpty ? "转写中..." : statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if totalFiles > 1 {
                    Text("File \(currentFile) of \(totalFiles)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Button("取消", action: onCancel)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RefiningView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
            Text("Refining with LLM...")
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("转写结果")
                    .font(.headline)
                Spacer()
                Button(action: onCopy) {
                    Label("拷贝", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Button(action: onNew) {
                    Label("新文件", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                Text(results.map { $0.text }.joined(separator: "\n\n"))
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                Button("拷贝") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error.localizedDescription, forType: .string)
                }
                .buttonStyle(.bordered)
                Button("重试", action: onRetry)
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

            Text("Transcription cancelled")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button("Start Over", action: onReset)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
