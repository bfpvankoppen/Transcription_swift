import SwiftUI

/// Main settings view with sidebar navigation (macOS System Settings style).
struct SettingsView: View {
    @Environment(AppState.self) var appState

    enum Page: String, CaseIterable, Identifiable {
        case hotkeys = "Hotkeys"
        case transcribeFile = "Transcribe File"
        case voiceCommands = "Voice Commands"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .hotkeys: "keyboard"
            case .transcribeFile: "doc.badge.plus"
            case .voiceCommands: "text.bubble"
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
            case .voiceCommands:
                VoiceCommandsView(config: appState.config)
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
                        Text("Praten")
                            .font(.title)
                            .fontWeight(.bold)
                        Text("Transcription")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        Text("Offline speech-to-text for macOS")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }

                Divider()

                // What is Praten
                AboutSection(title: "What is Praten?") {
                    Text("Praten (Dutch for \"to talk\") is a native macOS app that transcribes speech to text entirely on your device. No internet connection, no cloud services, no data leaving your Mac.")
                        .font(.callout)
                }

                // How to Use
                AboutSection(title: "How to Use") {
                    NumberedItem(number: "1", title: "Quick Transcription", description: "Press your hotkey (default: Cmd+Option) in any app. Speak, then press again. Your speech is transcribed and pasted instantly into the active text field.")
                    NumberedItem(number: "2", title: "Meeting Recording", description: "Use Record Meeting from the menu bar to capture longer sessions. Praten transcribes in real time using overlapping windows for accuracy. After recording, optionally refine the full transcript for best results.")
                    NumberedItem(number: "3", title: "File Transcription", description: "Drop an audio file (WAV, MP3, M4A, etc.) into the Transcribe File panel. Praten processes it in chunks and produces a complete transcript.")
                }

                // Features
                AboutSection(title: "Features") {
                    BulletList(items: [
                        "Hotkey recording — press to record, press again to transcribe and paste",
                        "Meeting transcription — continuous recording with live transcript",
                        "File transcription — transcribe audio files of any length",
                        "Voice commands — define text replacements (e.g., \"new line\" becomes a line break)",
                        "History — searchable log of all transcriptions with semantic search, copy, and export",
                        "25 languages — automatic detection, no configuration needed",
                        "Fully offline — no network access required, all processing on-device",
                        "Menu bar app — runs quietly in your menu bar, no Dock icon",
                    ])
                }

                // Speech Recognition Model
                AboutSection(title: "Speech Recognition") {
                    Text("Powered by NVIDIA Parakeet TDT 0.6B v3 — a 600-million parameter FastConformer model trained on ~670,000 hours of multilingual audio. Ranked #1 on the HuggingFace Open ASR Leaderboard at release (6.34% WER on English benchmarks).")
                        .font(.callout)
                    BulletList(items: [
                        "Automatic punctuation and capitalization",
                        "Processes audio at roughly 3x real-time on CPU",
                        "INT8 quantized for efficient inference (~642 MB on disk)",
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

                // Privacy
                AboutSection(title: "Privacy") {
                    BulletList(items: [
                        "All transcription happens locally — no audio or text is sent anywhere",
                        "No analytics, no telemetry, no network connections",
                        "Transcription history is stored locally and can be cleared at any time",
                    ])
                }

                // Limitations
                AboutSection(title: "Limitations") {
                    BulletList(items: [
                        "Background noise — accuracy drops with increasing noise; best results with clean audio",
                        "Overlapping speakers — no speaker separation; meetings with crosstalk have higher error rates",
                        "Specialized vocabulary — uncommon names, technical jargon, or brand names may not be recognized",
                        "Accents — strong regional accents may reduce accuracy",
                    ])
                }

                Divider()

                // Attribution
                AboutSection(title: "Attribution") {
                    HStack(spacing: 4) {
                        Text("Model:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Text("NVIDIA Parakeet TDT 0.6B v3")
                            .font(.callout)
                        Text("(")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Link("CC-BY-4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0")!)
                            .font(.callout)
                        Text(")")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        Text("Engine:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Text("sherpa-onnx by k2-fsa")
                            .font(.callout)
                        Text("(")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Link("Apache 2.0", destination: URL(string: "https://github.com/k2-fsa/sherpa-onnx")!)
                            .font(.callout)
                        Text(")")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer(minLength: 8)

                HStack {
                    Spacer()
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
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

private struct NumberedItem: View {
    let number: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.medium)
                Text(description)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
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
