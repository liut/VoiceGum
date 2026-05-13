import SwiftUI
import VoiceGumCore

@main
struct VoiceGumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("VoiceGum", id: "main") {
            MainView()
                .frame(minWidth: 400, idealWidth: 480, minHeight: 360, idealHeight: 420)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(String(localized: "关于 VoiceGum")) {
                    let alert = NSAlert()
                    alert.messageText = "VoiceGum"
                    alert.informativeText = "A macOS menu bar ASR application.\n\nVersion 1.0.0"
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(String(localized: "设置...")) {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
