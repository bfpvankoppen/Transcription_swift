"""
Transcription history window for Parkeet.

Compact single-row entries with click-to-expand detail view.
"""

from __future__ import annotations

import logging
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QApplication,
    QFrame,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from src.history import HistoryEntry, HistoryManager

logger = logging.getLogger(__name__)

PREVIEW_CHARS = 80


def _format_timestamp(iso_ts: str) -> str:
    """Format timestamp as relative (<24h) or absolute."""
    dt = datetime.fromisoformat(iso_ts)
    now = datetime.now(timezone.utc)
    delta = now - dt

    total_seconds = int(delta.total_seconds())
    if total_seconds < 60:
        return "now"
    if total_seconds < 3600:
        return f"{total_seconds // 60}m"
    if total_seconds < 86400:
        return f"{total_seconds // 3600}h"

    local_dt = dt.astimezone()
    yesterday = (now - timedelta(days=1)).astimezone().date()
    if local_dt.date() == yesterday:
        return local_dt.strftime("Yesterday %I:%M %p")
    return local_dt.strftime("%b %d, %I:%M %p")


def _truncate(text: str, max_len: int = PREVIEW_CHARS) -> str:
    """Truncate text with ellipsis."""
    if len(text) <= max_len:
        return text
    return text[:max_len].rstrip() + "\u2026"


class _HistoryRow(QFrame):
    """A single compact history row with click-to-expand."""

    def __init__(self, entry: HistoryEntry, parent=None) -> None:
        super().__init__(parent)
        self._entry = entry
        self._expanded = False

        self.setFrameShape(QFrame.Shape.StyledPanel)
        self.setStyleSheet(
            "_HistoryRow { border: 1px solid #333; border-radius: 4px; padding: 4px; }"
        )
        self.setCursor(Qt.CursorShape.PointingHandCursor)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(8, 4, 8, 4)
        outer.setSpacing(0)

        # Compact row: type | preview | time
        self._row = QHBoxLayout()
        self._row.setSpacing(8)

        # Type label
        if entry.type == "hotkey":
            type_text = "Dictation"
            type_color = "#64B4FF"
            preview = _truncate(entry.text or "")
        else:
            type_text = "File"
            type_color = "#7BC47F"
            source = entry.source_name or "unknown"
            output = Path(entry.output_path).name if entry.output_path else "unknown"
            preview = f"{source} \u2192 {output}"

        type_label = QLabel(type_text)
        type_label.setStyleSheet(f"font-weight: bold; color: {type_color};")
        type_label.setFixedWidth(62)

        self._preview_label = QLabel(preview)
        self._preview_label.setStyleSheet("color: #CCC;")
        self._preview_label.setTextInteractionFlags(Qt.TextInteractionFlag.NoTextInteraction)

        time_label = QLabel(_format_timestamp(entry.timestamp))
        time_label.setStyleSheet("color: #888;")
        time_label.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)

        self._row.addWidget(type_label)
        self._row.addWidget(self._preview_label, stretch=1)
        self._row.addWidget(time_label)
        outer.addLayout(self._row)

        # Expanded detail (hidden by default)
        self._detail = QWidget()
        self._detail.setVisible(False)
        detail_layout = QVBoxLayout(self._detail)
        detail_layout.setContentsMargins(70, 6, 0, 2)
        detail_layout.setSpacing(4)

        if entry.type == "hotkey":
            full_text = QLabel(entry.text or "")
            full_text.setWordWrap(True)
            full_text.setTextInteractionFlags(
                Qt.TextInteractionFlag.TextSelectableByMouse
            )
            full_text.setStyleSheet("color: #DDD;")
            detail_layout.addWidget(full_text)

            btn_row = QHBoxLayout()
            copy_btn = QPushButton("Copy")
            copy_btn.setFixedWidth(60)
            copy_btn.setCursor(Qt.CursorShape.ArrowCursor)
            copy_btn.clicked.connect(self._on_copy)
            btn_row.addStretch()
            btn_row.addWidget(copy_btn)
            detail_layout.addLayout(btn_row)
        else:
            output_path = Path(entry.output_path) if entry.output_path else None
            if output_path and output_path.exists():
                btn_row = QHBoxLayout()
                open_btn = QPushButton("Open File")
                open_btn.setFixedWidth(80)
                open_btn.setCursor(Qt.CursorShape.ArrowCursor)
                open_btn.clicked.connect(self._on_open_file)
                btn_row.addStretch()
                btn_row.addWidget(open_btn)
                detail_layout.addLayout(btn_row)
            else:
                err = QLabel("File not found \u2014 it may have been moved or deleted")
                err.setStyleSheet("color: #E55; font-style: italic;")
                detail_layout.addWidget(err)

        outer.addWidget(self._detail)

    def mousePressEvent(self, event) -> None:
        self._expanded = not self._expanded
        self._detail.setVisible(self._expanded)
        self._preview_label.setVisible(not self._expanded)
        super().mousePressEvent(event)

    def _on_copy(self) -> None:
        QApplication.clipboard().setText(self._entry.text or "")
        logger.debug("Copied %d chars to clipboard from history", len(self._entry.text or ""))

    def _on_open_file(self) -> None:
        p = Path(self._entry.output_path) if self._entry.output_path else None
        if p and p.exists():
            subprocess.Popen(["open", str(p)])
            logger.debug("Opened file from history: %s", p)
        else:
            logger.warning("File not found when opening from history: %s", self._entry.output_path)


class HistoryWindow(QWidget):
    """Compact scrollable history of recent transcriptions."""

    def __init__(self, history: HistoryManager, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Transcription History")
        self.setFixedWidth(780)
        self.setMinimumHeight(300)
        self.setWindowFlags(
            Qt.WindowType.Window | Qt.WindowType.WindowCloseButtonHint
        )
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose, False)

        self._history = history

        layout = QVBoxLayout(self)
        layout.setContentsMargins(8, 8, 8, 8)

        self._empty_label = QLabel("No recent transcriptions")
        self._empty_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._empty_label.setStyleSheet("color: #888; font-style: italic; padding: 40px;")

        self._scroll = QScrollArea()
        self._scroll.setWidgetResizable(True)
        self._scroll.setFrameShape(QFrame.Shape.NoFrame)

        self._container = QWidget()
        self._container_layout = QVBoxLayout(self._container)
        self._container_layout.setContentsMargins(0, 0, 0, 0)
        self._container_layout.setSpacing(2)
        self._scroll.setWidget(self._container)

        layout.addWidget(self._empty_label)
        layout.addWidget(self._scroll)

    def refresh(self) -> None:
        """Rebuild the list from history entries."""
        # Clear existing rows
        while self._container_layout.count():
            item = self._container_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        entries = self._history.entries
        has_entries = len(entries) > 0
        self._empty_label.setVisible(not has_entries)
        self._scroll.setVisible(has_entries)

        for entry in entries:
            row = _HistoryRow(entry)
            self._container_layout.addWidget(row)

        self._container_layout.addStretch()
