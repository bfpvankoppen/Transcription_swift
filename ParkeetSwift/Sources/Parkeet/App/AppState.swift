import Foundation
import AppKit
import os

/// Central state machine for the transcription pipeline.
///
/// States: idle → recording → transcribing → pasting → idle
@MainActor
@Observable
final class AppState {

    // MARK: - State

    enum State: String {
        case idle
        case loading       // Model loading on first launch
        case recording
        case transcribing
        case pasting
    }

    private(set) var state: State = .idle
    private(set) var modelLoaded = false
    private(set) var statusText = "Loading model…"
    private(set) var audioLevels: [Float] = Array(repeating: 0, count: 28)
    private(set) var transcribedWordCount: Int = 0

    // MARK: - Dependencies

    let config = Config()
    let recorder = AudioRecorder()
    let transcriber = Transcriber()
    let pasteService = PasteService()
    let hotkeyListener = HotkeyListener()
    let historyStore = HistoryStore()
    let overlay = OverlayPanel()
    let soundPlayer = SoundPlayer()
    let embeddingEngine = EmbeddingEngine()

    private var levelTimer: Timer?
    private var permissionTimer: Timer?
    private var targetApp: NSRunningApplication?
    private var hotkeyStarted = false

    private let log = Logger(subsystem: "com.praten.app", category: "AppState")

    // MARK: - Lifecycle

    func start() {
        log.info("Starting Praten")
        state = .loading
        statusText = "Loading model…"

        historyStore.embeddingEngine = embeddingEngine
        historyStore.rebuildEmbeddings()

        // Load model in background
        Task.detached(priority: .userInitiated) { [self] in
            do {
                try await transcriber.loadModel(
                    onStatus: { status in
                        Task { @MainActor in
                            self.statusText = status
                        }
                    }
                )
                await MainActor.run {
                    self.modelLoaded = true
                    self.state = .idle
                    self.statusText = "Ready"
                    self.log.info("Model loaded, ready for transcription")
                }
            } catch {
                await MainActor.run {
                    self.statusText = "Model load failed: \(error.localizedDescription)"
                    self.log.error("Model load failed: \(error)")
                }
            }
        }

        // Set up hotkey callback
        hotkeyListener.onToggle = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleHotkeyToggle()
            }
        }

        // Start hotkey if accessibility is already granted, otherwise poll for it
        if PermissionChecker.isAccessibilityGranted {
            startHotkey()
        } else {
            log.info("Waiting for Accessibility permission — polling every 2s")
            statusText = "Waiting for Accessibility permission…"
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.checkPermissionAndStartHotkey()
                }
            }
        }
    }

    private func checkPermissionAndStartHotkey() {
        guard !hotkeyStarted, PermissionChecker.isAccessibilityGranted else { return }

        log.info("Accessibility permission granted — starting hotkey listener")
        permissionTimer?.invalidate()
        permissionTimer = nil

        if modelLoaded {
            statusText = "Ready"
        }

        startHotkey()
    }

    private func startHotkey() {
        hotkeyListener.start(modifiers: config.hotkeyModifiers)
        hotkeyStarted = true
    }

    // MARK: - Hotkey Toggle

    private func handleHotkeyToggle() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        default:
            log.debug("Hotkey pressed during \(self.state.rawValue), ignoring")
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard modelLoaded else {
            log.warning("Cannot record: model not loaded")
            return
        }

        // Capture the frontmost app BEFORE we show our overlay
        targetApp = NSWorkspace.shared.frontmostApplication

        state = .recording
        log.notice("Recording started")

        if config.soundEnabled {
            soundPlayer.play(.recordStart)
        }

        // Start audio capture
        do {
            try recorder.start()
        } catch {
            log.error("Failed to start recording: \(error)")
            state = .idle
            return
        }

        // Show overlay and start level metering
        overlay.showRecording()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.audioLevels = self.recorder.currentLevels
                self.overlay.updateLevels(self.audioLevels)
            }
        }
    }

    private func stopRecording() {
        state = .transcribing
        log.notice("Recording stopped, starting transcription")

        if config.soundEnabled {
            soundPlayer.play(.recordStop)
        }

        // Stop level metering
        levelTimer?.invalidate()
        levelTimer = nil

        // Get audio and stop recorder
        let audio = recorder.stop()

        // Show transcribing state on overlay
        overlay.showTranscribing()

        // Transcribe in background
        Task.detached(priority: .userInitiated) { [self] in
            let text = await transcriber.transcribe(audio: audio)
            await MainActor.run {
                self.finishTranscription(text)
            }
        }
    }

    // MARK: - Transcription Complete

    private func finishTranscription(_ rawText: String) {
        let text = VoiceCommands.apply(to: rawText, enabled: config.voiceCommands)
        let wordCount = text.split(separator: " ").count
        transcribedWordCount = wordCount

        log.info("Transcription complete: \(wordCount) words")

        if text.isEmpty {
            log.warning("Empty transcription result")
            overlay.hide()
            state = .idle
            return
        }

        // Show word count on overlay briefly
        overlay.showComplete(wordCount: wordCount)

        // Save to history
        historyStore.add(entry: HistoryEntry(
            type: .hotkey,
            text: text,
            wordCount: wordCount
        ))

        // Paste after brief delay
        state = .pasting
        paste(text: text)
    }

    private func paste(text: String) {
        // Re-focus the target app
        if let app = targetApp {
            app.activate()
        }

        // Small delay for focus to settle, then paste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            pasteService.paste(text: text)

            if config.soundEnabled {
                soundPlayer.play(.transcriptionComplete)
            }

            // Hide overlay after showing word count
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                overlay.hide()
                state = .idle
                targetApp = nil
            }
        }
    }

    // MARK: - File Transcription

    func transcribeFile(
        url: URL,
        onProgress: @escaping @Sendable (FileTranscriber.Progress) -> Void
    ) async -> String? {
        guard modelLoaded else { return nil }

        log.info("Starting file transcription: \(url.lastPathComponent)")

        let fileTranscriber = FileTranscriber(transcriber: transcriber)
        do {
            let result = try await fileTranscriber.transcribe(
                fileURL: url,
                onProgress: onProgress
            )

            historyStore.add(entry: HistoryEntry(
                type: .file,
                text: result,
                wordCount: result.split(separator: " ").count,
                sourceFilename: url.lastPathComponent
            ))

            return result
        } catch {
            log.error("File transcription failed: \(error)")
            return nil
        }
    }
}
