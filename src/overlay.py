"""
Floating recording overlay for the Transcription app.

A frameless, always-on-top, translucent overlay window that:
- Does NOT steal focus from the currently active application
- Shows an animated audio waveform (vertical bars) at ~30 fps
- Fades in / fades out smoothly
- Sits centered horizontally near the top of the primary screen

Usage
-----
    from overlay import RecordingOverlay

    overlay = RecordingOverlay()
    overlay.fade_in()                        # show with animation
    overlay.update_levels([0.3, 0.7, ...])   # feed audio amplitudes
    overlay.show_transcribing()              # freeze waveform, show label
    overlay.fade_out()                       # dismiss with animation

The widget is designed to be driven by an external audio-capture loop that
calls ``update_levels()`` at roughly 30 fps with a list of float amplitudes
in the range [0.0, 1.0].
"""

from __future__ import annotations

import math
import sys
from typing import List, Optional

from PyQt6.QtCore import (
    QEasingCurve,
    QPropertyAnimation,
    QRectF,
    Qt,
    QTimer,
    pyqtSlot,
)
from PyQt6.QtGui import (
    QBrush,
    QColor,
    QGuiApplication,
    QPainter,
    QPainterPath,
    QPen,
)
from PyQt6.QtWidgets import (
    QApplication,
    QGraphicsOpacityEffect,
    QLabel,
    QVBoxLayout,
    QWidget,
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

OVERLAY_WIDTH = 360          # px – total window width
OVERLAY_HEIGHT = 64          # px – total window height
CORNER_RADIUS = 16.0         # px – rounded corner radius
TOP_MARGIN = 60              # px – distance from top of screen

BAR_COUNT = 28               # number of vertical bars in the waveform
BAR_WIDTH = 6                # px – width of each bar
BAR_GAP = 4                  # px – gap between bars
BAR_MIN_HEIGHT = 4           # px – minimum bar height (idle state)
BAR_CORNER = 2.0             # px – bar corner radius

BG_COLOR = QColor(20, 20, 24, 200)        # dark translucent background
BAR_COLOR = QColor(100, 180, 255, 220)    # waveform bar colour
BAR_COLOR_LOW = QColor(80, 140, 220, 180) # lower-amplitude tint
LABEL_COLOR = QColor(180, 180, 190, 220)  # "Transcribing..." text colour

FADE_DURATION_MS = 250       # fade in / fade out duration
FPS = 30                     # waveform refresh rate
SMOOTHING = 0.35             # exponential smoothing factor (0 = no change, 1 = instant)


class RecordingOverlay(QWidget):
    """Floating translucent overlay that shows an animated audio waveform."""

    # ------------------------------------------------------------------
    # Construction
    # ------------------------------------------------------------------

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)

        # --- Window flags ---------------------------------------------------
        # We use Qt.WindowType.Window (NOT Tool) because Tool creates an
        # NSPanel which cannot properly join all macOS Spaces/Desktops.
        # The app is hidden from Dock via NSApplicationActivationPolicyAccessory.
        self.setWindowFlags(
            Qt.WindowType.Window
            | Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.WindowDoesNotAcceptFocus
            | Qt.WindowType.WindowTransparentForInput
        )

        # Translucent background – we will paint it ourselves in paintEvent.
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)

        # Fixed size – not user-resizable.
        self.setFixedSize(OVERLAY_WIDTH, OVERLAY_HEIGHT)

        # --- Opacity effect for fade in/out --------------------------------
        self._opacity_effect = QGraphicsOpacityEffect(self)
        self._opacity_effect.setOpacity(0.0)
        self.setGraphicsEffect(self._opacity_effect)

        self._fade_anim = QPropertyAnimation(self._opacity_effect, b"opacity")
        self._fade_anim.setEasingCurve(QEasingCurve.Type.InOutCubic)
        self._fade_anim.setDuration(FADE_DURATION_MS)

        # --- "Transcribing..." label (hidden by default) -------------------
        self._label = QLabel("Transcribing\u2026", self)
        self._label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._label.setStyleSheet(
            f"color: rgba({LABEL_COLOR.red()}, {LABEL_COLOR.green()}, "
            f"{LABEL_COLOR.blue()}, {LABEL_COLOR.alpha()}); "
            f"font-size: 13px; font-weight: 500; background: transparent;"
        )
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self._label)
        self._label.hide()

        # --- Waveform state ------------------------------------------------
        self._levels: List[float] = [0.0] * BAR_COUNT
        self._display_levels: List[float] = [0.0] * BAR_COUNT  # smoothed
        self._is_transcribing = False

        # --- Repaint timer (~30 fps) ---------------------------------------
        self._timer = QTimer(self)
        self._timer.setInterval(int(1000 / FPS))
        self._timer.timeout.connect(self._on_tick)

        # --- Visible on ALL macOS Spaces/Desktops -------------------------
        # Force native window creation, then tell macOS this window
        # belongs on every Space so the overlay follows the user.
        self.winId()  # forces Qt to create the underlying NSWindow
        self._apply_all_spaces_behavior()

        # --- Position the overlay ------------------------------------------
        self._center_on_screen()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def fade_in(self) -> None:
        """Show the overlay with a smooth fade-in animation."""
        self._is_transcribing = False
        self._label.hide()
        self._levels = [0.0] * BAR_COUNT
        self._display_levels = [0.0] * BAR_COUNT

        self._center_on_screen()
        self.show()
        self._apply_all_spaces_behavior()
        self.raise_()

        self._fade_anim.stop()
        self._fade_anim.setStartValue(self._opacity_effect.opacity())
        self._fade_anim.setEndValue(1.0)
        self._fade_anim.start()

        self._timer.start()

    def fade_out(self, on_finished: Optional[callable] = None) -> None:
        """Hide the overlay with a smooth fade-out animation.

        Parameters
        ----------
        on_finished:
            Optional callback invoked once the fade-out completes.
        """
        self._timer.stop()

        self._fade_anim.stop()
        self._fade_anim.setStartValue(self._opacity_effect.opacity())
        self._fade_anim.setEndValue(0.0)

        # Disconnect any previous one-shot connections, then connect.
        try:
            self._fade_anim.finished.disconnect(self._on_fade_out_finished)
        except TypeError:
            pass
        self._fade_anim.finished.connect(self._on_fade_out_finished)

        if on_finished is not None:
            try:
                self._fade_anim.finished.disconnect(on_finished)
            except TypeError:
                pass
            self._fade_anim.finished.connect(on_finished)

        self._fade_anim.start()

    def update_levels(self, amplitudes: List[float]) -> None:
        """Feed new audio amplitude data to the waveform.

        Parameters
        ----------
        amplitudes:
            A list of floats in the range [0.0, 1.0].  The list will be
            resampled (stretched or compressed) to ``BAR_COUNT`` bars.
            Values are clamped to [0.0, 1.0].
        """
        if self._is_transcribing:
            return  # waveform frozen during transcription

        if not amplitudes:
            self._levels = [0.0] * BAR_COUNT
            return

        # Resample to BAR_COUNT bars using nearest-neighbour.
        resampled: List[float] = []
        src_len = len(amplitudes)
        for i in range(BAR_COUNT):
            idx = int(i * src_len / BAR_COUNT)
            idx = min(idx, src_len - 1)
            val = max(0.0, min(1.0, amplitudes[idx]))
            resampled.append(val)

        self._levels = resampled

    def show_transcribing(self) -> None:
        """Freeze the waveform and display a 'Transcribing...' label."""
        self._is_transcribing = True
        self._label.show()

    # ------------------------------------------------------------------
    # Painting
    # ------------------------------------------------------------------

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt naming convention)
        """Draw the dark translucent rounded-rect background and waveform."""
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        # --- Background ----------------------------------------------------
        bg_path = QPainterPath()
        bg_path.addRoundedRect(
            QRectF(0, 0, self.width(), self.height()),
            CORNER_RADIUS,
            CORNER_RADIUS,
        )
        painter.fillPath(bg_path, QBrush(BG_COLOR))

        # --- Waveform bars -------------------------------------------------
        total_bars_width = BAR_COUNT * BAR_WIDTH + (BAR_COUNT - 1) * BAR_GAP
        x_start = (self.width() - total_bars_width) / 2.0
        max_bar_height = self.height() - 20.0  # leave 10 px padding top+bottom

        for i in range(BAR_COUNT):
            level = self._display_levels[i]
            bar_h = max(BAR_MIN_HEIGHT, level * max_bar_height)
            x = x_start + i * (BAR_WIDTH + BAR_GAP)
            y = (self.height() - bar_h) / 2.0

            # Tint: brighter when louder.
            t = level
            r = int(BAR_COLOR_LOW.red() + t * (BAR_COLOR.red() - BAR_COLOR_LOW.red()))
            g = int(BAR_COLOR_LOW.green() + t * (BAR_COLOR.green() - BAR_COLOR_LOW.green()))
            b = int(BAR_COLOR_LOW.blue() + t * (BAR_COLOR.blue() - BAR_COLOR_LOW.blue()))
            a = int(BAR_COLOR_LOW.alpha() + t * (BAR_COLOR.alpha() - BAR_COLOR_LOW.alpha()))
            color = QColor(r, g, b, a)

            bar_path = QPainterPath()
            bar_path.addRoundedRect(QRectF(x, y, BAR_WIDTH, bar_h), BAR_CORNER, BAR_CORNER)
            painter.fillPath(bar_path, QBrush(color))

        painter.end()

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _apply_all_spaces_behavior(self) -> None:
        """Make the overlay visible on ALL macOS Spaces/Desktops.

        Must be called AFTER show() because Qt recreates the underlying
        NSPanel during show() and sets MoveToActiveSpace, which is
        mutually exclusive with CanJoinAllSpaces.
        """
        try:
            from AppKit import (
                NSWindowCollectionBehaviorCanJoinAllSpaces,
                NSWindowCollectionBehaviorFullScreenAuxiliary,
                NSWindowCollectionBehaviorMoveToActiveSpace,
                NSFloatingWindowLevel,
            )
            import objc
            from ctypes import c_void_p

            view_ptr = self.winId().__int__()
            ns_view = objc.objc_object(c_void_p=c_void_p(view_ptr))
            ns_window = ns_view.window()
            if ns_window is None:
                return

            # Read current behavior and clear the conflicting bit
            behavior = ns_window.collectionBehavior()
            behavior &= ~NSWindowCollectionBehaviorMoveToActiveSpace
            behavior |= (
                NSWindowCollectionBehaviorCanJoinAllSpaces
                | NSWindowCollectionBehaviorFullScreenAuxiliary
            )
            ns_window.setCollectionBehavior_(behavior)
            ns_window.setLevel_(NSFloatingWindowLevel)

            # Prevent NSPanel from hiding when the app loses focus
            if ns_window.respondsToSelector_(b"setHidesOnDeactivate:"):
                ns_window.setHidesOnDeactivate_(False)

        except Exception:
            pass

    def _center_on_screen(self) -> None:
        """Position the overlay centred horizontally near the top of the primary screen."""
        screen = QGuiApplication.primaryScreen()
        if screen is None:
            return
        geom = screen.availableGeometry()
        x = geom.x() + (geom.width() - self.width()) // 2
        y = geom.y() + TOP_MARGIN
        self.move(x, y)

    @pyqtSlot()
    def _on_tick(self) -> None:
        """Called at ~30 fps. Smooth the waveform levels and repaint."""
        for i in range(BAR_COUNT):
            target = self._levels[i]
            current = self._display_levels[i]
            # Exponential smoothing for fluid motion.
            self._display_levels[i] = current + SMOOTHING * (target - current)
        self.update()  # schedule a repaint

    @pyqtSlot()
    def _on_fade_out_finished(self) -> None:
        """Hide the widget after fade-out completes."""
        self.hide()
        self._is_transcribing = False
        self._label.hide()
        # Clean up signal.
        try:
            self._fade_anim.finished.disconnect(self._on_fade_out_finished)
        except TypeError:
            pass


