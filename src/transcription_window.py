"""
Transcription window for file-based transcription.

Multi-state window: estimating -> ready -> progress -> complete.
"""

from __future__ import annotations

import logging
import subprocess
from pathlib import Path

from PyQt6.QtCore import Qt, pyqtSignal
from PyQt6.QtWidgets import (
    QApplication,
    QFileDialog,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QProgressBar,
    QPushButton,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

logger = logging.getLogger(__name__)


def format_duration(seconds: float) -> str:
    """Format seconds as human-readable duration."""
    if seconds < 60:
        return f"{seconds:.0f}s"
    minutes, secs = divmod(int(seconds), 60)
    if minutes < 60:
        return f"{minutes}m {secs}s"
    hours, mins = divmod(minutes, 60)
    return f"{hours}h {mins}m {secs}s"


class TranscriptionWindow(QWidget):
    """Multi-state window for file transcription workflow."""

    start_requested = pyqtSignal()
    cancel_requested = pyqtSignal()

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Transcribe File")
        self.setFixedWidth(480)
        self.setWindowFlags(
            Qt.WindowType.Window | Qt.WindowType.WindowCloseButtonHint
        )
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose, False)

        self._save_path: Path | None = None

        self._stack = QStackedWidget()
        self._build_estimating_page()
        self._build_ready_page()
        self._build_progress_page()
        self._build_complete_page()

        layout = QVBoxLayout(self)
        layout.addWidget(self._stack)

    # -- Page builders (called once in __init__) --

    def _build_estimating_page(self) -> None:
        page = QWidget()
        layout = QVBoxLayout(page)

        self._est_file_label = QLabel("File: ...")
        self._est_duration_label = QLabel("Duration: ...")
        self._est_status_label = QLabel("Converting and estimating speed...")
        self._est_status_label.setStyleSheet("color: #888; font-style: italic;")

        layout.addWidget(self._est_file_label)
        layout.addWidget(self._est_duration_label)
        layout.addSpacing(12)
        layout.addWidget(self._est_status_label)
        layout.addStretch()

        self._stack.addWidget(page)  # page 0

    def _build_ready_page(self) -> None:
        page = QWidget()
        layout = QVBoxLayout(page)

        self._ready_file_label = QLabel("File: ...")
        self._ready_duration_label = QLabel("Duration: ...")
        self._ready_estimate_label = QLabel("Estimated time: ...")

        save_group = QGroupBox("Save location")
        save_layout = QHBoxLayout(save_group)
        self._save_path_edit = QLineEdit()
        self._save_path_edit.setReadOnly(True)
        browse_btn = QPushButton("Browse...")
        browse_btn.clicked.connect(self._on_browse)
        save_layout.addWidget(self._save_path_edit, stretch=1)
        save_layout.addWidget(browse_btn)

        self._start_btn = QPushButton("Start Transcription")
        self._start_btn.setDefault(True)
        self._start_btn.clicked.connect(self.start_requested.emit)

        layout.addWidget(self._ready_file_label)
        layout.addWidget(self._ready_duration_label)
        layout.addWidget(self._ready_estimate_label)
        layout.addSpacing(12)
        layout.addWidget(save_group)
        layout.addSpacing(12)
        layout.addWidget(self._start_btn)
        layout.addStretch()

        self._stack.addWidget(page)  # page 1

    def _build_progress_page(self) -> None:
        page = QWidget()
        layout = QVBoxLayout(page)

        self._prog_file_label = QLabel("Transcribing: ...")
        self._progress_bar = QProgressBar()
        self._progress_bar.setRange(0, 100)
        self._prog_pct_label = QLabel("0%")
        self._prog_time_label = QLabel("Elapsed: 0s | Remaining: estimating...")

        cancel_btn = QPushButton("Cancel")
        cancel_btn.clicked.connect(self.cancel_requested.emit)

        layout.addWidget(self._prog_file_label)
        layout.addSpacing(8)
        layout.addWidget(self._progress_bar)
        layout.addWidget(self._prog_pct_label)
        layout.addWidget(self._prog_time_label)
        layout.addSpacing(12)
        layout.addWidget(cancel_btn)
        layout.addStretch()

        self._stack.addWidget(page)  # page 2

    def _build_complete_page(self) -> None:
        page = QWidget()
        layout = QVBoxLayout(page)

        self._complete_text: str = ""

        self._complete_label = QLabel("Transcription complete!")
        self._complete_label.setStyleSheet("font-size: 16px; font-weight: bold;")
        self._complete_path_label = QLabel("Saved to: ...")
        self._complete_path_label.setWordWrap(True)
        self._complete_word_count = QLabel("")
        self._complete_word_count.setStyleSheet("color: #888;")

        btn_row = QHBoxLayout()
        self._copy_text_btn = QPushButton("Copy Text")
        self._copy_text_btn.clicked.connect(self._on_copy_text)
        self._open_btn = QPushButton("Open File")
        self._open_btn.clicked.connect(self._on_open_file)
        close_btn = QPushButton("Close")
        close_btn.clicked.connect(self.close)
        btn_row.addWidget(self._copy_text_btn)
        btn_row.addWidget(self._open_btn)
        btn_row.addWidget(close_btn)

        layout.addWidget(self._complete_label)
        layout.addWidget(self._complete_path_label)
        layout.addWidget(self._complete_word_count)
        layout.addSpacing(16)
        layout.addLayout(btn_row)
        layout.addStretch()

        self._stack.addWidget(page)  # page 3

    # -- Public API --

    def show_estimating(self, file_name: str) -> None:
        """Show the estimating state."""
        self._est_file_label.setText(f"File: {file_name}")
        self._est_duration_label.setText("Duration: calculating...")
        self._est_status_label.setText("Converting and estimating speed...")
        self._stack.setCurrentIndex(0)
        self.show()
        self.raise_()

    def show_ready(
        self,
        file_name: str,
        duration_str: str,
        estimate_str: str,
        save_path: Path,
    ) -> None:
        """Show the ready state with estimation results."""
        self._ready_file_label.setText(f"File: {file_name}")
        self._ready_duration_label.setText(f"Duration: {duration_str}")
        self._ready_estimate_label.setText(f"Estimated transcription time: {estimate_str}")
        self._save_path = save_path
        self._save_path_edit.setText(str(save_path))
        self._stack.setCurrentIndex(1)

    def show_progress(self, file_name: str) -> None:
        """Switch to the progress state."""
        self._prog_file_label.setText(f"Transcribing: {file_name}")
        self._progress_bar.setValue(0)
        self._prog_pct_label.setText("0%")
        self._prog_time_label.setText("Elapsed: 0s | Remaining: estimating...")
        self._stack.setCurrentIndex(2)

    def update_progress(self, pct: int, elapsed_str: str, remaining_str: str) -> None:
        """Update the progress bar and time labels."""
        self._progress_bar.setValue(pct)
        self._prog_pct_label.setText(f"{pct}%")
        self._prog_time_label.setText(
            f"Elapsed: {elapsed_str} | Remaining: {remaining_str}"
        )

    def show_complete(
        self, save_path: Path, text: str = "", *, was_cancelled: bool = False,
    ) -> None:
        """Show the completion state with optional transcribed text for copying."""
        self._save_path = save_path
        self._complete_text = text
        word_count = len(text.split()) if text else 0

        if was_cancelled:
            self._complete_label.setText("Transcription cancelled")
            self._complete_path_label.setText(
                f"Partial transcription saved to:\n{save_path}"
            )
        else:
            self._complete_label.setText("Transcription complete!")
            self._complete_path_label.setText(f"Saved to:\n{save_path}")

        if word_count > 0:
            self._complete_word_count.setText(f"{word_count:,} words")
            self._complete_word_count.setVisible(True)
        else:
            self._complete_word_count.setVisible(False)

        self._copy_text_btn.setVisible(bool(text))
        self._stack.setCurrentIndex(3)

    @property
    def save_path(self) -> Path | None:
        return self._save_path

    # -- Internal --

    def _on_browse(self) -> None:
        path, _ = QFileDialog.getSaveFileName(
            self,
            "Save Transcription",
            str(self._save_path) if self._save_path else "",
            "Text Files (*.txt)",
        )
        if path:
            self._save_path = Path(path)
            self._save_path_edit.setText(str(self._save_path))
            logger.info("Save path changed to: %s", self._save_path)

    def _on_copy_text(self) -> None:
        if self._complete_text:
            QApplication.clipboard().setText(self._complete_text)
            self._copy_text_btn.setText("Copied!")
            logger.info("Copied %d chars of transcription to clipboard", len(self._complete_text))

    def _on_open_file(self) -> None:
        if self._save_path and self._save_path.exists():
            subprocess.Popen(["open", str(self._save_path)])
