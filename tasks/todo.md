# Parkeet Swift Rewrite

## Architecture Plan

### Target
macOS 14+ (Sonoma), Swift 5.9+, SwiftUI + AppKit hybrid

### Integration Strategy: sherpa-onnx
- **No SPM package available** — must build from source or use pre-built xcframework
- Build sherpa-onnx for macOS: `clone repo → ./build-swift-macos.sh → get dylib + headers`
- Bridge to Swift via `SherpaOnnx-Bridging-Header.h` → `#import "sherpa-onnx/c-api/c-api.h"`
- Swift wrapper: `SherpaOnnx.swift` (from sherpa-onnx repo, adapted)
- Model: `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8` (encoder, decoder, joiner, tokens)
- Config: `modelType: "nemo_transducer"`, `numThreads: 4`, `sampleRate: 16000`

### Project Structure
```
ParkeetSwift/
  ParkeetSwift.xcodeproj/     # Xcode project (created manually on macOS)
  project.yml                  # XcodeGen spec for reproducible project generation
  Sources/
    App/
      ParkeetApp.swift         # @main App, NSApplicationDelegateAdaptor
      AppDelegate.swift        # NSStatusItem (menu bar), app lifecycle
      AppState.swift           # @Observable state machine (idle/recording/transcribing)
    Audio/
      AudioRecorder.swift      # AVAudioEngine, 16kHz mono, real-time levels
    Transcription/
      Transcriber.swift        # sherpa-onnx offline recognizer wrapper
      FileTranscriber.swift    # Chunked file transcription with progress
      ModelDownloader.swift    # First-run model download with progress
    Hotkey/
      HotkeyListener.swift    # NSEvent.addGlobalMonitorForEvents
    Overlay/
      OverlayPanel.swift       # NSPanel subclass (all-Spaces, floating)
      OverlayViewController.swift  # Waveform animation (Core Animation)
    Paste/
      PasteService.swift       # NSPasteboard + CGEvent Cmd+V
    UI/
      SettingsView.swift       # SwiftUI Settings scene
      HistoryView.swift        # SwiftUI history list
      TranscribeFileView.swift # SwiftUI file transcription UI
      VoiceCommandsView.swift  # SwiftUI voice command toggles
    Model/
      Config.swift             # @AppStorage + UserDefaults
      HistoryStore.swift       # JSON persistence, auto-purge
      VoiceCommands.swift      # Text post-processing (regex)
    Bridge/
      SherpaOnnx.swift         # Swift wrapper for C API
  Resources/
    Assets.xcassets/           # App icon
  Support/
    Info.plist
    Parkeet.entitlements       # Microphone, Accessibility
    SherpaOnnx-Bridging-Header.h
  Scripts/
    build-sherpa-onnx.sh       # Build sherpa-onnx dylib for macOS
    download-model.sh          # Download Parakeet model
```

### Component Mapping (Python → Swift)

| Python Module | Swift Equivalent | Key Changes |
|--------------|-----------------|-------------|
| `run.py` + `app.py` | `ParkeetApp.swift` + `AppDelegate.swift` + `AppState.swift` | SwiftUI App lifecycle, @Observable state machine |
| `recorder.py` (sounddevice) | `AudioRecorder.swift` (AVAudioEngine) | Native API, install tap on input node |
| `transcriber.py` (sherpa_onnx Python) | `Transcriber.swift` (sherpa-onnx C API) | Bridging header, same model files |
| `hotkey.py` (pynput) | `HotkeyListener.swift` (NSEvent) | No more thread-crossing issues |
| `overlay.py` (PyQt6 QWidget) | `OverlayPanel.swift` (NSPanel) | Core Animation instead of QPainter |
| `paster.py` (pyobjc) | `PasteService.swift` (native) | Direct API calls, no bridge |
| `settings_window.py` (PyQt6) | `SettingsView.swift` (SwiftUI) | Dramatically less code |
| `history_window.py` (PyQt6) | `HistoryView.swift` (SwiftUI) | SwiftUI List with search |
| `history.py` | `HistoryStore.swift` | Codable + JSON, same approach |
| `config.py` | `Config.swift` | @AppStorage / UserDefaults |
| `voice_commands.py` | `VoiceCommands.swift` | Same regex logic |
| `sounds.py` (NSSound via pyobjc) | Inline `NSSound` calls | Trivial in Swift |
| `file_transcriber.swift` | `FileTranscriber.swift` | async/await instead of threads |

### Threading Model
- **Main actor**: All UI, overlay, menu bar
- **Background tasks**: `Task { }` with async/await for transcription
- **Audio thread**: AVAudioEngine tap callback (real-time thread)
- No manual thread management — structured concurrency handles it

### macOS Permissions (entitlements)
- `com.apple.security.device.audio-input` — Microphone
- `com.apple.security.automation.apple-events` — Accessibility (paste)
- App Sandbox: OFF for initial development (global hotkey + paste need it)
  - For App Store: will need to request temporary exception entitlements

### App Store Considerations
- Sandboxing required — global hotkey monitoring needs `com.apple.security.temporary-exception.apple-events`
- Model files bundled in app bundle (Resources/) — ~640MB app size
- Or: download model on first launch (smaller initial download)
- Accessibility permission required for paste simulation

## Implementation Order

- [x] Research sherpa-onnx Swift API & integration
- [x] Research Swift macOS architecture patterns
- [ ] Phase 1: Project skeleton
  - [ ] Create project structure and supporting files
  - [ ] XcodeGen project.yml
  - [ ] Info.plist, entitlements, bridging header
  - [ ] Build scripts for sherpa-onnx
- [ ] Phase 2: Core pipeline (record → transcribe → paste)
  - [ ] AppDelegate + menu bar + AppState
  - [ ] AudioRecorder (AVAudioEngine)
  - [ ] SherpaOnnx bridge + Transcriber
  - [ ] PasteService (NSPasteboard + CGEvent)
  - [ ] HotkeyListener (NSEvent global monitor)
- [ ] Phase 3: Overlay
  - [ ] OverlayPanel (NSPanel, all-Spaces)
  - [ ] Waveform animation (Core Animation)
- [ ] Phase 4: UI
  - [ ] SettingsView (SwiftUI)
  - [ ] HistoryView + HistoryStore
  - [ ] VoiceCommands + VoiceCommandsView
  - [ ] TranscribeFileView + FileTranscriber
- [ ] Phase 5: Polish
  - [ ] Sound feedback
  - [ ] Model download on first launch
  - [ ] Error handling and logging (os_log)
  - [ ] App icon and assets

## Previous Python Tasks (completed)

- [x] Sound feedback — macOS system sounds for record start/stop, transcription complete
- [x] Copy Text button on file transcription complete screen
- [x] macOS notification when file transcription completes (word count)
- [x] Search bar in History page — real-time filtering by text/filename
- [x] Drag-and-drop audio files onto Transcribe File page
- [x] Settings window redesign — sidebar + content pane (macOS style)
- [x] Hub window: History, Transcribe File, About, Attribution pages
- [x] Transcription history feature
- [x] Compact history rows with click-to-expand
- [x] Focus fix: PID check + hide Parkeet windows during recording
