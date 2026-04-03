import AppKit
import Foundation
import UserNotifications

// ── Entry point ──────────────────────────────────────────────

let config = Config.load()

// ── Status icon in menu bar ──────────────────────────────────

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No dock icon

let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.title = "🎙"

let menu = NSMenu()
let quitItem = NSMenuItem(title: "Quit Escriba", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(quitItem)
statusItem.menu = menu

// ── Thread-safe state machine ────────────────────────────────

enum DictationState {
    case idle
    case recording
    case transcribing
}

let stateLock = NSLock()
var _state: DictationState = .idle
var state: DictationState {
    get { stateLock.withLock { _state } }
    set { stateLock.withLock { _state = newValue } }
}

var recorder: AudioRecorder?
var transcriber: Transcriber?

func setStatus(_ emoji: String) {
    DispatchQueue.main.async {
        statusItem.button?.title = emoji
    }
}

// ── Notifications (UserNotifications framework, macOS 14+) ───

func requestNotificationPermission() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
}

func notify(_ message: String) {
    let content = UNMutableNotificationContent()
    content.title = "Escriba"
    content.body = message
    let request = UNNotificationRequest(
        identifier: UUID().uuidString, content: content,
        trigger: nil)
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
}

func playSound() {
    if config.notifySound {
        NSSound(named: "Tink")?.play()
    }
}

// ── Initialize transcriber (loads model once at startup) ─────

requestNotificationPermission()

do {
    transcriber = try Transcriber(config: config)
    print("✓ Whisper model loaded: \(config.model)")
} catch {
    print("✗ Failed to load Whisper model: \(error)")
    print("  Run install.sh to download the model.")
    exit(1)
}

let textCleaner = TextCleaner(config: config)

// ── Recording flow ───────────────────────────────────────────

func startRecording() {
    guard state == .idle else { return }
    state = .recording
    setStatus("⏺")

    let rec = AudioRecorder(config: config)
    recorder = rec

    rec.onRecordingComplete = { audioURL in
        guard let url = audioURL else {
            state = .idle
            setStatus("🎙")
            return
        }
        transcribe(audioURL: url)
    }

    do {
        try rec.start()
    } catch {
        print("✗ Failed to start recording: \(error)")
        state = .idle
        setStatus("🎙")
    }
}

func stopRecording() {
    guard state == .recording else { return }
    recorder?.stop()
    recorder = nil
}

func transcribe(audioURL: URL) {
    state = .transcribing
    setStatus("⏳")

    DispatchQueue.global(qos: .userInitiated).async {
        defer {
            try? FileManager.default.removeItem(at: audioURL)
            DispatchQueue.main.async {
                state = .idle
                setStatus("🎙")
            }
        }

        do {
            guard let t = transcriber else { return }
            var text = try t.transcribe(audioURL: audioURL)

            if text.isEmpty {
                DispatchQueue.main.async { notify("Nothing recognized.") }
                return
            }

            // Post-process
            text = textCleaner.clean(text)

            DispatchQueue.main.async {
                TextInjector.type(text)
                playSound()
            }
        } catch {
            print("✗ Transcription error: \(error)")
            DispatchQueue.main.async {
                notify("Transcription failed.")
            }
        }
    }
}

// ── Hotkey listener ──────────────────────────────────────────

let hotkey = HotkeyListener(doubleTapInterval: config.doubleTapInterval)
hotkey.onDoubleTap = {
    switch state {
    case .idle:
        startRecording()
    case .recording:
        stopRecording()
    case .transcribing:
        break // Ignore taps while transcribing
    }
}

do {
    try hotkey.start()
    print("✓ Listening for double-tap Control")
    print("  Double-tap Control to start/stop dictation")
    print("  Language: \(config.language)")
    if config.enableLLMCleanup {
        print("  LLM cleanup: ON (\(config.llmCleanupModel))")
    }
} catch {
    print("✗ \(error)")
    print("  Grant Accessibility permission and restart.")
    exit(1)
}

// ── Run forever ──────────────────────────────────────────────

app.run()
