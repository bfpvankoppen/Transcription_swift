"""
Persistent configuration for Parkeet.

Reads and writes ~/.config/parkeet/config.json.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Dict

logger = logging.getLogger(__name__)

CONFIG_DIR = Path.home() / ".config" / "parkeet"
CONFIG_FILE = CONFIG_DIR / "config.json"

DEFAULT_CONFIG = {
    "hotkey": ["cmd", "alt"],
    "history_retention_hours": 48,
    "sound_enabled": True,
    "notification_enabled": True,
    "voice_commands": {},  # per-command overrides; missing keys default to True
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

    @property
    def voice_commands(self) -> Dict[str, bool]:
        """Per-command enabled state. Missing keys default to True."""
        return self._data.get("voice_commands", {})

    @voice_commands.setter
    def voice_commands(self, value: Dict[str, bool]) -> None:
        self._data["voice_commands"] = value
        self.save()
        logger.info("Config saved: voice_commands=%s", value)

    def set_voice_command(self, command: str, enabled: bool) -> None:
        """Toggle a single voice command on or off."""
        cmds = self._data.get("voice_commands", {})
        cmds[command] = enabled
        self._data["voice_commands"] = cmds
        self.save()
        logger.info("Config saved: voice_command %r = %s", command, enabled)

    def get_voice_commands_enabled(self) -> Dict[str, bool]:
        """Return the full enabled dict with defaults filled in.

        Commands not explicitly set in config default to True.
        """
        from src.voice_commands import default_enabled
        result = default_enabled()
        result.update(self._data.get("voice_commands", {}))
        return result
