"""
Transcription history persistence for Parkeet.

Stores recent transcriptions in ~/.config/parkeet/history.json.
Auto-purges entries older than the configured retention period.
"""

from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Literal

from src.config import CONFIG_DIR

logger = logging.getLogger(__name__)

HISTORY_FILE = CONFIG_DIR / "history.json"
CURRENT_VERSION = 1


class HistoryEntry:
    """A single history entry (hotkey or file transcription)."""

    def __init__(
        self,
        *,
        id: str,
        type: Literal["hotkey", "file"],
        timestamp: str,
        text: str | None = None,
        source_name: str | None = None,
        output_path: str | None = None,
    ) -> None:
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.text = text
        self.source_name = source_name
        self.output_path = output_path

    @property
    def dt(self) -> datetime:
        return datetime.fromisoformat(self.timestamp)

    def to_dict(self) -> dict:
        d = {"id": self.id, "type": self.type, "timestamp": self.timestamp}
        if self.type == "hotkey":
            d["text"] = self.text
        else:
            d["source_name"] = self.source_name
            d["output_path"] = self.output_path
        return d

    @classmethod
    def from_dict(cls, data: dict) -> HistoryEntry:
        return cls(
            id=data.get("id", str(uuid.uuid4())),
            type=data["type"],
            timestamp=data["timestamp"],
            text=data.get("text"),
            source_name=data.get("source_name"),
            output_path=data.get("output_path"),
        )


class HistoryManager:
    """Manages transcription history with auto-purge."""

    def __init__(self, retention_hours: float = 48.0) -> None:
        self._retention_hours = retention_hours
        self._entries: list[HistoryEntry] = []
        self._load()
        self._purge()

    @property
    def retention_hours(self) -> float:
        return self._retention_hours

    @retention_hours.setter
    def retention_hours(self, value: float) -> None:
        self._retention_hours = value
        self._purge()

    @property
    def entries(self) -> list[HistoryEntry]:
        """Return entries newest-first."""
        return list(reversed(self._entries))

    def add_hotkey(self, text: str) -> None:
        """Record a hotkey transcription."""
        entry = HistoryEntry(
            id=str(uuid.uuid4()),
            type="hotkey",
            timestamp=datetime.now(timezone.utc).isoformat(),
            text=text,
        )
        self._entries.append(entry)
        logger.info("History: added hotkey entry (%d chars)", len(text))
        self._purge()
        self._save()

    def add_file(self, source_name: str, output_path: str) -> None:
        """Record a file transcription."""
        entry = HistoryEntry(
            id=str(uuid.uuid4()),
            type="file",
            timestamp=datetime.now(timezone.utc).isoformat(),
            source_name=source_name,
            output_path=output_path,
        )
        self._entries.append(entry)
        logger.info("History: added file entry (%s -> %s)", source_name, output_path)
        self._purge()
        self._save()

    def _purge(self) -> None:
        """Remove entries older than retention period."""
        cutoff = datetime.now(timezone.utc) - timedelta(hours=self._retention_hours)
        before = len(self._entries)
        self._entries = [
            e for e in self._entries if e.dt >= cutoff
        ]
        removed = before - len(self._entries)
        if removed > 0:
            logger.info("History: purged %d entries older than %dh", removed, self._retention_hours)
            self._save()

    def _load(self) -> None:
        """Load history from disk."""
        if not HISTORY_FILE.exists():
            logger.debug("History file not found, starting fresh")
            return
        try:
            with open(HISTORY_FILE, "r") as f:
                data = json.load(f)
            self._entries = [
                HistoryEntry.from_dict(e) for e in data.get("entries", [])
            ]
            logger.info("History loaded: %d entries", len(self._entries))
        except (json.JSONDecodeError, OSError, KeyError):
            logger.warning("Corrupt history file, starting fresh")
            self._entries = []

    def _save(self) -> None:
        """Write history to disk."""
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        data = {
            "version": CURRENT_VERSION,
            "entries": [e.to_dict() for e in self._entries],
        }
        try:
            with open(HISTORY_FILE, "w") as f:
                json.dump(data, f, indent=2)
            logger.debug("History saved: %d entries", len(self._entries))
        except OSError:
            logger.exception("Failed to save history")
