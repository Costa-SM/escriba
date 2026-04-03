import AppKit
import Carbon

/// Listens for a double-tap of the Control key using a CGEvent tap.
/// Requires Accessibility permission (System Settings > Privacy > Accessibility).
final class HotkeyListener {
    private let interval: Double
    private var lastControlPress: Date?
    private var controlWasDown: Bool = false
    private var eventTap: CFMachPort?

    /// Fires when a double-tap is detected.
    var onDoubleTap: (() -> Void)?

    init(doubleTapInterval: Double) {
        self.interval = doubleTapInterval
    }

    func start() throws {
        // We need to capture flagsChanged (modifier key) events
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)

        // Store self in a pointer we can recover inside the C callback
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, _, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else {
                    return Unmanaged.passRetained(event)
                }
                let listener = Unmanaged<HotkeyListener>
                    .fromOpaque(userInfo).takeUnretainedValue()
                listener.handleEvent(event)
                return Unmanaged.passRetained(event)
            },
            userInfo: userInfo
        ) else {
            throw HotkeyError.tapCreationFailed
        }

        self.eventTap = tap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleEvent(_ event: CGEvent) {
        let flags = event.flags
        let controlNowDown = flags.contains(.maskControl)

        // Ignore if other modifiers are held (Shift, Cmd, Option)
        let otherModifiers: CGEventFlags = [.maskShift, .maskCommand, .maskAlternate]
        if !flags.intersection(otherModifiers).isEmpty {
            controlWasDown = controlNowDown
            return
        }

        // Detect transition: Control was up → now pressed down (key-down edge only)
        if controlNowDown && !controlWasDown {
            let now = Date()
            if let last = lastControlPress, now.timeIntervalSince(last) <= interval {
                // Double-tap detected
                lastControlPress = nil
                onDoubleTap?()
            } else {
                lastControlPress = now
            }
        }

        controlWasDown = controlNowDown
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
    }

    enum HotkeyError: Error, CustomStringConvertible {
        case tapCreationFailed

        var description: String {
            switch self {
            case .tapCreationFailed:
                return """
                Failed to create event tap. \
                Grant Accessibility permission in System Settings > \
                Privacy & Security > Accessibility.
                """
            }
        }
    }
}
