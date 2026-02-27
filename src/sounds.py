"""
Subtle sound feedback using macOS system sounds.

Plays built-in system sounds via NSSound for non-blocking audio.
"""

from __future__ import annotations

import logging

logger = logging.getLogger(__name__)

# macOS system sound paths
_SOUNDS_DIR = "/System/Library/Sounds"
_SOUND_MAP = {
    "record_start": f"{_SOUNDS_DIR}/Tink.aiff",
    "record_stop": f"{_SOUNDS_DIR}/Pop.aiff",
    "transcription_complete": f"{_SOUNDS_DIR}/Glass.aiff",
}


def play(name: str) -> None:
    """Play a named sound asynchronously. Silently ignores errors."""
    path = _SOUND_MAP.get(name)
    if not path:
        logger.warning("Unknown sound name: %s", name)
        return
    try:
        from AppKit import NSSound

        sound = NSSound.alloc().initWithContentsOfFile_byReference_(path, True)
        if sound:
            sound.play()
            logger.debug("Playing sound: %s", name)
        else:
            logger.debug("Could not load sound: %s", path)
    except Exception:
        logger.debug("Sound playback failed for %s", name, exc_info=True)
