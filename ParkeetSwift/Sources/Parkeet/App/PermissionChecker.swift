import AppKit
import AVFoundation
import os

/// Checks required macOS permissions at startup and triggers native system prompts.
///
/// - Microphone: native system dialog appears automatically on first use.
/// - Accessibility: `AXIsProcessTrustedWithOptions(prompt: true)` shows the native
///   macOS dialog AND auto-adds the app to System Settings > Accessibility.
///   The user just needs to toggle the switch — no manual searching.
@MainActor
struct PermissionChecker {

    private static let log = Logger(subsystem: "com.praten.app", category: "Permissions")

    /// Check all permissions and trigger native prompts for any that are missing.
    /// Returns `true` if all permissions are already granted.
    @discardableResult
    static func checkAndPrompt() -> Bool {
        let micGranted = checkMicrophone()
        let accessibilityGranted = checkAccessibility()

        if micGranted && accessibilityGranted {
            log.info("All permissions granted")
            return true
        }

        return false
    }

    /// Returns `true` if accessibility is currently granted.
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Microphone

    private static func checkMicrophone() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .notDetermined:
            // Trigger the native macOS microphone prompt (non-blocking)
            log.info("Requesting microphone permission")
            let logger = log
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted {
                    logger.info("Microphone permission granted")
                } else {
                    logger.warning("Microphone permission denied")
                }
            }
            return false

        case .authorized:
            return true

        case .denied, .restricted:
            log.warning("Microphone permission denied — opening System Settings")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            return false

        @unknown default:
            return false
        }
    }

    // MARK: - Accessibility

    private static func checkAccessibility() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        // Prompt: true triggers the native macOS dialog that auto-adds the app
        // to System Settings > Accessibility. User just needs to toggle the switch.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            log.warning("Accessibility permission not granted — prompted user via system dialog")
        }
        return trusted
    }

    /// Open System Settings to the Accessibility privacy pane.
    static func openAccessibilitySettings() {
        log.info("Opening System Settings > Accessibility")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
