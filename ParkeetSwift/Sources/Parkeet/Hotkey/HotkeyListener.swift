import AppKit
import os

/// Detects global modifier-only hotkey (e.g. Cmd+Option) using NSEvent monitors.
///
/// Uses NSEvent global + local monitors which require Accessibility permission
/// (not Input Monitoring). Accessibility is reliably prompted via
/// AXIsProcessTrustedWithOptions, which adds the app to the list automatically.
final class HotkeyListener {

    /// Called on the main thread when the hotkey combo is pressed and released.
    var onToggle: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var requiredModifiers: NSEvent.ModifierFlags = [.command, .option]
    private var modifiersPressed = false

    private let log = Logger(subsystem: "com.parkeet.app", category: "HotkeyListener")

    // MARK: - Lifecycle

    func start(modifiers: [HotkeyModifier]) {
        updateModifiers(modifiers)

        let eventMask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]

        // Global monitor: catches events when OTHER apps are focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleEvent(event)
        }

        // Local monitor: catches events when OUR app is focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleEvent(event)
            return event
        }

        if globalMonitor != nil {
            log.info("Hotkey listener started: \(self.displayString(for: modifiers))")
        } else {
            log.error("Failed to create global event monitor (Accessibility permission required)")
        }
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        log.info("Hotkey listener stopped")
    }

    /// Hot-swap the modifier combo without restarting the listener.
    func updateModifiers(_ modifiers: [HotkeyModifier]) {
        var flags: NSEvent.ModifierFlags = []
        for mod in modifiers {
            flags.insert(mod.nsFlag)
        }
        requiredModifiers = flags
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // A non-modifier key was pressed — cancel any pending modifier combo
            modifiersPressed = false
            return
        }

        // flagsChanged event — check modifier state
        let currentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection(Self.allModifiers)

        if currentFlags.contains(requiredModifiers) {
            // All required modifiers are now held
            modifiersPressed = true
        } else if modifiersPressed {
            // Modifiers were held and now released — trigger!
            modifiersPressed = false
            DispatchQueue.main.async { [weak self] in
                self?.onToggle?()
            }
        }
    }

    // MARK: - Display

    func displayString(for modifiers: [HotkeyModifier]) -> String {
        modifiers.map(\.symbol).joined()
    }

    private static let allModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
}

// MARK: - Modifier definitions

enum HotkeyModifier: String, Codable, CaseIterable {
    case cmd
    case alt
    case ctrl
    case shift

    var nsFlag: NSEvent.ModifierFlags {
        switch self {
        case .cmd: .command
        case .alt: .option
        case .ctrl: .control
        case .shift: .shift
        }
    }

    var symbol: String {
        switch self {
        case .cmd: "⌘"
        case .alt: "⌥"
        case .ctrl: "⌃"
        case .shift: "⇧"
        }
    }

    var displayName: String {
        switch self {
        case .cmd: "Command"
        case .alt: "Option"
        case .ctrl: "Control"
        case .shift: "Shift"
        }
    }
}
