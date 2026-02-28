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

    private static let log = Logger(subsystem: "com.parkeet.app", category: "Permissions")

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

        log.warning("Accessibility permission not granted — triggering native prompt")

        // This shows the native macOS dialog AND auto-adds the app to the
        // Accessibility list in System Settings. The user just toggles the switch.
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        return false
    }
}
