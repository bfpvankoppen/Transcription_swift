import CoreGraphics
import AppKit
import os

/// Detects global modifier-only hotkey (e.g. Cmd+Option) using CGEventTap.
///
/// Uses `.listenOnly` mode which only requires Input Monitoring permission
/// (not Accessibility). This is compatible with notarized distribution.
final class HotkeyListener {

    /// Called on the main thread when the hotkey combo is pressed and released.
    var onToggle: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var requiredModifiers: CGEventFlags = [.maskCommand, .maskAlternate]
    private var modifiersPressed = false

    private let log = Logger(subsystem: "com.parkeet.app", category: "HotkeyListener")

    // MARK: - Lifecycle

    func start(modifiers: [HotkeyModifier]) {
        updateModifiers(modifiers)

        // Check Input Monitoring permission
        if !CGPreflightListenEventAccess() {
            log.warning("Input Monitoring not granted, requesting...")
            CGRequestListenEventAccess()
            // Will need app restart after user grants permission
        }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
                               | (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            let listener = Unmanaged<HotkeyListener>.fromOpaque(userInfo!).takeUnretainedValue()
            return listener.handleEvent(type: type, event: event)
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            log.error("Failed to create event tap (Input Monitoring permission required)")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)!
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        log.info("Hotkey listener started: \(self.displayString(for: modifiers))")
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        log.info("Hotkey listener stopped")
    }

    /// Hot-swap the modifier combo without restarting the listener.
    func updateModifiers(_ modifiers: [HotkeyModifier]) {
        var flags: CGEventFlags = []
        for mod in modifiers {
            flags.insert(mod.cgFlag)
        }
        requiredModifiers = flags
    }

    // MARK: - Event Handling

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            // A non-modifier key was pressed — cancel any pending modifier combo
            modifiersPressed = false
            return Unmanaged.passUnretained(event)
        }

        // flagsChanged event
        let currentFlags = event.flags.intersection(.maskAll)
        let required = requiredModifiers

        if currentFlags.contains(required) {
            // All required modifiers are now held
            modifiersPressed = true
        } else if modifiersPressed {
            // Modifiers were held and now released — trigger!
            modifiersPressed = false
            DispatchQueue.main.async { [weak self] in
                self?.onToggle?()
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Display

    func displayString(for modifiers: [HotkeyModifier]) -> String {
        modifiers.map(\.symbol).joined()
    }
}

// MARK: - CGEventFlags extension

private extension CGEventFlags {
    static let maskAll: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
}

// MARK: - Modifier definitions

enum HotkeyModifier: String, Codable, CaseIterable {
    case cmd
    case alt
    case ctrl
    case shift

    var cgFlag: CGEventFlags {
        switch self {
        case .cmd: .maskCommand
        case .alt: .maskAlternate
        case .ctrl: .maskControl
        case .shift: .maskShift
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
