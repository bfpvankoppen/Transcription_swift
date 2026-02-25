# Settings UI + Configurable Hotkey + Force Quit Visibility

## Plan

### Context
Parkeet currently hides from the Dock and Force Quit (uses `NSApplicationActivationPolicyAccessory`). The hotkey (Cmd+Option) is hardcoded. User wants:
1. A settings window accessible from the Dock icon to configure the shortcut
2. The app visible in Force Quit so it can always be killed

### Changes

1. **`run.py`** — Change `Accessory` → `Regular` activation policy. Subclass `QApplication` as `ParkeetApp` to catch Dock icon click → show settings.

2. **`src/config.py`** (new) — Config manager. Reads/writes `~/.config/parkeet/config.json`. Default: `{"hotkey": ["cmd", "alt"]}`. Auto-save on change.

3. **`src/hotkey_recorder.py`** (new) — `HotkeyRecorderButton(QPushButton)`. Click to record, captures modifier keys, requires 2+ modifiers, shows macOS symbols (⌘ ⌥ ⌃ ⇧). Escape/focus-loss cancels.

4. **`src/settings_window.py`** (new) — `SettingsWindow(QWidget)` with hotkey recorder. Close hides (not destroys). No Save button — changes apply immediately.

5. **`src/hotkey.py`** — Rename `CmdOptionHotkeyListener` → `ConfigurableHotkeyListener`. Accepts `modifiers: list[str]`. Same toggle logic, same start/stop lifecycle.

6. **`src/app.py`** — Wire config, settings window, configurable listener, tray "Settings..." menu item. Dynamic hotkey display in status messages.

### Implementation Order
1. `src/config.py`
2. `src/hotkey_recorder.py`
3. `src/settings_window.py`
4. `src/hotkey.py`
5. `run.py`
6. `src/app.py`

## Tasks

- [ ] Create `src/config.py` — config read/write
- [ ] Create `src/hotkey_recorder.py` — hotkey capture widget
- [ ] Create `src/settings_window.py` — settings dialog
- [ ] Refactor `src/hotkey.py` — configurable modifiers
- [ ] Update `run.py` — Regular policy + ParkeetApp subclass
- [ ] Update `src/app.py` — wire everything
- [ ] Test end-to-end: Dock visibility, settings, hotkey change, persistence

## Verification

1. App appears in Dock and Force Quit (Cmd+Option+Esc)
2. Click Dock icon → settings window opens
3. Right-click tray → "Settings..." → same settings window
4. Click hotkey field → press Cmd+Shift → recorder captures it
5. Cmd+Shift triggers recording (new hotkey works)
6. Cmd+Option does NOT trigger (old hotkey replaced)
7. Quit and relaunch → Cmd+Shift persists from config
8. Overlay still works on all Spaces, focus stays in user's text field
