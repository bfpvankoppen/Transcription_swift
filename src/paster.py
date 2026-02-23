"""
Text pasting for macOS.

Sets the system clipboard via NSPasteboard, then simulates Cmd+V
via CGEvent to paste into the currently focused text field.
Restores the original clipboard afterwards.
"""

from __future__ import annotations

import time

import AppKit
import Quartz

# Virtual keycode for 'V' on macOS (hardware scancode, layout-independent)
_V_KEYCODE = 9


def paste_text(text: str) -> None:
    """Paste text into the currently focused text field via Cmd+V.

    Saves and restores the user's clipboard.
    Requires Accessibility permission for CGEventPost.
    """
    if not text or not text.strip():
        return

    pasteboard = AppKit.NSPasteboard.generalPasteboard()

    # Save current clipboard
    old_contents = pasteboard.stringForType_(AppKit.NSPasteboardTypeString)

    # Set clipboard to transcribed text
    pasteboard.clearContents()
    pasteboard.setString_forType_(text, AppKit.NSPasteboardTypeString)

    # Simulate Cmd+V
    event_down = Quartz.CGEventCreateKeyboardEvent(None, _V_KEYCODE, True)
    Quartz.CGEventSetFlags(event_down, Quartz.kCGEventFlagMaskCommand)
    event_up = Quartz.CGEventCreateKeyboardEvent(None, _V_KEYCODE, False)
    Quartz.CGEventSetFlags(event_up, Quartz.kCGEventFlagMaskCommand)

    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_down)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_up)

    # Wait for the paste to be processed, then restore clipboard
    time.sleep(0.15)
    if old_contents is not None:
        pasteboard.clearContents()
        pasteboard.setString_forType_(old_contents, AppKit.NSPasteboardTypeString)


if __name__ == "__main__":
    print("Pasting in 3 seconds... switch to a text field!")
    time.sleep(3)
    paste_text("Hello from Transcription app!")
    print("Done.")
