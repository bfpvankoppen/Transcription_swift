# Meeting Mode — Live Transcription

## Summary

A new "Start Meeting" menu bar action opens a dedicated window and begins continuous recording. Audio is transcribed in near-real-time chunks (~3 seconds), with each segment appearing in the window as it completes. When the user stops the meeting, they can copy, save as .txt, or save as .md with timestamps.

## Chunk Strategy

- **Minimum chunk duration:** 3 seconds
- **Boundary detection:** After 3s, continue recording until the first low-energy point (silence gap between words)
- **Hard ceiling:** 10 seconds — if no silence found, cut at 10s as fallback
- **Silence detection:** Scan audio energy (RMS) in 100ms windows, find the quietest point after the 3s mark
- **No overlap needed** — silence-aware boundaries naturally land between words

## Data Model

```swift
struct MeetingSegment: Identifiable {
    let id = UUID()
    let timestamp: TimeInterval  // seconds since meeting start
    let text: String
}
```

## Architecture

### MeetingTranscriber

Manages the recording loop, chunk extraction, and transcription pipeline.

- Uses existing `AudioRecorder` for mic capture (16kHz mono)
- Adds chunk extraction: pull latest audio buffer, find silence boundary, transcribe
- Runs a timer loop: wait 3s, scan for silence, extract chunk, transcribe on background thread
- Accumulates `[MeetingSegment]` with timestamps
- Exposes `@Observable` state for the UI

### MeetingView (SwiftUI)

Dedicated window with three states:

**Recording state:**
- Status bar: pulsing red dot, elapsed time, word count
- Scrolling transcript with timestamps on the left (auto-scrolls to bottom)
- Latest segment shows a subtle animation as it appears
- Red "Stop Meeting" button at bottom

**Completed state:**
- Status bar: "Meeting ended — HH:MM:SS — N words"
- Transcript remains scrollable and selectable
- Three export buttons: Copy All, Save as .txt, Save as .md
- Saved to History automatically

### Export Formats

**Copy All / .txt:** Segments joined with spaces, plain text.

**Markdown (.md):**
```
# Meeting Transcript — 2 Mar 2026, 14:30

**[00:00]** Hello everyone, welcome to the meeting today.

**[00:03]** We're going to discuss the Q4 roadmap and priorities.

**[00:07]** First item on the agenda is the new feature rollout.
```

## Files to Create

- `ParkeetSwift/Sources/Parkeet/Transcription/MeetingTranscriber.swift`
- `ParkeetSwift/Sources/Parkeet/UI/MeetingView.swift`

## Files to Modify

- `AppDelegate.swift` — add "Start Meeting" / "Stop Meeting" menu item, manage meeting window
- `AudioRecorder.swift` — add method to extract latest chunk buffer (flush and return samples since last extraction)
- `HistoryStore.swift` — support `.meeting` source type for history entries

## UI Layout

```
+-------------------------------------------+
|  * Recording    00:04:32    247 words      |  <- status bar
+-------------------------------------------+
|  00:00  Hello everyone, welcome to the     |
|         meeting today.                     |
|  00:03  We're going to discuss the Q4      |
|         roadmap and priorities.            |
|  00:07  First item on the agenda is        |
|         the new feature rollout.           |
|                                 v scroll   |
+-------------------------------------------+
|           [ Stop Meeting ]                 |  <- red button
+-------------------------------------------+
```

After stopping:

```
+-------------------------------------------+
|  Meeting ended  00:04:32    247 words      |
+-------------------------------------------+
|  (same transcript, selectable)             |
+-------------------------------------------+
| [Copy All]  [Save .txt]  [Save .md]       |
+-------------------------------------------+
```
