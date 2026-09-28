import AppKit

@MainActor
public final class FnKeyDetector: ObservableObject {
    public static let shared = FnKeyDetector()

    @Published public var isFnKeyPressed = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyDownTimestamp: CFTimeInterval = 0

    private init() {}

    public var isTapActive: Bool { eventTap != nil }

    nonisolated public var triggerKeyCode: Int64 {
        let raw = UserDefaults.standard.integer(forKey: "voicegum.voiceInput.triggerKeyCode")
        return raw > 0 ? Int64(raw) : 54 // Right Cmd
    }

    nonisolated public var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: "voicegum.voiceInput.enabled") == nil { return false }
        return UserDefaults.standard.bool(forKey: "voicegum.voiceInput.enabled")
    }

    public func start() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let det = Unmanaged<FnKeyDetector>.fromOpaque(refcon).takeUnretainedValue()

            let enabled = det.isEnabled
            let targetKey = det.triggerKeyCode
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            guard enabled else { return Unmanaged.passRetained(event) }
            guard keyCode == targetKey else { return Unmanaged.passRetained(event) }

            let isPressed: Bool
            if type == .flagsChanged {
                isPressed = event.flags.contains(modifierFlag(for: targetKey))
            } else {
                isPressed = type == .keyDown
            }

            let now = CACurrentMediaTime()
            Task { @MainActor [weak det] in
                // Fn reports one physical press as both a key event and a flagsChanged event,
                // so only transitions are forwarded to keep one notification per press.
                guard let det, isPressed != det.isFnKeyPressed else { return }
                if isPressed {
                    det.keyDownTimestamp = now
                    det.isFnKeyPressed = true
                    NotificationCenter.default.post(name: .voiceInputTriggerKeyDown, object: nil)
                } else {
                    let duration = now - det.keyDownTimestamp
                    det.isFnKeyPressed = false
                    NotificationCenter.default.post(name: .voiceInputTriggerKeyUp, object: nil, userInfo: ["duration": duration])
                }
            }
            return nil
        }

        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: eventMask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())

        guard let tap = eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }
}

private func modifierFlag(for keyCode: Int64) -> CGEventFlags {
    switch keyCode {
    case 54, 55: return .maskCommand
    case 58, 61: return .maskAlternate
    case 56, 60: return .maskShift
    case 59, 62: return .maskControl
    case 63:     return .maskSecondaryFn
    default:     return []
    }
}

extension Notification.Name {
    public static let fnKeyReleased = Notification.Name("fnKeyReleased")
    public static let voiceInputTriggerKeyDown = Notification.Name("voiceInputTriggerKeyDown")
    public static let voiceInputTriggerKeyUp = Notification.Name("voiceInputTriggerKeyUp")
    public static let voiceInputInjectText = Notification.Name("voiceInputInjectText")
}
