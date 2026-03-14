import Foundation
import os

/// Persistent configuration using UserDefaults.
///
/// Stored at ~/Library/Preferences/com.praten.app.plist (standard for macOS apps).
@Observable
final class Config {

    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "com.praten.app", category: "Config")

    // MARK: - Keys

    private enum Keys {
        static let hotkeyModifiers = "hotkeyModifiers"
        static let historyRetentionHours = "historyRetentionHours"
        static let soundEnabled = "soundEnabled"
        static let notificationEnabled = "notificationEnabled"
        static let voiceCommands = "voiceCommands"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    // MARK: - Properties

    var hotkeyModifiers: [HotkeyModifier] {
        get {
            guard let raw = defaults.stringArray(forKey: Keys.hotkeyModifiers) else {
                return [.cmd, .alt]  // Default: Cmd+Option
            }
            return raw.compactMap { HotkeyModifier(rawValue: $0) }
        }
        set {
            defaults.set(newValue.map(\.rawValue), forKey: Keys.hotkeyModifiers)
            log.info("Hotkey updated: \(newValue.map(\.symbol).joined())")
        }
    }

    var historyRetentionHours: Double {
        get {
            if defaults.object(forKey: Keys.historyRetentionHours) == nil { return 48.0 }
            return defaults.double(forKey: Keys.historyRetentionHours)
        }
        set {
            defaults.set(newValue, forKey: Keys.historyRetentionHours)
        }
    }

    var soundEnabled: Bool {
        get {
            // Default to true if never set
            if defaults.object(forKey: Keys.soundEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.soundEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.soundEnabled)
        }
    }

    var notificationEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.notificationEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.notificationEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.notificationEnabled)
        }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Keys.hasCompletedOnboarding) }
    }

    var voiceCommands: [String: Bool] {
        get {
            guard let dict = defaults.dictionary(forKey: Keys.voiceCommands) as? [String: Bool] else {
                return VoiceCommands.defaultEnabled
            }
            return dict
        }
        set {
            defaults.set(newValue, forKey: Keys.voiceCommands)
        }
    }
}
