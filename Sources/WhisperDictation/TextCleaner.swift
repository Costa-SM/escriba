import Foundation

/// Post-processing for transcribed text.
/// Handles filler removal, basic cleanup, and optionally pipes through a local LLM.
final class TextCleaner {
    private let config: Config
    /// Max seconds to wait for LLM cleanup before falling back to rule-based result.
    private let llmTimeoutSeconds: Double = 15.0

    init(config: Config) {
        self.config = config
    }

    /// Clean transcribed text: remove fillers, normalize whitespace.
    /// If LLM post-processing is enabled, also run through a local model.
    func clean(_ text: String) -> String {
        var result = text

        // Step 1: Rule-based cleanup (always active, fast)
        result = removeFillers(result)
        result = normalizeWhitespace(result)
        result = fixCommonArtifacts(result)

        // Step 2: LLM cleanup (optional, slower but higher quality)
        if config.enableLLMCleanup {
            if let llmResult = llmCleanup(result) {
                result = llmResult
            }
        }

        return result
    }

    // ── Rule-based cleanup ───────────────────────────────────

    private let fillerPatterns: [(pattern: String, options: NSRegularExpression.Options)] = [
        // English fillers
        (#"\b(um|uh|erm|er|ah|like,?)\b"#, [.caseInsensitive]),
        // Repeated words: "the the" → "the"
        (#"\b(\w+)\s+\1\b"#, [.caseInsensitive]),
        // Common Whisper hallucinations on silence
        (#"(?i)\[?(music|silence|blank audio|inaudible|background noise)\]?"#, []),
        (#"(?i)thanks? for watching\.?"#, []),
        (#"(?i)please subscribe\.?"#, []),
        (#"(?i)thank you\.?\s*$"#, []),
    ]

    private func removeFillers(_ text: String) -> String {
        var result = text
        for (pattern, options) in fillerPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                continue
            }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result
    }

    private func normalizeWhitespace(_ text: String) -> String {
        // Collapse multiple spaces
        var result = text.replacingOccurrences(
            of: #"\s{2,}"#, with: " ", options: .regularExpression)
        // Fix space before punctuation
        result = result.replacingOccurrences(
            of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
        // Fix missing space after punctuation
        result = result.replacingOccurrences(
            of: #"([.,!?;:])([A-Za-z])"#, with: "$1 $2", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fixCommonArtifacts(_ text: String) -> String {
        var result = text
        // Whisper sometimes outputs "..." between sentences
        result = result.replacingOccurrences(of: "...", with: ".")
        // Double periods
        result = result.replacingOccurrences(of: "..", with: ".")
        return result
    }

    // ── LLM-based cleanup via llama.cpp CLI ──────────────────

    private func llmCleanup(_ text: String) -> String? {
        let llamaBin = Config.installDir
            .appendingPathComponent("llama.cpp/build/bin/llama-cli").path
        let modelPath = Config.installDir
            .appendingPathComponent("models/\(config.llmCleanupModel)").path

        guard FileManager.default.fileExists(atPath: llamaBin) else {
            print("⚠ LLM cleanup enabled but llama-cli not found at: \(llamaBin)")
            print("  Run ./install.sh --with-llm to install it.")
            return nil
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            print("⚠ LLM cleanup enabled but model not found at: \(modelPath)")
            print("  Run ./install.sh --with-llm to download it.")
            return nil
        }

        let prompt = """
        Fix the following transcribed speech. Remove filler words, fix grammar and \
        punctuation. Keep the original meaning and tone. Only output the corrected \
        text, nothing else.

        Input: \(text)
        Output:
        """

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: llamaBin)
        process.arguments = [
            "--model", modelPath,
            "--prompt", prompt,
            "--n-predict", "512",
            "--temp", "0.1",
            "--repeat-penalty", "1.1",
            "--log-disable",
            "--no-display-prompt",
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()

            // Wait with timeout to prevent hanging indefinitely
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                semaphore.signal()
            }

            let timeout = DispatchTime.now() + .milliseconds(Int(llmTimeoutSeconds * 1000))
            if semaphore.wait(timeout: timeout) == .timedOut {
                print("⚠ LLM cleanup timed out after \(llmTimeoutSeconds)s, killing process")
                process.terminate()
                return nil
            }

            guard process.terminationStatus == 0 else {
                print("⚠ LLM cleanup process exited with status \(process.terminationStatus)")
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                return output
            }
        } catch {
            print("⚠ LLM cleanup failed: \(error)")
        }

        return nil
    }
}
