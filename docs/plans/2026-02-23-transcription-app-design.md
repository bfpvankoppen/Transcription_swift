# Transcription App Design

Personal speech-to-text app for macOS, similar to SuperWhisper. Press a hotkey combo, speak, press again, transcribed text pastes into the focused text field.

## Architecture

Menu bar app with three layers:

- **Menu bar icon** — always running, shows status
- **Floating overlay** — dark bar with waveform, appears during recording
- **Engine layer** — hotkey listener, audio recorder, transcription model, text paster

## Interaction Loop

```
IDLE --> Cmd+Option --> RECORDING --> Cmd+Option --> TRANSCRIBING --> PASTE --> IDLE
```

1. IDLE: Menu bar icon sits quietly. Model loaded in memory.
2. Cmd+Option: Overlay appears. Mic starts recording. Waveform animates.
3. Cmd+Option: Recording stops. Overlay shows "Transcribing...".
4. PASTE: Text inserted into whatever field was focused before the overlay appeared.
5. IDLE: Overlay fades out. Ready for next use.

## Recording Overlay

- Floating, frameless, always-on-top window centered horizontally near top of screen
- Dark translucent background with rounded corners
- Real-time waveform — vertical bars animated from mic audio levels at ~30fps
- No buttons or text during recording, just the waveform
- On stop: waveform freezes, subtle "Transcribing..." label appears
- Then fades out

The overlay does NOT steal focus from the current text field.

## Tech Stack

```
Python 3.11 (via pyenv)
├── PyQt6              — Menu bar icon + floating overlay window
├── sounddevice        — Audio recording from mic
├── nemo_toolkit[asr]  — Loads & runs Parakeet model (parakeet-1.1b-rnnt-multilingual-asr)
├── torch              — ML backend (CPU/MPS on Apple Silicon)
├── pynput             — Global hotkey capture (Cmd+Option)
└── pyobjc-framework-Cocoa — AppleScript bridge to paste text
```

## Model

- NVIDIA Parakeet 1.1b RNNT Multilingual ASR
- ~500MB download, loaded once at startup, stays in memory
- Runs on CPU via PyTorch on Apple Silicon M4

## Target Hardware

- MacBook Air M4, 16GB RAM
- macOS with Accessibility permissions granted for hotkey capture

## Constraints

- No settings UI, no extra features
- Single purpose: hotkey, record, transcribe, paste
- English transcription only (for now)
