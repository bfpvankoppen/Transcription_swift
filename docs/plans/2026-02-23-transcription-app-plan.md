# Transcription App Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a macOS menu bar app that records speech via a Cmd+Option hotkey toggle, transcribes it with NVIDIA Parakeet, and pastes the text into the focused text field.

**Architecture:** Python menu bar app with PyQt6. Three layers: (1) system tray icon, (2) floating non-activating overlay with waveform, (3) engine layer handling hotkey, audio capture, NeMo transcription, and CGEvent-based paste. pynput listener runs on a daemon thread; its toggle signal crosses to the Qt main thread via pyqtSignal.

**Tech Stack:** Python 3.11, PyQt6, sounddevice, nemo_toolkit[asr], torch, pynput, pyobjc-framework-Cocoa, pyobjc-framework-Quartz

---

## Task 1: Project Setup

**Files:**
- Create: `setup.sh`
- Create: `requirements.txt`

**Step 1: Create requirements.txt**

```txt
torch
torchaudio
nemo_toolkit[asr]
PyQt6
sounddevice
pynput
pyobjc-framework-Cocoa
pyobjc-framework-Quartz
numpy
```

**Step 2: Create setup script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Ensure pyenv is available
if ! command -v pyenv &>/dev/null; then
    echo "Installing pyenv via Homebrew..."
    brew install pyenv
fi

# Install Python 3.11 if not present
if ! pyenv versions --bare | grep -q "^3\.11"; then
    pyenv install 3.11
fi

# Create virtual environment
PYTHON=$(pyenv prefix 3.11)/bin/python3
$PYTHON -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install --upgrade pip
pip install -r requirements.txt

echo ""
echo "Setup complete. Activate with: source .venv/bin/activate"
```

**Step 3: Run setup**

Run: `chmod +x setup.sh && ./setup.sh`
Expected: Virtual environment created, all packages installed.

**Step 4: Verify key imports**

Run: `source .venv/bin/activate && python -c "import torch; import nemo; import PyQt6; import sounddevice; import pynput; print('All imports OK')"`
Expected: "All imports OK"

**Step 5: Commit**

```bash
git init
git add requirements.txt setup.sh
git commit -m "chore: project setup with dependencies"
```

---

## Task 2: Recording Overlay

**Files:**
- Create: `src/overlay.py`

**Step 1: Create the overlay module**

The overlay is a frameless, always-on-top, translucent PyQt6 widget that does NOT steal focus. It draws an animated waveform of vertical bars via QPainter at ~30fps. Key window flags:

- `Qt.WindowType.Tool` — no Dock/Cmd-Tab entry
- `Qt.WindowType.FramelessWindowHint` — no title bar
- `Qt.WindowType.WindowStaysOnTopHint` — always on top
- `Qt.WindowType.WindowDoesNotAcceptFocus` — does not steal focus
- `Qt.WindowType.WindowTransparentForInput` — input passes through

Attributes: `WA_TranslucentBackground`, `WA_MacAlwaysShowToolWindow`

Constants:
- Window: 360x64px, corner radius 16, 60px from top of screen
- Bars: 28 bars, 6px wide, 4px gap, min height 4px
- Colors: bg `rgba(20,20,24,200)`, bars `rgba(100,180,255,220)` bright / `rgba(80,140,220,180)` dim
- Fade: 250ms InOutCubic via QGraphicsOpacityEffect + QPropertyAnimation
- Smoothing: 0.35 exponential smoothing on bar heights

Public API:
- `fade_in()` — show overlay, start waveform timer
- `update_levels(amplitudes: list[float])` — feed [0.0..1.0] floats, resampled to 28 bars
- `show_transcribing()` — freeze waveform, show "Transcribing..." label
- `fade_out(on_finished=None)` — fade out, optionally call callback

The file already exists at the project root as `overlay.py` from research — move to `src/overlay.py` and verify it works.

**Step 2: Run the demo**

Run: `source .venv/bin/activate && python src/overlay.py`
Expected: A dark floating bar appears near the top of the screen with animated waveform bars. After 4 seconds it shows "Transcribing...", then fades out.

**Step 3: Commit**

```bash
git add src/overlay.py
git commit -m "feat: recording overlay with waveform animation"
```

---

## Task 3: Global Hotkey Listener

**Files:**
- Create: `src/hotkey.py`

**Step 1: Create the hotkey module**

Two classes:

**`CmdOptionHotkeyListener`** — tracks Cmd and Option key press/release state. Fires `on_toggle` callback when both keys are pressed together and then released. Cancels if any non-modifier key is pressed during the hold (prevents false triggers from Cmd+Option+Esc etc.).

Key methods:
- `_is_cmd(key)` — matches `Key.cmd`, `Key.cmd_l`, `Key.cmd_r`
- `_is_option(key)` — matches `Key.alt`, `Key.alt_l`, `Key.alt_r`
- `_on_press(key)` — track modifier state, set `_combo_activated` when both held
- `_on_release(key)` — fire toggle when both released and not cancelled
- `start()` — launch pynput `Listener` as daemon thread
- `stop()` — stop the listener

**`HotkeyBridge(QObject)`** — bridges pynput thread to Qt main thread with a `toggled = pyqtSignal()`. Usage: `listener = CmdOptionHotkeyListener(on_toggle=bridge.toggled.emit)`

```python
from PyQt6.QtCore import QObject, pyqtSignal

