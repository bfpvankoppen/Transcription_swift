import SwiftUI
import UniformTypeIdentifiers

/// File transcription view with drag-and-drop, progress, and results.
struct TranscribeFileView: View {
    @EnvironmentObject var appState: AppState

    enum TranscribeState {
        case idle
        case transcribing(progress: Double)
        case complete(text: String, wordCount: Int)
        case error(String)
    }

    @State private var state: TranscribeState = .idle
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 20) {
            switch state {
            case .idle:
                idleView

            case .transcribing(let progress):
                transcribingView(progress: progress)

            case .complete(let text, let wordCount):
                completeView(text: text, wordCount: wordCount)

            case .error(let message):
                errorView(message: message)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.audio], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - States

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Transcribe Audio File")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Drop an audio file here or click to choose")
                .foregroundColor(.secondary)

            Button("Choose File…") {
                chooseFile()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
        )
    }

    private func transcribingView(progress: Double) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)

            Text("Transcribing… \(Int(progress * 100))%")
                .font(.headline)
        }
    }

    private func completeView(text: String, wordCount: Int) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("\(wordCount) words transcribed")
                    .font(.headline)
            }

            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(.quaternary)
            .cornerRadius(8)

            HStack {
                Button("Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Transcribe Another") {
                    state = .idle
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.red)

            Text(message)
                .foregroundColor(.secondary)

            Button("Try Again") {
                state = .idle
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .wav, .aiff, .mp3]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribe(url: url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, error in
            guard let url else { return }
            // Copy to temp location (the drop URL is ephemeral)
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: tempURL)
            DispatchQueue.main.async {
                self.transcribe(url: tempURL)
            }
        }
        return true
    }

    private func transcribe(url: URL) {
        state = .transcribing(progress: 0)

        Task {
            let fileTranscriber = FileTranscriber(transcriber: appState.transcriber)
            do {
                let text = try await fileTranscriber.transcribe(
                    fileURL: url,
                    onProgress: { progress in
                        Task { @MainActor in
                            state = .transcribing(progress: progress)
                        }
                    }
                )
                let wordCount = text.split(separator: " ").count
                state = .complete(text: text, wordCount: wordCount)
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }
}
