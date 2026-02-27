"""
Settings window for Parkeet.

macOS System Settings style: sidebar on the left, content pane on the right.
Acts as the main hub — hotkey settings, transcription history, and file transcription.
"""

from __future__ import annotations

import logging

from PyQt6.QtCore import Qt, pyqtSignal
from PyQt6.QtWidgets import (
    QApplication,
    QComboBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QPushButton,
    QScrollArea,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from src.history import HistoryEntry, HistoryManager
from src.history_window import _HistoryRow
from src.hotkey import DISPLAY_NAMES

logger = logging.getLogger(__name__)

# Modifier options: (config_name, display_label)
_MODIFIER_OPTIONS = [
    ("cmd", f"{DISPLAY_NAMES['cmd']} Command"),
    ("alt", f"{DISPLAY_NAMES['alt']} Option"),
    ("ctrl", f"{DISPLAY_NAMES['ctrl']} Control"),
    ("shift", f"{DISPLAY_NAMES['shift']} Shift"),
]

# Retention presets: (display_label, hours)
_RETENTION_OPTIONS = [
    ("1 day", 24),
    ("2 days", 48),
    ("7 days", 168),
    ("14 days", 336),
    ("30 days", 720),
    ("90 days", 2160),
]

_WINDOW_STYLE = """
    SettingsWindow {
        background-color: #1E1E1E;
    }
"""

_SIDEBAR_STYLE = """
    QListWidget {
        background-color: #252525;
        border: none;
        border-right: 1px solid #333;
        outline: none;
        font-size: 13px;
        padding: 8px 0;
    }
    QListWidget::item {
        color: #CCC;
        padding: 6px 16px;
        border-radius: 6px;
        margin: 1px 8px;
    }
    QListWidget::item:selected {
        background-color: #3A3A3A;
        color: #FFF;
    }
    QListWidget::item:hover:!selected {
        background-color: #303030;
    }
"""

_GROUP_STYLE = """
    QFrame#GroupBox {
        background-color: #2A2A2A;
        border: 1px solid #3A3A3A;
        border-radius: 8px;
    }
"""

_SEPARATOR_STYLE = """
    QFrame#Separator {
        background-color: #3A3A3A;
        border: none;
        max-height: 1px;
    }
"""

_TITLE_STYLE = "color: #FFF; font-size: 18px; font-weight: bold;"
_LABEL_STYLE = "color: #DDD; font-size: 13px;"
_BUTTON_STYLE = """
    QPushButton {
        background-color: #3A3A3A;
        color: #DDD;
        border: 1px solid #4A4A4A;
        border-radius: 6px;
        padding: 8px 20px;
        font-size: 13px;
    }
    QPushButton:hover {
        background-color: #4A4A4A;
        border: 1px solid #5A5A5A;
    }
    QPushButton:pressed {
        background-color: #555;
    }
"""
_COMBO_STYLE = """
    QComboBox {
        background-color: #3A3A3A;
        color: #DDD;
        border: 1px solid #4A4A4A;
        border-radius: 6px;
        padding: 4px 8px;
        min-width: 140px;
    }
    QComboBox:hover {
        border: 1px solid #5A5A5A;
    }
    QComboBox::drop-down {
        border: none;
        width: 20px;
    }
    QComboBox::down-arrow {
        image: none;
        border: none;
    }
    QComboBox QAbstractItemView {
        background-color: #3A3A3A;
        color: #DDD;
        selection-background-color: #4A7AFF;
        border: 1px solid #4A4A4A;
        border-radius: 4px;
    }
"""


def _make_separator() -> QFrame:
    """Create a 1px horizontal separator line."""
    sep = QFrame()
    sep.setObjectName("Separator")
    sep.setFrameShape(QFrame.Shape.HLine)
    sep.setStyleSheet(_SEPARATOR_STYLE)
    sep.setFixedHeight(1)
    return sep


def _make_row(label_text: str, control: QWidget) -> QHBoxLayout:
    """Create a label-left / control-right row."""
    row = QHBoxLayout()
    row.setContentsMargins(16, 10, 16, 10)
    label = QLabel(label_text)
    label.setStyleSheet(_LABEL_STYLE)
    row.addWidget(label)
    row.addStretch()
    row.addWidget(control)
    return row


def _make_group() -> QFrame:
    """Create a rounded-rectangle group container."""
    frame = QFrame()
    frame.setObjectName("GroupBox")
    frame.setStyleSheet(_GROUP_STYLE)
    return frame


_AUDIO_EXTENSIONS = {".m4a", ".caf", ".aac", ".aiff", ".aif", ".mp3", ".wav", ".qta"}

_DROP_ZONE_DEFAULT = """
    QFrame#DropZone {
        background-color: #2A2A2A;
        border: 2px dashed #4A4A4A;
        border-radius: 10px;
    }
"""
_DROP_ZONE_HOVER = """
    QFrame#DropZone {
        background-color: #2A3040;
        border: 2px dashed #4A7AFF;
        border-radius: 10px;
    }
"""


class _DropZone(QFrame):
    """Drag-and-drop zone for audio files."""

    def __init__(self, settings_window: "SettingsWindow", parent=None) -> None:
        super().__init__(parent)
        self._settings_window = settings_window
        self.setObjectName("DropZone")
        self.setAcceptDrops(True)
        self.setMinimumHeight(120)
        self.setStyleSheet(_DROP_ZONE_DEFAULT)

        layout = QVBoxLayout(self)
        layout.setAlignment(Qt.AlignmentFlag.AlignCenter)

        icon_label = QLabel("\u2b07")  # down arrow
        icon_label.setStyleSheet("color: #666; font-size: 28px;")
        icon_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(icon_label)

        text_label = QLabel("Drop audio file here")
        text_label.setStyleSheet("color: #888; font-size: 13px;")
        text_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(text_label)

    def dragEnterEvent(self, event) -> None:
        if event.mimeData().hasUrls():
            for url in event.mimeData().urls():
                path = url.toLocalFile()
                if any(path.lower().endswith(ext) for ext in _AUDIO_EXTENSIONS):
                    event.acceptProposedAction()
                    self.setStyleSheet(_DROP_ZONE_HOVER)
                    return
        event.ignore()

    def dragLeaveEvent(self, event) -> None:
        self.setStyleSheet(_DROP_ZONE_DEFAULT)

    def dropEvent(self, event) -> None:
        self.setStyleSheet(_DROP_ZONE_DEFAULT)
        for url in event.mimeData().urls():
            path = url.toLocalFile()
            if any(path.lower().endswith(ext) for ext in _AUDIO_EXTENSIONS):
                logger.info("Audio file dropped: %s", path)
                self._settings_window.file_dropped.emit(path)
                event.acceptProposedAction()
                return
        event.ignore()


class SettingsWindow(QWidget):
    """macOS System Settings style: sidebar + content pane."""

    hotkey_changed = pyqtSignal(list)
    retention_changed = pyqtSignal(float)
    sound_enabled_changed = pyqtSignal(bool)
    notification_enabled_changed = pyqtSignal(bool)
    voice_command_toggled = pyqtSignal(str, bool)  # (command_phrase, enabled)
    transcribe_file_requested = pyqtSignal()
    file_dropped = pyqtSignal(str)  # absolute path of dropped audio file

    # Sidebar page indices
    PAGE_SETTINGS = 0
    PAGE_VOICE_COMMANDS = 1
    PAGE_HISTORY = 2
    PAGE_TRANSCRIBE = 3
    PAGE_ABOUT = 4
    PAGE_ATTRIBUTION = 5

    # Keep legacy alias so callers using PAGE_HOTKEYS still work
    PAGE_HOTKEYS = PAGE_SETTINGS

    def __init__(
        self,
        current_hotkey: list[str],
        history: HistoryManager,
        retention_hours: float = 48.0,
        sound_enabled: bool = True,
        notification_enabled: bool = True,
        voice_commands: dict[str, bool] | None = None,
        parent=None,
    ) -> None:
        super().__init__(parent)
        self._history = history

        self.setWindowTitle("Parkeet Settings")
        self.setFixedSize(920, 500)
        self.setWindowFlags(
            Qt.WindowType.Window | Qt.WindowType.WindowCloseButtonHint
        )
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose, False)
        self.setStyleSheet(_WINDOW_STYLE)

        # --- Main layout: sidebar | content ---
        main = QHBoxLayout(self)
        main.setContentsMargins(0, 0, 0, 0)
        main.setSpacing(0)

        # Sidebar container (list + quit button)
        sidebar_widget = QWidget()
        sidebar_widget.setFixedWidth(170)
        sidebar_widget.setStyleSheet("background-color: #252525;")
        sidebar_layout = QVBoxLayout(sidebar_widget)
        sidebar_layout.setContentsMargins(0, 0, 0, 12)
        sidebar_layout.setSpacing(0)

        self._sidebar = QListWidget()
        self._sidebar.setStyleSheet(_SIDEBAR_STYLE)
        self._sidebar.addItem(QListWidgetItem("Settings"))
        self._sidebar.addItem(QListWidgetItem("Voice Commands"))
        self._sidebar.addItem(QListWidgetItem("History"))
        self._sidebar.addItem(QListWidgetItem("Transcribe File"))
        self._sidebar.addItem(QListWidgetItem("About"))
        self._sidebar.setCurrentRow(0)
        self._sidebar.currentRowChanged.connect(self._on_page_changed)
        sidebar_layout.addWidget(self._sidebar)

        _bottom_btn_style = """
            QPushButton {{
                background-color: transparent;
                color: {color};
                border: none;
                padding: 6px 16px;
                font-size: 12px;
                text-align: left;
            }}
            QPushButton:hover {{
                color: {hover};
            }}
        """

        attr_btn = QPushButton("Attribution")
        attr_btn.setStyleSheet(_bottom_btn_style.format(color="#888", hover="#BBB"))
        attr_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        attr_btn.clicked.connect(lambda: self._show_page_deselect(self.PAGE_ATTRIBUTION))
        sidebar_layout.addWidget(attr_btn)

        quit_btn = QPushButton("Quit Parkeet")
        quit_btn.setStyleSheet(_bottom_btn_style.format(color="#E55", hover="#F77"))
        quit_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        quit_btn.clicked.connect(QApplication.quit)
        sidebar_layout.addWidget(quit_btn)

        main.addWidget(sidebar_widget)

        # Content pane (stacked pages)
        self._pages = QStackedWidget()
        self._pages.addWidget(self._build_settings_page(current_hotkey, sound_enabled, notification_enabled))
        self._pages.addWidget(self._build_voice_commands_page(voice_commands or {}))
        self._pages.addWidget(self._build_history_page(retention_hours))
        self._pages.addWidget(self._build_transcribe_page())
        self._pages.addWidget(self._build_about_page())
        self._pages.addWidget(self._build_attribution_page())
        main.addWidget(self._pages, stretch=1)

    # ------------------------------------------------------------------
    # Page builders
    # ------------------------------------------------------------------

    def _build_settings_page(
        self,
        current_hotkey: list[str],
        sound_enabled: bool,
        notification_enabled: bool,
    ) -> QWidget:
        """Build the Settings page: Hotkeys and Feedback groups."""
        page = QWidget()
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)

        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(16)

        title = QLabel("Settings")
        title.setStyleSheet(_TITLE_STYLE)
        layout.addWidget(title)

        # --- Hotkeys group ---
        hk_header = QLabel("Hotkeys")
        hk_header.setStyleSheet("color: #999; font-size: 11px; text-transform: uppercase;")
        layout.addWidget(hk_header)

        group = _make_group()
        group_layout = QVBoxLayout(group)
        group_layout.setContentsMargins(0, 0, 0, 0)
        group_layout.setSpacing(0)

        self._combo1 = QComboBox()
        self._combo1.setStyleSheet(_COMBO_STYLE)
        self._combo2 = QComboBox()
        self._combo2.setStyleSheet(_COMBO_STYLE)

        for config_name, display in _MODIFIER_OPTIONS:
            self._combo1.addItem(display, config_name)
            self._combo2.addItem(display, config_name)

        key1 = current_hotkey[0] if len(current_hotkey) > 0 else "cmd"
        key2 = current_hotkey[1] if len(current_hotkey) > 1 else "alt"
        self._set_combo_value(self._combo1, key1)
        self._set_combo_value(self._combo2, key2)

        self._combo1.currentIndexChanged.connect(self._on_hotkey_combo_changed)
        self._combo2.currentIndexChanged.connect(self._on_hotkey_combo_changed)

        group_layout.addLayout(_make_row("Key 1", self._combo1))
        group_layout.addWidget(_make_separator())
        group_layout.addLayout(_make_row("Key 2", self._combo2))

        layout.addWidget(group)

        # --- Sound & Notifications group ---
        fb_header = QLabel("Feedback")
        fb_header.setStyleSheet("color: #999; font-size: 11px; text-transform: uppercase;")
        layout.addWidget(fb_header)

        fb_group = _make_group()
        fb_layout = QVBoxLayout(fb_group)
        fb_layout.setContentsMargins(0, 0, 0, 0)
        fb_layout.setSpacing(0)

        self._sound_combo = QComboBox()
        self._sound_combo.setStyleSheet(_COMBO_STYLE)
        self._sound_combo.addItem("On", True)
        self._sound_combo.addItem("Off", False)
        self._sound_combo.setCurrentIndex(0 if sound_enabled else 1)
        self._sound_combo.currentIndexChanged.connect(self._on_sound_changed)

        fb_layout.addLayout(_make_row("Sound effects", self._sound_combo))
        fb_layout.addWidget(_make_separator())

        self._notif_combo = QComboBox()
        self._notif_combo.setStyleSheet(_COMBO_STYLE)
        self._notif_combo.addItem("On", True)
        self._notif_combo.addItem("Off", False)
        self._notif_combo.setCurrentIndex(0 if notification_enabled else 1)
        self._notif_combo.currentIndexChanged.connect(self._on_notification_changed)

        fb_layout.addLayout(_make_row("Notifications", self._notif_combo))

        layout.addWidget(fb_group)

        layout.addStretch()
        scroll.setWidget(content)

        page_layout = QVBoxLayout(page)
        page_layout.setContentsMargins(0, 0, 0, 0)
        page_layout.addWidget(scroll)
        return page

    def _build_voice_commands_page(self, voice_commands: dict[str, bool]) -> QWidget:
        """Build the Voice Commands page with per-command On/Off toggles."""
        from src.voice_commands import ALL_COMMANDS, REPLACEMENT_DISPLAY

        page = QWidget()
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)

        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(16)

        title = QLabel("Voice Commands")
        title.setStyleSheet(_TITLE_STYLE)
        layout.addWidget(title)

        desc = QLabel(
            'Say "new line" or "comma" while dictating to insert formatting. '
            "Toggle individual commands below. English commands only."
        )
        desc.setStyleSheet("color: #888; font-size: 12px;")
        desc.setWordWrap(True)
        layout.addWidget(desc)

        group = _make_group()
        group_layout = QVBoxLayout(group)
        group_layout.setContentsMargins(0, 0, 0, 0)
        group_layout.setSpacing(0)

        self._vc_combos: dict[str, QComboBox] = {}

        for idx, (cmd, replacement) in enumerate(ALL_COMMANDS):
            combo = QComboBox()
            combo.setStyleSheet(_COMBO_STYLE)
            combo.addItem("On", True)
            combo.addItem("Off", False)
            enabled = voice_commands.get(cmd, True)
            combo.setCurrentIndex(0 if enabled else 1)
            combo.currentIndexChanged.connect(
                lambda _, c=cmd: self._on_voice_command_toggled(c)
            )
            self._vc_combos[cmd] = combo

            display_repl = REPLACEMENT_DISPLAY.get(replacement, replacement)
            label = f'"{cmd}"  \u2192  {display_repl}'
            group_layout.addLayout(_make_row(label, combo))

            if idx < len(ALL_COMMANDS) - 1:
                group_layout.addWidget(_make_separator())

        layout.addWidget(group)

        layout.addStretch()
        scroll.setWidget(content)

        page_layout = QVBoxLayout(page)
        page_layout.setContentsMargins(0, 0, 0, 0)
        page_layout.addWidget(scroll)
        return page

    def _build_history_page(self, retention_hours: float) -> QWidget:
        """Build the History page: retention setting + scrollable entry list."""
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(16)

        title = QLabel("History")
        title.setStyleSheet(_TITLE_STYLE)
        layout.addWidget(title)

        # Retention setting
        group = _make_group()
        group_layout = QVBoxLayout(group)
        group_layout.setContentsMargins(0, 0, 0, 0)
        group_layout.setSpacing(0)

        self._retention_combo = QComboBox()
        self._retention_combo.setStyleSheet(_COMBO_STYLE)
        for display, hours in _RETENTION_OPTIONS:
            self._retention_combo.addItem(display, hours)

        self._set_retention_value(retention_hours)
        self._retention_combo.currentIndexChanged.connect(
            self._on_retention_changed
        )

        group_layout.addLayout(
            _make_row("Keep transcriptions", self._retention_combo)
        )
        layout.addWidget(group)

        # Search bar
        self._history_search = QLineEdit()
        self._history_search.setPlaceholderText("Search transcriptions\u2026")
        self._history_search.setClearButtonEnabled(True)
        self._history_search.setStyleSheet(
            "QLineEdit {"
            "  background-color: #2A2A2A;"
            "  color: #DDD;"
            "  border: 1px solid #3A3A3A;"
            "  border-radius: 6px;"
            "  padding: 6px 10px;"
            "  font-size: 13px;"
            "}"
            "QLineEdit:focus {"
            "  border: 1px solid #4A7AFF;"
            "}"
        )
        self._history_search.textChanged.connect(self._on_history_search)
        layout.addWidget(self._history_search)

        # History entries scroll area
        self._history_empty = QLabel("No recent transcriptions")
        self._history_empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._history_empty.setStyleSheet(
            "color: #888; font-style: italic; padding: 40px;"
        )

        self._history_scroll = QScrollArea()
        self._history_scroll.setWidgetResizable(True)
        self._history_scroll.setFrameShape(QFrame.Shape.NoFrame)

        self._history_container = QWidget()
        self._history_layout = QVBoxLayout(self._history_container)
        self._history_layout.setContentsMargins(0, 0, 0, 0)
        self._history_layout.setSpacing(2)
        self._history_scroll.setWidget(self._history_container)

        layout.addWidget(self._history_empty)
        layout.addWidget(self._history_scroll, stretch=1)

        return page

    def _build_transcribe_page(self) -> QWidget:
        """Build the Transcribe File page with drag-and-drop zone."""
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(16)

        title = QLabel("Transcribe File")
        title.setStyleSheet(_TITLE_STYLE)
        layout.addWidget(title)

        desc = QLabel(
            "Select or drag an audio file to transcribe. Supports M4A, CAF, "
            "AAC, AIFF, MP3, WAV, and QTA formats."
        )
        desc.setStyleSheet("color: #888; font-size: 12px;")
        desc.setWordWrap(True)
        layout.addWidget(desc)

        # Drop zone
        self._drop_zone = _DropZone(self)
        layout.addWidget(self._drop_zone, stretch=1)

        btn = QPushButton("Choose File\u2026")
        btn.setStyleSheet(_BUTTON_STYLE)
        btn.setFixedWidth(160)
        btn.setCursor(Qt.CursorShape.PointingHandCursor)
        btn.clicked.connect(self._on_transcribe_clicked)
        layout.addWidget(btn)

        layout.addStretch()
        return page

    def _build_about_page(self) -> QWidget:
        """Build the About page with model info, languages, and limitations."""
        page = QWidget()
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)

        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(16)

        title = QLabel("About")
        title.setStyleSheet(_TITLE_STYLE)
        layout.addWidget(title)

        app_desc = QLabel("Parkeet \u2014 Offline speech-to-text for macOS")
        app_desc.setStyleSheet("color: #CCC; font-size: 13px;")
        layout.addWidget(app_desc)

        _info_style = "color: #CCC; font-size: 12px;"
        _heading_style = "color: #FFF; font-size: 13px; font-weight: bold;"

        # --- Model ---
        model_group = _make_group()
        mg = QVBoxLayout(model_group)
        mg.setContentsMargins(16, 12, 16, 12)
        mg.setSpacing(8)

        mg.addWidget(self._styled_label("Speech Recognition Model", _heading_style))
        mg.addWidget(self._rich_label(
            "<b>NVIDIA Parakeet TDT 0.6B v3</b> \u2014 a 600-million parameter "
            "FastConformer model trained on ~670,000 hours of multilingual audio. "
            "Ranked #1 on the HuggingFace Open ASR Leaderboard at release with "
            "an average Word Error Rate of <b>6.34%</b> on English benchmarks."
            "<br><br>"
            "All transcription happens locally on your Mac \u2014 no audio data "
            "is sent to the cloud."
        ))
        layout.addWidget(model_group)

        # --- Capabilities ---
        cap_group = _make_group()
        cg = QVBoxLayout(cap_group)
        cg.setContentsMargins(16, 12, 16, 12)
        cg.setSpacing(8)

        cg.addWidget(self._styled_label("Capabilities", _heading_style))
        cg.addWidget(self._rich_label(
            "\u2022 Automatic language detection \u2014 no need to select a language<br>"
            "\u2022 Automatic punctuation and capitalization<br>"
            "\u2022 Processes audio at roughly 3x real-time on CPU<br>"
            "\u2022 INT8 quantized for efficient CPU inference (~642 MB on disk)"
        ))
        layout.addWidget(cap_group)

        # --- Languages ---
        lang_group = _make_group()
        lg = QVBoxLayout(lang_group)
        lg.setContentsMargins(16, 12, 16, 12)
        lg.setSpacing(8)

        lg.addWidget(self._styled_label("Supported Languages (25)", _heading_style))
        lg.addWidget(self._rich_label(
            "<b>Best accuracy:</b> English, Spanish, Italian, Portuguese, "
            "German, Russian, French<br><br>"
            "<b>Good accuracy:</b> Ukrainian, Dutch, Polish, Slovak, Czech, "
            "Bulgarian, Croatian, Romanian, Finnish<br><br>"
            "<b>Moderate accuracy:</b> Hungarian, Swedish, Danish, Estonian, "
            "Greek, Lithuanian, Maltese, Latvian, Slovenian"
        ))
        lg.addWidget(self._rich_label(
            "<span style='color: #888;'>Coverage: European languages only. "
            "Does not support Asian, African, or Middle Eastern languages.</span>"
        ))
        layout.addWidget(lang_group)

        # --- Limitations ---
        lim_group = _make_group()
        lmg = QVBoxLayout(lim_group)
        lmg.setContentsMargins(16, 12, 16, 12)
        lmg.setSpacing(8)

        lmg.addWidget(self._styled_label("Limitations", _heading_style))
        lmg.addWidget(self._rich_label(
            "\u2022 <b>Background noise</b> \u2014 accuracy drops with increasing "
            "noise; best results with clean audio<br>"
            "\u2022 <b>Overlapping speakers</b> \u2014 no speaker separation; "
            "meetings with crosstalk have higher error rates<br>"
            "\u2022 <b>Specialized vocabulary</b> \u2014 uncommon names, technical "
            "jargon, or brand names may not be recognized<br>"
            "\u2022 <b>Accents</b> \u2014 strong regional accents may reduce accuracy<br>"
            "\u2022 <b>Portuguese</b> \u2014 trained on European Portuguese; "
            "Brazilian Portuguese may underperform"
        ))
        layout.addWidget(lim_group)

        layout.addStretch()
        scroll.setWidget(content)

        page_layout = QVBoxLayout(page)
        page_layout.setContentsMargins(0, 0, 0, 0)
        page_layout.addWidget(scroll)
        return page

    def _build_attribution_page(self) -> QWidget:
        """Build the Attribution page with credits and licenses."""
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(16)

        title = QLabel("Attribution")
        title.setStyleSheet(_TITLE_STYLE)
        layout.addWidget(title)

        app_desc = QLabel("Parkeet \u2014 Offline speech-to-text for macOS")
        app_desc.setStyleSheet("color: #CCC; font-size: 13px;")
        layout.addWidget(app_desc)

        # Credits group
        group = _make_group()
        group_layout = QVBoxLayout(group)
        group_layout.setContentsMargins(16, 12, 16, 12)
        group_layout.setSpacing(10)

        model_label = QLabel(
            "Speech recognition powered by "
            "<b>NVIDIA Parakeet TDT 0.6B v3</b>"
            "<br>"
            "<span style='color: #888;'>License: CC-BY-4.0 \u2014 "
            "creativecommons.org/licenses/by/4.0</span>"
        )
        model_label.setStyleSheet("color: #CCC; font-size: 12px;")
        model_label.setWordWrap(True)
        model_label.setTextFormat(Qt.TextFormat.RichText)
        group_layout.addWidget(model_label)

        group_layout.addWidget(_make_separator())

        engine_label = QLabel(
            "Inference engine: "
            "<b>sherpa-onnx</b> by k2-fsa"
            "<br>"
            "<span style='color: #888;'>License: Apache 2.0 \u2014 "
            "github.com/k2-fsa/sherpa-onnx</span>"
        )
        engine_label.setStyleSheet("color: #CCC; font-size: 12px;")
        engine_label.setWordWrap(True)
        engine_label.setTextFormat(Qt.TextFormat.RichText)
        group_layout.addWidget(engine_label)

        layout.addWidget(group)
        layout.addStretch()
        return page

    # ------------------------------------------------------------------
    # Label helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _styled_label(text: str, style: str) -> QLabel:
        label = QLabel(text)
        label.setStyleSheet(style)
        return label

    @staticmethod
    def _rich_label(html: str) -> QLabel:
        label = QLabel(html)
        label.setStyleSheet("color: #CCC; font-size: 12px;")
        label.setWordWrap(True)
        label.setTextFormat(Qt.TextFormat.RichText)
        return label

    # ------------------------------------------------------------------
    # Navigation
    # ------------------------------------------------------------------

    def _on_page_changed(self, index: int) -> None:
        self._pages.setCurrentIndex(index)
        if index == self.PAGE_HISTORY:
            self.refresh_history()

    def _show_page_deselect(self, page_index: int) -> None:
        """Show a page that isn't in the sidebar (e.g. Attribution)."""
        self._sidebar.clearSelection()
        self._sidebar.setCurrentRow(-1)
        self._pages.setCurrentIndex(page_index)

    def show_page(self, index: int) -> None:
        """Show the window and navigate to a specific page."""
        self._sidebar.setCurrentRow(index)
        self.show()
        self.raise_()
        self.activateWindow()

    # ------------------------------------------------------------------
    # History
    # ------------------------------------------------------------------

    def refresh_history(self) -> None:
        """Rebuild the history entry list, applying the current search filter."""
        # Clear existing rows
        while self._history_layout.count():
            item = self._history_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        query = self._history_search.text().strip().lower()
        entries = self._history.entries

        if query:
            entries = [e for e in entries if self._entry_matches(e, query)]

        has_entries = len(entries) > 0
        self._history_empty.setVisible(not has_entries)
        self._history_scroll.setVisible(has_entries)

        if not has_entries and query:
            self._history_empty.setText("No matching transcriptions")
        else:
            self._history_empty.setText("No recent transcriptions")

        for entry in entries:
            row = _HistoryRow(entry)
            self._history_layout.addWidget(row)

        self._history_layout.addStretch()

    @staticmethod
    def _entry_matches(entry: HistoryEntry, query: str) -> bool:
        """Check if a history entry matches the search query."""
        if entry.type == "hotkey":
            return query in (entry.text or "").lower()
        # File entry: match source name or output path
        return (
            query in (entry.source_name or "").lower()
            or query in (entry.output_path or "").lower()
        )

    def _on_history_search(self) -> None:
        """Filter history entries when search text changes."""
        self.refresh_history()

    # ------------------------------------------------------------------
    # Combo helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _set_combo_value(combo: QComboBox, value: str) -> None:
        for i in range(combo.count()):
            if combo.itemData(i) == value:
                combo.setCurrentIndex(i)
                return

    def _set_retention_value(self, hours: float) -> None:
        """Select the closest matching retention preset."""
        best_idx = 0
        best_diff = float("inf")
        for i in range(self._retention_combo.count()):
            diff = abs(self._retention_combo.itemData(i) - hours)
            if diff < best_diff:
                best_diff = diff
                best_idx = i
        self._retention_combo.setCurrentIndex(best_idx)

    # ------------------------------------------------------------------
    # Signal handlers
    # ------------------------------------------------------------------

    def _on_hotkey_combo_changed(self) -> None:
        key1 = self._combo1.currentData()
        key2 = self._combo2.currentData()
        if key1 == key2:
            return
        self.hotkey_changed.emit([key1, key2])

    def _on_retention_changed(self) -> None:
        hours = self._retention_combo.currentData()
        logger.info("Retention changed to %s hours", hours)
        self.retention_changed.emit(float(hours))

    def _on_sound_changed(self) -> None:
        enabled = self._sound_combo.currentData()
        logger.info("Sound feedback changed to %s", enabled)
        self.sound_enabled_changed.emit(enabled)

    def _on_notification_changed(self) -> None:
        enabled = self._notif_combo.currentData()
        logger.info("Notifications changed to %s", enabled)
        self.notification_enabled_changed.emit(enabled)

    def _on_voice_command_toggled(self, command: str) -> None:
        combo = self._vc_combos.get(command)
        if combo is None:
            return
        enabled = combo.currentData()
        logger.info("Voice command %r changed to %s", command, enabled)
        self.voice_command_toggled.emit(command, enabled)

    def _on_transcribe_clicked(self) -> None:
        logger.info("Transcribe file requested from settings")
        self.transcribe_file_requested.emit()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

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
