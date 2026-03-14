import AppKit
import SwiftUI
import os

/// Floating overlay panel that appears on all macOS Spaces.
///
/// Shows animated waveform during recording, "Transcribing…" during processing,
/// and word count on completion. Uses NSPanel for full control over window behavior.
final class OverlayPanel: NSPanel {

    enum DisplayState {
        case hidden
        case recording
        case transcribing
        case complete(wordCount: Int)
    }

    private(set) var displayState: DisplayState = .hidden
    private var contentHostingView: NSHostingView<OverlayContentView>?
    private var overlayViewModel = OverlayViewModel()
    private var fadeAnimator: NSViewAnimation?

    private let log = Logger(subsystem: "com.praten.app", category: "OverlayPanel")

    // MARK: - Init

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 384, height: 104),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        // Floating above all windows
        isFloatingPanel = true
        level = .floating

        // Appear on all Spaces, stay during Mission Control
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]

        // Don't steal focus or hide when app loses focus
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true

        // Transparent chrome
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false

        // Hide from screen sharing
        sharingType = .none

        // Don't release when closed
        isReleasedWhenClosed = false

        // Set SwiftUI content
        let hostingView = NSHostingView(rootView: OverlayContentView(viewModel: overlayViewModel))
        self.contentView = hostingView
        self.contentHostingView = hostingView
    }

    // Never steal keyboard focus
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Show/Hide

    func showRecording() {
        displayState = .recording
        overlayViewModel.state = .recording
        overlayViewModel.levels = Array(repeating: 0, count: 28)
        positionOnScreen()
        fadeIn()
        log.debug("Overlay: recording")
    }

    func showTranscribing() {
        displayState = .transcribing
        overlayViewModel.state = .transcribing
        log.debug("Overlay: transcribing")
    }

    func showComplete(wordCount: Int) {
        displayState = .complete(wordCount: wordCount)
        overlayViewModel.state = .complete(wordCount: wordCount)
        log.debug("Overlay: complete (\(wordCount) words)")
    }

    func hide() {
        displayState = .hidden
        fadeOut()
        log.debug("Overlay: hidden")
    }

    func updateLevels(_ levels: [Float]) {
        overlayViewModel.levels = levels
    }

    // MARK: - Positioning

    private func positionOnScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.maxY - frame.height - 40
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Animation

    private func fadeIn() {
        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 1.0
        }
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0.0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }
}

// MARK: - OverlayViewModel

@Observable
class OverlayViewModel {
    var state: OverlayPanel.DisplayState = .hidden
    var levels: [Float] = Array(repeating: 0, count: 28)
}

// MARK: - OverlayContentView (SwiftUI)

struct OverlayContentView: View {
    @Bindable var viewModel: OverlayViewModel

    var body: some View {
        ZStack {
            // Rounded background
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

            // Content based on state
            switch viewModel.state {
            case .hidden:
                EmptyView()

            case .recording:
                VStack(spacing: 6) {
                    WaveformView(levels: viewModel.levels)
                        .padding(.horizontal, 16)
                    Text("Speak now…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }

            case .transcribing:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Transcribing…")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }

            case .complete(let wordCount):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("\(wordCount) words transcribed")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                }
            }
        }
        .padding(12)
        .frame(width: 384, height: 104)
    }
}

// MARK: - WaveformView

struct WaveformView: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<levels.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(
                        width: 6,
                        height: max(4, CGFloat(levels[index]) * 40)
                    )
                    .animation(.easeOut(duration: 0.05), value: levels[index])
            }
        }
    }
}
