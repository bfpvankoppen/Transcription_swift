# Meeting Mode Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add live meeting transcription — records continuously, transcribes in ~3s chunks with silence-aware boundaries, displays segments in real-time in a dedicated window.

**Architecture:** MeetingTranscriber manages a recording loop that accumulates audio, finds silence-aware chunk boundaries (3s min, 10s ceiling), and transcribes each chunk via the shared Transcriber. MeetingView shows segments scrolling in real-time. AppDelegate adds a "Start Meeting" menu item.

**Tech Stack:** Swift, SwiftUI, AVFoundation (AudioRecorder), sherpa-onnx (Transcriber)

---

### Task 1: Add `extractAccumulatedSamples()` to AudioRecorder

**Files:**
- Modify: `ParkeetSwift/Sources/Parkeet/Audio/AudioRecorder.swift`

**Step 1: Add the extraction method**

Add after the `stop()` method (after line 95):

```swift
/// Extract and clear all accumulated 16kHz samples without stopping recording.
/// Used by meeting mode to pull audio chunks while recording continues.
func extractAccumulatedSamples() -> [Float] {
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
    return samples
}
```

**Step 2: Build to verify it compiles**

Run: `cd ParkeetSwift && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add ParkeetSwift/Sources/Parkeet/Audio/AudioRecorder.swift
git commit -m "feat(audio): add extractAccumulatedSamples for meeting mode chunking"
```

---

### Task 2: Add `.meeting` entry type to HistoryStore

**Files:**
- Modify: `ParkeetSwift/Sources/Parkeet/Model/HistoryStore.swift`

**Step 1: Add the meeting case**

In `HistoryEntry.EntryType` enum (line 102), add `meeting`:

```swift
enum EntryType: String, Codable {
    case hotkey
    case file
    case meeting
}
```

No other changes needed — the existing `HistoryEntry` fields (`text`, `wordCount`, `sourceFilename`) are sufficient.

**Step 2: Build**

Run: `cd ParkeetSwift && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add ParkeetSwift/Sources/Parkeet/Model/HistoryStore.swift
git commit -m "feat(history): add meeting entry type"
```

---

### Task 3: Create MeetingTranscriber

**Files:**
- Create: `ParkeetSwift/Sources/Parkeet/Transcription/MeetingTranscriber.swift`

**Step 1: Write the full MeetingTranscriber**

```swift
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
```

**Step 2: Build**

Run: `cd ParkeetSwift && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add ParkeetSwift/Sources/Parkeet/Transcription/MeetingTranscriber.swift
git commit -m "feat: add MeetingTranscriber with silence-aware chunking"
```

---

### Task 4: Create MeetingView

**Files:**
- Create: `ParkeetSwift/Sources/Parkeet/UI/MeetingView.swift`

**Step 1: Write the full MeetingView**

