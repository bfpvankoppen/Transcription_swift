import AppKit
import SwiftUI
import os

final class AppDelegate: NSObject, NSApplicationDelegate {

    let appState = AppState()

    private var statusItem: NSStatusItem!
    private let log = Logger(subsystem: "com.parkeet.app", category: "AppDelegate")

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("Parkeet launching")

        // Accessory app: no dock icon, overlay can appear on all Spaces
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()
        appState.start()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Parkeet")
            button.image?.size = NSSize(width: 16, height: 16)
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let statusMenuItem = NSMenuItem(title: "Parkeet", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))

        menu.addItem(NSMenuItem(
            title: "Transcribe File…",
            action: #selector(openFileTranscription),
            keyEquivalent: "o"
        ))

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit Parkeet",
            action: #selector(quitApp),
            keyEquivalent: "q"
        ))

        // Set targets
        for item in menu.items {
            item.target = self
        }

        statusItem.menu = menu
    }

    // MARK: - Menu Actions

    @objc private func openSettings() {
        log.debug("Opening settings")
        NSApp.activate(activatingAllWindows: true)

        // Open SwiftUI Settings scene
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        // Trigger Settings window via standard menu action
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func openFileTranscription() {
        log.debug("Opening file transcription")

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .wav, .aiff, .mp3]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an audio file to transcribe"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                let result = await self.appState.transcribeFile(url: url)
                if let result {
                    self.showTranscriptionResult(result, filename: url.lastPathComponent)
                }
            }
        }
    }

    private func showTranscriptionResult(_ text: String, filename: String) {
        let wordCount = text.split(separator: " ").count
        let alert = NSAlert()
        alert.messageText = "Transcription Complete"
        alert.informativeText = "\(filename): \(wordCount) words"
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @objc private func quitApp() {
        log.info("Quitting Parkeet")
        NSApp.terminate(nil)
    }
}
