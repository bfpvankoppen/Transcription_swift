# Insights from notchprompt (saif0200/notchprompt)

Native Swift macOS notch-adjacent teleprompter. Shares core challenges with Parkeet:
overlay windows, menu bar utility, global hotkeys, NSWindow management, focus handling.

Source: https://github.com/saif0200/notchprompt

---

## 1. Overlay Window Hardening

Parkeet currently uses `canJoinAllSpaces | fullScreenAuxiliary`. Notchprompt adds behaviors we're missing:

| Behavior | Constant | Value | Purpose |
|---|---|---|---|
| `stationary` | `NSWindowCollectionBehaviorStationary` | `1 << 4` | Overlay stays put when swiping between Spaces |
| `ignoresCycle` | `NSWindowCollectionBehaviorIgnoresCycle` | `1 << 6` | Overlay excluded from Cmd+\` window cycling |

Additional NSPanel properties to set via pyobjc:

```python
# Prevent overlay from becoming key window unless explicitly clicked
ns_panel.setBecomesKeyOnlyIfNeeded_(True)

# Force overlay to front even when app is not active
ns_window.orderFrontRegardless()
```

### Implementation

Update `_apply_all_spaces_behavior()` in `overlay.py`:

```python
NSWindowCollectionBehaviorStationary = 1 << 4
NSWindowCollectionBehaviorIgnoresCycle = 1 << 6

behavior = (
    NSWindowCollectionBehaviorCanJoinAllSpaces
    | NSWindowCollectionBehaviorFullScreenAuxiliary
    | NSWindowCollectionBehaviorStationary
    | NSWindowCollectionBehaviorIgnoresCycle
)
ns_window.setCollectionBehavior_(behavior)
ns_window.setBecomesKeyOnlyIfNeeded_(True)
```

---

## 2. Privacy Mode (Screen Sharing)

Single NSWindow API hides the overlay from screen recording/sharing:

```python
from AppKit import NSWindowSharingNone, NSWindowSharingReadOnly

# Hide overlay from screen capture
ns_window.setSharingType_(NSWindowSharingNone)

# Show overlay in screen capture (default)
ns_window.setSharingType_(NSWindowSharingReadOnly)
```

Caveat: best-effort only — some screen sharing tools ignore this hint.

Use case: users presenting or screen recording don't want the recording overlay visible.

---

## 3. Replace pynput with NSEvent Global Monitors

**This is the highest-impact change.** It would eliminate the root cause of Parkeet's
focus-stealing problem rather than working around it.

### Current Problem (pynput)
1. pynput listener runs in a background thread
2. `pyqtSignal` emitted from background thread to Qt main thread
3. macOS activates the app as a side effect of the thread crossing
4. By the time the slot runs, Parkeet is already frontmost
5. Workaround: pre-capture frontmost app in pynput thread, delayed re-activation

### notchprompt's Approach (NSEvent monitors)
```swift
// Runs on the main RunLoop — no thread crossing, no focus stealing
NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
    _ = self?.handleShortcut(event)
}
```

### pyobjc Equivalent
```python
from AppKit import NSEvent, NSCommandKeyMask, NSAlternateKeyMask

def setup_global_hotkey():
    mask = NSEvent.EventTypeMask.keyDown  # or flagsChanged for modifier-only

    def handler(event):
        flags = event.modifierFlags() & NSEvent.ModifierFlags.deviceIndependentFlagsMask
        required = NSCommandKeyMask | NSAlternateKeyMask
        if flags == required:
            chars = event.charactersIgnoringModifiers()
            if chars:
                handle_shortcut(chars)

    monitor = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(mask, handler)
    return monitor  # must keep reference to prevent GC

# For modifier-only hotkey (Cmd+Option without a letter key):
# Use NSEvent.EventTypeMask.flagsChanged instead of .keyDown
# Track modifier press/release state manually
```

Benefits:
- Runs on main thread RunLoop — no thread-crossing focus steal
- No pynput dependency
- Still requires Accessibility permission (same as pynput)
- Dual monitors needed: `addGlobalMonitor` (other apps focused) + `addLocalMonitor` (own app focused)

---

## 4. Dual-Rate Animation Timer

Notchprompt runs 60fps during active animation, drops to 8fps when idle:

```python
# PyQt6 equivalent
class AnimatedOverlay:
    def __init__(self):
        self._anim_timer = QTimer()
        self._anim_timer.timeout.connect(self._tick)

    def start_animating(self):
        self._anim_timer.setInterval(16)   # ~60fps
        self._anim_timer.start()

    def go_idle(self):
        self._anim_timer.setInterval(125)  # ~8fps
        # or self._anim_timer.stop() if no idle animation needed
