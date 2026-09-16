import AppKit
import SwiftUI
import Combine

/// Observable state that drives the overlay UI. Either transcriber populates this.
@MainActor
class OverlayState: ObservableObject {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    @Published var transcribedText = ""
    @Published var isEnhancing = false
    @Published var processingStatusText = ""
    @Published var isVisible = false

    private var cancellables = Set<AnyCancellable>()

    /// Generic bind that works with any concrete transcriber type.
    /// Avoids needing one overload per transcriber. Uses sink + store(in:) so that
    /// cancellables.removeAll() actually cancels subscriptions from the previous transcriber.
    func bind(
        isRecording: some Publisher<Bool, Never>,
        audioLevel: some Publisher<Float, Never>,
        transcribedText: some Publisher<String, Never>,
        isEnhancing: some Publisher<Bool, Never>
    ) {
        cancellables.removeAll()
        isRecording.sink { [weak self] in self?.isRecording = $0 }.store(in: &cancellables)
        audioLevel.sink { [weak self] in self?.audioLevel = $0 }.store(in: &cancellables)
        transcribedText.sink { [weak self] in self?.transcribedText = $0 }.store(in: &cancellables)
        isEnhancing.sink { [weak self] in self?.isEnhancing = $0 }.store(in: &cancellables)
    }

    /// Bind to Cloudflare-hosted Whisper Large V3 Turbo.
    func bind(to transcriber: CloudflareTranscriber) {
        bind(isRecording: transcriber.$isRecording, audioLevel: transcriber.$audioLevel,
             transcribedText: transcriber.$transcribedText, isEnhancing: transcriber.$isEnhancing)
    }

    func reset() {
        isRecording = false
        audioLevel = 0
        transcribedText = ""
        isEnhancing = false
        processingStatusText = ""
        isVisible = false
        cancellables.removeAll()
    }
}

/// A borderless, non-activating floating panel that sits at the bottom-center
/// (or top-center in notch mode) of the main screen and hosts the WaveformView.
class RecordingOverlayWindow: NSPanel {

    private var hostingView: NSHostingView<OverlayContent>?
    private(set) var isNotchMode = false

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = true
    }

    func show(state: OverlayState, notchMode: Bool = false) {
        self.isNotchMode = notchMode

        // Reuse existing hosting view when mode hasn't changed, to avoid
        // tearing down and recreating the SwiftUI view hierarchy every session.
        if let existing = hostingView, existing.rootView.notchMode == notchMode {
            // State is already @ObservedObject, so SwiftUI will pick up changes automatically.
        } else {
            let content = OverlayContent(state: state, notchMode: notchMode)
            let hosting = NSHostingView(rootView: content)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            contentView = hosting
            hostingView = hosting
        }

        if notchMode {
            // Notch mode: position at top-center, flush with top of screen
            // Use a higher window level so it sits above everything like the real notch
            level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            collectionBehavior = [.stationary, .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

            let shadowPadding: CGFloat = 20
            let contentWidth: CGFloat = 360
            let contentHeight: CGFloat = 140
            let totalWidth = contentWidth + shadowPadding * 2
            let totalHeight = contentHeight + shadowPadding

            if let screen = NSScreen.main {
                let x = screen.frame.origin.x + (screen.frame.width - totalWidth) / 2
                let y = screen.frame.origin.y + screen.frame.height - totalHeight
                setFrame(CGRect(x: x, y: y, width: totalWidth, height: totalHeight), display: false)
            }
        } else {
            // Default pill mode: position at bottom-center
            level = .floating
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let size = CGSize(width: 360, height: 140)
            if let screen = NSScreen.main {
                let x = screen.visibleFrame.midX - size.width / 2
                let y = screen.visibleFrame.minY + 30
                setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: false)
            }
        }

        alphaValue = 1
        orderFront(nil)

        // Trigger the expand animation on next runloop tick so SwiftUI picks it up
        if notchMode {
            DispatchQueue.main.async {
                state.isVisible = true
            }
        }
    }

    func hide(state: OverlayState? = nil, completion: (() -> Void)? = nil) {
        if isNotchMode, let state {
            // Step 1: Clear text and collapse to compact shape
            state.transcribedText = ""
            state.isEnhancing = false
            state.processingStatusText = ""
            state.isRecording = false

            // Step 2: After compact transition settles, shrink width to zero
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                state.isVisible = false
            }

            // Step 3: Remove window after shrink animation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                self?.orderOut(nil)
                completion?()
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.orderOut(nil)
                completion?()
            })
        }
    }
}

// MARK: - SwiftUI content hosted inside the panel

private struct OverlayContent: View {
    @ObservedObject var state: OverlayState
    var notchMode: Bool = false

    var body: some View {
        WaveformView(
            audioLevel: state.audioLevel,
            isRecording: state.isRecording,
            transcribedText: state.transcribedText,
            isEnhancing: state.isEnhancing,
            processingStatusText: state.processingStatusText,
            notchMode: notchMode,
            notchVisible: state.isVisible
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, notchMode ? 0 : 8)
    }
}