class HotkeyBridge(QObject):
    toggled = pyqtSignal()
```

**Step 2: Add standalone demo**

`if __name__ == "__main__"` block that prints toggle count and state (RECORDING/STOPPED) to verify the hotkey works globally.

**Step 3: Test the hotkey**

Run: `source .venv/bin/activate && python src/hotkey.py`
Expected: Press Cmd+Option and release — prints "Toggle #1 -> RECORDING". Press again — prints "Toggle #2 -> STOPPED".

Note: Requires Input Monitoring permission for Terminal in System Settings > Privacy & Security.

**Step 4: Commit**

```bash
git add src/hotkey.py
git commit -m "feat: global Cmd+Option hotkey toggle listener"
```

---

## Task 4: Audio Recorder

**Files:**
- Create: `src/recorder.py`

**Step 1: Create the audio recorder module**

**`AudioRecorder`** class wrapping `sounddevice.InputStream`:
- Records from default mic at 16000 Hz, mono, float32
- Uses a callback-based stream that appends chunks to a list
- Provides real-time amplitude levels for the waveform overlay
- Returns the complete recording as a numpy array when stopped

```python
import sounddevice as sd
import numpy as np
import threading

class AudioRecorder:
    def __init__(self, sample_rate: int = 16000, channels: int = 1):
        self._sample_rate = sample_rate
        self._channels = channels
        self._chunks: list[np.ndarray] = []
        self._stream = None
        self._current_levels: list[float] = []
        self._lock = threading.Lock()

    def start(self) -> None:
        self._chunks = []
        self._stream = sd.InputStream(
            samplerate=self._sample_rate,
            channels=self._channels,
            dtype="float32",
            blocksize=int(self._sample_rate / 30),  # ~33ms blocks for 30fps
            callback=self._audio_callback,
        )
        self._stream.start()

    def stop(self) -> np.ndarray:
        if self._stream:
            self._stream.stop()
            self._stream.close()
            self._stream = None
        if self._chunks:
            return np.concatenate(self._chunks, axis=0)
        return np.zeros((0,), dtype=np.float32)

    def get_levels(self, num_bars: int = 28) -> list[float]:
        with self._lock:
            return list(self._current_levels)

    def _audio_callback(self, indata, frames, time_info, status):
        self._chunks.append(indata.copy())
        # Compute amplitude levels for waveform display
        mono = indata[:, 0] if indata.ndim > 1 else indata.flatten()
        # Split into num_bars segments and take RMS of each
        num_bars = 28
        segment_size = max(1, len(mono) // num_bars)
        levels = []
        for i in range(num_bars):
            start = i * segment_size
            end = min(start + segment_size, len(mono))
            segment = mono[start:end]
            rms = float(np.sqrt(np.mean(segment ** 2)))
            # Scale up for visibility (typical speech RMS is 0.01-0.1)
            scaled = min(1.0, rms * 8.0)
            levels.append(scaled)
        with self._lock:
            self._current_levels = levels
```

**Step 2: Add standalone demo**

Records 3 seconds of audio, prints levels each frame, then prints total samples captured.

**Step 3: Test the recorder**

Run: `source .venv/bin/activate && python src/recorder.py`
Expected: Prints waveform levels for 3 seconds, then reports total audio captured.

Note: macOS will prompt for Microphone permission on first run.

**Step 4: Commit**

```bash
git add src/recorder.py
git commit -m "feat: audio recorder with real-time level metering"
```

---

## Task 5: Transcription Engine

**Files:**
- Create: `src/transcriber.py`

**Step 1: Create the transcriber module**

**`Transcriber`** class that loads and runs the Parakeet model:

```python
import tempfile
import numpy as np
import soundfile as sf
import torch
import nemo.collections.asr as nemo_asr

class Transcriber:
    def __init__(self):
        self._model = None

    def load_model(self) -> None:
        """Load the Parakeet model. Call once at startup."""
        self._model = nemo_asr.models.EncDecRNNTBPEModel.from_pretrained(
            model_name="nvidia/parakeet-1.1b-rnnt-multilingual-asr"
        )
        self._model.eval()
        # Try MPS (Metal) first, fall back to CPU
        if torch.backends.mps.is_available():
            try:
                self._model = self._model.to(torch.device("mps"))
            except Exception:
                self._model = self._model.to(torch.device("cpu"))
        else:
            self._model = self._model.to(torch.device("cpu"))

    def transcribe(self, audio: np.ndarray, sample_rate: int = 16000) -> str:
        """Transcribe a numpy audio array to text."""
        if self._model is None:
            raise RuntimeError("Model not loaded. Call load_model() first.")

        # NeMo transcribe() expects file paths, so write a temp WAV
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            sf.write(f.name, audio, sample_rate)
            tmp_path = f.name

        try:
            results = self._model.transcribe([tmp_path], batch_size=1)
            # Handle both string and Hypothesis return types
            if isinstance(results[0], str):
                return results[0]
            return results[0].text if hasattr(results[0], "text") else str(results[0])
        finally:
            import os
            os.unlink(tmp_path)
```

Key details:
- Model downloads on first run (~500MB) and is cached by HuggingFace
- Tries MPS (Metal Performance Shaders) for Apple Silicon acceleration, falls back to CPU
- NeMo's `transcribe()` expects file paths, so we write a temp WAV file
- Handles both NeMo 1.x (returns strings) and NeMo 2.x (returns Hypothesis objects)

**Step 2: Add standalone demo**

Records 5 seconds of audio using `AudioRecorder`, then transcribes it.

**Step 3: Test the transcriber**

Run: `source .venv/bin/activate && python src/transcriber.py`
Expected: First run downloads the model. Speak during recording. Transcribed text is printed.

Note: First run will be slow due to model download. Subsequent runs load from cache.

**Step 4: Commit**

```bash
git add src/transcriber.py
git commit -m "feat: Parakeet transcription engine"
```

---

## Task 6: Text Paster

**Files:**
- Create: `src/paster.py`

**Step 1: Create the paster module**

Uses NSPasteboard to set clipboard, then CGEvent to simulate Cmd+V:

```python
import time
import AppKit
import Quartz

def paste_text(text: str) -> None:
    """Paste text into the currently focused text field via Cmd+V."""
    if not text or not text.strip():
        return

    pasteboard = AppKit.NSPasteboard.generalPasteboard()

    # Save current clipboard
    old_contents = pasteboard.stringForType_(AppKit.NSPasteboardTypeString)

    # Set clipboard to transcribed text
    pasteboard.clearContents()
    pasteboard.setString_forType_(text, AppKit.NSPasteboardTypeString)

    # Simulate Cmd+V (keycode 9 = 'V')
    event_down = Quartz.CGEventCreateKeyboardEvent(None, 9, True)
    Quartz.CGEventSetFlags(event_down, Quartz.kCGEventFlagMaskCommand)
    event_up = Quartz.CGEventCreateKeyboardEvent(None, 9, False)
    Quartz.CGEventSetFlags(event_up, Quartz.kCGEventFlagMaskCommand)

    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_down)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_up)

    # Restore clipboard after paste completes
    time.sleep(0.15)
    if old_contents is not None:
        pasteboard.clearContents()
        pasteboard.setString_forType_(old_contents, AppKit.NSPasteboardTypeString)
