import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Live meeting transcription window.
///
/// Shows a scrolling transcript during recording, then export options when stopped.
struct MeetingView: View {

    @Environment(AppState.self) private var appState
    @State private var meetingTranscriber: MeetingTranscriber?
    @State private var isRecording = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            transcriptArea
            Divider()
            controlBar
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear { startMeeting() }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Recording")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
            } else if let mt = meetingTranscriber, !mt.segments.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Meeting ended")
                    .font(.system(size: 13, weight: .medium))
            }

            Spacer()

            if let mt = meetingTranscriber {
                Text(formatDuration(mt.elapsedSeconds))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text("\(mt.totalWordCount) words")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Transcript Area

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let mt = meetingTranscriber {
                        // Newest segments at top for a live-feed feel
                        ForEach(mt.segments.reversed()) { segment in
                            segmentRow(segment)
                                .id(segment.id)
                        }

                        if isRecording && mt.segments.isEmpty {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Listening...")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 20)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: meetingTranscriber?.segments.count) {
                // Auto-scroll to top where newest segment appears
                if let last = meetingTranscriber?.segments.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .top)
                    }
                }
            }
        }
    }

    private func segmentRow(_ segment: MeetingSegment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(formatTimestamp(segment.timestamp))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)

            Text(segment.text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        Group {
            if isRecording {
                recordingControls
            } else if let mt = meetingTranscriber, !mt.segments.isEmpty {
                completedControls
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var recordingControls: some View {
        Button(action: stopMeeting) {
            Label("Stop Meeting", systemImage: "stop.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
    }

    private var completedControls: some View {
        HStack(spacing: 12) {
            Button(action: copyAll) {
                Label("Copy All", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)

            Button(action: { saveFile(asMarkdown: false) }) {
                Label("Save .txt", systemImage: "doc.text")
            }
            .buttonStyle(.bordered)

            Button(action: { saveFile(asMarkdown: true) }) {
                Label("Save .md", systemImage: "doc.richtext")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Actions

    private func startMeeting() {
        guard appState.modelLoaded else {
            errorMessage = "Model not loaded yet"
            return
        }

        let mt = MeetingTranscriber(recorder: appState.recorder, transcriber: appState.transcriber)
        self.meetingTranscriber = mt

        do {
            try mt.start()
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopMeeting() {
        meetingTranscriber?.stop()
        isRecording = false

        // Save to history
        if let mt = meetingTranscriber, !mt.segments.isEmpty {
            appState.historyStore.add(entry: HistoryEntry(
                type: .meeting,
                text: mt.plainText,
                wordCount: mt.totalWordCount
            ))
        }
    }

    private func copyAll() {
        guard let mt = meetingTranscriber else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mt.plainText, forType: .string)
    }

    private func saveFile(asMarkdown: Bool) {
        guard let mt = meetingTranscriber else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = asMarkdown
            ? "meeting-transcript.md"
            : "meeting-transcript.txt"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let content = asMarkdown ? mt.markdownText() : mt.plainText
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Formatting

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
