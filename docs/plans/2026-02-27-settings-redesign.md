# Settings Window Redesign — Apple-Style Grouped Sections

## Context

Redesign the Parkeet settings window to follow macOS System Settings design language. Single-pane layout with two Apple-style rounded groups stacked vertically. Replaces the current QGroupBox-based layout.

## Window Structure

Fixed-width (~400px) dark-themed window. Two grouped sections:

### Group 1 — Keyboard

| Label | Control |
|---|---|
| Key 1 | Dropdown: Command, Option, Control, Shift |
| Key 2 | Dropdown: Command, Option, Control, Shift |

Behavior unchanged from current implementation. Dual-dropdown, duplicate detection, `hotkey_changed` signal.

### Group 2 — History

| Label | Control |
|---|---|
| Keep transcriptions | Dropdown: 1 day, 7 days, 14 days, 30 days, 90 days |

New `retention_changed` signal emits hours (24, 168, 336, 720, 2160). On load, selects closest preset to current config value.

## Visual Design

- Rounded-rectangle containers (~8px radius, subtle border or lighter background)
- Section header labels above each group
- Label-left / control-right within each row
- 1px separator between rows within a group
- Dark theme: dark grays, #333 borders, #CCC text

## Files Changed

| File | Change |
|---|---|
| `src/settings_window.py` | Full rewrite — Apple-style grouped layout, retention dropdown |
| `src/app.py` | Pass retention_hours to constructor, connect retention_changed signal |

## Signals

- `hotkey_changed(list)` — unchanged
- `retention_changed(float)` — new, emits hours value
