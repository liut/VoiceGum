import AppKit
import SwiftUI
import CFunASREngine
import VoiceGumCore
import VoiceGumServices
import VoiceGumPreferences
import VoiceGumVoiceInput
import VoiceGumFnKey
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var preferencesWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var translationProgressWindow: NSWindow?
    private var translationTask: Task<Void, Never>?
    private var isTranslating: Bool { translationTask != nil }

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        funasr_engine_init()
        Task { _ = await Logger.shared.getLogPath() }
        _ = VoiceInputViewModel.shared

        if AppPreferences.shared.voiceInputEnabled {
            FnKeyDetector.shared.start()
            let tapOk = FnKeyDetector.shared.isTapActive

            if tapOk {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let alert = NSAlert()
                    alert.messageText = "语音输入已就绪"
                    alert.informativeText = "按住触发键开始录音，松开后自动注入文字。首次使用时会提示语音识别和麦克风权限。"
                    alert.addButton(withTitle: "知道了")
                    alert.runModal()
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let alert = NSAlert()
                    alert.messageText = "语音输入需要辅助功能权限"
                    alert.informativeText = "请前往 系统设置 → 隐私与安全性 → 辅助功能，添加并勾选 VoiceGum，然后重新启动应用。"
                    alert.addButton(withTitle: "打开系统设置")
                    alert.addButton(withTitle: "稍后")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cancel in-flight async tasks so the transcription loop exits.
        NotificationCenter.default.post(name: .voiceGumWillTerminate, object: nil)

        let anyActive = GGMLTranscriptionService.isTranscribingActive
                     || FunASRTranscriptionService.isTranscribingActive
        guard anyActive else {
            GGMLTranscriptionService.invalidateActiveModel()
            FunASRTranscriptionService.invalidateActiveModel()
            return .terminateNow
        }

        Task { @MainActor in
            let completed = await GGMLTranscriptionService.waitForTranscriptionCompletion(timeout: 5)
            let completed2 = await FunASRTranscriptionService.waitForTranscriptionCompletion(timeout: 5)
            if completed { GGMLTranscriptionService.invalidateActiveModel() }
            if completed2 { FunASRTranscriptionService.invalidateActiveModel() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // sv_free (called in applicationShouldTerminate) frees the ggml
        // context and Metal buffers, but ggml's static device vector may
        // retain stale resource-set entries. exit() → __cxa_finalize_ranges
        // then crashes in ggml_metal_device_free. Bypass with _exit —
        // the OS reclaims all memory including GPU, no actual leak.
        _exit(0)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

        // MARK: - File Open

    @objc func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            NotificationCenter.default.post(name: .voiceGumOpenFile, object: url)
        }
    }

    func application(_ sender: NSApplication, openFiles files: [String]) {
        guard let file = files.first else { return }
        NotificationCenter.default.post(name: .voiceGumOpenFile, object: URL(fileURLWithPath: file))
    }

    // MARK: - Settings Window

    func showSettings() {
        openSettings(tab: 0)
    }

    private func openSettings(tab: Int) {
        if let existing = preferencesWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(self)
            return
        }
        let settingsView = SettingsView(initialTab: tab)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "设置")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 530, height: 600))
        window.minSize = NSSize(width: 400, height: 400)
        window.maxSize = NSSize(width: 1200, height: 900)
        window.center()

        preferencesWindow = window
        window.makeKeyAndOrderFront(self)
    }

    // MARK: - History Window

    func openHistory() {
        if let existing = historyWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(self)
            return
        }
        let hostingController = NSHostingController(rootView: HistoryView())

        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "历史记录")
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 520))
        window.center()

        historyWindow = window
        window.makeKeyAndOrderFront(self)
    }

    // MARK: - SRT Translation

    func translateSRTFile() {
        guard !isTranslating else {
            translationProgressWindow?.makeKeyAndOrderFront(self)
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let manager = SRTTranslationManager()
        showTranslationProgress()

        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outputURL = try await manager.translate(file: url) { [weak self] current, total in
                    guard let self else { return }
                    Task { @MainActor in
                        self.updateTranslationProgress(current: current, total: total)
                    }
                }
                await MainActor.run {
                    self.dismissTranslationProgress()
                    self.showTranslationComplete(outputURL: outputURL)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.dismissTranslationProgress()
                }
            } catch {
                await MainActor.run {
                    self.dismissTranslationProgress()
                    self.showTranslationError(error)
                }
            }
        }
    }

    // MARK: - Translation Progress Window

    private func showTranslationProgress() {
        if translationProgressWindow == nil {
            let progressView = TranslationProgressView(
                onCancel: { [weak self] in
                    self?.translationTask?.cancel()
                }
            )
            let hostingController = NSHostingController(rootView: progressView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "翻译中...")
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 360, height: 120))
            window.center()
            window.isReleasedWhenClosed = false

            translationProgressWindow = window
        }

        // Reset progress display
        if let progressView = (translationProgressWindow?.contentViewController as? NSHostingController<TranslationProgressView>) {
            progressView.rootView = TranslationProgressView(
                onCancel: { [weak self] in
                    self?.translationTask?.cancel()
                }
            )
        }

        translationProgressWindow?.makeKeyAndOrderFront(self)
    }

    private func updateTranslationProgress(current: Int, total: Int) {
        guard let window = translationProgressWindow,
              let hosting = window.contentViewController as? NSHostingController<TranslationProgressView> else { return }
        hosting.rootView = TranslationProgressView(
            current: current,
            total: total,
            onCancel: { [weak self] in
                self?.translationTask?.cancel()
            }
        )
    }

    private func dismissTranslationProgress() {
        translationProgressWindow?.close()
        translationTask = nil
    }

    private func showTranslationComplete(outputURL: URL) {
        let alert = NSAlert()
        alert.messageText = String(localized: "翻译完成")
        alert.informativeText = outputURL.path
        alert.addButton(withTitle: String(localized: "在 Finder 中显示"))
        alert.addButton(withTitle: String(localized: "确定"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        }
    }

    private func showTranslationError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "翻译失败")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "确定"))
        alert.runModal()
    }
}
