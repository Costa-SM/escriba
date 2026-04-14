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
    @objc func requestAccessibilityPermission() {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        )
    }

    @objc func toggleLLM(_ sender: NSMenuItem) {
        textCleaner.llmEnabled.toggle()
        sender.state = textCleaner.llmEnabled ? .on : .off
        logInfo("LLM cleanup toggled \(textCleaner.llmEnabled ? "ON" : "OFF")")
    }
}
let menuHandler = MenuHandler()

let menu = NSMenu()

let accessibilityItem = NSMenuItem(
    title: "⚠️ Grant Accessibility Permission…",
    action: #selector(MenuHandler.requestAccessibilityPermission),
    keyEquivalent: ""
)
accessibilityItem.target = menuHandler
menu.addItem(accessibilityItem)
menu.addItem(.separator())

let llmItem = NSMenuItem(
    title: "LLM Cleanup",
    action: #selector(MenuHandler.toggleLLM(_:)),
    keyEquivalent: ""
)
llmItem.target = menuHandler
llmItem.state = config.enableLLMCleanup ? .on : .off
menu.addItem(llmItem)
menu.addItem(.separator())

let quitItem = NSMenuItem(title: "Quit Escriba", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(quitItem)
statusItem.menu = menu

logInfo("Menu bar icon created")

// ── State machine ────────────────────────────────────────────
// All state mutations happen on the main thread.

enum DictationState {
    case idle
    case recording
    case transcribing
}

var state: DictationState = .idle

var recorder: AudioRecorder?
var transcriber: Transcriber?

// Number of phrase chunks still being transcribed.
// Only ever touched on the main thread.
var pendingChunks = 0

// Whether this is the first chunk in the current session (for spacing).
var isFirstChunk = true

// LLM chunk-pair buffering: when LLM is enabled, accumulate 2 chunks of text
// before running the LLM on the combined text.
var llmChunkBuffer = ""
var llmChunkCount = 0

// Serial queue: ensures chunks are transcribed in the order they arrived
// and that text is injected in the correct sequence.
let transcriptionQueue = DispatchQueue(label: "com.escriba.transcription", qos: .userInitiated)

// ── Menu bar icon animation ──────────────────────────────────

var animationTimer: Timer?

func startAnimation(_ frames: [String], interval: TimeInterval = 0.6) {
    DispatchQueue.main.async {
        animationTimer?.invalidate()
        var i = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            statusItem.button?.title = frames[i % frames.count]
            i += 1
        }
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

// ── Chunk pipeline ───────────────────────────────────────────
//
// AudioRecorder emits phrase-sized WAV chunks whenever it detects a short pause.
// Each chunk is queued on a serial transcription queue so results arrive in order.
// The recorder keeps running during transcription, giving the user immediate
// feedback (text for phrase N appears while they speak phrase N+1).

/// Called on the main thread each time AudioRecorder has a complete phrase chunk.
func handleChunk(url: URL) {
    pendingChunks += 1
    logInfo("Chunk queued (pending: \(pendingChunks))")

    transcriptionQueue.async {
        defer {
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async { chunkFinished() }
        }

        do {
            guard let t = transcriber else { return }
            var text = try t.transcribe(audioURL: url)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                logInfo("Chunk produced empty result")
                return
            }
            logInfo("Chunk raw: \(text.prefix(80))")

            DispatchQueue.main.async {
                if textCleaner.llmEnabled {
                    // Buffer chunks in pairs for LLM cleanup.
                    if !llmChunkBuffer.isEmpty { llmChunkBuffer += " " }
                    llmChunkBuffer += text
                    llmChunkCount += 1

                    if llmChunkCount >= 2 {
                        let combined = llmChunkBuffer
                        llmChunkBuffer = ""
                        llmChunkCount = 0
                        transcriptionQueue.async {
                            let cleaned = textCleaner.clean(combined)
                            let output = isFirstChunk ? cleaned : " " + cleaned
                            DispatchQueue.main.async {
                                isFirstChunk = false
                                TextInjector.typeChunk(output)
                            }
                        }
                    }
                } else {
                    // Fast path: rule-based cleanup per chunk, paste immediately.
                    let cleaned = textCleaner.cleanFast(text)
                    let output = isFirstChunk ? cleaned : " " + cleaned
                    isFirstChunk = false
                    TextInjector.typeChunk(output)
                }
            }
        } catch {
            logError("Chunk transcription error: \(error)")
        }
    }
}

/// Called on the main thread when a chunk transcription finishes.
func chunkFinished() {
    pendingChunks -= 1
    logInfo("Chunk done (pending: \(pendingChunks))")
    if state == .transcribing && pendingChunks == 0 {
        finishSession()
    }
}

/// Called on the main thread when recording has stopped.
func recordingEnded() {
    recorder = nil
    if pendingChunks > 0 {
        // Still waiting for background transcriptions to complete.
        state = .transcribing
        startAnimation(["⌛", "⏳"], interval: 0.5)
        logInfo("Recording done — waiting for \(pendingChunks) pending chunk(s)")
    } else {
        finishSession()
    }
}

/// Tear down after the session is fully complete.
func finishSession() {
    stopAnimation()

    // Flush any remaining LLM-buffered chunk.
    if textCleaner.llmEnabled && !llmChunkBuffer.isEmpty {
        let remaining = llmChunkBuffer
        llmChunkBuffer = ""
        llmChunkCount = 0
        transcriptionQueue.async {
            let cleaned = textCleaner.clean(remaining)
            let output = isFirstChunk ? cleaned : " " + cleaned
            DispatchQueue.main.async {
                isFirstChunk = false
                TextInjector.typeChunk(output)
                TextInjector.endStream()
                playDoneSound()
                state = .idle
                setStatus("🎙")
                logInfo("Session complete")
            }
        }
        return
    }

    TextInjector.endStream()
    playDoneSound()
    state = .idle
    setStatus("🎙")
    logInfo("Session complete")
}

// ── Recording flow ───────────────────────────────────────────

func startRecording() {
    guard state == .idle else { return }
    state = .recording
    isFirstChunk = true
    llmChunkBuffer = ""
    llmChunkCount = 0
    transcriber?.resetContext()
    setStatus("🔴")
    playStartSound()
    logInfo("Recording started")

    // Save clipboard once for the whole session; restored in finishSession → endStream.
    TextInjector.beginStream()

    let rec = AudioRecorder(config: config)
    recorder = rec

    rec.onChunkReady = { audioURL in
        handleChunk(url: audioURL)
    }

    rec.onRecordingComplete = {
        recordingEnded()
    }

    do {
        try rec.start()
    } catch {
        logError("Failed to start recording: \(error)")
        TextInjector.endStream()
        state = .idle
        setStatus("🎙")
    }
}

func stopRecording() {
    guard state == .recording else { return }
    logInfo("Recording stopped by user")
    recorder?.stop()
    // recorder.stop() calls onRecordingComplete → recordingEnded(), which clears recorder.
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
        break // Ignore — waiting for pending chunks
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

DispatchQueue.main.async {
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
