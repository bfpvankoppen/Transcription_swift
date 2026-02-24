# Transcription App (Parakeet)

macOS speech-to-text app using NVIDIA Parakeet TDT 0.6B v3 (INT8 ONNX via sherpa-onnx).
Press Cmd+Option to record, press again to stop, transcription is pasted into the focused text field.

## Architecture

- **Python 3.11** via pyenv, venv at `.venv/`
- **PyQt6** for overlay UI, system tray, event loop
- **sherpa-onnx** for offline ASR inference (INT8 quantized, 642MB model)
- **sounddevice** for 16kHz mono audio capture
- **pynput** for global Cmd+Option hotkey detection
- **pyobjc** (AppKit/Quartz) for clipboard paste simulation and NSWindow control

## Project Structure

```
run.py              # Entry point
src/
  app.py            # Main controller, state machine, system tray
  overlay.py        # Floating recording overlay with waveform animation
  hotkey.py         # Global Cmd+Option hotkey listener (pynput + Qt bridge)
  recorder.py       # Audio recorder with real-time level metering
  transcriber.py    # Parakeet model wrapper (sherpa-onnx)
  paster.py         # Clipboard + Cmd+V paste simulation (pyobjc)
models/             # Downloaded ONNX model files (gitignored)
```

## Running

```bash
source .venv/bin/activate
python run.py
```

Alias: `parkeet` (defined in ~/.zshrc)

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
