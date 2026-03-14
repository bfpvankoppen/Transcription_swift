import SwiftUI

@main
struct PratenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar app — no main window. Settings opened from tray menu.
        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}