```

Applicable to Parkeet's waveform overlay — full speed only while recording.

---

## 5. Debounced Auto-Save for Settings

Notchprompt merges all property changes into a single stream, debounced to 250ms:

```python
# PyQt6 equivalent
class SettingsManager:
    def __init__(self):
        self._save_timer = QTimer()
        self._save_timer.setSingleShot(True)
        self._save_timer.setInterval(250)
        self._save_timer.timeout.connect(self._do_save)

    def mark_dirty(self):
        """Call this whenever any setting changes."""
        self._save_timer.start()  # restarts the 250ms countdown

    def _do_save(self):
        # Write settings to disk
        ...
```

Prevents excessive disk writes when the user is adjusting multiple settings rapidly.

---

## 6. Dynamic Tray Menu Updates

Notchprompt dynamically updates menu item titles/states right before the menu opens:

```python
# PyQt6 equivalent
self.tray_menu.aboutToShow.connect(self._update_menu_items)

def _update_menu_items(self):
    if self.is_recording:
        self.record_action.setText("Stop Recording (Cmd+Option)")
    else:
        self.record_action.setText("Start Recording (Cmd+Option)")
```

Always reflects current state without maintaining separate update paths.

---

## 7. Multi-Display Support

Notchprompt's screen selection fallback chain:

1. **Explicit user selection** — if user picked a screen in settings
2. **Built-in display** — `CGDisplayIsBuiltin(id) != 0`
3. **Name heuristic** — string match for "built-in" in `localizedName`
4. **Menu bar screen** — `id == CGMainDisplayID()`
5. **First available** — last resort

```python
from AppKit import NSScreen
from Quartz import CGDisplayIsBuiltin, CGMainDisplayID

def select_screen():
    for screen in NSScreen.screens():
        desc = screen.deviceDescription()
        display_id = desc['NSScreenNumber']
        if CGDisplayIsBuiltin(display_id):
            return screen
    # Fallback to main display
    return NSScreen.mainScreen()
```

Observe display changes to reposition overlay:

```python
from AppKit import NSNotificationCenter, NSApplication

NSNotificationCenter.defaultCenter().addObserver_selector_name_object_(
    self,
    'screenChanged:',
    'NSApplicationDidChangeScreenParametersNotification',
    None
)
```

---

## 8. Smooth Visual Transitions (Lerp)

Notchprompt interpolates between states rather than snapping:

```python
# Linear interpolation for smooth transitions
def lerp(current, target, factor, dt):
    diff = target - current
    if abs(diff) < 0.001:
        return target
    return current + diff * min(1.0, factor * dt)

# Usage in animation tick
self.current_opacity = lerp(self.current_opacity, self.target_opacity, 8.0, dt)
```

Applicable to overlay show/hide transitions, waveform amplitude changes.

---

## 9. NSWindow API Quick Reference

| Swift API | pyobjc Equivalent | Value |
|---|---|---|
| `.screenSaver` level | `NSScreenSaverWindowLevel` | 1000 |
| `.nonactivatingPanel` | Set via styleMask on NSPanel | Bit flag |
| `.canJoinAllSpaces` | `NSWindowCollectionBehaviorCanJoinAllSpaces` | `1 << 0` |
| `.fullScreenAuxiliary` | `NSWindowCollectionBehaviorFullScreenAuxiliary` | `1 << 8` |
| `.stationary` | `NSWindowCollectionBehaviorStationary` | `1 << 4` |
| `.ignoresCycle` | `NSWindowCollectionBehaviorIgnoresCycle` | `1 << 6` |
| `hidesOnDeactivate = false` | `setHidesOnDeactivate_(False)` | |
| `sharingType = .none` | `setSharingType_(NSWindowSharingNone)` | 0 |
| `becomesKeyOnlyIfNeeded` | `setBecomesKeyOnlyIfNeeded_(True)` | |
| `orderFrontRegardless()` | `orderFrontRegardless()` | |

---

## Priority for Implementation

1. **Overlay hardening** (stationary + ignoresCycle + becomesKeyOnlyIfNeeded) — quick win
2. **Privacy mode** (sharingType) — single line, high user value
3. **NSEvent hotkey replacement** — eliminates focus-steal root cause, removes pynput dependency
4. **Dual-rate timer** — reduces CPU usage during idle
5. **Debounced auto-save** — when settings UI is added
6. **Dynamic tray menu** — when menu items need state-dependent text
7. **Multi-display support** — when users report multi-monitor issues
8. **Smooth transitions** — polish pass
