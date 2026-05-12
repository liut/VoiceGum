import AppKit
import Observation

@MainActor
final class FnKeyDetector: ObservableObject {
    static let shared = FnKeyDetector()

    @Published var isFnKeyPressed = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    func start() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let detector = Unmanaged<FnKeyDetector>.fromOpaque(refcon).takeUnretainedValue()

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 63 {
                let isKeyUp = type == .keyUp
                Task { @MainActor in
                    detector.isFnKeyPressed = !isKeyUp
                    if isKeyUp {
                        NotificationCenter.default.post(name: .fnKeyReleased, object: nil)
                    }
                }
            }

            return Unmanaged.passRetained(event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else { return }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }
}

extension Notification.Name {
    static let fnKeyReleased = Notification.Name("fnKeyReleased")
}
