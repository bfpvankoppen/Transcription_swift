# Parkeet

macOS speech-to-text app using NVIDIA Parakeet TDT 0.6B v3 (INT8 ONNX via sherpa-onnx).
Press Cmd+Option to record, press again to stop, transcription is pasted into the focused text field.

## Architecture

- **Python 3.11** via pyenv, venv at `.venv/`
- **PyQt6** for overlay UI, system tray, event loop
- **sherpa-onnx** for offline ASR inference (INT8 quantized, 642MB model)
- **sounddevice** for 16kHz mono audio capture
- **pynput** for global Cmd+Option hotkey detection
- **pyobjc** (AppKit/Quartz) for clipboard paste simulation, focus management, NSWindow control
- **PyInstaller** for standalone .app packaging

## Project Structure

```
run.py              # Entry point
src/
  app.py            # Main controller, state machine, system tray, focus restore
  overlay.py        # Floating recording overlay with waveform animation
  hotkey.py         # Global Cmd+Option hotkey listener (pynput + Qt bridge)
  recorder.py       # Audio recorder with real-time level metering
  transcriber.py    # Parakeet model wrapper (sherpa-onnx)
  paster.py         # Clipboard + Cmd+V paste simulation (pyobjc)
models/             # ONNX model files (gitignored)
parkeet.spec        # PyInstaller spec for building Parkeet.app
build.sh            # Build script: pyinstaller + codesign + dmg
assets/
  Parkeet.icns      # App icon
  icon.png          # Source icon (1024x1024)
  generate_icon.py  # Script to regenerate icon
dist/               # Build output (gitignored)
  Parkeet.app       # Standalone app bundle (~700MB)
  Parkeet.dmg       # Distributable disk image (~534MB)
```

## Running

**Development:**
```bash
source .venv/bin/activate
python run.py
```

**Standalone app:**
```bash
bash build.sh          # Build Parkeet.app + Parkeet.dmg
open dist/Parkeet.app  # Launch
```

**Desktop shortcut:** Finder alias on Desktop points to `dist/Parkeet.app`

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

## Core Principles

- **Simplicity First**: Make every change as simple as possible. Minimal code impact.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.
- **Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.

## Key Technical Notes

- Model: `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8` (25 languages, auto-detect)
- Must use `model_type="nemo_transducer"` with sherpa-onnx (not default "transducer")
- Overlay uses NSWindow collection behaviors via pyobjc to appear on all macOS Spaces
- Qt `Tool` window type creates NSPanel which sets `MoveToActiveSpace` — must clear this bit and set `CanJoinAllSpaces` AFTER `show()`
- Hotkey uses pynput listener thread bridged to Qt main thread via `HotkeyBridge(QObject)` with `pyqtSignal`
- Paste uses NSPasteboard + CGEvent Cmd+V simulation; requires Accessibility permission
- macOS permissions needed: Microphone, Accessibility, Input Monitoring

## Lessons Learned (macOS App Development)

### Focus Management
- **Qt signal thread-crossing steals focus**: When a `pyqtSignal` is emitted from a background thread (pynput) and delivered to the Qt main thread, macOS activates the app as a side effect. By the time the connected slot runs, our app is already frontmost. Calling `frontmostApplication()` inside the slot returns our own app, not the user's.
- **Fix: capture frontmost app in the pynput thread BEFORE emitting the signal**: `_pre_capture_and_emit()` calls `NSWorkspace.frontmostApplication()` while the user's app is still active, stores the reference, then emits the Qt signal. After the overlay appears, `_refocus_target()` re-activates the saved app via `activateWithOptions_(NSApplicationActivateIgnoringOtherApps)` with a 150ms QTimer delay.
- **Don't use `LSUIElement=true` if the user needs to find the app**: It hides the app from Dock, Force Quit, and Cmd+Tab. Users can't discover or manage the app. Better to show in Dock and use focus management instead.
- **`NSApplicationActivationPolicyAccessory`** hides from Dock — same problem as LSUIElement. Removed it so the app is visible everywhere.

### PyInstaller Packaging
- **`sys._MEIPASS`**: PyInstaller extracts bundled files to a temp directory. Use `getattr(sys, '_MEIPASS', None)` to detect bundled mode and find resources. Always provide a fallback to the dev path (`os.path.dirname(__file__)`).
- **sherpa-onnx native libs**: Must explicitly add `sherpa_onnx/lib/*.so` and `*.dylib` as binaries in the spec file. PyInstaller doesn't auto-detect them.
- **sounddevice/PortAudio**: Bundle `_sounddevice_data/portaudio-binaries/libportaudio.dylib` as data.
- **Hidden imports needed**: `sherpa_onnx`, `pynput.keyboard._darwin`, `sounddevice`, `soundfile`, `AppKit`, `Quartz`, `objc`.
- **Ad-hoc code signing**: `codesign --force --deep --sign -` is required for Gatekeeper to allow the app to run.

### macOS .app Bundles
- **Shell script as CFBundleExecutable doesn't work well**: The Python process spawned by `exec` doesn't properly inherit the bundle's identity. PyInstaller creating a real Mach-O binary solves this.
- **Icon cache is aggressive**: After changing `.icns`, must run `lsregister -f` on the .app AND `killall Finder` to refresh.
- **Finder aliases vs symlinks**: `ln -s` creates Unix symlinks that show generic icons. Use `osascript` with Finder's `make alias file` to create proper macOS aliases that inherit the app icon.
- **DMG creation**: `hdiutil create -volname "Name" -srcfolder "path/to/App.app" -ov -format UDZO output.dmg`

### Overlay Window (All macOS Spaces)
- After each `show()`, must re-apply `_apply_all_spaces_behavior()` to clear `MoveToActiveSpace` bit and set `CanJoinAllSpaces | FullScreenAuxiliary` via pyobjc — Qt resets these on every `show()`.
- Use `setHidesOnDeactivate_(False)` to prevent NSPanel from hiding when app loses focus.
- Do NOT try to avoid `show()`/`hide()` by keeping the window always visible at opacity 0 — this breaks overlay following across macOS Spaces and can interfere with hotkey detection.

### Blocking Dialogs in Accessory Apps
- `QMessageBox` in an accessory/background app creates windows that are invisible behind other apps. The user sees nothing and the app appears hung. Use non-blocking tray notifications (`QSystemTrayIcon.showMessage()`) instead of modal dialogs for status messages.
