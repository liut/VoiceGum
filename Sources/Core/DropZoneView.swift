import SwiftUI
import AppKit

struct DropZoneView: View {
    @Binding var fileURL: URL?
    var onFileSelected: (() -> Void)?

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            // Drop zone background
            NSDropZoneViewRepresentable(isTargeted: $isTargeted, droppedFileURL: $fileURL)
                .onChange(of: fileURL) { _, newValue in
                    if newValue != nil {
                        onFileSelected?()
                    }
                }

            // Content
            VStack(spacing: 12) {
                if let url = fileURL {
                    // File selected - show with checkmark
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)

                    Text(url.lastPathComponent)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .padding(.horizontal)
                } else {
                    // No file - show drop prompt
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 40))
                        .foregroundColor(isTargeted ? .accentColor : .secondary)

                    Text(isTargeted ? "Release to drop" : "Drop audio file here or click to select")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.gray.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .padding(8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if fileURL == nil {
                selectFile()
            }
        }
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .audio,
            .mpeg4Audio,
            .mp3,
            .wav,
            .aiff,
            .mpeg4Movie,
            .quickTimeMovie,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            fileURL = url
        }
    }
}

struct NSDropZoneViewRepresentable: NSViewRepresentable {
    @Binding var isTargeted: Bool
    @Binding var droppedFileURL: URL?

    func makeNSView(context: Context) -> NSView {
        let view = DroppableNSView()
        view.isTargetedBinding = $isTargeted
        view.droppedFileURLBinding = $droppedFileURL
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

class DroppableNSView: NSView {
    var isTargetedBinding: Binding<Bool>?
    var droppedFileURLBinding: Binding<URL?>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasValidAudioFiles(sender) else { return [] }
        isTargetedBinding?.wrappedValue = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isTargetedBinding?.wrappedValue = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargetedBinding?.wrappedValue = false
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let audioURL = urls.first(where: { isAudioFile($0) }) else {
            return false
        }
        droppedFileURLBinding?.wrappedValue = audioURL
        return true
    }

    private func hasValidAudioFiles(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }
        return urls.contains { isAudioFile($0) }
    }

    private func isAudioFile(_ url: URL) -> Bool {
        let audioExtensions = ["wav", "mp3", "m4a", "flac", "aac", "alac", "aiff", "caf", "mp4", "mov", "m4v"]
        return audioExtensions.contains(url.pathExtension.lowercased())
    }
}