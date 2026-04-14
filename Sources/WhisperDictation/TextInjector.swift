import AppKit
import Carbon

/// Types text at the current cursor position by pasting via the clipboard.
enum TextInjector {

    // Clipboard saved at the start of a streaming session.
    private static var streamSaved: String? = nil

    /// Paste `text` at the cursor and restore the previous clipboard.
    /// Use for single-shot injection (non-streaming).
    static func type(_ text: String) {
        let saved = NSPasteboard.general.string(forType: .string)
        paste(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSPasteboard.general.clearContents()
            if let s = saved { NSPasteboard.general.setString(s, forType: .string) }
        }
    }

    /// Begin a streaming session. Saves the current clipboard.
    /// Must be called from the main thread before the first `typeChunk`.
    static func beginStream() {
        streamSaved = NSPasteboard.general.string(forType: .string)
    }

    /// Paste one chunk during a streaming session.
    /// Does not restore the clipboard — call `endStream()` when done.
    static func typeChunk(_ text: String) {
        paste(text)
    }

    /// End a streaming session. Restores the clipboard saved by `beginStream()`.
    static func endStream() {
        let saved = streamSaved
        streamSaved = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSPasteboard.general.clearContents()
            if let s = saved { NSPasteboard.general.setString(s, forType: .string) }
        }
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    private static func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let dn = CGEvent(keyboardEventSource: src, virtualKey: UInt16(kVK_ANSI_V), keyDown: true)
        dn?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: UInt16(kVK_ANSI_V), keyDown: false)
        up?.flags = .maskCommand
        dn?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
