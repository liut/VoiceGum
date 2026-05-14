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
            CommandGroup(after: .newItem) {
                Button(String(localized: "打开音频文件...")) {
                    appDelegate.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button(String(localized: "关于 VoiceGum")) {
                    let alert = NSAlert()
                    alert.messageText = "VoiceGum"
                    alert.informativeText = "macOS 语音转文字工具，支持本地模型与在线 API。\n\nVersion 1.0.0"
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(String(localized: "设置...")) {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
                Button(String(localized: "历史记录")) {
                    appDelegate.openHistory()
                }
                .keyboardShortcut("y", modifiers: .command)
            }
        }
    }
}
