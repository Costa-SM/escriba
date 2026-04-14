import AppKit
import Carbon

/// Listens for a double-tap of the fn/Globe key using a CGEvent tap.
/// Requires Accessibility permission (System Settings > Privacy > Accessibility).
///
/// The second fn tap is swallowed (returned nil from the tap callback) so that
/// macOS's own "double-tap fn to dictate" shortcut does not also fire.
/// If both Escriba and system dictation still activate, disable the system
/// shortcut at System Settings → Keyboard → Dictation → Keyboard Shortcut.
final class HotkeyListener {
    private let interval: Double
    private var lastFnPress: Date?
    private var fnWasDown: Bool = false
    private var eventTap: CFMachPort?

    /// Fires when a double-tap is detected.
    var onDoubleTap: (() -> Void)?

    init(doubleTapInterval: Double) {
        self.interval = doubleTapInterval
    }

    func start() throws {
        // flagsChanged fires on every modifier-key transition, including fn/Globe.
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

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
                return listener.handleEvent(event)
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

    private func handleEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        let fnNowDown = flags.contains(.maskSecondaryFn)

        // Ignore if standard modifiers are also held (fn+Shift, fn+Cmd, etc.)
        let otherModifiers: CGEventFlags = [.maskShift, .maskCommand, .maskAlternate, .maskControl]
        if !flags.intersection(otherModifiers).isEmpty {
            fnWasDown = fnNowDown
            return Unmanaged.passRetained(event)
        }

        // Detect fn key-down edge (up → down transition only)
        if fnNowDown && !fnWasDown {
            let now = Date()
            if let last = lastFnPress, now.timeIntervalSince(last) <= interval {
                // Double-tap confirmed — swallow this event so macOS dictation doesn't fire.
                lastFnPress = nil
                fnWasDown = fnNowDown
                DispatchQueue.main.async { self.onDoubleTap?() }
                return nil
            } else {
                lastFnPress = now
            }
        }

        fnWasDown = fnNowDown
        return Unmanaged.passRetained(event)
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
