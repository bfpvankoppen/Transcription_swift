import AVFoundation
import AVFAudio
import os

/// Records audio from the default microphone at 16kHz mono with real-time level metering.
///
/// AVAudioEngine captures at hardware sample rate; AVAudioConverter downsamples to 16kHz.
final class AudioRecorder: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var collectedBuffers: [AVAudioPCMBuffer] = []
    private let bufferLock = NSLock()

    /// Current RMS levels for 28 waveform bars, normalized to [0, 1].
    private(set) var currentLevels: [Float] = Array(repeating: 0, count: 28)

    private let log = Logger(subsystem: "com.parkeet.app", category: "AudioRecorder")

    static let targetSampleRate: Double = 16000
    static let barCount = 28

    // MARK: - Recording

    func start() throws {
        // Check microphone permission before attempting to record
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            log.error("Microphone permission not granted (status: \(micStatus.rawValue))")
            throw RecordingError.microphoneNotAuthorized
        }

        collectedBuffers.removeAll()
        currentLevels = Array(repeating: 0, count: Self.barCount)

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        log.info("Hardware audio format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        // Target: 16kHz mono float32 for Parakeet model
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.formatCreationFailed
        }

        guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw RecordingError.converterCreationFailed
        }
        self.converter = conv

        // Install tap at hardware rate, convert in callback
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        try engine.start()
        log.info("Recording started")
    }

    /// Stop recording and return all audio as a single Float32 array at 16kHz.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil

        log.notice("Recording stopped, collected \(self.collectedBuffers.count) buffers")

        // Concatenate all converted buffers into a single array
        bufferLock.lock()
        let buffers = collectedBuffers
        collectedBuffers.removeAll()
        bufferLock.unlock()

        var samples: [Float] = []
        for buf in buffers {
            guard let channelData = buf.floatChannelData else { continue }
            let count = Int(buf.frameLength)
            samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: count))
        }

        // Add tail padding to flush the recognition pipeline
        samples.append(contentsOf: [Float](repeating: 0, count: 3200))

        let duration = Double(samples.count) / Self.targetSampleRate
        // Compute peak amplitude to detect silent/dead mic
        let peak = samples.max() ?? 0
        log.notice("Total audio: \(String(format: "%.1f", duration))s, \(samples.count) samples, peak: \(String(format: "%.4f", peak))")

        return samples
    }

    // MARK: - Buffer Processing

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        // 1. Compute RMS for level metering (28 bars from the raw buffer)
        updateLevels(from: buffer)

        // 2. Convert to 16kHz mono
        guard let converter else { return }

        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let converted = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: frameCapacity
        ) else { return }

        var error: NSError?
        var inputConsumed = false

        converter.convert(to: converted, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            log.error("Audio conversion error: \(error)")
            return
        }

        if converted.frameLength > 0 {
            bufferLock.lock()
            collectedBuffers.append(converted)
            bufferLock.unlock()
        }
    }

    private func updateLevels(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let samples = channelData[0]

        // Split into barCount segments, compute RMS per segment
        let segmentSize = max(frameCount / Self.barCount, 1)
        var newLevels = [Float](repeating: 0, count: Self.barCount)

        for bar in 0..<Self.barCount {
            let start = bar * segmentSize
            let end = min(start + segmentSize, frameCount)
            guard start < end else { continue }

            var sum: Float = 0
            for i in start..<end {
                let s = samples[i]
                sum += s * s
            }
            let rms = sqrtf(sum / Float(end - start))

            // Convert to dB, normalize to [0, 1]
            let db = 20 * log10f(max(rms, 1e-7))
            newLevels[bar] = max(0, (db + 60) / 60)
        }

        // Exponential smoothing
        let smoothing: Float = 0.35
        for i in 0..<Self.barCount {
            currentLevels[i] = currentLevels[i] * (1 - smoothing) + newLevels[i] * smoothing
        }
    }
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case microphoneNotAuthorized
    case formatCreationFailed
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .microphoneNotAuthorized: "Microphone permission not granted. Open System Settings > Privacy & Security > Microphone."
        case .formatCreationFailed: "Failed to create target audio format"
        case .converterCreationFailed: "Failed to create audio converter"
        }
    }
}
