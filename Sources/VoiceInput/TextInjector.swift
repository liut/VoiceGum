import AppKit

@MainActor
final class TextInjector {
    static func inject(text: String, targetApp: NSRunningApplication?) {
        // Activate target app so paste goes to the right place
        if let target = targetApp,
           target != NSWorkspace.shared.frontmostApplication {
            target.activate(options: .activateIgnoringOtherApps)
        }

        let pb = NSPasteboard.general
        let savedString = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)
        postCmdV()

        // Restore original clipboard after paste completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            pb.clearContents()
            if let saved = savedString {
                pb.setString(saved, forType: .string)
            }
        }
    }

    private static func postCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let loc = CGEventTapLocation.cghidEventTap
        let cmd: CGKeyCode = 0x37, v: CGKeyCode = 0x09

        func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
            e.flags = flags
            e.post(tap: loc)
        }

        post(cmd, down: true)
        post(v, down: true, flags: .maskCommand)
        post(v, down: false, flags: .maskCommand)
        post(cmd, down: false)
    }
}
