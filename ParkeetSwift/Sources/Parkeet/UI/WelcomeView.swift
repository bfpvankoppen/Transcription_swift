import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import os

/// First-launch onboarding window that guides users through permissions setup.
///
/// Shows on first launch only. Three steps:
/// 1. Welcome — what Praten does
/// 2. Permissions — grant microphone + accessibility with live status
/// 3. Ready — shows the hotkey and how to start
struct WelcomeView: View {

    @Environment(AppState.self) private var appState
    @State private var step = 0
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var pollTimer: Timer?
    @State private var desktopShortcutCreated = false

    private let log = Logger(subsystem: "com.praten.app", category: "WelcomeView")

    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            Group {
                switch step {
                case 0: welcomeStep
                case 1: permissionsStep
                case 2: readyStep
                default: desktopShortcutStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation bar
            HStack {
                // Step indicator
                HStack(spacing: 6) {
                    ForEach(0..<4) { i in
                        Circle()
                            .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }

                Spacer()

                if step > 0 {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.2)) { step -= 1 }
                    }
                }

                if step == 3 {
                    Button("Skip") {
                        onComplete()
                    }

                    Button("Get Started") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Continue") {
                        withAnimation(.easeInOut(duration: 0.2)) { step += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(step == 1 && !allPermissionsGranted)
                }
            }
            .padding()
        }
        .frame(width: 520, height: 480)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    private var allPermissionsGranted: Bool {
        micGranted && accessibilityGranted
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("Welcome to Praten")
                .font(.system(size: 24, weight: .semibold))

            Text("Speech-to-text that works everywhere on your Mac.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "mic.fill", text: "Press a hotkey to start recording")
                featureRow(icon: "text.cursor", text: "Your speech is transcribed and pasted instantly")
                featureRow(icon: "globe", text: "Works in 25 languages, fully offline")
                featureRow(icon: "lock.shield", text: "Everything stays on your Mac — nothing sent to the cloud")
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.tint)
            Text(text)
                .font(.system(size: 13))
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("Permissions")
                .font(.system(size: 24, weight: .semibold))

            Text("Praten needs two permissions to work.\nThis only takes a moment.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 14) {
                microphoneCard
                accessibilityCard
            }

            if allPermissionsGranted {
                Label("All permissions granted — you're good to go!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, weight: .medium))
            }

            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: Microphone Card

    private var microphoneCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(micGranted ? .green : .orange)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Microphone")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Needed to hear your voice for transcription.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if micGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                }
            }

            if !micGranted {
                Text("A system dialog will appear — just click **Allow**.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button(action: requestMicrophone) {
                    Label("Allow Microphone", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(micGranted ? Color.green.opacity(0.06) : Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(micGranted ? Color.green.opacity(0.2) : Color.orange.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: Accessibility Card

    private var accessibilityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(accessibilityGranted ? .green : .orange)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Needed to detect your keyboard shortcut and paste text.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if accessibilityGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                }
            }

            if !accessibilityGranted {
                VStack(alignment: .leading, spacing: 6) {
                    instructionRow(number: "1", text: "Click the button below — **System Settings** will open")
                    instructionRow(number: "2", text: "If Praten is in the list, **toggle the switch on**")
                    instructionRow(number: "3", text: "If not, click the **+** button at the bottom")
                    instructionRow(number: "4", text: "Go to **Applications**, search for **Praten**, and select it")
                    instructionRow(number: "5", text: "Come back here — it will update automatically")
                }
                .padding(.leading, 4)

                Button(action: requestAccessibility) {
                    Label("Open System Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Text("This window will update automatically once access is granted.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(accessibilityGranted ? Color.green.opacity(0.06) : Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accessibilityGranted ? Color.green.opacity(0.2) : Color.orange.opacity(0.15), lineWidth: 1)
        )
    }

    private func instructionRow(number: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 3: Ready

    private var readyStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("You're all set!")
                .font(.system(size: 24, weight: .semibold))

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    hotkeyBadge
                    Text("to start recording")
                        .font(.system(size: 15))
                }

                HStack(spacing: 8) {
                    hotkeyBadge
                    Text("again to stop and paste")
                        .font(.system(size: 15))
                }
            }

            Text("Look for the mic icon in your menu bar to access settings.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var hotkeyBadge: some View {
        let symbols = appState.config.hotkeyModifiers.map(\.symbol).joined()
        return Text(symbols)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }

    // MARK: - Step 4: Desktop Shortcut

    private var desktopShortcutStep: some View {
        VStack(spacing: 16) {
            Spacer()

            if desktopShortcutCreated {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))

                Text("Shortcut Added!")
                    .font(.system(size: 24, weight: .semibold))

                Text("Praten is now on your Desktop.\nClick **Get Started** to begin.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)

                Text("Add to Desktop?")
                    .font(.system(size: 24, weight: .semibold))

                Text("Create a shortcut on your Desktop so you\ncan easily find and launch Praten.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: createDesktopShortcut) {
                    Label("Add to Desktop", systemImage: "plus.square")
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
            }

            Spacer()
        }
        .padding(.horizontal, 40)
        .animation(.easeInOut(duration: 0.4), value: desktopShortcutCreated)
    }

    private func createDesktopShortcut() {
        let appURL = Bundle.main.bundleURL

        // Use NSSavePanel so the sandbox grants write access to the chosen location
        let panel = NSSavePanel()
        panel.title = "Save Praten Shortcut"
        panel.nameFieldStringValue = "Praten"
        panel.allowedContentTypes = [.aliasFile]
        panel.canCreateDirectories = false

        // Default to Desktop
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            panel.directoryURL = desktop
        }

        panel.begin { response in
            guard response == .OK, let saveURL = panel.url else {
                log.info("User cancelled desktop shortcut save panel")
                return
            }

            do {
                // Remove existing file at the chosen location
                try? FileManager.default.removeItem(at: saveURL)

                // Create a Finder alias at the user-chosen location
                let bookmarkData = try appURL.bookmarkData(
                    options: .suitableForBookmarkFile,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                try URL.writeBookmarkData(bookmarkData, to: saveURL)
                desktopShortcutCreated = true
                log.info("Desktop shortcut created at \(saveURL.path)")
            } catch {
                log.error("Failed to create desktop shortcut: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Permission Actions

    private func requestMicrophone() {
        // Always attempt to request — macOS will show the system dialog if possible.
        // If already denied, the completion returns false and we open System Settings.
        if #available(macOS 14.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    micGranted = granted
                    if !granted {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            }
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    micGranted = granted
                    if !granted {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            }
        }
    }

    private func requestAccessibility() {
        PermissionChecker.openAccessibilitySettings()
    }

    // MARK: - Polling

    private func startPolling() {
        checkPermissions()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async { checkPermissions() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func checkPermissions() {
        if #available(macOS 14.0, *) {
            micGranted = AVAudioApplication.shared.recordPermission == .granted
        } else {
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
        accessibilityGranted = AXIsProcessTrusted()
    }
}
