import SwiftUI
import VoiceGumServices

public struct HistoryView: View {
    @State private var entries: [HistoryEntry] = []
    @State private var selectedEntry: HistoryEntry?

    public init() {}

    public var body: some View {
        if let entry = selectedEntry {
            HistoryDetailView(entry: entry, onBack: { selectedEntry = nil })
        } else {
            historyList
        }
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            Text(String(localized: "历史记录"))
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text(String(localized: "暂无历史记录"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries.reversed()) { entry in
                    HistoryRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedEntry = entry }
                }
            }
        }
        .frame(width: 400, height: 440)
        .task { await loadEntries() }
    }

    private func loadEntries() async {
        entries = await HistoryManager.shared.entries
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.minute, .second]
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.displayTitle)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
            HStack(spacing: 12) {
                Text(dateFormatter.string(from: entry.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(entry.engineDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let d = entry.duration, let formatted = durationFormatter.string(from: d) {
                    Text(formatted)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if entry.summaryText != nil {
                    Image(systemName: "text.quote")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct HistoryDetailView: View {
    let entry: HistoryEntry
    let onBack: () -> Void

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.minute, .second]
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Label(String(localized: "返回"), systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                }) {
                    Label(String(localized: "拷贝"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "文件名")).font(.caption).foregroundColor(.secondary)
                            Text(entry.sourceFileName).font(.subheadline)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(localized: "日期")).font(.caption).foregroundColor(.secondary)
                            Text(dateFormatter.string(from: entry.timestamp)).font(.subheadline)
                        }
                    }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "引擎")).font(.caption).foregroundColor(.secondary)
                            Text(entry.engineDescription).font(.subheadline)
                        }
                        Spacer()
                        if let d = entry.duration, let formatted = durationFormatter.string(from: d) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(String(localized: "时长")).font(.caption).foregroundColor(.secondary)
                                Text(formatted).font(.subheadline)
                            }
                        }
                    }

                    if let summary = entry.summaryText {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "摘要")).font(.caption).foregroundColor(.secondary)
                            Text(summary)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.05)))
                    }

                    Divider()
                    Text(entry.text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(16)
            }
        }
        .frame(width: 400, height: 440)
    }
}
