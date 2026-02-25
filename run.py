#!/usr/bin/env python3
"""Entry point for Parkeet."""

import logging
import logging.handlers
import sys
from pathlib import Path

import AppKit
from PyQt6.QtWidgets import QApplication

from src.app import TranscriptionApp


LOG_DIR = Path.home() / ".config" / "parkeet"
LOG_FILE = LOG_DIR / "parkeet.log"

logger = logging.getLogger(__name__)


def _setup_logging() -> None:
    """Configure file + console logging for the entire app."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    fmt = logging.Formatter(
        "%(asctime)s %(levelname)-5s [%(name)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # File: DEBUG level, rotated at 2 MB, keep 3 backups
    file_handler = logging.handlers.RotatingFileHandler(
        LOG_FILE, maxBytes=2 * 1024 * 1024, backupCount=3, encoding="utf-8",
    )
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(fmt)

    # Console (stderr): INFO level
    console_handler = logging.StreamHandler(sys.stderr)
    console_handler.setLevel(logging.INFO)
    console_handler.setFormatter(fmt)

    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    root.addHandler(file_handler)
    root.addHandler(console_handler)


def main() -> None:
    _setup_logging()
    logger.info("Parkeet starting")

    app = QApplication(sys.argv)

    # Accessory policy: no Dock icon, but overlay appears on all Spaces.
    # Regular policy breaks all-Spaces overlay on macOS 26.
    AppKit.NSApp.setActivationPolicy_(
        AppKit.NSApplicationActivationPolicyAccessory
    )

    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("Parkeet")

    transcription_app = TranscriptionApp()
    app._transcription_app = transcription_app

    transcription_app.start()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