```swift
import SwiftUI
import AppKit

/// Live meeting transcription window.
///
/// Shows a scrolling transcript during recording, then export options when stopped.
struct MeetingView: View {

    @Environment(AppState.self) private var appState
    @State private var meetingTranscriber: MeetingTranscriber?
    @State private var isRecording = false
    @State private var errorMessage: String?
    @State private var showSavePanel = false
    @State private var saveAsMarkdown = false

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            transcriptArea
            Divider()
            controlBar
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear { startMeeting() }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(pulseOpacity)
                Text("Recording")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
            } else if let mt = meetingTranscriber, !mt.segments.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Meeting ended")
                    .font(.system(size: 13, weight: .medium))
            }

            Spacer()

            if let mt = meetingTranscriber {
                Text(formatDuration(mt.elapsedSeconds))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text("\(mt.totalWordCount) words")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @State private var pulseVisible = true

    private var pulseOpacity: Double {
        // Use TimelineView in the actual pulse circle instead
        1.0
    }

    // MARK: - Transcript Area

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let mt = meetingTranscriber {
                        ForEach(mt.segments) { segment in
                            segmentRow(segment)
                                .id(segment.id)
                        }

                        if isRecording && mt.segments.isEmpty {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Listening…")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 20)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: meetingTranscriber?.segments.count) {
                // Auto-scroll to latest segment
                if let last = meetingTranscriber?.segments.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func segmentRow(_ segment: MeetingSegment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(formatTimestamp(segment.timestamp))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)

            Text(segment.text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        Group {
            if isRecording {
                recordingControls
            } else if let mt = meetingTranscriber, !mt.segments.isEmpty {
                completedControls
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var recordingControls: some View {
        Button(action: stopMeeting) {
            Label("Stop Meeting", systemImage: "stop.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
    }

    private var completedControls: some View {
        HStack(spacing: 12) {
            Button(action: copyAll) {
                Label("Copy All", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)

            Button(action: { saveFile(asMarkdown: false) }) {
                Label("Save .txt", systemImage: "doc.text")
            }
            .buttonStyle(.bordered)

            Button(action: { saveFile(asMarkdown: true) }) {
                Label("Save .md", systemImage: "doc.richtext")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Actions

    private func startMeeting() {
        guard appState.modelLoaded else {
            errorMessage = "Model not loaded yet"
            return
        }

        let mt = MeetingTranscriber(recorder: appState.recorder, transcriber: appState.transcriber)
        self.meetingTranscriber = mt

        do {
            try mt.start()
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopMeeting() {
        meetingTranscriber?.stop()
        isRecording = false

        // Save to history
        if let mt = meetingTranscriber, !mt.segments.isEmpty {
            appState.historyStore.add(entry: HistoryEntry(
                type: .meeting,
                text: mt.plainText,
                wordCount: mt.totalWordCount
            ))
        }
    }

    private func copyAll() {
        guard let mt = meetingTranscriber else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mt.plainText, forType: .string)
    }

    private func saveFile(asMarkdown: Bool) {
        guard let mt = meetingTranscriber else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = asMarkdown ? [.plainText] : [.plainText]
        panel.nameFieldStringValue = asMarkdown
            ? "meeting-transcript.md"
            : "meeting-transcript.txt"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let content = asMarkdown
                ? mt.markdownText(date: mt.segments.first.map { _ in Date() } ?? Date())
                : mt.plainText
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Formatting

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
```

**Step 2: Build**

Run: `cd ParkeetSwift && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add ParkeetSwift/Sources/Parkeet/UI/MeetingView.swift
git commit -m "feat: add MeetingView with live transcript and export"
```

---

### Task 5: Wire up Meeting in AppDelegate

**Files:**
- Modify: `ParkeetSwift/Sources/Parkeet/App/AppDelegate.swift`

**Step 1: Add meetingWindow property**

After line 12 (`private var welcomeWindow: NSWindow?`), add:

```swift
private var meetingWindow: NSWindow?
```

**Step 2: Add "Start Meeting" menu item**

In `setupMenuBar()`, after the "Transcribe File…" menu item (after line 65), add:

```swift
menu.addItem(NSMenuItem(
    title: "Start Meeting…",
    action: #selector(startMeeting),
    keyEquivalent: "m"
))
```

**Step 3: Add the startMeeting action**

After the `openFileTranscription()` method (after line 91), add:

```swift
@objc private func startMeeting() {
    log.info("Opening meeting window")

    // Close existing meeting window if open
    meetingWindow?.close()

    let meetingView = MeetingView()
        .environment(appState)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Parkeet — Meeting"
    window.contentView = NSHostingView(rootView: meetingView)
    window.center()
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 400, height: 300)
    self.meetingWindow = window

    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
}
```

**Step 4: Build**

Run: `cd ParkeetSwift && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 5: Commit**

```bash
git add ParkeetSwift/Sources/Parkeet/App/AppDelegate.swift
git commit -m "feat: add Start Meeting menu item and window management"
```

---

### Task 6: Build, launch, and verify end-to-end

**Step 1: Full build and launch**

Run: `cd ParkeetSwift && bash run.sh`

**Step 2: Test the meeting flow**

1. Click mic icon in menu bar → "Start Meeting…"
2. Meeting window opens, starts recording
3. Speak — segments should appear every ~3 seconds
4. Click "Stop Meeting"
5. Verify: transcript is displayed, word count is correct
6. Test "Copy All" — paste into a text editor
7. Test "Save .txt" — save to Desktop, open and verify
8. Test "Save .md" — save to Desktop, verify timestamps in markdown

**Step 3: Commit all remaining changes**

```bash
git add -A
git commit -m "feat: meeting mode — live transcription with silence-aware chunking"
```
