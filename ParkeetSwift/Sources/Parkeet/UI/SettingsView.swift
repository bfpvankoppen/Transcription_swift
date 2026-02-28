import SwiftUI

/// Main settings view with sidebar navigation (macOS System Settings style).
struct SettingsView: View {
    @Environment(AppState.self) var appState

    enum Page: String, CaseIterable, Identifiable {
        case hotkeys = "Hotkeys"
        case transcribeFile = "Transcribe File"
        case history = "History"
        case voiceCommands = "Voice Commands"
        case about = "About"
        case attribution = "Attribution"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .hotkeys: "keyboard"
            case .transcribeFile: "doc.badge.plus"
            case .history: "clock"
            case .voiceCommands: "text.bubble"
            case .about: "info.circle"
            case .attribution: "doc.text"
            }
        }
    }

    @State var selectedPage: Page = .hotkeys

    init(initialPage: Page = .hotkeys) {
        _selectedPage = State(initialValue: initialPage)
    }

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
            case .transcribeFile:
                TranscribeFileView()
            case .history:
                HistoryView(historyStore: appState.historyStore, config: appState.config)
            case .voiceCommands:
                VoiceCommandsView(config: appState.config)
            case .about:
                AboutView()
            case .attribution:
                AttributionView()
            }
        }
        .frame(width: 600, height: 500)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.blue)
                        Text("Parkeet")
                            .font(.title)
                            .fontWeight(.bold)
                        Text("Offline speech-to-text for macOS")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                Divider()

                // Speech Recognition Model
                AboutSection(title: "Speech Recognition Model") {
                    Text("NVIDIA Parakeet TDT 0.6B v3 — a 600-million parameter FastConformer model trained on ~670,000 hours of multilingual audio. Ranked #1 on the HuggingFace Open ASR Leaderboard at release with an average Word Error Rate of 6.34% on English benchmarks.")
                        .font(.callout)

                    Text("All transcription happens locally on your Mac — no audio data is sent to the cloud.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .italic()
                }

                // Capabilities
                AboutSection(title: "Capabilities") {
                    BulletList(items: [
                        "Automatic language detection — no need to select a language",
                        "Automatic punctuation and capitalization",
                        "Processes audio at roughly 3x real-time on CPU",
                        "INT8 quantized for efficient CPU inference (~642 MB on disk)",
                    ])
                }

                // Supported Languages
                AboutSection(title: "Supported Languages (25)") {
                    LanguageTier(
                        tier: "Best accuracy",
                        languages: "English, Spanish, Italian, Portuguese, German, Russian, French"
                    )
                    LanguageTier(
                        tier: "Good accuracy",
                        languages: "Ukrainian, Dutch, Polish, Slovak, Czech, Bulgarian, Croatian, Romanian, Finnish"
                    )
                    LanguageTier(
                        tier: "Moderate accuracy",
                        languages: "Hungarian, Swedish, Danish, Estonian, Greek, Lithuanian, Maltese, Latvian, Slovenian"
                    )
                    Text("Coverage: European languages only. Does not support Asian, African, or Middle Eastern languages.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Limitations
                AboutSection(title: "Limitations") {
                    BulletList(items: [
                        "Background noise — accuracy drops with increasing noise; best results with clean audio",
                        "Overlapping speakers — no speaker separation; meetings with crosstalk have higher error rates",
                        "Specialized vocabulary — uncommon names, technical jargon, or brand names may not be recognized",
                        "Accents — strong regional accents may reduce accuracy",
                        "Portuguese — trained on European Portuguese; Brazilian Portuguese may underperform",
                    ])
                }

                Spacer(minLength: 8)

                HStack {
                    Spacer()
                    Text("Version 2.0.0")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Attribution

struct AttributionView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.blue)
                        Text("Parkeet")
                            .font(.title)
                            .fontWeight(.bold)
                        Text("Offline speech-to-text for macOS")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                Divider()

                // Model
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speech Recognition Model")
                        .font(.headline)
                    Text("NVIDIA Parakeet TDT 0.6B v3")
                        .font(.callout)
                    HStack(spacing: 4) {
                        Text("License:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Link("CC-BY-4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0")!)
                            .font(.callout)
                    }
                }

                Divider()

                // Engine
                VStack(alignment: .leading, spacing: 8) {
                    Text("Inference Engine")
                        .font(.headline)
                    Text("sherpa-onnx by k2-fsa")
                        .font(.callout)
                    HStack(spacing: 4) {
                        Text("License:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Link("Apache 2.0", destination: URL(string: "https://github.com/k2-fsa/sherpa-onnx")!)
                            .font(.callout)
                    }
                }

                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - About Helpers

private struct AboutSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
    }
}

private struct BulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("\u{2022}")
                        .font(.callout)
                    Text(item)
                        .font(.callout)
                }
            }
        }
    }
}

private struct LanguageTier: View {
    let tier: String
    let languages: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tier)
                .font(.callout)
                .fontWeight(.medium)
            Text(languages)
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }
}
