#!/usr/bin/env python3
"""Entry point for the Transcription app."""

import sys

from PyQt6.QtWidgets import QApplication

from src.app import TranscriptionApp


def main() -> None:
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)  # Keep running as tray app
    app.setApplicationName("Transcription")

    transcription_app = TranscriptionApp()
    transcription_app.start()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
