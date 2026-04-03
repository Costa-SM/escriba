import AVFoundation
import Foundation

/// Records audio from the default input device to a temp WAV file.
/// Whisper expects 16kHz mono 16-bit PCM.
final class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var silenceTimer: Timer?
    private var maxTimer: Timer?
    private let config: Config

    /// Called when recording stops (silence timeout, max duration, or manual).
    var onRecordingComplete: ((URL?) -> Void)?

    // Silence detection state
    private var silentSamples: Int = 0
    private let silenceThresholdRMS: Float = 0.01

    init(config: Config) {
        self.config = config
    }

    /// Start recording. Returns immediately; audio is captured in the background.
    func start() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target format: 16kHz mono Float32 (we'll convert to 16-bit PCM on write)
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatError
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            throw RecorderError.converterError
        }

        // Output file in 16-bit PCM WAV for whisper.cpp
        guard let wavFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw RecorderError.formatError
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-dictation-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: wavFormat.settings)

        self.outputURL = url
        self.audioFile = file
        self.audioEngine = engine
        self.silentSamples = 0

        let silenceTimeoutSamples = Int(16000 * config.silenceTimeout)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self = self else { return }

            // Convert to 16kHz mono
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000 / inputFormat.sampleRate
            )
            guard frameCount > 0,
                  let convertedBuffer = AVAudioPCMBuffer(
                      pcmFormat: recordingFormat, frameCapacity: frameCount)
            else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil else { return }

            // Write to file
            try? self.audioFile?.write(from: convertedBuffer)

            // Silence detection
            if self.config.silenceTimeout > 0 {
                let rms = self.computeRMS(buffer: convertedBuffer)
                if rms < self.silenceThresholdRMS {
                    self.silentSamples += Int(convertedBuffer.frameLength)
                    if self.silentSamples >= silenceTimeoutSamples {
                        DispatchQueue.main.async { self.stop() }
                    }
                } else {
                    self.silentSamples = 0
                }
            }
        }

        try engine.start()

        // Safety timeout
        if config.maxRecordSeconds > 0 {
            maxTimer = Timer.scheduledTimer(
                withTimeInterval: TimeInterval(config.maxRecordSeconds),
                repeats: false
            ) { [weak self] _ in
                self?.stop()
            }
        }
    }

    /// Stop recording and deliver the audio file.
    func stop() {
        maxTimer?.invalidate()
        maxTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil

        onRecordingComplete?(outputURL)
        outputURL = nil
    }

    private func computeRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        let data = channelData[0]
        var sumSquares: Float = 0
        for i in 0..<count {
            sumSquares += data[i] * data[i]
        }
        return sqrtf(sumSquares / Float(count))
    }

    enum RecorderError: Error {
        case formatError
        case converterError
    }
}