```

**Step 2: Add standalone demo**

3-second countdown, then pastes "Hello from Transcription app!" into the focused field.

**Step 3: Test the paster**

Run: `source .venv/bin/activate && python src/paster.py`
Expected: Switch to a text field within 3 seconds. "Hello from Transcription app!" appears.

Note: Requires Accessibility permission for the terminal.

**Step 4: Commit**

```bash
git add src/paster.py
git commit -m "feat: text paster via NSPasteboard + CGEvent Cmd+V"
```

---

## Task 7: Main App — Wire Everything Together

**Files:**
- Create: `src/__init__.py` (empty)
- Create: `src/app.py`
- Create: `run.py`

**Step 1: Create the main app**

**`TranscriptionApp`** class that orchestrates all components:

```python
import sys
import threading
from PyQt6.QtWidgets import QApplication, QSystemTrayIcon, QMenu
from PyQt6.QtGui import QIcon, QPixmap, QPainter, QColor
from PyQt6.QtCore import QObject, pyqtSignal, pyqtSlot, QTimer

from src.overlay import RecordingOverlay
from src.hotkey import CmdOptionHotkeyListener, HotkeyBridge
from src.recorder import AudioRecorder
from src.transcriber import Transcriber
from src.paster import paste_text


class TranscriptionApp(QObject):
    """Main application controller."""

    transcription_done = pyqtSignal(str)

    def __init__(self):
        super().__init__()
        self._recording = False

        # Components
        self._overlay = RecordingOverlay()
        self._recorder = AudioRecorder()
        self._transcriber = Transcriber()

        # Hotkey
        self._hotkey_bridge = HotkeyBridge()
        self._hotkey_bridge.toggled.connect(self._on_toggle)
        self._hotkey_listener = CmdOptionHotkeyListener(
            on_toggle=self._hotkey_bridge.toggled.emit
        )

        # Transcription result signal
        self.transcription_done.connect(self._on_transcription_done)

        # Level feed timer (drives waveform at 30fps during recording)
        self._level_timer = QTimer()
        self._level_timer.setInterval(33)
        self._level_timer.timeout.connect(self._feed_levels)

        # System tray
        self._tray = None

    def start(self) -> None:
        """Initialize and start the app."""
        # Load model (show loading state in tray)
        self._setup_tray()
        self._tray.setToolTip("Loading model...")

        # Load model in background thread
        def _load():
            self._transcriber.load_model()
            # Update tray on main thread after load
            QTimer.singleShot(0, lambda: self._tray.setToolTip("Ready — Cmd+Option to record"))

        threading.Thread(target=_load, daemon=True).start()

        # Start hotkey listener
        self._hotkey_listener.start()

    @pyqtSlot()
    def _on_toggle(self) -> None:
        if not self._recording:
            self._start_recording()
        else:
            self._stop_recording()

    def _start_recording(self) -> None:
        self._recording = True
        self._recorder.start()
        self._overlay.fade_in()
        self._level_timer.start()
        self._tray.setToolTip("Recording...")

    def _stop_recording(self) -> None:
        self._recording = False
        self._level_timer.stop()
        audio = self._recorder.stop()
        self._overlay.show_transcribing()
        self._tray.setToolTip("Transcribing...")

        # Transcribe in background thread
        def _transcribe():
            text = self._transcriber.transcribe(audio)
            self.transcription_done.emit(text)

        threading.Thread(target=_transcribe, daemon=True).start()

    @pyqtSlot()
    def _feed_levels(self) -> None:
        levels = self._recorder.get_levels()
        self._overlay.update_levels(levels)

    @pyqtSlot(str)
    def _on_transcription_done(self, text: str) -> None:
        self._overlay.fade_out()
        if text.strip():
            # Small delay to let overlay fade before pasting
            QTimer.singleShot(300, lambda: paste_text(text))
        self._tray.setToolTip("Ready — Cmd+Option to record")

    def _setup_tray(self) -> None:
        # Create a simple microphone icon (colored circle)
        pixmap = QPixmap(22, 22)
        pixmap.fill(QColor(0, 0, 0, 0))
        painter = QPainter(pixmap)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setBrush(QColor(100, 180, 255))
        painter.setPen(QColor(100, 180, 255))
        painter.drawEllipse(3, 3, 16, 16)
        painter.end()

        icon = QIcon(pixmap)
        self._tray = QSystemTrayIcon(icon)

        menu = QMenu()
        quit_action = menu.addAction("Quit")
        quit_action.triggered.connect(QApplication.quit)
        self._tray.setContextMenu(menu)
        self._tray.show()
