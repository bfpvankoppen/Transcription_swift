"""
Global hotkey detection for Cmd+Option toggle on macOS.

Requires macOS Accessibility / Input Monitoring permissions.
Uses pynput to detect when both Command and Option are pressed
together and then released, functioning as a toggle.
"""

from __future__ import annotations

from pynput import keyboard
from PyQt6.QtCore import QObject, pyqtSignal


class HotkeyBridge(QObject):
    """Bridges the pynput listener thread to the Qt main thread via a signal."""

    toggled = pyqtSignal()


class CmdOptionHotkeyListener:
    """
    Detects when Command + Option are pressed together and then released.
    Works globally (even when another app is focused).

    If any non-modifier key is pressed while holding Cmd+Option, the combo
    is cancelled to avoid false triggers from shortcuts like Cmd+Option+Esc.
    """

    def __init__(self, on_toggle: callable) -> None:
        self._on_toggle = on_toggle
        self._cmd_pressed = False
        self._option_pressed = False
        self._combo_activated = False
        self._cancelled = False
        self._listener = None

    @staticmethod
    def _is_cmd(key) -> bool:
        return key in (keyboard.Key.cmd, keyboard.Key.cmd_l, keyboard.Key.cmd_r)

    @staticmethod
    def _is_option(key) -> bool:
        return key in (keyboard.Key.alt, keyboard.Key.alt_l, keyboard.Key.alt_r)

    @staticmethod
    def _is_modifier(key) -> bool:
        return key in {
            keyboard.Key.cmd, keyboard.Key.cmd_l, keyboard.Key.cmd_r,
            keyboard.Key.alt, keyboard.Key.alt_l, keyboard.Key.alt_r,
            keyboard.Key.shift, keyboard.Key.shift_l, keyboard.Key.shift_r,
            keyboard.Key.ctrl, keyboard.Key.ctrl_l, keyboard.Key.ctrl_r,
            keyboard.Key.caps_lock,
        }

    def _on_press(self, key) -> None:
        if self._is_cmd(key):
            self._cmd_pressed = True
        elif self._is_option(key):
            self._option_pressed = True
        elif not self._is_modifier(key):
            self._cancelled = True

        if self._cmd_pressed and self._option_pressed and not self._cancelled:
            self._combo_activated = True

    def _on_release(self, key) -> None:
        if self._is_cmd(key):
            self._cmd_pressed = False
        elif self._is_option(key):
            self._option_pressed = False

        if self._combo_activated and not self._cmd_pressed and not self._option_pressed:
            if not self._cancelled:
                self._on_toggle()
            self._combo_activated = False
            self._cancelled = False

        if not self._cmd_pressed and not self._option_pressed:
            self._cancelled = False
            self._combo_activated = False

    def start(self) -> None:
        """Start listening for the global hotkey. Non-blocking."""
        self._listener = keyboard.Listener(
            on_press=self._on_press,
            on_release=self._on_release,
        )
        self._listener.daemon = True
        self._listener.start()

    def stop(self) -> None:
        """Stop the listener."""
        if self._listener:
            self._listener.stop()
            self._listener = None


if __name__ == "__main__":
    import time

    toggle_count = 0

    def on_toggle():
        global toggle_count
        toggle_count += 1
        state = "RECORDING" if toggle_count % 2 == 1 else "STOPPED"
        print(f"[Toggle #{toggle_count}] -> {state}")

    print("Listening for Cmd+Option toggle... (Ctrl+C to quit)")
    print("Press and release Cmd+Option to toggle.")

    listener = CmdOptionHotkeyListener(on_toggle=on_toggle)
    listener.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        listener.stop()
        print("\nDone.")
