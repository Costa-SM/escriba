import Foundation
import CWhisper

/// Wraps whisper.cpp C API to transcribe a WAV file.
final class Transcriber {
    private var ctx: OpaquePointer?
    private let config: Config

    init(config: Config) throws {
        self.config = config

        let modelPath = config.modelPath.path
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw TranscriberError.modelNotFound(modelPath)
        }

        var cparams = whisper_context_default_params()
        // Enable CoreML / Metal acceleration on Apple Silicon
        cparams.use_gpu = true

        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw TranscriberError.initFailed
        }
        self.ctx = ctx
    }

    deinit {
        if let ctx = ctx {
            whisper_free(ctx)
        }
    }

    /// Transcribe a 16kHz mono WAV file. Returns the recognized text.
    func transcribe(audioURL: URL) throws -> String {
        guard let ctx = ctx else {
            throw TranscriberError.initFailed
        }

        // Read WAV file as raw PCM samples
        let samples = try loadWAVSamples(url: audioURL)
        guard !samples.isEmpty else {
            return ""
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.single_segment = false
        params.no_timestamps = true

        if config.threads > 0 {
            params.n_threads = Int32(config.threads)
        }

        // Run inference, checking the return code
        let result: Int32
        if config.language != "auto" {
            // whisper_full_params expects a C string that lives for the duration of the call.
            // withCString keeps the pointer valid within its closure scope.
            result = config.language.withCString { langPtr in
                params.language = langPtr
                return samples.withUnsafeBufferPointer { samplesPtr in
                    whisper_full(ctx, params, samplesPtr.baseAddress, Int32(samples.count))
                }
            }
        } else {
            params.language = nil
            params.detect_language = true
            result = samples.withUnsafeBufferPointer { samplesPtr in
                whisper_full(ctx, params, samplesPtr.baseAddress, Int32(samples.count))
            }
        }

        guard result == 0 else {
            throw TranscriberError.transcriptionFailed(Int(result))
        }

        // Collect segments
        let nSegments = whisper_full_n_segments(ctx)
        var text = ""
        for i in 0..<nSegments {
            if let segText = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: segText)
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read a 16kHz mono 16-bit PCM WAV and return Float32 samples normalized to [-1, 1].
    /// Parses the WAV header properly to find the data chunk offset.
    private func loadWAVSamples(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)

        // Minimum: RIFF(4) + size(4) + WAVE(4) + fmt(8+16) + data(8) = 44
        guard data.count >= 44 else {
            throw TranscriberError.invalidAudio
        }

        // Validate RIFF/WAVE header
        let riff = String(data: data[0..<4], encoding: .ascii)
        let wave = String(data: data[8..<12], encoding: .ascii)
        guard riff == "RIFF", wave == "WAVE" else {
            throw TranscriberError.invalidAudio
        }

        // Walk chunks to find the "data" chunk
        var offset = 12
        var dataOffset = -1
        var dataSize = -1

        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<offset+4], encoding: .ascii) ?? ""
            let chunkSize = data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: offset + 4, as: UInt32.self)
            }

            if chunkID == "data" {
                dataOffset = offset + 8
                dataSize = Int(chunkSize)
                break
            }

            // Move to next chunk (chunkID + size field + chunk data)
            offset += 8 + Int(chunkSize)
        }

        guard dataOffset >= 0, dataSize > 0, dataOffset + dataSize <= data.count else {
            throw TranscriberError.invalidAudio
        }

        let pcmData = data[dataOffset..<(dataOffset + dataSize)]
        let sampleCount = pcmData.count / 2 // 16-bit = 2 bytes per sample

        var samples = [Float](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { rawPtr in
            let int16Ptr = rawPtr.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = Float(int16Ptr[i]) / 32768.0
            }
        }

        return samples
    }

    enum TranscriberError: Error, CustomStringConvertible {
        case modelNotFound(String)
        case initFailed
        case invalidAudio
        case transcriptionFailed(Int)

        var description: String {
            switch self {
            case .modelNotFound(let path):
                return "Whisper model not found at: \(path)"
            case .initFailed:
                return "Failed to initialize whisper.cpp context"
            case .invalidAudio:
                return "Invalid or empty audio file"
            case .transcriptionFailed(let code):
                return "Whisper transcription failed with error code: \(code)"
            }
        }
    }
}
