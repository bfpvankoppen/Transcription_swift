"""
Settings window for Parkeet.

Minimal preferences UI with two dropdown selectors for the hotkey combo.
"""

from __future__ import annotations

from PyQt6.QtCore import Qt, pyqtSignal
from PyQt6.QtWidgets import (
    QComboBox,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QVBoxLayout,
    QWidget,
)

from src.hotkey import DISPLAY_NAMES

# Modifier options: (config_name, display_label)
_MODIFIER_OPTIONS = [
    ("cmd", f"{DISPLAY_NAMES['cmd']} Command"),
    ("alt", f"{DISPLAY_NAMES['alt']} Option"),
    ("ctrl", f"{DISPLAY_NAMES['ctrl']} Control"),
    ("shift", f"{DISPLAY_NAMES['shift']} Shift"),
]


class SettingsWindow(QWidget):
    """Minimal settings window for configuring the recording hotkey."""

    hotkey_changed = pyqtSignal(list)

    def __init__(self, current_hotkey: list[str], parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Parkeet Settings")
        self.setMinimumWidth(320)
        self.setWindowFlags(
            Qt.WindowType.Window | Qt.WindowType.WindowCloseButtonHint
        )
        # Close hides — Dock click re-shows without recreating.
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose, False)

        layout = QVBoxLayout(self)

        # Hotkey group
        group = QGroupBox("Recording Hotkey")
        group_layout = QHBoxLayout(group)

        label1 = QLabel("Key 1:")
        self._combo1 = QComboBox()
        plus_label = QLabel("+")
        label2 = QLabel("Key 2:")
        self._combo2 = QComboBox()

        for config_name, display in _MODIFIER_OPTIONS:
            self._combo1.addItem(display, config_name)
            self._combo2.addItem(display, config_name)

        # Set current values
        key1 = current_hotkey[0] if len(current_hotkey) > 0 else "cmd"
        key2 = current_hotkey[1] if len(current_hotkey) > 1 else "alt"
        self._set_combo_value(self._combo1, key1)
        self._set_combo_value(self._combo2, key2)

        self._combo1.currentIndexChanged.connect(self._on_combo_changed)
        self._combo2.currentIndexChanged.connect(self._on_combo_changed)

        group_layout.addWidget(label1)
        group_layout.addWidget(self._combo1)
        group_layout.addWidget(plus_label)
        group_layout.addWidget(label2)
        group_layout.addWidget(self._combo2)
        group_layout.addStretch()

        layout.addWidget(group)
        layout.addStretch()

    @staticmethod
    def _set_combo_value(combo: QComboBox, value: str) -> None:
        for i in range(combo.count()):
            if combo.itemData(i) == value:
                combo.setCurrentIndex(i)
                return

    def _on_combo_changed(self) -> None:
        key1 = self._combo1.currentData()
        key2 = self._combo2.currentData()
        if key1 == key2:
            return  # ignore duplicate selection
        self.hotkey_changed.emit([key1, key2])

    def update_hotkey_display(self, hotkey: list[str]) -> None:
        """Update the dropdowns to reflect a new hotkey."""
        self._combo1.blockSignals(True)
        self._combo2.blockSignals(True)
        if len(hotkey) > 0:
            self._set_combo_value(self._combo1, hotkey[0])
        if len(hotkey) > 1:
            self._set_combo_value(self._combo2, hotkey[1])
        self._combo1.blockSignals(False)
        self._combo2.blockSignals(False)
