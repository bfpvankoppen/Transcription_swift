"""
Persistent configuration for Parkeet.

Reads and writes ~/.config/parkeet/config.json.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

logger = logging.getLogger(__name__)

CONFIG_DIR = Path.home() / ".config" / "parkeet"
CONFIG_FILE = CONFIG_DIR / "config.json"

DEFAULT_CONFIG = {
    "hotkey": ["cmd", "alt"],
    "history_retention_hours": 48,
    "sound_enabled": True,
    "notification_enabled": True,
}


class Config:
    """Reads and writes ~/.config/parkeet/config.json."""

    def __init__(self) -> None:
        self._data: dict = {}
        self.load()

    def load(self) -> None:
        """Load config from disk. Falls back to defaults for missing keys."""
        if CONFIG_FILE.exists():
            try:
                with open(CONFIG_FILE, "r") as f:
                    self._data = json.load(f)
            except (json.JSONDecodeError, OSError):
                logger.warning("Corrupt config file, falling back to defaults")
                self._data = {}
        for key, default in DEFAULT_CONFIG.items():
            if key not in self._data:
                self._data[key] = default
        logger.info("Config loaded: %s", self._data)

    def save(self) -> None:
        """Write config to disk."""
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        with open(CONFIG_FILE, "w") as f:
            json.dump(self._data, f, indent=2)

    @property
    def hotkey(self) -> list[str]:
        return self._data.get("hotkey", DEFAULT_CONFIG["hotkey"])

    @hotkey.setter
    def hotkey(self, value: list[str]) -> None:
        self._data["hotkey"] = value
        self.save()
        logger.info("Config saved: hotkey=%s", value)

    @property
    def history_retention_hours(self) -> float:
        return self._data.get("history_retention_hours", 48)

    @history_retention_hours.setter
    def history_retention_hours(self, value: float) -> None:
        self._data["history_retention_hours"] = value
        self.save()
        logger.info("Config saved: history_retention_hours=%s", value)

    @property
    def sound_enabled(self) -> bool:
        return self._data.get("sound_enabled", True)

    @sound_enabled.setter
    def sound_enabled(self, value: bool) -> None:
        self._data["sound_enabled"] = value
        self.save()
        logger.info("Config saved: sound_enabled=%s", value)

    @property
    def notification_enabled(self) -> bool:
        return self._data.get("notification_enabled", True)

    @notification_enabled.setter
    def notification_enabled(self, value: bool) -> None:
        self._data["notification_enabled"] = value
        self.save()
        logger.info("Config saved: notification_enabled=%s", value)
