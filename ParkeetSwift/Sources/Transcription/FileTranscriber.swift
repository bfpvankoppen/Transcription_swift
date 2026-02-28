import Foundation
import AVFoundation
import os

/// Transcribes audio files with chunking and progress reporting.
///
/// Converts input to 16kHz mono WAV, splits into 30s chunks, transcribes sequentially.
final class FileTranscriber {

    private let transcriber: Transcriber
    private var cancelled = false
    private let log = Logger(subsystem: "com.parkeet.app", category: "FileTranscriber")

    private static let chunkDuration: Double = 30.0  // seconds

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
    }

    struct FileInfo {
        let duration: Double
        let sampleRate: Double
        let channels: Int
        let filename: String
    }

    // MARK: - Transcription

    /// Transcribe an audio file with progress callbacks.
    func transcribe(
        fileURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        cancelled = false

        // 1. Convert to 16kHz mono
        log.info("Converting \(fileURL.lastPathComponent) to 16kHz mono")
        let samples = try await loadAudio(from: fileURL)
        let totalSamples = samples.count
        let sampleRate = AudioRecorder.targetSampleRate

        // 2. Split into chunks
        let chunkSize = Int(Self.chunkDuration * sampleRate)
        var chunks: [[Float]] = []
        var offset = 0
        while offset < totalSamples {
            let end = min(offset + chunkSize, totalSamples)
            chunks.append(Array(samples[offset..<end]))
            offset = end
        }

        log.info("Split into \(chunks.count) chunks (\(String(format: "%.1f", Double(totalSamples) / sampleRate))s total)")

        // 3. Transcribe chunks sequentially
        var results: [String] = []
        for (index, chunk) in chunks.enumerated() {
            if cancelled {
                log.info("File transcription cancelled at chunk \(index)/\(chunks.count)")
                break
            }

            let text = await transcriber.transcribe(audio: chunk)
            if !text.isEmpty {
                results.append(text)
            }

            let progress = Double(index + 1) / Double(chunks.count)
            onProgress(progress)
        }

        let fullText = results.joined(separator: " ")
        log.info("File transcription complete: \(fullText.split(separator: " ").count) words")
        return fullText
    }

    func cancel() {
        cancelled = true
    }

    // MARK: - Audio Loading

    /// Load an audio file and convert to Float32 array at 16kHz mono.
    private func loadAudio(from url: URL) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fileFormat = file.processingFormat

        // Read all frames
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount) else {
            throw FileTranscriberError.bufferCreationFailed
        }
        try file.read(into: buffer)

        // Convert to 16kHz mono if needed
        if fileFormat.sampleRate == AudioRecorder.targetSampleRate && fileFormat.channelCount == 1 {
            // Already in target format
            guard let channelData = buffer.floatChannelData else {
                throw FileTranscriberError.noAudioData
            }
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        }

        // Need conversion
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw FileTranscriberError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: fileFormat, to: targetFormat) else {
            throw FileTranscriberError.converterCreationFailed
        }

        let ratio = AudioRecorder.targetSampleRate / fileFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw FileTranscriberError.bufferCreationFailed
        }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            throw error
        }

        guard let channelData = outputBuffer.floatChannelData else {
            throw FileTranscriberError.noAudioData
        }

        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}

enum FileTranscriberError: LocalizedError {
    case bufferCreationFailed
    case noAudioData
    case formatCreationFailed
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .bufferCreationFailed: "Failed to create audio buffer"
        case .noAudioData: "No audio data in file"
        case .formatCreationFailed: "Failed to create target audio format"
        case .converterCreationFailed: "Failed to create audio format converter"
        }
    }
}
