# User Identity

See `__pycache__/.context/identity.md` for Björn's personal context, background, professional history, and preferences. This file should be consulted when context about who the user is matters for the task at hand.

# Parkeet

Native Swift macOS speech-to-text app using NVIDIA Parakeet TDT 0.6B v3 (INT8 ONNX via sherpa-onnx).
Press Cmd+Option to record, press again to stop, transcription is pasted into the focused text field.

## Architecture

- **Swift 5.9** / **SwiftUI** — native macOS app, menu-bar accessory (no Dock icon)
- **sherpa-onnx** C API — offline ASR inference (INT8 quantized, 642MB model)
- **AVAudioEngine** — 16kHz mono audio capture with real-time level metering
- **NSEvent** global monitors — Cmd+Option hotkey detection (no pynput)
- **AppKit** — NSStatusItem menu bar, NSPanel overlay, CGEvent paste simulation
- **SPM + XcodeGen** — build system (Package.swift + project.yml)

## Project Structure

```
ParkeetSwift/
├── Package.swift                    # SPM manifest (macOS 14.0+)
├── project.yml                      # XcodeGen config
├── run.sh                           # Build & package script
├── Sources/
│   ├── CSherpaOnnx/                 # C API wrapper module
│   │   ├── include/c-api.h          # sherpa-onnx C header
│   │   ├── include/module.modulemap
│   │   └── shim.c
│   └── Parkeet/
│       ├── App/
│       │   ├── ParkeetApp.swift       # @main SwiftUI entry point
│       │   ├── AppDelegate.swift      # Menu bar, window management
│       │   ├── AppState.swift         # Central state machine (@Observable)
│       │   ├── PermissionChecker.swift
│       │   └── SoundPlayer.swift
│       ├── Audio/
│       │   └── AudioRecorder.swift    # AVAudioEngine, 28-bar waveform
│       ├── Transcription/
│       │   ├── Transcriber.swift      # Parakeet model wrapper
│       │   ├── MeetingTranscriber.swift # Live meeting mode
│       │   └── FileTranscriber.swift  # Batch file processing
│       ├── Bridge/
│       │   └── SherpaOnnx.swift       # Swift bindings for C API
│       ├── Hotkey/
│       │   └── HotkeyListener.swift   # NSEvent global monitors
│       ├── Overlay/
│       │   └── OverlayPanel.swift     # Recording UI (all Spaces)
│       ├── Paste/
│       │   └── PasteService.swift     # Clipboard + Cmd+V simulation
│       ├── Model/
│       │   ├── Config.swift           # UserDefaults persistence
│       │   ├── HistoryStore.swift     # Transcription history (JSON)
│       │   └── VoiceCommands.swift    # Text replacements
│       └── UI/
│           ├── SettingsView.swift     # Sidebar navigation settings
│           ├── MeetingView.swift      # Live transcription window
│           ├── TranscribeFileView.swift
│           ├── HistoryView.swift
│           ├── VoiceCommandsView.swift
│           └── WelcomeView.swift      # Onboarding
├── Support/
│   ├── Info.plist
│   ├── Parkeet.entitlements
│   └── SherpaOnnx-Bridging-Header.h
├── Scripts/
│   ├── build-sherpa-onnx.sh         # Compile sherpa-onnx C libraries
│   └── download-model.sh            # Download Parakeet model
└── Resources/
    └── models/                      # ONNX model files (gitignored)
```

## Building & Running

```bash
# First time: build sherpa-onnx and download model
cd ParkeetSwift
bash Scripts/build-sherpa-onnx.sh
bash Scripts/download-model.sh

# Build & run
bash run.sh
```

## Workflow Rules

Follow these for EVERY prompt and task:

### 1. Plan Before Building
- Enter plan mode for any non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately
- Write detailed specs upfront to reduce ambiguity

### 2. Subagent Strategy
- Use subagents to keep main context clean
- Offload research, exploration, and parallel analysis to subagents
- One task per subagent for focused execution

### 3. Self-Improvement Loop
- After ANY correction from the user: update `tasks/lessons.md` with the pattern
- Write rules that prevent the same mistake recurring
- Review lessons at session start

### 4. Verification Before Done
- Never mark a task complete without proving it works
- Run tests, check logs, demonstrate correctness
- Ask: "Would a staff engineer approve this?"

### 5. Demand Elegance (Balanced)
- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky, step back and implement the elegant solution
- Skip this for simple, obvious fixes — don't over-engineer

### 6. Autonomous Bug Fixing
- When given a bug report: just fix it, don't ask for hand-holding
- Point at logs, errors, failing tests — then resolve them
- Zero context switching required from the user

### 7. Task Management
1. Write plan to `tasks/todo.md` with checkable items
2. Check in before starting implementation
3. Mark items complete as you go
4. High-level summary at each step
5. Add review section to `tasks/todo.md`
6. Capture lessons in `tasks/lessons.md` after corrections

### 8. Comprehensive Logging
- Logging is **core functionality**, not an afterthought — every application must have it from day one
- Every significant operation, state transition, and error path must produce a log entry
- Use structured log levels consistently: `DEBUG` for internals, `INFO` for operations, `WARNING` for recoverable issues, `ERROR` for failures
- Include enough context in each log message to diagnose issues without a debugger
- When building or modifying any feature, always include appropriate logging as part of the implementation

## Core Principles

- **Simplicity First**: Make every change as simple as possible. Minimal code impact.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.
- **Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.

## Key Technical Notes

- Model: `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8` (25 languages, auto-detect)
- Must use `model_type="nemo_transducer"` with sherpa-onnx (not default "transducer")
- Overlay uses NSPanel with collection behaviors to appear on all macOS Spaces
- Hotkey uses NSEvent global monitors (addGlobalMonitorForEvents) — pure AppKit, no third-party
- Paste uses NSPasteboard + CGEvent Cmd+V simulation; requires Accessibility permission
- macOS permissions needed: Microphone, Accessibility, Input Monitoring
- **Accessory activation policy required** — Regular policy pins ALL windows to one Space on macOS 26

## Lessons Learned (macOS App Development)

### Overlay Window (All macOS Spaces)
- **Requires Accessory activation policy** — Regular policy pins ALL windows to one Space on macOS 26.
- Set behavior from scratch: `CanJoinAllSpaces | Stationary | IgnoresCycle | FullScreenAuxiliary`.
- After each `show()`, must re-apply space behaviors — AppKit may reset during window creation.
- Use `setHidesOnDeactivate_(false)` to prevent NSPanel from hiding when app loses focus.

### macOS .app Bundles
- **Icon cache is aggressive**: After changing `.icns`, must run `lsregister -f` on the .app AND `killall Finder` to refresh.
- **DMG creation**: `hdiutil create -volname "Name" -srcfolder "path/to/App.app" -ov -format UDZO output.dmg`
- **Ad-hoc code signing**: `codesign --force --deep --sign -` is required for Gatekeeper.

## Reference: notchprompt Patterns

Source: https://github.com/saif0200/notchprompt (native Swift macOS overlay app)
Full analysis: `tasks/notchprompt-insights.md`

Key patterns applicable to Parkeet: overlay window hardening (stationary + ignoresCycle behaviors),
privacy mode (NSWindow sharingType), NSEvent global monitors, dual-rate animation timers,
debounced auto-save, and multi-display support.
