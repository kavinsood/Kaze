import AppKit
import SwiftUI
import Combine

/// Geometry reported by AppKit for a display with a physical camera notch.
/// Values are in points, so they continue to work across display scaling modes.
struct NotchMetrics: Equatable {
    let physicalWidth: CGFloat
    let physicalHeight: CGFloat

    /// Tight equal wings keep the compact surface close to Atoll's closed-notch
    /// proportions while leaving enough room for Kaze's icon and waveform.
    let leadingWingWidth: CGFloat = 52
    let trailingWingWidth: CGFloat = 52

    /// Atoll extends the surface slightly above the display edge. Keeping this
    /// black bleed outside the visible screen removes the faint antialiased seam
    /// where an app-rendered surface meets the physical camera housing.
    let topScreenBleed: CGFloat = 4

    var expandedWidth: CGFloat {
        physicalWidth + leadingWingWidth + trailingWingWidth
    }

    var expandedExtraHeight: CGFloat { 34 }

    static func read(from screen: NSScreen) -> NotchMetrics? {
        guard screen.safeAreaInsets.top > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return nil
        }

        let width = screen.frame.width - leftArea.width - rightArea.width
        guard width > 0 else { return nil }

        return NotchMetrics(
            physicalWidth: width.rounded(),
            physicalHeight: screen.safeAreaInsets.top.rounded()
        )
    }
}

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
    private var frameCancellables = Set<AnyCancellable>()
    private weak var notchScreen: NSScreen?
    private var notchMetrics: NotchMetrics?
    private(set) var isNotchMode = false

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = true
    }

    /// AppKit normally constrains windows away from the camera housing's safe
    /// area. This HUD intentionally spans that area so its wings can extend an
    /// equal distance from both physical-notch edges.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func show(state: OverlayState, notchMode: Bool = false) {
        let screen = NSScreen.main
        let measuredMetrics = screen.flatMap(NotchMetrics.read(from:))
        let effectiveNotchMode = notchMode && measuredMetrics != nil
        self.isNotchMode = effectiveNotchMode
        self.notchScreen = effectiveNotchMode ? screen : nil
        self.notchMetrics = effectiveNotchMode ? measuredMetrics : nil

        // Reuse existing hosting view when mode hasn't changed, to avoid
        // tearing down and recreating the SwiftUI view hierarchy every session.
        if let existing = hostingView,
           existing.rootView.notchMode == effectiveNotchMode,
           existing.rootView.notchMetrics == measuredMetrics {
            // State is already @ObservedObject, so SwiftUI will pick up changes automatically.
        } else {
            let content = OverlayContent(
                state: state,
                notchMode: effectiveNotchMode,
                notchMetrics: measuredMetrics
            )
            let hosting = NSHostingView(rootView: content)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            contentView = hosting
            hostingView = hosting
        }

        if effectiveNotchMode, let screen, let measuredMetrics {
            // Notch mode: position at top-center, flush with top of screen
            // Use a higher window level so it sits above everything like the real notch
            // Stay above the menu bar without using the private shielding level,
            // which can prevent a non-activating panel from being composited.
            level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
            collectionBehavior = [.stationary, .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

            // Start hidden behind the hardware notch. The state change below grows
            // the real panel and its SwiftUI contents out into the two wings.
            setNotchFrame(
                screen: screen,
                metrics: measuredMetrics,
                wingsVisible: state.isVisible,
                contentExpanded: hasExpandedContent(state),
                animated: false
            )
            observeNotchFrame(state: state)
        } else {
            frameCancellables.removeAll()
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
        orderFrontRegardless()

        // Trigger the expand animation on next runloop tick so SwiftUI picks it up
        if effectiveNotchMode {
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

    private func observeNotchFrame(state: OverlayState) {
        frameCancellables.removeAll()

        let refresh: () -> Void = { [weak self, weak state] in
            guard let self, let state,
                  let screen = self.notchScreen,
                  let metrics = self.notchMetrics else { return }

            self.setNotchFrame(
                screen: screen,
                metrics: metrics,
                wingsVisible: state.isVisible,
                contentExpanded: self.hasExpandedContent(state),
                animated: true
            )
        }

        state.$isVisible.dropFirst().sink { _ in refresh() }.store(in: &frameCancellables)
        state.$transcribedText.dropFirst().sink { _ in refresh() }.store(in: &frameCancellables)
        state.$isEnhancing.dropFirst().sink { _ in refresh() }.store(in: &frameCancellables)
        state.$processingStatusText.dropFirst().sink { _ in refresh() }.store(in: &frameCancellables)
    }

    private func hasExpandedContent(_ state: OverlayState) -> Bool {
        let hasTranscript = !state.transcribedText.isEmpty && !state.isEnhancing
        let hasProcessingStatus = state.isEnhancing && !state.processingStatusText.isEmpty
        return hasTranscript || hasProcessingStatus
    }

    private func setNotchFrame(
        screen: NSScreen,
        metrics: NotchMetrics,
        wingsVisible: Bool,
        contentExpanded: Bool,
        animated _: Bool
    ) {
        // Keep the transparent panel at its final centered width. AppKit pins a
        // narrow window to the camera safe-area edge when it is widened later,
        // which shifts the rendered island to the right. SwiftUI still animates
        // the visible wings from the physical notch edges.
        let width = metrics.expandedWidth
        let height = metrics.physicalHeight + metrics.topScreenBleed
            + (wingsVisible && contentExpanded ? metrics.expandedExtraHeight : 0)
        let targetFrame = CGRect(
            x: (screen.frame.midX - width / 2).rounded(),
            y: (screen.frame.maxY + metrics.topScreenBleed - height).rounded(),
            width: width.rounded(),
            height: height.rounded()
        )

        guard frame != targetFrame else { return }
        // SwiftUI animates the surface inside the panel. Updating the AppKit
        // frame directly keeps its top-center anchor exact throughout.
        setFrame(targetFrame, display: true)
    }
}

// MARK: - SwiftUI content hosted inside the panel

private struct OverlayContent: View {
    @ObservedObject var state: OverlayState
    var notchMode: Bool = false
    var notchMetrics: NotchMetrics?

    var body: some View {
        WaveformView(
            audioLevel: state.audioLevel,
            isRecording: state.isRecording,
            transcribedText: state.transcribedText,
            isEnhancing: state.isEnhancing,
            processingStatusText: state.processingStatusText,
            notchMode: notchMode,
            notchVisible: state.isVisible,
            notchMetrics: notchMetrics
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, notchMode ? 0 : 8)
    }
}
