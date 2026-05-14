import AppKit
import SwiftUI
import CAsrEngine
import VoiceGumCore
import VoiceGumServices

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
        asr_engine_init()
        Task { _ = await Logger.shared.getLogPath() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GGMLTranscriptionService.invalidateActiveModel()
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
