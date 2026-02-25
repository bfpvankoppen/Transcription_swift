"""
Global hotkey detection with configurable modifier keys on macOS.

Requires macOS Accessibility / Input Monitoring permissions.
Uses pynput to detect when configured modifier keys are pressed
together and then released, functioning as a toggle.
"""

from __future__ import annotations

import logging

from pynput import keyboard
from PyQt6.QtCore import QObject, pyqtSignal

logger = logging.getLogger(__name__)


class HotkeyBridge(QObject):
    """Bridges the pynput listener thread to the Qt main thread via a signal."""

    toggled = pyqtSignal()


# Mapping from config string names to sets of pynput Key objects
MODIFIER_KEY_MAP = {
    "cmd": {keyboard.Key.cmd, keyboard.Key.cmd_l, keyboard.Key.cmd_r},
    "alt": {keyboard.Key.alt, keyboard.Key.alt_l, keyboard.Key.alt_r},
    "ctrl": {keyboard.Key.ctrl, keyboard.Key.ctrl_l, keyboard.Key.ctrl_r},
    "shift": {keyboard.Key.shift, keyboard.Key.shift_l, keyboard.Key.shift_r},
}

ALL_MODIFIER_KEYS = set()
for _keys in MODIFIER_KEY_MAP.values():
    ALL_MODIFIER_KEYS |= _keys
ALL_MODIFIER_KEYS.add(keyboard.Key.caps_lock)

# macOS modifier symbols for display
DISPLAY_NAMES = {
    "cmd": "\u2318",
    "alt": "\u2325",
    "ctrl": "\u2303",
    "shift": "\u21E7",
}

# Canonical display order
_ORDER = ["ctrl", "alt", "shift", "cmd"]


def format_hotkey(modifiers: list[str]) -> str:
    """Format a modifier list as macOS symbols (e.g. '\u2318\u2325')."""
    ordered = sorted(modifiers, key=lambda m: _ORDER.index(m) if m in _ORDER else 99)
    return "".join(DISPLAY_NAMES.get(m, m) for m in ordered)


class ConfigurableHotkeyListener:
    """
    Detects when a configurable set of modifier keys are all pressed
    together and then released. Works globally.

    If any non-modifier key is pressed while holding the combo, it is
    cancelled to avoid false triggers from shortcuts like Cmd+Option+Esc.
    """

    def __init__(self, modifiers: list[str], on_toggle: callable) -> None:
        self._on_toggle = on_toggle
        self._modifier_names = list(modifiers)
        self._pressed: dict[str, bool] = {name: False for name in modifiers}
        self._combo_activated = False
        self._cancelled = False
        self._listener = None

    def _key_to_name(self, key) -> str | None:
        """Map a pynput key to one of the configured modifier names."""
        for name in self._modifier_names:
            if key in MODIFIER_KEY_MAP.get(name, set()):
                return name
        return None

    def _all_pressed(self) -> bool:
        return all(self._pressed.values())

    def _none_pressed(self) -> bool:
        return not any(self._pressed.values())

    def _on_press(self, key) -> None:
        name = self._key_to_name(key)
        if name:
            self._pressed[name] = True
        elif key not in ALL_MODIFIER_KEYS:
            self._cancelled = True

        if self._all_pressed() and not self._cancelled:
            self._combo_activated = True

    def _on_release(self, key) -> None:
        name = self._key_to_name(key)
        if name:
            self._pressed[name] = False

        if self._combo_activated and self._none_pressed():
            if not self._cancelled:
                logger.info("Hotkey toggle fired (%s)", self._modifier_names)
                self._on_toggle()
            self._combo_activated = False
            self._cancelled = False

        if self._none_pressed():
            self._cancelled = False
            self._combo_activated = False

    def update_modifiers(self, modifiers: list[str]) -> None:
        """Hot-swap the modifier configuration without restarting the listener.

        Avoids stopping/restarting the pynput thread, which would crash on
        macOS 26+ because TSMGetInputSourceProperty requires main-thread
        execution and pynput re-initialises it on its background thread.
        """
        logger.debug("Hot-swapping modifiers: %s -> %s", self._modifier_names, modifiers)
        self._modifier_names = list(modifiers)
        self._pressed = {name: False for name in modifiers}
        self._combo_activated = False
        self._cancelled = False

    def start(self) -> None:
        """Start listening for the global hotkey. Non-blocking."""
        logger.info("Starting hotkey listener for %s", self._modifier_names)
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


# Backwards compatibility alias
CmdOptionHotkeyListener = ConfigurableHotkeyListener


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

    listener = ConfigurableHotkeyListener(
        modifiers=["cmd", "alt"], on_toggle=on_toggle
    )
    listener.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        listener.stop()
        print("\nDone.")
