import AppKit
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let appState = AppState()

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private let log = Logger(subsystem: "com.parkeet.app", category: "AppDelegate")

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("Parkeet launching")

        // Accessory app: no dock icon, overlay can appear on all Spaces
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()

        if !appState.config.hasCompletedOnboarding {
            log.info("First launch — showing welcome window")
            showWelcomeWindow()
        } else {
            // Returning user — check permissions silently
            PermissionChecker.checkAndPrompt()
        }

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
        openSettingsWindow(page: .hotkeys)
    }

    @objc private func openFileTranscription() {
        openSettingsWindow(page: .transcribeFile)
    }

    private func openSettingsWindow(page: SettingsView.Page) {
        log.debug("Opening settings on \(page.rawValue)")

        if let window = settingsWindow, window.isVisible {
            // Update to requested page by recreating the content view
            let settingsView = SettingsView(initialPage: page)
                .environment(appState)
            window.contentView = NSHostingView(rootView: settingsView)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let settingsView = SettingsView(initialPage: page)
            .environment(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Parkeet Settings"
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
        window.isReleasedWhenClosed = false
        self.settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: - Welcome Window

    private func showWelcomeWindow() {
        let welcomeView = WelcomeView(onComplete: { [weak self] in
            guard let self else { return }
            self.appState.config.hasCompletedOnboarding = true
            self.welcomeWindow?.close()
            self.welcomeWindow = nil
            self.log.info("Onboarding complete")
        })
        .environment(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Parkeet"
        window.contentView = NSHostingView(rootView: welcomeView)
        window.center()
        window.isReleasedWhenClosed = false
        self.welcomeWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func quitApp() {
        log.info("Quitting Parkeet")
        NSApp.terminate(nil)
    }
}
