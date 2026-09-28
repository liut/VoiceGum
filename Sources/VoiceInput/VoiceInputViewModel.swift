import AppKit
import SwiftUI
import Combine
import VoiceGumPreferences
import VoiceGumFnKey

@MainActor
public final class VoiceInputViewModel: ObservableObject {

    public static let shared = VoiceInputViewModel()

    @Published public var overlayState: OverlayState = .hidden
    @Published public var partialText: String = ""
    @Published public var rmsLevel: Float = 0
    @Published public var asrEngine: VoiceInputASREngine = .systemSpeech

    private let engine = VoiceInputEngine()
    private var overlayWindow: VoiceInputOverlayWindow?
    private var startTask: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private let minPressDuration: TimeInterval = 0.3

    private var isEnabled: Bool { AppPreferences.shared.voiceInputEnabled }

    private init() {
        Task {
            await engine.setStateChangeHandler { [weak self] in self?.handleStateChange($0) }
            await engine.setPartialTextHandler { [weak self] in
                self?.partialText = $0
                self?.overlayWindow?.updateText($0)
            }
            await engine.setRMSLevelHandler { [weak self] in
                self?.rmsLevel = $0
                self?.overlayWindow?.updateRMS($0)
            }
            await engine.setEngineChangeHandler { [weak self] in
                self?.asrEngine = $0
                self?.overlayWindow?.updateEngine($0)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(handleTriggerKeyDown), name: .voiceInputTriggerKeyDown, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleTriggerKeyUp), name: .voiceInputTriggerKeyUp, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleInjectText), name: .voiceInputInjectText, object: nil)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { _ in
                if AppPreferences.shared.voiceInputEnabled {
                    if !FnKeyDetector.shared.isTapActive { FnKeyDetector.shared.start() }
                } else {
                    FnKeyDetector.shared.stop()
                }
            }
            .store(in: &cancellables)
    }

    @objc private func handleInjectText(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let text = userInfo["text"] as? String else { return }
        TextInjector.inject(text: text, targetApp: nil)
        dismissOverlay()
        reset()
    }

    @objc private func handleTriggerKeyDown(_ notification: Notification) {
        guard isEnabled else { return }
        // One capsule per session. A press arriving while a session is still in flight must not
        // replace the visible window: the replaced window would be left on screen forever, and
        // the engine ignores startRecording while busy anyway.
        guard overlayWindow == nil else { return }
        let window = VoiceInputOverlayWindow()
        window.updateEngine(asrEngine)
        window.show()
        overlayWindow = window
        startTask?.cancel()
        startTask = Task { await engine.startRecording() }
    }

    @objc private func handleTriggerKeyUp(_ notification: Notification) {
        guard let userInfo = notification.userInfo, let duration = userInfo["duration"] as? TimeInterval else { return }
        // The capsule stays on screen while the session is in flight, so releasing the key only
        // stops recording; the capsule goes away when the text is injected (or the session ends).
        if duration < minPressDuration {
            startTask?.cancel()
            Task { await engine.cancelRecording() }
            return
        }
        Task { await engine.stopRecording() }
    }

    private func handleStateChange(_ state: VoiceInputState) {
        switch state {
        case .idle: overlayState = .hidden
        case .recording:
            overlayState = .showing
            startEscapeMonitor()
        case .recognizing: overlayState = .recognizing
        case .injecting: overlayState = .injecting
        case .done:
            overlayState = .hidden
            stopEscapeMonitor()
            dismissOverlay()
            reset()
        case .cancelled:
            overlayState = .hidden
            stopEscapeMonitor()
            dismissOverlay()
            reset()
        case .error(let error):
            overlayState = .error(error.errorDescription ?? "未知错误")
            stopEscapeMonitor()
            if overlayWindow == nil {
                overlayWindow = VoiceInputOverlayWindow()
                overlayWindow?.show()
            }
            overlayWindow?.updateText(error.errorDescription ?? "错误")
            let window = overlayWindow
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                // Only close if this window is still the current overlay (not replaced by a new recording)
                guard let self, let shown = window, self.overlayWindow === shown else { return }
                self.dismissOverlay()
                self.reset()
            }
        }
    }

    private func dismissOverlay() {
        guard let window = overlayWindow else { return }
        overlayWindow = nil
        window.hide()
    }

    private func startEscapeMonitor() {
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return }
            Task { @MainActor in await self.engine.cancelRecording() }
        }
    }

    private func stopEscapeMonitor() {
        if let m = escapeMonitor { NSEvent.removeMonitor(m); escapeMonitor = nil }
    }

    private func reset() { partialText = ""; rmsLevel = 0 }
}

public enum OverlayState: Equatable {
    case hidden, showing, recognizing, injecting
    case error(String)
}
