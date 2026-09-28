import AppKit
import SwiftUI

/// Observable model for overlay content — bridges updates from AppKit to SwiftUI.
final class OverlayViewModel: ObservableObject {
    @Published var rmsLevel: Float = 0
    @Published var displayText: String = ""
    @Published var engine: VoiceInputASREngine = .systemSpeech
}

/// Floating capsule overlay window for voice input status display.
final class VoiceInputOverlayWindow: NSPanel {

    private let hostingView: NSHostingView<OverlayContent>
    let overlayModel = OverlayViewModel()

    private let panelHeight: CGFloat = 56
    private let cornerRadius: CGFloat = 28
    private let minWidth: CGFloat = 240
    private let maxWidth: CGFloat = 620

    init() {
        let content = OverlayContent(model: overlayModel)
        hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        configurePanel()
        setupContentView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func configurePanel() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
    }

    private func setupContentView() {
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(hostingView)
        self.contentView = effectView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 16),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -16),
            hostingView.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
        ])
    }

    // MARK: - Public API

    func updateText(_ text: String) {
        overlayModel.displayText = text
        sizeToFitContent(animated: true)
    }

    func updateRMS(_ level: Float) {
        overlayModel.rmsLevel = level
    }

    func updateEngine(_ engine: VoiceInputASREngine) {
        overlayModel.engine = engine
    }

    func show() {
        positionAtScreenBottom()
        alphaValue = 0
        orderFrontRegardless()

        var startFrame = frame
        startFrame.origin.y -= 20
        setFrame(startFrame, display: false)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            ctx.allowsImplicitAnimation = true
            self.animator().alphaValue = 1.0
            var targetFrame = self.frame
            targetFrame.origin.y += 20
            self.animator().setFrame(targetFrame, display: true)
        }
    }

    /// Dismisses the overlay. `fadeDuration` 0 removes it right away — the voice input flow wants
    /// the capsule gone the moment the text reaches the target field. A non-zero duration fades
    /// it out instead, which is the hook for a future fade-out transition.
    func hide(fadeDuration: TimeInterval = 0, completion: (() -> Void)? = nil) {
        guard fadeDuration > 0 else {
            orderOut(nil)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            self.animator().alphaValue = 0
            var frame = self.frame
            frame.origin.y -= 10
            self.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion?()
        })
    }

    // MARK: - Private

    private func positionAtScreenBottom() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.visibleFrame
        let width = calculateWidth()
        let origin = NSPoint(
            x: screenFrame.midX - width / 2,
            y: screenFrame.minY + 80
        )
        setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: panelHeight), display: false)
    }

    private func calculateWidth() -> CGFloat {
        let textChars = overlayModel.displayText.count
        let textWidth: CGFloat = textChars > 0 ? min(560, max(160, CGFloat(textChars) * 10)) : 160
        let width = 44 + 16 + textWidth + 16
        return max(minWidth, min(maxWidth, width))
    }

    private func sizeToFitContent(animated: Bool) {
        let width = calculateWidth()
        var newFrame = frame
        newFrame.size.width = width
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        newFrame.origin.x = screen.visibleFrame.midX - width / 2

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                self.animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: true)
        }
    }
}

/// SwiftUI content for the overlay window.
struct OverlayContent: View {
    @ObservedObject var model: OverlayViewModel

    var body: some View {
        HStack(spacing: 8) {
            WaveformView(model: model)

            if !model.displayText.isEmpty {
                Text(model.displayText)
                    .foregroundColor(.white)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 160, maxWidth: 560, alignment: .leading)
                    .animation(.easeInOut(duration: 0.25), value: model.displayText)
            }
        }
    }
}
