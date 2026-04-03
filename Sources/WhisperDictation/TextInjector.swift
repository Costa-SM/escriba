import AppKit
import Carbon

/// Types text at the current cursor position by pasting via the clipboard.
/// Uses clipboard + CGEvent paste rather than keystroke simulation to handle
/// Unicode, punctuation, accented characters, and all keyboard layouts.
enum TextInjector {

    /// Paste text at the current cursor position, then restore the previous clipboard.
    static func type(_ text: String) {
        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V using the layout-independent key code for 'v'
        // kVK_ANSI_V (0x09) is actually layout-independent in Carbon despite the name —
        // it refers to a physical key position, not the character it produces.
        // However, to be safe, we use the Carbon constant.
        let source = CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Restore clipboard after a generous delay to let the target app process the paste.
        // 0.5s accommodates Electron apps, VS Code, etc.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            if let previous = previousContents {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }
}
