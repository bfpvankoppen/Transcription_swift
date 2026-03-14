import AppKit
import os

/// Plays system sounds for audio feedback.
final class SoundPlayer {

    enum Sound: String {
        case recordStart
        case recordStop
        case transcriptionComplete
    }

    private let log = Logger(subsystem: "com.praten.app", category: "SoundPlayer")

    private static let soundPaths: [Sound: String] = [
        .recordStart: "/System/Library/Sounds/Tink.aiff",
        .recordStop: "/System/Library/Sounds/Pop.aiff",
        .transcriptionComplete: "/System/Library/Sounds/Glass.aiff",
    ]

    func play(_ sound: Sound) {
        guard let path = Self.soundPaths[sound] else { return }
        guard let nsSound = NSSound(contentsOfFile: path, byReference: true) else {
            log.warning("Failed to load sound: \(sound.rawValue)")
            return
        }
        nsSound.play()
    }
}
