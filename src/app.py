"""
Main application controller for the Transcription app.

Orchestrates: hotkey listener, audio recorder, overlay, transcription engine, paster.

State machine:
    IDLE -> Cmd+Option -> RECORDING -> Cmd+Option -> TRANSCRIBING -> PASTE -> IDLE
"""

from __future__ import annotations

import threading

from PyQt6.QtCore import QObject, QTimer, pyqtSignal, pyqtSlot
from PyQt6.QtGui import QColor, QIcon, QPainter, QPixmap
from PyQt6.QtWidgets import QApplication, QMenu, QMessageBox, QSystemTrayIcon

from src.hotkey import CmdOptionHotkeyListener, HotkeyBridge
from src.overlay import RecordingOverlay
from src.paster import paste_text
from src.recorder import AudioRecorder
from src.transcriber import Transcriber


class TranscriptionApp(QObject):
    """Main application controller."""

    transcription_done = pyqtSignal(str)
    _status_update = pyqtSignal(str)

    def __init__(self) -> None:
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

        # Transcription result crosses from worker thread to main thread
        self.transcription_done.connect(self._on_transcription_done)
        self._status_update.connect(self._on_status_update)

        # Level feed timer (drives waveform at ~30fps during recording)
        self._level_timer = QTimer()
        self._level_timer.setInterval(33)
        self._level_timer.timeout.connect(self._feed_levels)

        # System tray
        self._tray: QSystemTrayIcon | None = None

    def start(self) -> None:
        """Initialize and start the app."""
        self._setup_tray()

        # Check if model needs downloading
        if not self._transcriber.is_model_cached():
            reply = QMessageBox.question(
                None,
                "Download Parakeet Model",
                "The Parakeet ASR model (~640MB) is not yet downloaded.\n\n"
                "Download it now? (Required for transcription)",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            )
            if reply != QMessageBox.StandardButton.Yes:
                self._tray.setToolTip("Model not downloaded — Quit and retry")
                self._tray.showMessage(
                    "Transcription",
                    "Model not downloaded. Transcription won't work until the model is downloaded.",
                    QSystemTrayIcon.MessageIcon.Warning,
                )
                return

        self._tray.setToolTip("Downloading / loading model...")
        self._tray.showMessage(
            "Transcription",
            "Loading Parakeet model... This may take a moment on first run.",
            QSystemTrayIcon.MessageIcon.Information,
        )

        # Load model in background thread with status updates
        def _load():
            def _on_status(msg: str):
                self._status_update.emit(msg)

            self._transcriber.load_model(on_status=_on_status)
            self._status_update.emit("Ready — Cmd+Option to record")

        threading.Thread(target=_load, daemon=True).start()

        # Start hotkey listener
        self._hotkey_listener.start()

    @pyqtSlot(str)
    def _on_status_update(self, message: str) -> None:
        if self._tray:
            self._tray.setToolTip(message)
            if "Ready" in message:
                self._tray.showMessage(
                    "Transcription",
                    "Model loaded! Press Cmd+Option to record.",
                    QSystemTrayIcon.MessageIcon.Information,
                )

    @pyqtSlot()
    def _on_toggle(self) -> None:
        if not self._recording:
            self._start_recording()
        else:
            self._stop_recording()

    def _start_recording(self) -> None:
        if not self._transcriber.is_loaded:
            return  # Model still loading, ignore hotkey
        self._recording = True
        self._recorder.start()
        self._overlay.fade_in()
        self._level_timer.start()
        if self._tray:
            self._tray.setToolTip("Recording...")

    def _stop_recording(self) -> None:
        self._recording = False
        self._level_timer.stop()
        audio = self._recorder.stop()
        self._overlay.show_transcribing()
        if self._tray:
            self._tray.setToolTip("Transcribing...")

        # Transcribe in background thread
        sample_rate = self._recorder.sample_rate

        def _transcribe():
            text = self._transcriber.transcribe(audio, sample_rate)
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
        if self._tray:
            self._tray.setToolTip("Ready — Cmd+Option to record")

    def _setup_tray(self) -> None:
        # Simple microphone-style icon (blue circle)
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
