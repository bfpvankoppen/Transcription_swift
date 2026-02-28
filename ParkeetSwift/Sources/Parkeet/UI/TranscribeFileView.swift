import SwiftUI
import UniformTypeIdentifiers

/// File transcription view with drag-and-drop, progress with time estimation, and results.
struct TranscribeFileView: View {
    @Environment(AppState.self) var appState

    enum TranscribeState {
        case idle
        case transcribing(progress: FileTranscriber.Progress, filename: String)
        case complete(text: String, wordCount: Int, filename: String)
        case error(String)
    }

    @State private var state: TranscribeState = .idle
    @State private var isDropTargeted = false
    @State private var fileTranscriber: FileTranscriber?

    var body: some View {
        VStack(spacing: 20) {
            switch state {
            case .idle:
                idleView

            case .transcribing(let progress, let filename):
                transcribingView(progress: progress, filename: filename)

            case .complete(let text, let wordCount, let filename):
                completeView(text: text, wordCount: wordCount, filename: filename)

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

    private func transcribingView(progress: FileTranscriber.Progress, filename: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 32))
                .foregroundColor(.blue)
                .symbolEffect(.pulse)

            Text("Transcribing")
                .font(.headline)

            Text(filename)
                .font(.callout)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)

            Text("\(Int(progress.fraction * 100))%")
                .font(.title2)
                .fontWeight(.medium)
                .monospacedDigit()

            HStack(spacing: 16) {
                Label(formatDuration(progress.elapsedSeconds), systemImage: "clock")
                    .font(.callout)
                    .foregroundColor(.secondary)

                if progress.chunksCompleted > 0 {
                    Label(
                        "~\(formatDuration(progress.estimatedRemainingSeconds)) remaining",
                        systemImage: "hourglass"
                    )
                    .font(.callout)
                    .foregroundColor(.secondary)
                }
            }
            .monospacedDigit()

            Text("Chunk \(progress.chunksCompleted) of \(progress.totalChunks)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Cancel") {
                fileTranscriber?.cancel()
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    private func completeView(text: String, wordCount: Int, filename: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Transcription Complete")
                    .font(.headline)
            }

            Text("\(filename) — \(wordCount) words")
                .font(.callout)
                .foregroundColor(.secondary)

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
                .buttonStyle(.borderedProminent)

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
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.copyItem(at: url, to: tempURL)
            DispatchQueue.main.async {
                self.transcribe(url: tempURL)
            }
        }
        return true
    }

    private func transcribe(url: URL) {
        let filename = url.lastPathComponent
        let initialProgress = FileTranscriber.Progress(
            chunksCompleted: 0,
            totalChunks: 1,
            elapsedSeconds: 0,
            estimatedRemainingSeconds: 0,
            fraction: 0
        )
        state = .transcribing(progress: initialProgress, filename: filename)

        Task {
            let ft = FileTranscriber(transcriber: appState.transcriber)
            fileTranscriber = ft

            do {
                let text = try await ft.transcribe(
                    fileURL: url,
                    onProgress: { progress in
                        Task { @MainActor in
                            state = .transcribing(progress: progress, filename: filename)
                        }
                    }
                )

                let wordCount = text.split(separator: " ").count

                // Save to history
                appState.historyStore.add(entry: HistoryEntry(
                    type: .file,
                    text: text,
                    wordCount: wordCount,
                    sourceFilename: filename
                ))

                state = .complete(text: text, wordCount: wordCount, filename: filename)
            } catch {
                state = .error(error.localizedDescription)
            }

            fileTranscriber = nil
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        if minutes < 60 {
            return "\(minutes)m \(secs)s"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m \(secs)s"
    }
}
