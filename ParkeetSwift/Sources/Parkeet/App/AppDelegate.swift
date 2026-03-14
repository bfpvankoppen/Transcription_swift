import AppKit
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let appState = AppState()

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var meetingWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private let log = Logger(subsystem: "com.praten.app", category: "AppDelegate")

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("Praten launching")

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
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Praten")
            button.image?.size = NSSize(width: 16, height: 16)
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        menu.addItem(NSMenuItem(
            title: "About Praten…",
            action: #selector(openAbout),
            keyEquivalent: ""
        ))

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ""
        ))

        menu.addItem(NSMenuItem(
            title: "Transcribe File…",
            action: #selector(openFileTranscription),
            keyEquivalent: ""
        ))

        menu.addItem(NSMenuItem(
            title: "History",
            action: #selector(openHistory),
            keyEquivalent: ""
        ))

        menu.addItem(NSMenuItem(
            title: "Record Meeting…",
            action: #selector(startMeeting),
            keyEquivalent: ""
        ))

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit Praten",
            action: #selector(quitApp),
            keyEquivalent: ""
        ))

        // Set targets
        for item in menu.items {
            item.target = self
        }

        statusItem.menu = menu
    }

    // MARK: - Menu Actions

    @objc private func openAbout() {
        log.info("Opening about window")

        if let window = aboutWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let aboutView = AboutView()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Praten"
        window.contentView = NSHostingView(rootView: aboutView)
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 400)
        self.aboutWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func openSettings() {
        openSettingsWindow(page: .hotkeys)
    }

    @objc private func openFileTranscription() {
        openSettingsWindow(page: .transcribeFile)
    }

    @objc private func openHistory() {
        log.info("Opening history window")

        if let window = historyWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let historyView = HistoryView(historyStore: appState.historyStore, config: appState.config)
            .environment(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Praten — History"
        window.contentView = NSHostingView(rootView: historyView)
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)
        self.historyWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func startMeeting() {
        log.info("Opening meeting window")
        meetingWindow?.close()

        let meetingView = MeetingView()
            .environment(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Praten — Recording"
        window.contentView = NSHostingView(rootView: meetingView)
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)
        self.meetingWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
        window.title = "Praten Settings"
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
        window.title = "Welcome to Praten"
        window.contentView = NSHostingView(rootView: welcomeView)
        window.center()
        window.isReleasedWhenClosed = false
        self.welcomeWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func quitApp() {
        log.info("Quitting Praten")
        NSApp.terminate(nil)
    }
}
