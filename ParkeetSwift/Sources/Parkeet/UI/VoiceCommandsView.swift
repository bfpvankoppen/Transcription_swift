import SwiftUI

/// Settings page for toggling individual voice commands on/off.
struct VoiceCommandsView: View {
    @Bindable var config: Config

    var body: some View {
        Form {
            Section {
                Text("When enabled, spoken command words are replaced with formatting characters in the transcription output.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Section("Formatting Commands") {
                ForEach(VoiceCommands.commands, id: \.phrase) { command in
                    Toggle(isOn: Binding(
                        get: { config.voiceCommands[command.phrase] ?? true },
                        set: { enabled in
                            var cmds = config.voiceCommands
                            cmds[command.phrase] = enabled
                            config.voiceCommands = cmds
                        }
                    )) {
                        HStack {
                            Text("\"\(command.phrase)\"")
                                .font(.system(size: 13))
                            Spacer()
                            Text(displayReplacement(command.replacement))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section {
                Button("Enable All") {
                    config.voiceCommands = VoiceCommands.defaultEnabled
                }
                Button("Disable All") {
                    var cmds = config.voiceCommands
                    for key in cmds.keys {
                        cmds[key] = false
                    }
                    config.voiceCommands = cmds
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func displayReplacement(_ r: String) -> String {
        switch r {
        case "\n\n": return "\\n\\n"
        case "\n": return "\\n"
        default: return r
        }
    }
}
