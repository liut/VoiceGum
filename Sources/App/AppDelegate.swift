import AppKit
import SwiftUI
import CFunASREngine
import VoiceGumCore
import VoiceGumServices
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var preferencesWindow: NSWindow?
    private var historyWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        funasr_engine_init()
        Task { _ = await Logger.shared.getLogPath() }
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
}
