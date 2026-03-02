import Foundation
import AVFoundation
import os

/// Live meeting transcription with silence-aware chunking.
///
/// Records continuously via AudioRecorder. Every ~3 seconds (extended to the
/// nearest silence gap, hard ceiling 10s), extracts a chunk, transcribes it,
/// and appends the result as a MeetingSegment.
@MainActor
@Observable
final class MeetingTranscriber {

    // MARK: - Public State

    private(set) var segments: [MeetingSegment] = []
    private(set) var isRecording = false
    private(set) var elapsedSeconds: Double = 0
    private(set) var totalWordCount: Int = 0

    // MARK: - Dependencies

    private let recorder: AudioRecorder
    private let transcriber: Transcriber

    // MARK: - Internal State

    private var pendingSamples: [Float] = []
    private var pollTimer: Timer?
    private var elapsedTimer: Timer?
    private var meetingStartTime: Date?
    private var transcriptionTask: Task<Void, Never>?
    private var isTranscribingChunk = false

    private let log = Logger(subsystem: "com.parkeet.app", category: "MeetingTranscriber")

    private static let sampleRate: Double = 16000
    private static let minChunkSamples = Int(3.0 * sampleRate)   // 3 seconds
    private static let maxChunkSamples = Int(10.0 * sampleRate)  // 10 seconds
    private static let silenceWindowSamples = Int(0.1 * sampleRate)  // 100ms RMS window

    init(recorder: AudioRecorder, transcriber: Transcriber) {
        self.recorder = recorder
        self.transcriber = transcriber
    }

    // MARK: - Start / Stop

    func start() throws {
        guard !isRecording else { return }

        segments.removeAll()
        pendingSamples.removeAll()
        totalWordCount = 0
        elapsedSeconds = 0
        isTranscribingChunk = false

        try recorder.start()
        meetingStartTime = Date()
        isRecording = true

        log.info("Meeting started")

        // Poll for new audio every 0.5s
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.pollAudio() }
        }

        // Update elapsed time every second
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if let start = self.meetingStartTime {
                    self.elapsedSeconds = Date().timeIntervalSince(start)
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }

        pollTimer?.invalidate()
        pollTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        // Extract any remaining audio and transcribe it
        let finalSamples = recorder.stop()
        pendingSamples.append(contentsOf: finalSamples)

        isRecording = false
        log.info("Meeting stopped, \(self.segments.count) segments, \(self.totalWordCount) words")

        // Transcribe any remaining audio
        if pendingSamples.count > Int(0.5 * Self.sampleRate) {
            let chunk = pendingSamples
            pendingSamples.removeAll()
            transcribeChunk(chunk)
        }
    }

    // MARK: - Audio Polling & Chunking

    private func pollAudio() {
        guard isRecording else { return }

        // Pull new samples from recorder
        let newSamples = recorder.extractAccumulatedSamples()
        if !newSamples.isEmpty {
            pendingSamples.append(contentsOf: newSamples)
        }

        // Check if we have enough for a chunk (>= 3 seconds)
        guard pendingSamples.count >= Self.minChunkSamples else { return }
        guard !isTranscribingChunk else { return }  // One at a time

        // Find silence boundary
        let cutPoint = findSilenceBoundary(in: pendingSamples)
        let chunk = Array(pendingSamples.prefix(cutPoint))
        pendingSamples.removeFirst(cutPoint)

        transcribeChunk(chunk)
    }

    /// Find the best cut point: scan for lowest energy 100ms window between 3s and 10s.
    /// Returns sample index to cut at.
    private func findSilenceBoundary(in samples: [Float]) -> Int {
        let searchStart = Self.minChunkSamples
        let searchEnd = min(samples.count, Self.maxChunkSamples)

        // If we don't have enough to search, cut at whatever we have (up to ceiling)
        guard searchStart < searchEnd else {
            return min(samples.count, Self.maxChunkSamples)
        }

        let windowSize = Self.silenceWindowSamples
        var lowestEnergy: Float = .greatestFiniteMagnitude
        var bestCutPoint = searchStart

        // Slide a 100ms window from 3s to 10s, find the quietest spot
        var i = searchStart
        while i + windowSize <= searchEnd {
            var sum: Float = 0
            for j in i..<(i + windowSize) {
                let s = samples[j]
                sum += s * s
            }
            let rms = sum / Float(windowSize)

            if rms < lowestEnergy {
                lowestEnergy = rms
                bestCutPoint = i + windowSize / 2  // Cut at center of quiet window
            }
            i += windowSize / 2  // Step by 50ms for decent resolution
        }

        return bestCutPoint
    }

    // MARK: - Transcription

    private func transcribeChunk(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        isTranscribingChunk = true

        let timestamp = elapsedSeconds - Double(chunk.count) / Self.sampleRate

        transcriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let text = await self.transcriber.transcribe(audio: chunk)

            await MainActor.run {
                self.isTranscribingChunk = false

                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.log.debug("Empty chunk transcription, skipping")
                    return
                }

                let segment = MeetingSegment(
                    timestamp: max(0, timestamp),
                    text: trimmed
                )
                self.segments.append(segment)
                self.totalWordCount += trimmed.split(separator: " ").count
                self.log.info("Segment at \(String(format: "%.1f", timestamp))s: \(trimmed.prefix(50))…")
            }
        }
    }

    // MARK: - Export

    var plainText: String {
        segments.map(\.text).joined(separator: " ")
    }

    func markdownText(date: Date = Date()) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "d MMM yyyy, HH:mm"
        let dateString = dateFormatter.string(from: date)

        var md = "# Meeting Transcript — \(dateString)\n\n"
        for segment in segments {
            let ts = formatTimestamp(segment.timestamp)
            md += "**[\(ts)]** \(segment.text)\n\n"
        }
        return md
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins >= 60 {
            let hrs = mins / 60
            return String(format: "%d:%02d:%02d", hrs, mins % 60, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - MeetingSegment

struct MeetingSegment: Identifiable {
    let id = UUID()
    let timestamp: TimeInterval
    let text: String
}
