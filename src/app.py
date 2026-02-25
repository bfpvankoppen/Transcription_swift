"""
Main application controller for Parkeet.

Orchestrates: hotkey listener, audio recorder, overlay, transcription engine, paster.

State machine:
    IDLE -> hotkey -> RECORDING -> hotkey -> TRANSCRIBING -> PASTE -> IDLE
"""

from __future__ import annotations

import logging
import threading

logger = logging.getLogger(__name__)

from PyQt6.QtCore import QObject, QTimer, pyqtSignal, pyqtSlot
from PyQt6.QtGui import QColor, QIcon, QPainter, QPixmap
from PyQt6.QtWidgets import QApplication, QMenu, QMessageBox, QSystemTrayIcon

from src.config import Config
from src.hotkey import ConfigurableHotkeyListener, HotkeyBridge, format_hotkey
from src.overlay import RecordingOverlay
from src.paster import paste_text
from src.recorder import AudioRecorder
from src.settings_window import SettingsWindow
from src.transcriber import Transcriber


class TranscriptionApp(QObject):
    """Main application controller."""

    transcription_done = pyqtSignal(str)
    _status_update = pyqtSignal(str)

    def __init__(self) -> None:
        super().__init__()
        self._recording = False
        self._target_app = None  # app that was focused when recording started

        # Configuration
        self._config = Config()

        # Components
        self._overlay = RecordingOverlay()
        self._recorder = AudioRecorder()
        self._transcriber = Transcriber()

        # Settings window
        self._settings_window = SettingsWindow(self._config.hotkey)
        self._settings_window.hotkey_changed.connect(self._on_hotkey_changed)

        # Hotkey — capture frontmost app BEFORE the Qt signal activates our app
        self._hotkey_bridge = HotkeyBridge()
        self._hotkey_bridge.toggled.connect(self._on_toggle)
        self._hotkey_listener = ConfigurableHotkeyListener(
            modifiers=self._config.hotkey,
            on_toggle=self._pre_capture_and_emit,
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

    # ------------------------------------------------------------------
    # Hotkey capture
    # ------------------------------------------------------------------

    def _pre_capture_and_emit(self) -> None:
        """Called from pynput thread. Capture frontmost app BEFORE Qt signal.

        The Qt signal crossing from background thread to main thread activates
        our app as a side effect, so by the time _on_toggle runs, we're already
        the frontmost app. Capture the real target here while the user's app
        is still active.
        """
        try:
            import AppKit
            self._target_app = (
                AppKit.NSWorkspace.sharedWorkspace().frontmostApplication()
            )
            logger.debug("Captured target app: %s", self._target_app.localizedName() if self._target_app else None)
        except Exception:
            logger.debug("Could not capture target app", exc_info=True)
            self._target_app = None
        self._hotkey_bridge.toggled.emit()

    def _refocus_target(self) -> None:
        """Re-activate the user's app (without clearing the saved reference)."""
        if self._target_app is None:
            return
        try:
            import AppKit
            self._target_app.activateWithOptions_(
                AppKit.NSApplicationActivateIgnoringOtherApps
            )
        except Exception:
            logger.debug("Could not refocus target app", exc_info=True)

    # ------------------------------------------------------------------
    # Settings
    # ------------------------------------------------------------------

    def show_settings(self) -> None:
        """Show or raise the settings window."""
        self._settings_window.show()
        self._settings_window.raise_()
        self._settings_window.activateWindow()

    @pyqtSlot(list)
    def _on_hotkey_changed(self, new_hotkey: list[str]) -> None:
        """Called when the user records a new hotkey in settings."""
        logger.info("Hotkey changed to %s", new_hotkey)
        self._config.hotkey = new_hotkey  # persists to disk

        # Hot-swap modifiers on the existing listener (do NOT restart —
        # pynput's TSMGetInputSourceProperty crashes on macOS 26+ when
        # a new listener thread re-initialises the Text Services Manager).
        self._hotkey_listener.update_modifiers(new_hotkey)

        # Update tray tooltip
        if self._tray and self._transcriber.is_loaded:
            hk = format_hotkey(new_hotkey)
            self._tray.setToolTip(f"Parkeet \u2014 Ready ({hk} to record)")

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start(self) -> None:
        """Initialize and start the app."""
        logger.info("App starting")
        self._setup_tray()

        hk = format_hotkey(self._config.hotkey)

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
                self._tray.setToolTip("Model not downloaded \u2014 Quit and retry")
                self._tray.showMessage(
                    "Parkeet",
                    "Model not downloaded. Transcription won't work until the model is downloaded.",
                    QSystemTrayIcon.MessageIcon.Warning,
                )
                return

        self._tray.setToolTip("Parkeet \u2014 Loading model\u2026")
        self._tray.showMessage(
            "Parkeet",
            "Loading model\u2026 This may take a moment on first run.",
            QSystemTrayIcon.MessageIcon.Information,
        )

        # Load model in background thread
        def _load():
            self._transcriber.load_model(
                on_status=lambda msg: self._status_update.emit(msg),
            )
            self._status_update.emit("ready")

        threading.Thread(target=_load, daemon=True).start()

        # Start hotkey listener
        self._hotkey_listener.start()

    @pyqtSlot(str)
    def _on_status_update(self, message: str) -> None:
        if not self._tray:
            return
        hk = format_hotkey(self._config.hotkey)
        if message == "ready":
            logger.info("Model ready, app is operational")
            self._tray.setToolTip(f"Parkeet \u2014 Ready ({hk} to record)")
            self._tray.showMessage(
                "Parkeet",
                f"Ready! Press {hk} to record.",
                QSystemTrayIcon.MessageIcon.Information,
            )
        else:
            self._tray.setToolTip(f"Parkeet \u2014 {message}")

    @pyqtSlot()
    def _on_toggle(self) -> None:
        if not self._recording:
            self._start_recording()
        else:
            self._stop_recording()

    def _start_recording(self) -> None:
        if not self._transcriber.is_loaded:
            logger.warning("Hotkey pressed but model not loaded yet, ignoring")
            return
        logger.info("Recording started")
        self._recording = True
        self._recorder.start()
        self._overlay.fade_in()
        self._level_timer.start()
        if self._tray:
            self._tray.setToolTip("Parkeet \u2014 Recording\u2026")
        QTimer.singleShot(150, self._refocus_target)

    def _stop_recording(self) -> None:
        logger.info("Recording stopped")
        self._recording = False
        self._level_timer.stop()
        audio = self._recorder.stop()
        self._overlay.show_transcribing()
        if self._tray:
            self._tray.setToolTip("Parkeet \u2014 Transcribing\u2026")
        QTimer.singleShot(150, self._refocus_target)

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
        if text.strip():
            logger.info("Transcription done (%d chars), pasting", len(text.strip()))
        else:
            logger.warning("Transcription returned empty text")
        self._overlay.fade_out()
        if text.strip():
            # Re-activate the user's app, then paste after a short delay
            self._refocus_target()
            self._target_app = None
            QTimer.singleShot(300, lambda: paste_text(text))
        else:
            self._target_app = None
        if self._tray:
            hk = format_hotkey(self._config.hotkey)
            self._tray.setToolTip(f"Parkeet \u2014 Ready ({hk} to record)")

    # ------------------------------------------------------------------
    # System tray
    # ------------------------------------------------------------------

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

        settings_action = menu.addAction("Settings\u2026")
        settings_action.triggered.connect(self.show_settings)

        menu.addSeparator()

        quit_action = menu.addAction("Quit Parkeet")
        quit_action.triggered.connect(QApplication.quit)

        self._tray.setContextMenu(menu)
        self._tray.setToolTip("Parkeet")
        self._tray.show()
