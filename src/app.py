"""
Main application controller for Parkeet.

Orchestrates: hotkey listener, audio recorder, overlay, transcription engine, paster.

State machine:
    IDLE -> hotkey -> RECORDING -> hotkey -> TRANSCRIBING -> PASTE -> IDLE
"""

from __future__ import annotations

import logging
import threading
from pathlib import Path

logger = logging.getLogger(__name__)

from PyQt6.QtCore import QObject, QTimer, pyqtSignal, pyqtSlot
from PyQt6.QtGui import QColor, QIcon, QPainter, QPixmap
from PyQt6.QtWidgets import QApplication, QMenu, QMessageBox, QSystemTrayIcon

from src.config import Config
from src.file_transcriber import FileTranscriber, FileInfo
from src.history import HistoryManager
from src.history_window import HistoryWindow
from src.hotkey import ConfigurableHotkeyListener, HotkeyBridge, format_hotkey
from src.overlay import RecordingOverlay
from src.paster import paste_text
from src.recorder import AudioRecorder
from src.settings_window import SettingsWindow
from src.sounds import play as play_sound
from src.transcriber import Transcriber
from src.transcription_window import TranscriptionWindow, format_duration


class TranscriptionApp(QObject):
    """Main application controller."""

    transcription_done = pyqtSignal(str)
    _status_update = pyqtSignal(str)
    _estimate_done = pyqtSignal(float)
    _file_progress = pyqtSignal(object)
    _file_complete = pyqtSignal(str)
    _file_error = pyqtSignal(str)

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

        # History
        self._history = HistoryManager(
            retention_hours=self._config.history_retention_hours,
        )
        self._history_window = HistoryWindow(self._history)

        # Settings window (main hub — needs history manager)
        self._settings_window = SettingsWindow(
            self._config.hotkey,
            history=self._history,
            retention_hours=self._config.history_retention_hours,
            sound_enabled=self._config.sound_enabled,
            notification_enabled=self._config.notification_enabled,
        )
        self._settings_window.hotkey_changed.connect(self._on_hotkey_changed)
        self._settings_window.retention_changed.connect(self._on_retention_changed)
        self._settings_window.sound_enabled_changed.connect(self._on_sound_enabled_changed)
        self._settings_window.notification_enabled_changed.connect(self._on_notification_enabled_changed)
        self._settings_window.transcribe_file_requested.connect(self._on_transcribe_file)
        self._settings_window.file_dropped.connect(self._on_file_dropped)

        # File transcription window
        self._transcription_window = TranscriptionWindow()
        self._transcription_window.start_requested.connect(self._on_file_start)
        self._transcription_window.cancel_requested.connect(self._on_file_cancel)
        self._file_transcriber: FileTranscriber | None = None
        self._current_file_path: Path | None = None
        self._current_wav_path: Path | None = None
        self._current_file_info: FileInfo | None = None

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

        # File transcription signals
        self._estimate_done.connect(self._on_estimate_done)
        self._file_progress.connect(self._on_file_progress)
        self._file_complete.connect(self._on_file_complete)
        self._file_error.connect(self._on_file_error)

        # Level feed timer (drives waveform at ~30fps during recording)
        self._level_timer = QTimer()
        self._level_timer.setInterval(33)
        self._level_timer.timeout.connect(self._feed_levels)

        # System tray
        self._tray: QSystemTrayIcon | None = None

    # ------------------------------------------------------------------
    # Sound
    # ------------------------------------------------------------------

    def _play_sound(self, name: str) -> None:
        """Play a sound if sound feedback is enabled."""
        if self._config.sound_enabled:
            play_sound(name)

    # ------------------------------------------------------------------
    # Hotkey capture
    # ------------------------------------------------------------------

    def _pre_capture_and_emit(self) -> None:
        """Called from pynput thread. Capture frontmost app BEFORE Qt signal.

        The Qt signal crossing from background thread to main thread activates
        our app as a side effect, so by the time _on_toggle runs, we're already
        the frontmost app. Capture the real target here while the user's app
        is still active.

        If the frontmost app is Parkeet itself (e.g. history or settings window
        is open), set target to None so we don't paste back into our own UI.
        """
        try:
            import AppKit
            import os
            captured = (
                AppKit.NSWorkspace.sharedWorkspace().frontmostApplication()
            )
            if captured and captured.processIdentifier() == os.getpid():
                logger.debug("Frontmost app is Parkeet, skipping capture")
                self._target_app = None
            else:
                self._target_app = captured
                logger.debug("Captured target app: %s", captured.localizedName() if captured else None)
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
        self._settings_window.show_page(SettingsWindow.PAGE_HOTKEYS)

    def _show_history(self) -> None:
        """Show history page in the settings window."""
        self._settings_window.show_page(SettingsWindow.PAGE_HISTORY)

    def _on_tray_activated(self, reason) -> None:
        """Show settings window when tray icon is clicked."""
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            self.show_settings()

    @pyqtSlot(float)
    def _on_retention_changed(self, hours: float) -> None:
        """Called when the user changes history retention in settings."""
        logger.info("History retention changed to %s hours", hours)
        self._config.history_retention_hours = hours
        self._history.retention_hours = hours

    @pyqtSlot(bool)
    def _on_sound_enabled_changed(self, enabled: bool) -> None:
        """Called when the user toggles sound feedback in settings."""
        logger.info("Sound feedback changed to %s", enabled)
        self._config.sound_enabled = enabled

    @pyqtSlot(bool)
    def _on_notification_enabled_changed(self, enabled: bool) -> None:
        """Called when the user toggles notifications in settings."""
        logger.info("Notifications changed to %s", enabled)
        self._config.notification_enabled = enabled

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

        # Load model in background thread
        def _load():
            self._transcriber.load_model(
                on_status=lambda msg: self._status_update.emit(msg),
            )
            self._status_update.emit("ready")

        threading.Thread(target=_load, daemon=True).start()

        # Start hotkey listener
        self._hotkey_listener.start()

        # Show main settings window on launch
        self.show_settings()

    @pyqtSlot(str)
    def _on_status_update(self, message: str) -> None:
        if not self._tray:
            return
        hk = format_hotkey(self._config.hotkey)
        if message == "ready":
            logger.info("Model ready, app is operational")
            self._tray.setToolTip(f"Parkeet \u2014 Ready ({hk} to record)")
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
        self._play_sound("record_start")

        # Hide any open Parkeet windows so the user's app regains focus
        self._hide_parkeet_windows()

        self._recorder.start()
        self._overlay.fade_in()
        self._level_timer.start()
        if self._tray:
            self._tray.setToolTip("Parkeet \u2014 Recording\u2026")
        QTimer.singleShot(150, self._refocus_target)

    def _hide_parkeet_windows(self) -> None:
        """Hide settings, history, and transcription windows during recording."""
        for window in (self._settings_window, self._history_window, self._transcription_window):
            if window.isVisible():
                window.hide()
                logger.debug("Hid %s for recording", window.windowTitle())

    def _stop_recording(self) -> None:
        logger.info("Recording stopped")
        self._recording = False
        self._play_sound("record_stop")
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
        stripped = text.strip()
        if stripped:
            word_count = len(stripped.split())
            logger.info("Transcription done (%d chars, %d words), pasting", len(stripped), word_count)
            self._history.add_hotkey(stripped)
            self._play_sound("transcription_complete")

            # Show word count in overlay for 2s, then auto-fade
            self._overlay.show_complete(word_count)

            # Re-activate the user's app, then paste after a short delay
            self._refocus_target()
            self._target_app = None
            QTimer.singleShot(300, lambda: paste_text(text))

            # Show tray notification if enabled
            if self._tray and self._config.notification_enabled:
                self._tray.showMessage(
                    "Parkeet",
                    f"Transcribed {word_count:,} words and pasted.",
                    QSystemTrayIcon.MessageIcon.Information,
                )
        else:
            logger.warning("Transcription returned empty text")
            self._overlay.fade_out()
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

        transcribe_action = menu.addAction("Transcribe File\u2026")
        transcribe_action.triggered.connect(self._on_transcribe_file)

        history_action = menu.addAction("Transcription History\u2026")
        history_action.triggered.connect(self._show_history)

        menu.addSeparator()

        quit_action = menu.addAction("Quit Parkeet")
        quit_action.triggered.connect(QApplication.quit)

        self._tray.setContextMenu(menu)
        self._tray.setToolTip("Parkeet")
        self._tray.activated.connect(self._on_tray_activated)
        self._tray.show()

    # ------------------------------------------------------------------
    # File transcription
    # ------------------------------------------------------------------

    def _on_transcribe_file(self) -> None:
        """Handle 'Transcribe File...' tray menu action."""
        if not self._transcriber.is_loaded:
            logger.warning("Transcribe File requested but model not loaded")
            if self._tray:
                self._tray.showMessage(
                    "Parkeet",
                    "Model is still loading. Please wait.",
                    QSystemTrayIcon.MessageIcon.Warning,
                )
            return

        from PyQt6.QtWidgets import QFileDialog

        path, _ = QFileDialog.getOpenFileName(
            None,
            "Select Audio File",
            "",
            "Audio Files (*.m4a *.caf *.aac *.aiff *.aif *.mp3 *.wav *.qta)"
            ";;All Files (*)",
        )
        if not path:
            return

        self._start_file_transcription(Path(path))

    @pyqtSlot(str)
    def _on_file_dropped(self, path: str) -> None:
        """Handle audio file dropped onto the Transcribe File page."""
        if not self._transcriber.is_loaded:
            logger.warning("File dropped but model not loaded")
            if self._tray:
                self._tray.showMessage(
                    "Parkeet",
                    "Model is still loading. Please wait.",
                    QSystemTrayIcon.MessageIcon.Warning,
                )
            return
        logger.info("File dropped for transcription: %s", path)
        self._start_file_transcription(Path(path))

    def _start_file_transcription(self, file_path: Path) -> None:
        """Begin estimation and transcription for the given file."""
        self._current_file_path = file_path
        logger.info("Starting file transcription pipeline: %s", file_path)

        self._transcription_window.show_estimating(self._current_file_path.name)

        def _convert_and_estimate():
            try:
                ft = FileTranscriber(self._transcriber)
                self._file_transcriber = ft

                wav_path = ft.convert_to_wav(self._current_file_path)
                self._current_wav_path = wav_path

                file_info = ft.get_file_info(wav_path)
                self._current_file_info = file_info

                estimated_sec = ft.estimate_speed(wav_path, file_info)
                self._estimate_done.emit(estimated_sec)
            except Exception as e:
                logger.exception("File conversion/estimation failed")
                self._file_error.emit(str(e))

        threading.Thread(target=_convert_and_estimate, daemon=True).start()

    @pyqtSlot(float)
    def _on_estimate_done(self, estimated_sec: float) -> None:
        """Switch window to ready state with estimation results."""
        if not self._current_file_info or not self._current_file_path:
            return

        file_name = self._current_file_path.name
        duration_str = format_duration(self._current_file_info.duration_sec)
        estimate_str = format_duration(estimated_sec)
        save_path = (
            self._current_file_path.parent
            / f"{self._current_file_path.stem}_transcription.txt"
        )

        logger.info(
            "Estimation ready: %s, duration=%s, estimate=%s",
            file_name, duration_str, estimate_str,
        )
        self._transcription_window.show_ready(
            file_name, duration_str, estimate_str, save_path,
        )

    def _on_file_start(self) -> None:
        """User clicked Start Transcription."""
        if not self._file_transcriber or not self._current_wav_path:
            return

        file_name = (
            self._current_file_path.name if self._current_file_path else "unknown"
        )
        logger.info("Starting file transcription: %s", file_name)
        self._transcription_window.show_progress(file_name)

        ft = self._file_transcriber
        wav_path = self._current_wav_path

        def _run():
            ft.transcribe_file(
                wav_path=wav_path,
                on_progress=lambda p: self._file_progress.emit(p),
                on_complete=lambda text: self._file_complete.emit(text),
                on_error=lambda msg: self._file_error.emit(msg),
            )

        threading.Thread(target=_run, daemon=True).start()

    def _on_file_cancel(self) -> None:
        """User clicked Cancel during transcription."""
        if self._file_transcriber:
            self._file_transcriber.cancel()

    @pyqtSlot(object)
    def _on_file_progress(self, progress) -> None:
        """Update progress bar from background thread via signal."""
        pct = int(progress.chunks_done / progress.total_chunks * 100)
        elapsed_str = format_duration(progress.elapsed_sec)
        remaining_str = format_duration(progress.estimated_remaining_sec)
        self._transcription_window.update_progress(pct, elapsed_str, remaining_str)

    @pyqtSlot(str)
    def _on_file_complete(self, text: str) -> None:
        """Transcription finished or cancelled. Save and show completion."""
        save_path = self._transcription_window.save_path
        if not save_path and self._current_file_path:
            save_path = (
                self._current_file_path.parent
                / f"{self._current_file_path.stem}_transcription.txt"
            )

        was_cancelled = (
            self._file_transcriber.is_cancelled if self._file_transcriber else False
        )

        try:
            save_path.parent.mkdir(parents=True, exist_ok=True)
            save_path.write_text(text, encoding="utf-8")
            logger.info("Transcription saved to %s (%d chars)", save_path, len(text))
            source_name = self._current_file_path.name if self._current_file_path else "unknown"
            self._history.add_file(source_name, str(save_path))
        except OSError:
            logger.exception("Failed to save transcription to %s", save_path)
            if self._tray:
                self._tray.showMessage(
                    "Parkeet",
                    f"Failed to save transcription to {save_path}",
                    QSystemTrayIcon.MessageIcon.Critical,
                )

        self._transcription_window.show_complete(save_path, text, was_cancelled=was_cancelled)
        self._play_sound("transcription_complete")

        if self._tray and not was_cancelled and self._config.notification_enabled:
            word_count = len(text.split())
            self._tray.showMessage(
                "Parkeet",
                f"Transcription complete \u2014 {word_count:,} words saved.",
                QSystemTrayIcon.MessageIcon.Information,
            )

        if self._file_transcriber:
            self._file_transcriber.cleanup()

    @pyqtSlot(str)
    def _on_file_error(self, message: str) -> None:
        """Handle file transcription errors."""
        logger.error("File transcription error: %s", message)
        if self._tray:
            self._tray.showMessage(
                "Parkeet",
                f"Transcription failed: {message}",
                QSystemTrayIcon.MessageIcon.Critical,
            )
        self._transcription_window.close()
        if self._file_transcriber:
            self._file_transcriber.cleanup()
