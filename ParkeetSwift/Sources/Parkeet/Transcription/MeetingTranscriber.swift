import Foundation
import AVFoundation
import os

/// Live meeting transcription with sliding window overlap.
///
/// Records continuously via AudioRecorder. Every 15 seconds, transcribes the
/// last 25 seconds of audio (10s overlap with previous window). Overlapping
/// text is deduplicated and corrections are applied when the overlap reveals
/// a previous transcription was wrong.
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

    // MARK: - Sliding Window Constants

    private static let sampleRate: Double = 16000
    private static let windowInterval: Double = 15.0     // Transcribe every 15s
    private static let windowDuration: Double = 25.0     // Each window covers 25s
    private static let overlapDuration: Double = 10.0    // 10s overlap with previous
    private static let maxRingBufferSeconds: Double = 60.0  // Safety cap

    // MARK: - Internal State

    private var ringBuffer: [Float] = []
    private var windowIndex = 0
    private var lastTranscriptionText: String = ""
    private var pollTimer: Timer?
    private var windowTimer: Timer?
    private var elapsedTimer: Timer?
    private var meetingStartTime: Date?
    private var transcriptionTask: Task<Void, Never>?
    private var isTranscribingChunk = false

    private let log = Logger(subsystem: "com.parkeet.app", category: "MeetingTranscriber")

    init(recorder: AudioRecorder, transcriber: Transcriber) {
        self.recorder = recorder
        self.transcriber = transcriber
    }

    // MARK: - Start / Stop

    func start() throws {
        guard !isRecording else { return }

        segments.removeAll()
        ringBuffer.removeAll()
        totalWordCount = 0
        elapsedSeconds = 0
        windowIndex = 0
        lastTranscriptionText = ""
        isTranscribingChunk = false

        try recorder.start()
        meetingStartTime = Date()
        isRecording = true

        log.info("Meeting started (sliding window: \(Self.windowDuration)s window, \(Self.windowInterval)s interval, \(Self.overlapDuration)s overlap)")

        // Poll for new audio every 0.5s — accumulates into ring buffer
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.pollAudio() }
        }

        // Transcribe window every 15s
        windowTimer = Timer.scheduledTimer(withTimeInterval: Self.windowInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.transcribeWindow() }
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
        windowTimer?.invalidate()
        windowTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        // Extract any remaining audio into ring buffer
        let finalSamples = recorder.stop()
        ringBuffer.append(contentsOf: finalSamples)

        isRecording = false
        log.info("Meeting stopped, \(self.segments.count) segments, \(self.totalWordCount) words")

        // Transcribe remaining ring buffer if there's enough audio (>0.5s)
        let minSamples = Int(0.5 * Self.sampleRate)
        if ringBuffer.count > minSamples {
            let chunk: [Float]
            let windowSamples = Int(Self.windowDuration * Self.sampleRate)
            if ringBuffer.count > windowSamples {
                chunk = Array(ringBuffer.suffix(windowSamples))
            } else {
                chunk = ringBuffer
            }
            let idx = windowIndex
            windowIndex += 1
            transcribeChunk(chunk, windowIndex: idx)
        }
    }

    // MARK: - Audio Polling

    private func pollAudio() {
        guard isRecording else { return }

        let newSamples = recorder.extractAccumulatedSamples()
        if !newSamples.isEmpty {
            ringBuffer.append(contentsOf: newSamples)
        }

        // Trim ring buffer to safety cap
        let maxSamples = Int(Self.maxRingBufferSeconds * Self.sampleRate)
        if ringBuffer.count > maxSamples {
            let excess = ringBuffer.count - maxSamples
            ringBuffer.removeFirst(excess)
            log.debug("Ring buffer trimmed, removed \(excess) samples")
        }
    }

    // MARK: - Sliding Window Transcription

    private func transcribeWindow() {
        guard isRecording else { return }
        guard !isTranscribingChunk else {
            log.debug("Skipping window — previous transcription still in progress")
            return
        }

        let windowSamples = Int(Self.windowDuration * Self.sampleRate)
        let minSamples = Int(2.0 * Self.sampleRate)  // Need at least 2s

        guard self.ringBuffer.count >= minSamples else {
            log.debug("Not enough audio for window (\(self.ringBuffer.count) samples, need \(minSamples))")
            return
        }

        // Extract last windowDuration seconds (or whatever's available)
        let chunk: [Float]
        if self.ringBuffer.count >= windowSamples {
            chunk = Array(self.ringBuffer.suffix(windowSamples))
        } else {
            chunk = self.ringBuffer
        }

        let idx = windowIndex
        windowIndex += 1

        log.info("Window \(idx): transcribing \(String(format: "%.1f", Double(chunk.count) / Self.sampleRate))s of audio")
        transcribeChunk(chunk, windowIndex: idx)
    }

    // MARK: - Transcription

    private func transcribeChunk(_ chunk: [Float], windowIndex idx: Int) {
        guard !chunk.isEmpty else { return }
        isTranscribingChunk = true

        let timestamp = elapsedSeconds - Double(chunk.count) / Self.sampleRate
        let transcriber = self.transcriber

        transcriptionTask = Task.detached(priority: .userInitiated) {
            let text = await transcriber.transcribe(audio: chunk)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isTranscribingChunk = false

                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.log.debug("Empty transcription for window \(idx), skipping")
                    return
                }

                self.mergeWithOverlap(newText: trimmed, timestamp: max(0, timestamp), windowIndex: idx)
            }
        }
    }

    // MARK: - Overlap Deduplication

    /// Merges new transcription text with previous output, deduplicating overlapping content.
    private func mergeWithOverlap(newText: String, timestamp: TimeInterval, windowIndex idx: Int) {
        if idx == 0 || lastTranscriptionText.isEmpty {
            // First window — append as-is
            let segment = MeetingSegment(timestamp: timestamp, text: newText, windowIndex: idx)
            segments.append(segment)
            totalWordCount += newText.split(separator: " ").count
            lastTranscriptionText = newText
            log.info("Window \(idx) (first): \(newText.prefix(60))…")
            return
        }

        let prevWords = lastTranscriptionText.split(separator: " ").map(String.init)
        let newWords = newText.split(separator: " ").map(String.init)

        let overlapCount = findOverlap(suffix: prevWords, prefix: newWords)

        if overlapCount > 0 {
            // Check if the overlap text differs (correction needed)
            let prevOverlap = prevWords.suffix(overlapCount).joined(separator: " ")
            let newOverlap = newWords.prefix(overlapCount).joined(separator: " ")

            if prevOverlap.lowercased() != newOverlap.lowercased() {
                log.info("Window \(idx): correcting overlap — '\(prevOverlap.prefix(40))' → '\(newOverlap.prefix(40))'")
                correctLastSegment(replacingSuffix: prevOverlap, with: newOverlap)
            } else {
                log.debug("Window \(idx): overlap matched (\(overlapCount) words)")
            }

            // Append non-overlapping content
            let novelWords = newWords.dropFirst(overlapCount)
            if !novelWords.isEmpty {
                let novelText = novelWords.joined(separator: " ")
                let segment = MeetingSegment(timestamp: timestamp, text: novelText, windowIndex: idx)
                segments.append(segment)
                totalWordCount += novelWords.count
                log.info("Window \(idx): +\(novelWords.count) new words: \(novelText.prefix(60))…")
            } else {
                log.debug("Window \(idx): no new content beyond overlap")
            }
        } else {
            // No overlap found — append entire text as new segment
            let segment = MeetingSegment(timestamp: timestamp, text: newText, windowIndex: idx)
            segments.append(segment)
            totalWordCount += newWords.count
            log.info("Window \(idx) (no overlap): \(newText.prefix(60))…")
        }

        lastTranscriptionText = newText
    }

    /// Greedy search for the longest suffix of `suffix` words that matches a prefix of `prefix` words.
    /// Uses normalized (lowercased) comparison. Requires at least 3 matching words and 60% match rate.
    private func findOverlap(suffix prevWords: [String], prefix newWords: [String]) -> Int {
        guard prevWords.count >= 3, newWords.count >= 3 else { return 0 }

        // Maximum possible overlap is the smaller of the two arrays
        let maxOverlap = min(prevWords.count, newWords.count)
        var bestOverlap = 0

        // Try overlap lengths from largest to smallest, take the first good one
        for length in stride(from: maxOverlap, through: 3, by: -1) {
            let suffixSlice = prevWords.suffix(length)
            let prefixSlice = newWords.prefix(length)

            var matchCount = 0
            for (a, b) in zip(suffixSlice, prefixSlice) {
                if a.lowercased() == b.lowercased() {
                    matchCount += 1
                }
            }

            let matchRate = Double(matchCount) / Double(length)
            if matchRate >= 0.6 && matchCount >= 3 {
                bestOverlap = length
                log.debug("Overlap found: \(length) words, \(String(format: "%.0f", matchRate * 100))% match")
                break
            }
        }

        return bestOverlap
    }

    /// Walk backwards through segments to find and correct text that was wrong in the overlap region.
    private func correctLastSegment(replacingSuffix oldSuffix: String, with newSuffix: String) {
        // Walk backwards to find the segment containing the old suffix
        for i in stride(from: segments.count - 1, through: 0, by: -1) {
            let segmentText = segments[i].text
            // Check if this segment ends with (or contains) the old suffix
            if let range = segmentText.range(of: oldSuffix, options: [.caseInsensitive, .backwards]) {
                let corrected = segmentText.replacingCharacters(in: range, with: newSuffix)
                segments[i].text = corrected

                // Recalculate total word count
                totalWordCount = segments.reduce(0) { $0 + $1.text.split(separator: " ").count }

                log.info("Corrected segment \(i): '\(segmentText.prefix(40))' → '\(corrected.prefix(40))'")
                return
            }
        }

        log.debug("Could not find segment to correct for suffix: '\(oldSuffix.prefix(40))'")
    }

    // MARK: - Export

    var plainText: String {
        segments.map { segment in
            "[\(formatTimestamp(segment.timestamp))] \(segment.text)"
        }.joined(separator: "\n")
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
    var text: String
    let windowIndex: Int
}