```

**Step 2: Create run.py entry point**

```python
#!/usr/bin/env python3
"""Entry point for the Transcription app."""
import sys
from PyQt6.QtWidgets import QApplication
from src.app import TranscriptionApp

def main():
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)  # Keep running as tray app

    transcription_app = TranscriptionApp()
    transcription_app.start()

    sys.exit(app.exec())

if __name__ == "__main__":
    main()
```

**Step 3: Run the full app**

Run: `source .venv/bin/activate && python run.py`
Expected: Tray icon appears. Model loads in background. Press Cmd+Option — overlay appears with waveform. Press again — transcribes and pastes.

**Step 4: Commit**

```bash
git add src/__init__.py src/app.py run.py
git commit -m "feat: main app wiring all components together"
```

---

## Task 8: End-to-End Verification

**Step 1: Grant permissions**

In System Settings > Privacy & Security, add Terminal (or your terminal app) to:
- Input Monitoring
- Accessibility
- Microphone (should prompt automatically)

**Step 2: Full flow test**

1. Run `python run.py`
2. Open TextEdit or any app with a text field
3. Click into the text field
4. Press Cmd+Option — overlay should appear with waveform
5. Speak a sentence in English
6. Press Cmd+Option again — overlay shows "Transcribing..."
7. Text appears in the text field
8. Overlay fades out

**Step 3: Verify no focus stealing**

1. Open Safari, click in the URL bar
2. Press Cmd+Option — overlay appears BUT the URL bar stays focused
3. Speak and press Cmd+Option
4. Text should appear in the Safari URL bar

**Step 4: Commit final state**

```bash
git add -A
git commit -m "feat: complete transcription app v1.0"
```

---

## macOS Permissions Checklist

| Permission | Location | Required For |
|---|---|---|
| Input Monitoring | System Settings > Privacy & Security > Input Monitoring | Global hotkey (pynput) |
| Accessibility | System Settings > Privacy & Security > Accessibility | Simulating Cmd+V paste (CGEvent) |
| Microphone | System Settings > Privacy & Security > Microphone | Audio recording (sounddevice) |

---

## Troubleshooting

- **NeMo install fails on macOS**: Try `pip install nemo_toolkit[asr] --no-deps` then manually install core deps: `pip install torch torchaudio omegaconf hydra-core sentencepiece huggingface_hub`
- **pynput doesn't detect keys**: Grant Input Monitoring permission to your terminal
- **Paste doesn't work**: Grant Accessibility permission to your terminal
- **Model inference slow on CPU**: Try MPS backend (code attempts this automatically). If still slow, consider using a smaller model or Whisper via `faster-whisper` as a fallback.
