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
    private(set) var isRefining = false
    private(set) var refinementProgress: Double = 0  // 0.0–1.0
    private(set) var elapsedSeconds: Double = 0
    private(set) var totalWordCount: Int = 0
    private(set) var canRefine = false  // True when full audio is available for refinement

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
    private var fullRecordingBuffer: [Float] = []  // Keeps ALL audio for post-stop refinement
    private var windowIndex = 0
    private var lastTranscriptionText: String = ""
    private var pollTimer: Timer?
    private var windowTimer: Timer?
    private var elapsedTimer: Timer?
    private var meetingStartTime: Date?
    private var transcriptionTask: Task<Void, Never>?
    private var refinementTask: Task<Void, Never>?
    private var isTranscribingChunk = false

    private let log = Logger(subsystem: "com.praten.app", category: "MeetingTranscriber")

    init(recorder: AudioRecorder, transcriber: Transcriber) {
        self.recorder = recorder
        self.transcriber = transcriber
    }

    // MARK: - Start / Stop

    func start() throws {
        guard !isRecording else { return }

        segments.removeAll()
        ringBuffer.removeAll()
        fullRecordingBuffer.removeAll()
        totalWordCount = 0
        elapsedSeconds = 0
        windowIndex = 0
        lastTranscriptionText = ""
        isTranscribingChunk = false
        isRefining = false
        refinementProgress = 0
        canRefine = false

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

        // Extract any remaining audio
        let finalSamples = recorder.stop()
        ringBuffer.append(contentsOf: finalSamples)
        fullRecordingBuffer.append(contentsOf: finalSamples)

        isRecording = false
        log.info("Meeting stopped, \(self.segments.count) segments, \(self.totalWordCount) words")

        // Mark that refinement is available (user can choose to trigger it)
        let audioDuration = Double(fullRecordingBuffer.count) / Self.sampleRate
        canRefine = audioDuration > 1.0
        if canRefine {
            log.info("Full recording available for refinement (\(String(format: "%.0f", audioDuration))s)")
        }
    }

    /// User-initiated refinement: transcribes the full recording and replaces windowed segments.
    /// Note: this removes per-segment timestamps since the full transcription is one continuous block.
    func startRefinement() {
        guard canRefine, !isRefining, !fullRecordingBuffer.isEmpty else { return }
        let fullAudio = fullRecordingBuffer
        isRefining = true
        refinementProgress = 0
        canRefine = false
        log.info("User initiated refinement (\(String(format: "%.0f", Double(fullAudio.count) / Self.sampleRate))s of audio)")
        refineWithFullTranscription(fullAudio)
    }

    /// Discard the full recording buffer (user chose not to refine).
    func discardFullRecording() {
        fullRecordingBuffer.removeAll()
        canRefine = false
        log.info("Full recording discarded, keeping windowed segments with timestamps")
    }

    // MARK: - Audio Polling

    private func pollAudio() {
        guard isRecording else { return }

        let newSamples = recorder.extractAccumulatedSamples()
        if !newSamples.isEmpty {
            ringBuffer.append(contentsOf: newSamples)
            fullRecordingBuffer.append(contentsOf: newSamples)
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
    ///
    /// Strategy: We know the overlap ratio from the window config (overlapDuration / windowDuration).
    /// Use this to estimate how many words to skip from the new transcription, then try text matching
    /// to refine the cut point. If text matching fails, fall back to the time-based estimate.
    private func mergeWithOverlap(newText: String, timestamp: TimeInterval, windowIndex idx: Int) {
        let newWords = newText.split(separator: " ").map(String.init)
        guard !newWords.isEmpty else { return }

        if idx == 0 || lastTranscriptionText.isEmpty {
            // First window — append as-is
            let segment = MeetingSegment(timestamp: timestamp, text: newText, windowIndex: idx)
            segments.append(segment)
            totalWordCount += newWords.count
            lastTranscriptionText = newText
            log.info("Window \(idx) (first): \(newText.prefix(60))…")
            return
        }

        let prevWords = lastTranscriptionText.split(separator: " ").map(String.init)

        // Estimate overlap word count from time ratio: overlapDuration / windowDuration
        let overlapRatio = Self.overlapDuration / Self.windowDuration
        let estimatedOverlapWords = Int(Double(newWords.count) * overlapRatio)

        // Try text matching first to find exact cut point
        let textMatchOverlap = findOverlap(suffix: prevWords, prefix: newWords)

        let skipCount: Int
        if textMatchOverlap > 0 {
            // Text matching succeeded — use it and apply correction if needed
            skipCount = textMatchOverlap
            let prevOverlap = prevWords.suffix(textMatchOverlap).joined(separator: " ")
            let newOverlap = newWords.prefix(textMatchOverlap).joined(separator: " ")
            if prevOverlap.lowercased() != newOverlap.lowercased() {
                correctLastSegment(replacingSuffix: prevOverlap, with: newOverlap)
                log.info("Window \(idx): text-match corrected overlap (\(textMatchOverlap) words)")
            }
        } else {
            // Text matching failed — use time-based estimate
            skipCount = estimatedOverlapWords
            log.debug("Window \(idx): no text match, skipping ~\(estimatedOverlapWords) words by time estimate")
        }

        // Append only the novel (non-overlapping) content
        let novelWords = Array(newWords.dropFirst(skipCount))
        if !novelWords.isEmpty {
            let novelText = novelWords.joined(separator: " ")
            let segment = MeetingSegment(timestamp: timestamp, text: novelText, windowIndex: idx)
            segments.append(segment)
            totalWordCount += novelWords.count
            log.info("Window \(idx): +\(novelWords.count) new words (skipped \(skipCount)): \(novelText.prefix(60))…")
        } else {
            log.debug("Window \(idx): no new content beyond overlap")
        }

        lastTranscriptionText = newText
    }

    /// Greedy search for the longest suffix of `suffix` words that matches a prefix of `prefix` words.
    /// Uses normalized (lowercased) comparison. Accepts matches with ≥50% word match and ≥2 matching words.
    private func findOverlap(suffix prevWords: [String], prefix newWords: [String]) -> Int {
        guard prevWords.count >= 2, newWords.count >= 2 else { return 0 }

        let maxOverlap = min(prevWords.count, newWords.count)

        for length in stride(from: maxOverlap, through: 2, by: -1) {
            let suffixSlice = prevWords.suffix(length)
            let prefixSlice = newWords.prefix(length)

            var matchCount = 0
            for (a, b) in zip(suffixSlice, prefixSlice) {
                if a.lowercased() == b.lowercased() {
                    matchCount += 1
                }
            }

            let matchRate = Double(matchCount) / Double(length)
            if matchRate >= 0.5 && matchCount >= 2 {
                log.debug("Overlap found: \(length) words, \(String(format: "%.0f", matchRate * 100))% match")
                return length
            }
        }

        return 0
    }

    /// Walk backwards through segments to find and correct text that was wrong in the overlap region.
    private func correctLastSegment(replacingSuffix oldSuffix: String, with newSuffix: String) {
        for i in stride(from: segments.count - 1, through: 0, by: -1) {
            let segmentText = segments[i].text
            if let range = segmentText.range(of: oldSuffix, options: [.caseInsensitive, .backwards]) {
                let corrected = segmentText.replacingCharacters(in: range, with: newSuffix)
                segments[i].text = corrected
                totalWordCount = segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
                log.info("Corrected segment \(i): '\(segmentText.prefix(40))' → '\(corrected.prefix(40))'")
                return
            }
        }
        log.debug("Could not find segment to correct for suffix: '\(oldSuffix.prefix(40))'")
    }

    // MARK: - Full Recording Refinement

    /// Transcribe the entire meeting audio and replace windowed segments with the authoritative result.
    /// Clears the full recording buffer when done.
    private func refineWithFullTranscription(_ fullAudio: [Float]) {
        let transcriber = self.transcriber
        let audioDuration = Double(fullAudio.count) / Self.sampleRate
        // Estimate processing time: Parakeet runs at ~0.08x RTF on Apple Silicon
        let estimatedProcessingTime = audioDuration * 0.08

        // Progress timer: update estimated progress based on elapsed time
        let progressStart = Date()
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let elapsed = Date().timeIntervalSince(progressStart)
                // Cap at 95% — the last 5% happens when transcription actually completes
                let progress = min(0.95, elapsed / max(1, estimatedProcessingTime))
                self.refinementProgress = progress
            }
        }

        refinementTask = Task.detached(priority: .userInitiated) {
            let fullText = await transcriber.transcribe(audio: fullAudio)

            await MainActor.run { [weak self] in
                guard let self else { return }
                progressTimer.invalidate()

                let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.log.warning("Full transcription returned empty, keeping windowed segments")
                    self.isRefining = false
                    self.refinementProgress = 0
                    self.fullRecordingBuffer.removeAll()
                    return
                }

                self.log.info("Full transcription: \(trimmed.count) chars, replacing \(self.segments.count) windowed segments")

                // Replace all windowed segments with a single authoritative segment
                let fullWords = trimmed.split(separator: " ")
                self.segments = [MeetingSegment(
                    timestamp: 0,
                    text: trimmed,
                    windowIndex: -1  // Indicates full-recording refinement
                )]
                self.totalWordCount = fullWords.count
                self.refinementProgress = 1.0

                self.log.info("Refinement complete: \(fullWords.count) words")
                self.isRefining = false
                self.fullRecordingBuffer.removeAll()
            }
        }
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
