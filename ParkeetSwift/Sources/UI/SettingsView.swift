import SwiftUI

/// Main settings view with sidebar navigation (macOS System Settings style).
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    enum Page: String, CaseIterable, Identifiable {
        case hotkeys = "Hotkeys"
        case history = "History"
        case voiceCommands = "Voice Commands"
        case about = "About"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .hotkeys: "keyboard"
            case .history: "clock"
            case .voiceCommands: "text.bubble"
            case .about: "info.circle"
            }
        }
    }

    @State private var selectedPage: Page = .hotkeys

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $selectedPage) { page in
                Label(page.rawValue, systemImage: page.icon)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch selectedPage {
            case .hotkeys:
                HotkeySettingsView(config: appState.config, hotkeyListener: appState.hotkeyListener)
            case .history:
                HistoryView(historyStore: appState.historyStore, config: appState.config)
            case .voiceCommands:
                VoiceCommandsView(config: appState.config)
            case .about:
                AboutView()
            }
        }
        .frame(width: 600, height: 400)
    }
}

// MARK: - Hotkey Settings

struct HotkeySettingsView: View {
    @Bindable var config: Config
    let hotkeyListener: HotkeyListener

    var body: some View {
        Form {
            Section("Recording Hotkey") {
                Text("Press this key combination to start/stop recording.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    ForEach(HotkeyModifier.allCases, id: \.self) { modifier in
                        Toggle(isOn: Binding(
                            get: { config.hotkeyModifiers.contains(modifier) },
                            set: { enabled in
                                var mods = config.hotkeyModifiers
                                if enabled {
                                    mods.append(modifier)
                                } else {
                                    mods.removeAll { $0 == modifier }
                                }
                                // Require at least one modifier
                                guard !mods.isEmpty else { return }
                                config.hotkeyModifiers = mods
                                hotkeyListener.updateModifiers(mods)
                            }
                        )) {
                            Text("\(modifier.symbol) \(modifier.displayName)")
                        }
                        .toggleStyle(.checkbox)
                    }
                }

                Text("Current: \(hotkeyListener.displayString(for: config.hotkeyModifiers))")
                    .font(.title2)
                    .padding(.top, 4)
            }

            Section("Audio") {
                Toggle("Sound feedback", isOn: Binding(
                    get: { config.soundEnabled },
                    set: { config.soundEnabled = $0 }
                ))

                Toggle("Notification on file transcription", isOn: Binding(
                    get: { config.notificationEnabled },
                    set: { config.notificationEnabled = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Parkeet")
                .font(.title)
                .fontWeight(.bold)

            Text("Speech-to-Text for macOS")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                AttributionRow(label: "ASR Engine", value: "sherpa-onnx")
                AttributionRow(label: "Model", value: "NVIDIA Parakeet TDT 0.6B v3 (INT8)")
                AttributionRow(label: "Languages", value: "25 European languages")
            }
            .padding()

            Spacer()

            Text("Version 2.0.0")
                .font(.caption)
                .foregroundColor(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AttributionRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .fontWeight(.medium)
        }
    }
}
