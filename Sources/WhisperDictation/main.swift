import AppKit
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

let menu = NSMenu()
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

func setStatus(_ emoji: String) {
    DispatchQueue.main.async {
        statusItem.button?.title = emoji
    }
}

func playSound() {
    if config.notifySound {
        NSSound(named: "Tink")?.play()
    }
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
    setStatus("⏺")
    logInfo("Recording started")

    let rec = AudioRecorder(config: config)
    recorder = rec

    rec.onRecordingComplete = { audioURL in
        guard let url = audioURL else {
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
    setStatus("⏳")
    logInfo("Transcribing...")

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
                logInfo("Transcription returned empty result")
                return
            }

            // Post-process
            text = textCleaner.clean(text)
            logInfo("Transcription complete: \(text.prefix(80))...")

            DispatchQueue.main.async {
                TextInjector.type(text)
                playSound()
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

do {
    try hotkey.start()
    logInfo("Hotkey listener active — double-tap Control to dictate")
    logInfo("Language: \(config.language)")
    if config.enableLLMCleanup {
        logInfo("LLM cleanup: ON (\(config.llmCleanupModel))")
    }
} catch {
    logError("\(error)")
    logError("Grant Accessibility permission in System Settings > Privacy & Security > Accessibility")
    exit(1)
}

logInfo("Escriba ready")

// ── Run forever ──────────────────────────────────────────────

app.run()
