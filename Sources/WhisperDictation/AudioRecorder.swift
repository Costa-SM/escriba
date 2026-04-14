import AVFoundation
import Foundation

/// Records audio from the default input device, splitting output into phrase-sized chunks.
///
/// When a short pause is detected (`chunkSilenceThreshold`) the current audio is flushed
/// via `onChunkReady` and a new chunk starts — without stopping the engine. This lets the
/// caller begin transcribing the first phrase while the user is still speaking the next one.
/// When a longer pause (`config.silenceTimeout`) or manual stop is detected, the final
/// chunk is flushed and `onRecordingComplete` fires.
final class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var chunkURL: URL?
    private var wavFormat: AVAudioFormat?
    private var maxTimer: Timer?
    private let config: Config

    /// Called on the main thread each time a phrase-sized chunk is ready.
    var onChunkReady: ((URL) -> Void)?

    /// Called on the main thread when the session ends (no more chunks will arrive).
    var onRecordingComplete: (() -> Void)?

    // Silence tracking
    private var chunkSilentFrames = 0   // resets when a chunk is flushed or speech resumes
    private var sessionSilentFrames = 0 // resets only when speech resumes
    private var currentChunkHasAudio = false
    private var stopped = false

    // Time-based flush with grace period for word-boundary detection
    private var lastFlushTime = Date()
    private var seekingSilence = false        // in grace period, waiting for a micro-silence
    private var seekingSilenceStart = Date()

    private let silenceThresholdRMS: Float = 0.01
    /// Slightly higher threshold to catch brief dips between words.
    private let microSilenceRMS: Float = 0.015
    /// Start looking for a word boundary after this many seconds.
    private let chunkSoftDeadline: TimeInterval = 2.5
    /// Force flush if no silence found within this grace window.
    private let chunkGracePeriod: TimeInterval = 0.3

    init(config: Config) {
        self.config = config
    }

    /// Start recording. Returns immediately; audio is captured on AVAudioEngine's thread.
    func start() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else { throw RecorderError.formatError }

        guard let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            throw RecorderError.converterError
        }

        guard let wf = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else { throw RecorderError.formatError }

        self.wavFormat = wf
        self.audioEngine = engine
        self.stopped = false

        try openNewChunk()

        // Phrase-boundary pause: shorter than session end so we can pipeline.
        // For the default silenceTimeout of 2.0 s this gives a 1.0 s chunk boundary.
        let chunkThresholdFrames = Int(16000.0 * max(0.4, config.silenceTimeout * 0.5))
        let sessionThresholdFrames = config.silenceTimeout > 0
            ? Int(16000.0 * config.silenceTimeout) : Int.max

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self, !self.stopped else { return }

            // Downsample to 16 kHz mono
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000.0 / inputFormat.sampleRate
            )
            guard frameCount > 0,
                  let converted = AVAudioPCMBuffer(pcmFormat: recordingFormat,
                                                   frameCapacity: frameCount)
            else { return }

            var err: NSError?
            let status = converter.convert(to: converted, error: &err) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, err == nil else { return }

            try? self.audioFile?.write(from: converted)

            let rms = self.computeRMS(buffer: converted)
            let frames = Int(converted.frameLength)

            // Time-based flush with grace period: wait for a micro-silence between words
            // to avoid cutting mid-syllable. Soft deadline at 2.5 s, hard limit at 2.8 s.
            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastFlushTime)

            if self.seekingSilence {
                let graceElapsed = now.timeIntervalSince(self.seekingSilenceStart)
                if rms < self.microSilenceRMS || graceElapsed >= self.chunkGracePeriod {
                    self.seekingSilence = false
                    self.flushCurrentChunk()
                }
            } else if self.currentChunkHasAudio && elapsed >= self.chunkSoftDeadline {
                if rms < self.microSilenceRMS {
                    self.flushCurrentChunk()
                } else {
                    self.seekingSilence = true
                    self.seekingSilenceStart = now
                }
            }

            if rms < self.silenceThresholdRMS {
                self.chunkSilentFrames   += frames
                self.sessionSilentFrames += frames

                // Flush phrase chunk on short pause (if it contains speech)
                if self.currentChunkHasAudio && self.chunkSilentFrames >= chunkThresholdFrames {
                    self.flushCurrentChunk()
                }

                // End session on long pause
                if self.sessionSilentFrames >= sessionThresholdFrames {
                    DispatchQueue.main.async { self.stop() }
                }
            } else {
                self.chunkSilentFrames   = 0
                self.sessionSilentFrames = 0
                self.currentChunkHasAudio = true
            }
        }

        try engine.start()

        if config.maxRecordSeconds > 0 {
            maxTimer = Timer.scheduledTimer(
                withTimeInterval: TimeInterval(config.maxRecordSeconds),
                repeats: false
            ) { [weak self] _ in self?.stop() }
        }
    }

    /// Stop recording. Safe to call multiple times.
    func stop() {
        guard !stopped else { return }
        stopped = true

        maxTimer?.invalidate()
        maxTimer = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // Flush any speech that hasn't been emitted yet
        if currentChunkHasAudio, let url = chunkURL {
            audioFile = nil
            chunkURL = nil
            currentChunkHasAudio = false
            onChunkReady?(url)
        } else {
            if let url = chunkURL { try? FileManager.default.removeItem(at: url) }
            audioFile = nil
            chunkURL = nil
        }

        onRecordingComplete?()
    }

    // ── Internals ─────────────────────────────────────────────────────────────

    private func flushCurrentChunk() {
        guard let url = chunkURL else { return }
        audioFile = nil
        chunkURL = nil
        currentChunkHasAudio = false
        chunkSilentFrames = 0
        seekingSilence = false
        lastFlushTime = Date()

        let flushedURL = url
        DispatchQueue.main.async { self.onChunkReady?(flushedURL) }

        // Start a fresh file for the next phrase
        try? openNewChunk()
    }

    private func openNewChunk() throws {
        guard let fmt = wavFormat else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("escriba-chunk-\(UUID().uuidString).wav")
        audioFile = try AVAudioFile(forWriting: url, settings: fmt.settings)
        chunkURL = url
        currentChunkHasAudio = false
    }

    private func computeRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        let data = channelData[0]
        var sumSquares: Float = 0
        for i in 0..<count { sumSquares += data[i] * data[i] }
        return sqrtf(sumSquares / Float(count))
    }

    enum RecorderError: Error {
        case formatError
        case converterError
    }
}
