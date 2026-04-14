import Foundation

/// User-configurable settings, loaded from ~/.config/whisper-dictation/config.json
struct Config: Codable {
    /// Whisper model name: "tiny", "base", "small", "medium", "large-v3"
    var model: String = "medium"

    /// Language code (ISO 639-1) or "auto" for detection
    var language: String = "auto"

    /// Max seconds between two fn/Globe presses to register as double-tap
    var doubleTapInterval: Double = 0.4

    /// Max recording duration in seconds (safety cutoff)
    var maxRecordSeconds: Int = 120

    /// Seconds of silence before auto-stopping. 0 = disabled (manual stop only).
    var silenceTimeout: Double = 2.0

    /// Play a sound on transcription complete
    var notifySound: Bool = true

    /// Number of threads for whisper.cpp inference (0 = auto)
    var threads: Int = 0

    /// Enable LLM-based post-processing to clean up filler words, grammar, etc.
    var enableLLMCleanup: Bool = false

    /// Model filename for LLM cleanup (relative to models/ dir).
    /// A small model like Qwen2.5-1.5B or Phi-3-mini works well.
    var llmCleanupModel: String = "ggml-smollm2-1.7b-q4_k_m.gguf"

    // ── Computed paths ────────────────────────────────────────

    static let installDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/whisper-dictation")
    }()

    static let configDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/whisper-dictation")
    }()

    static let configFile: URL = {
        configDir.appendingPathComponent("config.json")
    }()

    var modelPath: URL {
        Config.installDir
            .appendingPathComponent("models")
            .appendingPathComponent("ggml-\(model).bin")
    }

    // ── Load / Save ──────────────────────────────────────────

    static func load() -> Config {
        guard FileManager.default.fileExists(atPath: configFile.path),
              let data = try? Data(contentsOf: configFile),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else {
            return Config()
        }
        return config
    }

    func save() throws {
        try FileManager.default.createDirectory(
            at: Config.configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Config.configFile)
    }
}
