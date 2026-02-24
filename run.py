#!/usr/bin/env python3
"""Entry point for the Transcription app."""

import sys

import AppKit
from PyQt6.QtWidgets import QApplication

from src.app import TranscriptionApp


def main() -> None:
    app = QApplication(sys.argv)

    # Hide from Dock and Cmd+Tab (menu bar / tray app only).
    # Must be called AFTER QApplication() creates the NSApplication.
    AppKit.NSApp.setActivationPolicy_(
        AppKit.NSApplicationActivationPolicyAccessory
    )

    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("Transcription")

    transcription_app = TranscriptionApp()
    transcription_app.start()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
