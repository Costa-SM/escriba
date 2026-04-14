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
        cparams.use_gpu = true

        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw TranscriberError.initFailed
        }
        self.ctx = ctx
    }

    deinit {
        if let ctx = ctx { whisper_free(ctx) }
    }

    // ── Segment callback box ──────────────────────────────────────────────────
    // Heap-allocated so a stable pointer can be passed through the C user_data field.

    private final class SegmentCallbackBox {
        let fn: (String) -> Void
        init(_ fn: @escaping (String) -> Void) { self.fn = fn }
    }

    // ── Transcription ─────────────────────────────────────────────────────────

    /// Transcribe a 16kHz mono WAV file.
    ///
    /// - Parameter onSegment: If provided, called once per segment as whisper
    ///   produces it (streaming mode). The return value will be an empty string
    ///   since all text is delivered via the callback.
    ///   If nil, all segments are collected and returned as a single string.
    func transcribe(audioURL: URL, onSegment: ((String) -> Void)? = nil) throws -> String {
        guard let ctx = ctx else { throw TranscriberError.initFailed }

        let samples = try loadWAVSamples(url: audioURL)
        guard !samples.isEmpty else { return "" }

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

        // Wire up the streaming callback when requested.
        // `box` is kept alive by the local variable through the whisper_full call.
        var box: SegmentCallbackBox? = nil
        if let onSeg = onSegment {
            let b = SegmentCallbackBox(onSeg)
            box = b
            params.new_segment_callback = { ctx, _, nNew, userData in
                guard let ctx, let userData else { return }
                let b = Unmanaged<SegmentCallbackBox>.fromOpaque(userData).takeUnretainedValue()
                let total = whisper_full_n_segments(ctx)
                let start = max(0, total - nNew)
                for i in start..<total {
                    if let cStr = whisper_full_get_segment_text(ctx, i) {
                        b.fn(String(cString: cStr))
                    }
                }
            }
            params.new_segment_callback_user_data = Unmanaged.passUnretained(b).toOpaque()
        }

        // Run inference
        let result: Int32
        if config.language != "auto" {
            result = config.language.withCString { langPtr in
                params.language = langPtr
                return samples.withUnsafeBufferPointer { ptr in
                    whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
                }
            }
        } else {
            // Passing "auto" lets whisper detect language then continue to transcribe.
            // (detect_language=true would stop after detection and return 0 segments.)
            result = "auto".withCString { langPtr in
                params.language = langPtr
                return samples.withUnsafeBufferPointer { ptr in
                    whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
                }
            }
        }

        // Keep box alive until whisper_full returns.
        withExtendedLifetime(box) {}

        guard result == 0 else { throw TranscriberError.transcriptionFailed(Int(result)) }

        // Streaming: all segments were already delivered via the callback.
        if onSegment != nil { return "" }

        // Non-streaming: collect all segments into one string.
        let nSegments = whisper_full_n_segments(ctx)
        var text = ""
        for i in 0..<nSegments {
            if let segText = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: segText)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ── WAV loader ────────────────────────────────────────────────────────────

    /// Read a 16kHz mono 16-bit PCM WAV and return Float32 samples normalized to [-1, 1].
    private func loadWAVSamples(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)

        guard data.count >= 44 else { throw TranscriberError.invalidAudio }

        let riff = String(data: data[0..<4], encoding: .ascii)
        let wave = String(data: data[8..<12], encoding: .ascii)
        guard riff == "RIFF", wave == "WAVE" else { throw TranscriberError.invalidAudio }

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
            offset += 8 + Int(chunkSize)
        }

        guard dataOffset >= 0, dataSize > 0, dataOffset + dataSize <= data.count else {
            throw TranscriberError.invalidAudio
        }

        let pcmData = data[dataOffset..<(dataOffset + dataSize)]
        let sampleCount = pcmData.count / 2

        var samples = [Float](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { rawPtr in
            let int16Ptr = rawPtr.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = Float(int16Ptr[i]) / 32768.0
            }
        }
        return samples
    }

    // ── Errors ────────────────────────────────────────────────────────────────

    enum TranscriberError: Error, CustomStringConvertible {
        case modelNotFound(String)
        case initFailed
        case invalidAudio
        case transcriptionFailed(Int)

        var description: String {
            switch self {
            case .modelNotFound(let path): return "Whisper model not found at: \(path)"
            case .initFailed:             return "Failed to initialize whisper.cpp context"
            case .invalidAudio:           return "Invalid or empty audio file"
            case .transcriptionFailed(let code): return "Whisper transcription failed with error code: \(code)"
            }
        }
    }
}
