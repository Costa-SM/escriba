import AppKit
import AVFoundation
import Foundation
import os.log

// ── Logging ──────────────────────────────────────────────────

let log = OSLog(subsystem: "com.whisper-dictation.escriba", category: "main")

func logInfo(_ msg: String) {
    os_log(.info, log: log, "%{public}@", msg)
    fputs("[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n", stderr)
}

func logError(_ msg: String) {
    os_log(.error, log: log, "%{public}@", msg)
    fputs("[\(ISO8601DateFormatter().string(from: Date()))] ERROR: \(msg)\n", stderr)
}

// ── Entry point ──────────────────────────────────────────────

logInfo("Escriba starting...")

let config = Config.load()
logInfo("Config loaded: model=\(config.model), language=\(config.language)")

// ── Status icon in menu bar ──────────────────────────────────

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No dock icon

let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.title = "🎙"

// Menu action target
class MenuHandler: NSObject {
    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
let menuHandler = MenuHandler()

let menu = NSMenu()

let accessibilityItem = NSMenuItem(
    title: "⚠️ Grant Accessibility Permission…",
    action: #selector(MenuHandler.openAccessibilitySettings),
    keyEquivalent: ""
)
accessibilityItem.target = menuHandler
menu.addItem(accessibilityItem)
menu.addItem(.separator())

let quitItem = NSMenuItem(title: "Quit Escriba", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(quitItem)
statusItem.menu = menu

logInfo("Menu bar icon created")

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

// ── Menu bar icon animation ──────────────────────────────────

var animationTimer: Timer?

// Must be called from any thread; schedules/cancels on the main run loop.
func startAnimation(_ frames: [String], interval: TimeInterval = 0.6) {
    DispatchQueue.main.async {
        animationTimer?.invalidate()
        var i = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            statusItem.button?.title = frames[i % frames.count]
            i += 1
        }
        // Show the first frame immediately
        statusItem.button?.title = frames[0]
    }
}

func stopAnimation() {
    DispatchQueue.main.async {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}

func setStatus(_ emoji: String) {
    DispatchQueue.main.async {
        statusItem.button?.title = emoji
    }
}

// ── Sounds ───────────────────────────────────────────────────

func playStartSound() {
    guard config.notifySound else { return }
    NSSound(named: "Ping")?.play()
}

func playDoneSound() {
    guard config.notifySound else { return }
    NSSound(named: "Tink")?.play()
}

// ── Initialize transcriber (loads model once at startup) ─────

logInfo("Loading whisper model: \(config.modelPath.path)")

do {
    transcriber = try Transcriber(config: config)
    logInfo("Whisper model loaded successfully")
} catch {
    logError("Failed to load Whisper model: \(error)")
    logError("Run install.sh to download the model.")
    exit(1)
}

let textCleaner = TextCleaner(config: config)

// ── Recording flow ───────────────────────────────────────────

func startRecording() {
    guard state == .idle else { return }
    state = .recording
    startAnimation(["⏺", "🔴"])
    playStartSound()
    logInfo("Recording started")

    let rec = AudioRecorder(config: config)
    recorder = rec

    rec.onRecordingComplete = { audioURL in
        guard let url = audioURL else {
            stopAnimation()
            state = .idle
            setStatus("🎙")
            logInfo("Recording cancelled (no audio)")
            return
        }
        transcribe(audioURL: url)
    }

    do {
        try rec.start()
    } catch {
        logError("Failed to start recording: \(error)")
        stopAnimation()
        state = .idle
        setStatus("🎙")
    }
}

func stopRecording() {
    guard state == .recording else { return }
    logInfo("Recording stopped by user")
    recorder?.stop()
    recorder = nil
}

func transcribe(audioURL: URL) {
    state = .transcribing
    stopAnimation()
    startAnimation(["⌛", "⏳"], interval: 0.5)
    logInfo("Transcribing...")

    DispatchQueue.global(qos: .userInitiated).async {
        defer {
            try? FileManager.default.removeItem(at: audioURL)
            DispatchQueue.main.async {
                stopAnimation()
                state = .idle
                setStatus("🎙")
            }
        }

        do {
            guard let t = transcriber else { return }
            var text = try t.transcribe(audioURL: audioURL)

            if text.isEmpty {
                logInfo("Transcription returned empty result")
                return
            }

            text = textCleaner.clean(text)
            logInfo("Transcription complete: \(text.prefix(80))...")

            DispatchQueue.main.async {
                TextInjector.type(text)
                playDoneSound()
            }
        } catch {
            logError("Transcription error: \(error)")
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

// Try to arm the event tap directly — success/failure is the ground truth for
// whether Accessibility is granted. AXIsProcessTrusted() can return stale
// results for a running process; attempting the tap bypasses that.
// Never exits on failure — launchd KeepAlive would restart and re-prompt endlessly.
var accessibilityPromptShown = false

func tryStartHotkey() {
    do {
        try hotkey.start()
        setStatus("🎙")
        logInfo("Hotkey listener active — double-tap fn/Globe to dictate")
        logInfo("Language: \(config.language)")
        if config.enableLLMCleanup {
            logInfo("LLM cleanup: ON (\(config.llmCleanupModel))")
        }
        logInfo("Escriba ready")
    } catch {
        setStatus("⚠️")
        if !accessibilityPromptShown {
            logInfo("Accessibility not granted — prompting user")
            AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            )
            accessibilityPromptShown = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { tryStartHotkey() }
    }
}

// ── Bootstrap after run loop starts ─────────────────────────
// Dispatching async ensures the NSApplication run loop is live before we
// trigger system permission dialogs and start the hotkey poll.

DispatchQueue.main.async {
    // Microphone: system shows a one-time "Allow microphone access?" dialog.
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        if granted {
            logInfo("Microphone permission granted")
        } else {
            logError("Microphone permission denied — dictation will not work")
        }
    }

    tryStartHotkey()
}

// ── Run forever ──────────────────────────────────────────────

app.run()
