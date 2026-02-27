# File Transcription Feature

## Plan

### Context
Parkeet currently only supports live microphone transcription via hotkey. User wants to transcribe audio files (Voice Memos from iPhone/Apple Watch/Mac, etc.) with progress tracking and time estimation.

### Decisions
- **Trigger:** "Transcribe File..." item in system tray menu
- **UI:** Dedicated window for the multi-step workflow
- **Transcription:** Chunk-based (30-second chunks) for progress reporting
- **Audio formats:** M4A, CAF, AAC, AIFF, MP3, WAV via macOS built-in `afconvert`
- **Save location:** User picks before starting, default is `<original_name>_transcription.txt` in same directory
- **Output format:** Plain text (.txt)

### User Flow
1. Click "Transcribe File..." in tray menu
2. Native file picker opens (filtered to supported audio formats)
3. Transcription window appears showing file name + duration
4. 2-second sample transcribed in background to estimate speed
5. Window shows: duration, estimated time, save location (with Browse button)
6. User clicks "Start Transcription"
7. Progress view: progress bar, percentage, elapsed/remaining time, Cancel button
8. Complete: "Transcription complete!" with Open File and Close buttons
9. If cancelled, partial transcription is saved

### Changes

1. **`src/file_transcriber.py`** (new) — Chunk-based file transcription engine. Loads audio via `afconvert`, splits into 30s chunks, transcribes sequentially with progress callback.

2. **`src/transcription_window.py`** (new) — Dedicated PyQt6 window with states: estimate → confirm → progress → complete.

3. **`src/app.py`** — Add "Transcribe File..." to tray menu, wire up file picker and transcription window.

4. **`src/config.py`** — Add default save directory preference (optional).

## Tasks

- [x] Create `src/file_transcriber.py` — audio loading, chunking, progress-aware transcription
- [x] Create `src/transcription_window.py` — multi-state UI window
- [x] Update `src/app.py` — tray menu item, file picker, wire window + transcriber
- [x] Test: imports, format_duration, app instantiation — all pass

## Verification

1. "Transcribe File..." appears in tray context menu
2. File picker filters to .m4a, .caf, .aac, .aiff, .mp3, .wav
3. Duration displayed correctly for selected file
4. 2-second sample produces reasonable time estimate
5. Save path defaults to `<name>_transcription.txt` next to source file
6. Browse button allows changing save location
7. Progress bar updates smoothly during transcription
8. Cancel stops transcription and saves partial result
9. Completed transcription matches expected text quality
10. "Open File" button opens the saved .txt file
