# Escriba

A lightweight, open-source dictation tool for macOS. Double-tap the **fn/Globe (🌐)** key to dictate — text appears at your cursor with proper punctuation, in any language.

Built on [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for fast, local, on-device transcription. No cloud. No subscription. No telemetry.

## Features

- **System-wide dictation** — works in any app, activated by double-tapping fn/Globe (🌐)
- **Multi-language** — supports 99+ languages with automatic detection, or pin a specific language for better accuracy
- **Proper punctuation** — Whisper produces naturally punctuated text out of the box
- **Filler removal** — strips "um", "uh", "like" and other verbal fillers automatically
- **Optional LLM cleanup** — post-process transcriptions with a local language model for grammar and clarity
- **Runs locally** — all processing happens on your Mac using Metal GPU acceleration
- **Animated menu bar** — icon animates while recording (⏺/🔴) and transcribing (⌛/⏳), returns to 🎙 when idle
- **Audio cues** — plays a sound when recording starts and when the result is pasted
- **Auto-permission prompts** — requests Accessibility and Microphone access on first launch; no manual setup required
- **Configurable** — model size, language, silence timeout, hotkey timing, all in a single JSON file

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (M1+) recommended; Intel Macs work but slower
- Xcode Command Line Tools (`xcode-select --install`)
- CMake (`brew install cmake`)
- ~1.5 GB disk for the medium Whisper model

## Install

```bash
git clone https://github.com/Costa-SM/escriba.git
cd escriba
./install.sh
```

This will:
1. Clone and build whisper.cpp with Metal acceleration
2. Download the Whisper medium model (~1.5 GB)
3. Compile the Swift binary and install it as an `.app` bundle
4. Install a launchd agent so it starts automatically on login

### With LLM text cleanup

To also install local LLM-based post-processing (fixes grammar, removes fillers more aggressively):

```bash
./install.sh --with-llm
```

This additionally builds llama.cpp and downloads SmolLM2 1.7B (~1 GB).

## Usage

After installation, double-tap the **fn/Globe (🌐)** key to start dictating. Speak naturally — Escriba will:

1. Record until you pause (silence detection) or double-tap fn/Globe again to stop early
2. Transcribe your speech locally using Whisper
3. Clean up the text (remove fillers, fix artifacts)
4. Paste the result at your cursor

The menu bar icon shows the current state: 🎙 idle, ⏺/🔴 recording, ⌛/⏳ transcribing.

### Grant permissions on first launch

On first launch, Escriba will automatically prompt for the two permissions it needs:

- **Accessibility** — required to listen for the fn/Globe hotkey and to paste text
- **Microphone** — required to record audio

A system dialog will appear for each. If you miss them, click the ⚠️ icon in the menu bar and select **Grant Accessibility Permission…**, or go to **System Settings → Privacy & Security** directly.

### Disable system dictation shortcut

macOS also uses double-tap fn to trigger its built-in Dictation. To avoid both firing at once, change or disable that shortcut:

**System Settings → Keyboard → Dictation → Keyboard Shortcut** → set to something other than fn (🌐).

### Verifying it's running

Check the menu bar for the 🎙 icon. If it's missing, check the logs:

```bash
# Startup and runtime logs
cat ~/.local/share/whisper-dictation/stderr.log

# Is the daemon running?
launchctl print gui/$(id -u)/com.whisper-dictation.agent | grep "state ="
```

## Configuration

Edit `~/.config/whisper-dictation/config.json`:

```json
{
  "model": "medium",
  "language": "auto",
  "doubleTapInterval": 0.4,
  "maxRecordSeconds": 120,
  "silenceTimeout": 2.0,
  "notifySound": true,
  "threads": 0,
  "enableLLMCleanup": false,
  "llmCleanupModel": "ggml-smollm2-1.7b-q4_k_m.gguf"
}
```

| Key | Description | Default |
|---|---|---|
| `model` | Whisper model: `tiny`, `base`, `small`, `medium`, `large-v3` | `medium` |
| `language` | ISO 639-1 code or `auto` | `auto` |
| `doubleTapInterval` | Max seconds between fn/Globe presses for double-tap | `0.4` |
| `maxRecordSeconds` | Safety cutoff for recording duration | `120` |
| `silenceTimeout` | Seconds of silence before auto-stop (0 = manual only) | `2.0` |
| `notifySound` | Play sounds on recording start and transcription complete | `true` |
| `threads` | Whisper inference threads (0 = auto) | `0` |
| `enableLLMCleanup` | Run transcriptions through a local LLM for cleanup | `false` |
| `llmCleanupModel` | GGUF model filename in the models directory | `ggml-smollm2-1.7b-q4_k_m.gguf` |

Changes take effect after restarting the daemon:

```bash
launchctl kickstart -k gui/$(id -u)/com.whisper-dictation.agent
```

## Switching models

```bash
# Download the model
curl -L -o ~/.local/share/whisper-dictation/models/ggml-large-v3.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin

# Edit ~/.config/whisper-dictation/config.json → "model": "large-v3"

# Restart
launchctl kickstart -k gui/$(id -u)/com.whisper-dictation.agent
```

## Uninstall

```bash
./uninstall.sh
```

Removes the binary, whisper.cpp, models, and the launchd agent. Your config at `~/.config/whisper-dictation/` is preserved.

## Architecture

Escriba is a single Swift binary with no GUI framework dependencies beyond AppKit (for the menu bar icon and clipboard). It links directly against `libwhisper` from whisper.cpp. The binary runs inside an `.app` bundle at `~/.local/share/escriba/Escriba.app/` so that macOS TCC grants Accessibility by bundle ID rather than binary hash, and so the bundle is visible to Spotlight and Raycast.

```
Sources/WhisperDictation/
├── main.swift           # Entry point, state machine, app lifecycle
├── Config.swift         # JSON config loading/saving
├── HotkeyListener.swift # CGEvent tap for double-tap fn/Globe detection
├── AudioRecorder.swift  # AVAudioEngine-based 16kHz mono recording
├── Transcriber.swift    # whisper.cpp C API wrapper
├── TextCleaner.swift    # Filler removal + optional LLM post-processing
└── TextInjector.swift   # Clipboard-based text injection at cursor

Sources/CWhisper/
├── module.modulemap     # Swift ↔ C bridge for whisper.h
└── shim.h
```

## License

GPL-3.0. See [LICENSE](LICENSE).