# ======================================================================
# Demo / self-test
# ======================================================================

def _demo() -> None:
    """Run a standalone demo that simulates audio input with sine waves."""
    import random

    app = QApplication(sys.argv)

    overlay = RecordingOverlay()
    overlay.fade_in()

    # --- Simulated audio input -------------------------------------------
    phase = [0.0]

    def _generate_fake_levels() -> List[float]:
        """Produce a list of amplitudes that looks like a talking waveform."""
        phase[0] += 0.08
        levels: List[float] = []
        for i in range(BAR_COUNT):
            # Base sine pattern.
            val = 0.3 + 0.35 * math.sin(phase[0] + i * 0.45)
            # Add random jitter.
            val += random.uniform(-0.12, 0.12)
            # Envelope – taper the edges.
            edge = min(i, BAR_COUNT - 1 - i) / (BAR_COUNT / 4)
            val *= min(1.0, edge)
            levels.append(max(0.0, min(1.0, val)))
        return levels

    feed_timer = QTimer()
    feed_timer.setInterval(int(1000 / FPS))

    def _feed():
        overlay.update_levels(_generate_fake_levels())

    feed_timer.timeout.connect(_feed)
    feed_timer.start()

    # --- After 4 seconds, show "Transcribing..." then fade out -----------
    def _stop_recording():
        feed_timer.stop()
        overlay.show_transcribing()
        QTimer.singleShot(1500, lambda: overlay.fade_out(on_finished=app.quit))

    QTimer.singleShot(4000, _stop_recording)

    sys.exit(app.exec())


if __name__ == "__main__":
    _demo()
