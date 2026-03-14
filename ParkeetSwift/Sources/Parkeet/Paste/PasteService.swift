import AppKit
import CoreGraphics
import os

/// Pastes text into the focused application via NSPasteboard + simulated Cmd+V.
///
/// Requires Accessibility permission for CGEvent.post().
final class PasteService {

    private let log = Logger(subsystem: "com.praten.app", category: "PasteService")

    /// Write text to clipboard and simulate Cmd+V in the frontmost app.
    func paste(text: String) {
        // 1. Save current clipboard (optional: restore after paste)
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // 2. Set clipboard to transcribed text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        log.info("Pasting \(text.count) characters")

        // 3. Simulate Cmd+V via CGEvent
        let source = CGEventSource(stateID: .combinedSessionState)

        // Suppress local keyboard events during paste
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let vKeyCode: CGKeyCode = 0x09  // 'v' key

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            log.error("Failed to create CGEvent for Cmd+V")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        // 4. Restore clipboard after a delay (let the paste complete first)
        if let previous = previousContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    /// Check if Accessibility permission is granted (required for CGEvent.post).
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility permission.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
