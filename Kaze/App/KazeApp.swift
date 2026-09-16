import SwiftUI
import AppKit
import Combine

@main
struct KazeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            ContentView(
                historyManager: appDelegate.historyManager,
                customWordsManager: appDelegate.customWordsManager,
                restartOnboarding: appDelegate.restartOnboarding
            )
            .frame(width: 760, height: 640)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var transcriber: CloudflareTranscriber?
    let historyManager = TranscriptionHistoryManager()
    let customWordsManager = CustomWordsManager()

    private let hotkeyManager = HotkeyManager()
    private let overlayWindow = RecordingOverlayWindow()
    private let overlayState = OverlayState()
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    /// Tracks the last icon name applied to the status bar button to prevent
    /// a KVO feedback loop where setting the image triggers an appearance
    /// change notification which calls updateStatusBarIcon() again endlessly.
    private var lastAppliedIconName: String?

    private var settingsWindowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?

    private var hotkeyMode: HotkeyMode {
        get {
            let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.hotkeyMode)
            return HotkeyMode(rawValue: raw ?? "") ?? .holdToTalk
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: AppPreferenceKey.hotkeyMode)
        }
    }

    private var notchModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppPreferenceKey.notchMode)
    }

    /// Returns the AVCapture unique ID for the user-selected microphone, or nil for system default.
    private var selectedMicrophoneUID: String? {
        let stored = UserDefaults.standard.string(forKey: AppPreferenceKey.selectedMicrophoneID) ?? ""
        guard !stored.isEmpty, isKnownAudioInputDevice(stored) else { return nil }
        return stored
    }

    private var hotkeyModeObserver: NSObjectProtocol?
    private var isSessionActive = false

    /// Captures all settings at the moment recording begins so that mid-session
    /// preference changes cannot route stop/finalize through the wrong engine.
    private struct RecordingSession {
        let transcriber: CloudflareTranscriber
        let source: TranscriptionSource?
        let startedAt: Date
        var endedAt: Date?

        var speechDuration: TimeInterval {
            max((endedAt ?? Date()).timeIntervalSince(startedAt), 0)
        }
    }

    /// The active recording session, non-nil while `isSessionActive` is true.
    private var activeSession: RecordingSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory so no Dock icon appears
        NSApp.setActivationPolicy(.accessory)
        migrateLegacyPreferences()

        // This fork intentionally performs no LLM post-processing after transcription.

        // Menu bar icon uses a dark/light appearance-aware image.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusBarIcon()
        if let button = statusItem?.button {
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.updateStatusBarIcon()
                }
            }
        }
        buildMenu()

        // Release QA hook: renders the real production overlay without touching
        // the microphone, credentials, hotkey, or transcription pipeline.
        if CommandLine.arguments.contains("--qa-overlay") {
            overlayState.audioLevel = 0.65
            overlayState.isRecording = true
            overlayWindow.show(state: overlayState, notchMode: true)
            return
        }

        updateStatusItemIndicator()

        // Upstream Sparkle updates are intentionally disabled for this private fork.

        if !UserDefaults.standard.bool(forKey: AppPreferenceKey.hasCompletedOnboarding) {
            showOnboarding()
        } else {
            // Already completed onboarding, so set up the hotkey (permissions should already be granted).
            Task {
                await requestPermissionsAndSetupHotkey()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {}

    private func migrateLegacyPreferences() {
        let defaults = UserDefaults.standard
        let storedMicrophone = defaults.string(forKey: AppPreferenceKey.selectedMicrophoneID) ?? ""
        if !storedMicrophone.isEmpty, !isKnownAudioInputDevice(storedMicrophone) {
            defaults.set("", forKey: AppPreferenceKey.selectedMicrophoneID)
        }

        // This fork only supports Cloudflare-hosted Whisper. Migrate every legacy engine choice.
        defaults.set(TranscriptionEngine.whisper.rawValue, forKey: AppPreferenceKey.transcriptionEngine)
        defaults.set("off", forKey: AppPreferenceKey.enhancementMode)
        defaults.set(false, forKey: AppPreferenceKey.smartFormattingEnabled)

    }

    private func updateStatusBarIcon() {
        guard let button = statusItem?.button else { return }
        let iconName = "kaze-icon"

        // Guard against redundant updates to break the KVO feedback loop:
        // setting button.image triggers an AppKit redraw which fires the
        // effectiveAppearance KVO observer, which calls this method again.
        // Without this guard the loop runs as fast as the CPU can go (~91% CPU).
        guard iconName != lastAppliedIconName else { return }
        lastAppliedIconName = iconName

        if let icon = NSImage(named: iconName)?.copy() as? NSImage {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            button.image = icon
        } else {
            let fallback = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Kaze")
            fallback?.isTemplate = true
            button.image = fallback
        }
        button.imagePosition = .imageOnly
        button.image?.accessibilityDescription = "Kaze"
    }

    private func buildMenu() {
        let menu = NSMenu()

        let aboutItem = NSMenuItem(title: "About Kaze", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Kaze", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func showAbout() {
        openSettingsWindow(initialTab: .about)
    }

    private func updateStatusItemIndicator() {
        guard let statusItem, let button = statusItem.button else { return }
        let isConfigured = TranscriptionEngine.whisper.isConfigured
        let shouldMuteIcon = !isSessionActive && !isConfigured

        statusItem.length = NSStatusItem.squareLength
        button.attributedTitle = NSAttributedString(string: "")
        button.alphaValue = shouldMuteIcon ? 0.45 : 1.0
        button.contentTintColor = nil
    }

    private func showOnboarding() {
        let onboardingView = OnboardingView { [weak self] in
            self?.onboardingWindowController?.window?.close()
            self?.onboardingWindowController = nil
            // Set up hotkey and permissions now that onboarding is complete
            Task { [weak self] in
                await self?.requestPermissionsAndSetupHotkey()
            }
        }
        let hostingController = NSHostingController(rootView: onboardingView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Kaze"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 540))

        window.delegate = self

        let controller = NSWindowController(window: window)
        onboardingWindowController = controller
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        centerWindow(window)

        // SwiftUI/AppKit can still adjust the final frame right after showing.
        DispatchQueue.main.async { [weak self, weak window] in
            guard self != nil, let window else { return }
            self?.centerWindow(window)
        }
    }

    private func centerWindow(_ window: NSWindow) {
        if let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first {
            let visibleFrame = screen.visibleFrame
            let centeredFrame = NSRect(
                x: visibleFrame.midX - window.frame.width / 2,
                y: visibleFrame.midY - window.frame.height / 2,
                width: window.frame.width,
                height: window.frame.height
            )
            window.setFrame(centeredFrame, display: true)
        } else {
            window.center()
        }
    }

    /// Requests microphone permissions (if needed) and sets up the global hotkey.
    /// Called after onboarding completes or on subsequent launches.
    func requestPermissionsAndSetupHotkey() async {
        // Request microphone permission silently. If already granted, this returns immediately.
        let transcriber = transcriber ?? CloudflareTranscriber()
        self.transcriber = transcriber
        _ = await transcriber.requestPermissions()
        setupHotkey()
    }

    func restartOnboarding() {
        UserDefaults.standard.set(false, forKey: AppPreferenceKey.hasCompletedOnboarding)
        onboardingWindowController?.window?.close()
        onboardingWindowController = nil
        showOnboarding()
    }

    @objc private func openSettings() {
        openSettingsWindow(initialTab: .general)
    }

    private func openSettingsWindow(initialTab: SettingsTab) {
        presentManagedWindow {
            if let window = self.settingsWindowController?.window {
                if let hostingController = window.contentViewController as? NSHostingController<AnyView> {
                    hostingController.rootView = self.makeSettingsContent(initialTab: initialTab)
                }
                self.settingsWindowController?.showWindow(nil)
                self.bringWindowToFront(window)
                return
            }

            let contentView = self.makeSettingsContent(initialTab: initialTab)
            let hostingController = NSHostingController(rootView: contentView)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 760, height: 640)
            window.maxSize = NSSize(width: 760, height: 640)
            window.center()
            window.title = "Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.delegate = self

            let controller = NSWindowController(window: window)
            self.settingsWindowController = controller
            controller.showWindow(nil)
            self.bringWindowToFront(window)
        }
    }

    private func makeSettingsContent(initialTab: SettingsTab) -> AnyView {
        AnyView(ContentView(
            historyManager: historyManager,
            customWordsManager: customWordsManager,
            restartOnboarding: restartOnboarding,
            initialTab: initialTab
        )
        .frame(width: 760, height: 640))
    }

    private func presentManagedWindow(_ action: @escaping () -> Void) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            action()
        }
    }

    private func bringWindowToFront(_ window: NSWindow) {
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if settingsWindowController?.window === window {
            settingsWindowController = nil
        }
        if onboardingWindowController?.window === window {
            onboardingWindowController = nil
        }

        // If no managed windows remain visible, revert to accessory (no dock icon)
        let hasVisibleWindow = [settingsWindowController, onboardingWindowController]
            .compactMap { $0?.window }
            .contains { $0.isVisible }
        if !hasVisibleWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func setupHotkey() {
        hotkeyManager.mode = hotkeyMode
        hotkeyManager.shortcut = HotkeyShortcut.loadFromDefaults()
        hotkeyManager.onKeyDown = { [weak self] in
            self?.beginRecording()
        }
        hotkeyManager.onKeyUp = { [weak self] in
            self?.endRecording()
        }
        let started = hotkeyManager.start()
        if !started {
            print("[Kaze] Accessibility permission not granted yet; hotkey will not work until granted.")
        }

        // Observe changes to hotkey mode preference (Fix #6: early-exit avoids
        // unnecessary work when unrelated UserDefaults keys change)
        hotkeyModeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newMode = self.hotkeyMode
                if self.hotkeyManager.mode != newMode {
                    self.hotkeyManager.mode = newMode
                }

                let newShortcut = HotkeyShortcut.loadFromDefaults()
                if self.hotkeyManager.shortcut != newShortcut {
                    self.hotkeyManager.shortcut = newShortcut
                }

                self.updateStatusItemIndicator()
            }
        }

        NotificationCenter.default.publisher(for: .cloudflareConfigurationDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemIndicator() }
            .store(in: &cancellables)

    }

    private func beginRecording() {
        guard !isSessionActive else { return }
        overlayState.processingStatusText = ""

        // Cloudflare-hosted Whisper is the only engine in this fork. Validate credentials
        // before activating the session so a configuration error cannot wedge the hotkey.
        let source = currentSourceApplication()

        guard TranscriptionEngine.whisper.isConfigured else {
            showTranscriptionError(
                "Add a valid Cloudflare Account ID and API token before recording.",
                openSettings: true
            )
            return
        }

        let words = customWordsManager.words
        let micUID = selectedMicrophoneUID
        let transcriber = transcriber ?? CloudflareTranscriber()
        self.transcriber = transcriber
        transcriber.customWords = words
        transcriber.selectedDeviceUID = micUID
        transcriber.onTranscriptionFinished = { [weak self] text in
            self?.processTranscription(text)
        }
        transcriber.onTranscriptionFailed = { [weak self] message in
            self?.handleTranscriptionFailure(message)
        }

        activeSession = RecordingSession(
            transcriber: transcriber,
            source: source,
            startedAt: Date()
        )
        isSessionActive = true
        updateStatusItemIndicator()
        overlayState.bind(to: transcriber)
        overlayWindow.show(state: overlayState, notchMode: notchModeEnabled)
        transcriber.startRecording()
    }

    private func endRecording() {
        guard isSessionActive, let session = activeSession else { return }
        activeSession?.endedAt = Date()

        session.transcriber.stopRecording()
        overlayState.isEnhancing = true
        overlayState.processingStatusText = "Transcribing"
    }

    private func processTranscription(_ rawText: String) {
        // Use the session that was active when recording started, not current prefs.
        let session = activeSession

        // Clear the processing state from the cloud transcription request.
        overlayState.processingStatusText = ""
        overlayState.isEnhancing = false

        // Optionally strip filler words (uh, um, er, hmm, etc.) before any further processing.
        let cleanedText: String
        if UserDefaults.standard.bool(forKey: AppPreferenceKey.removeFillerWords) {
            cleanedText = FillerWordCleaner.clean(rawText)
        } else {
            cleanedText = rawText
        }

        guard !cleanedText.isEmpty else {
            overlayWindow.hide(state: overlayState)
            isSessionActive = false
            activeSession = nil
            updateStatusItemIndicator()
            return
        }

        let speechDuration = session?.speechDuration ?? 0
        let source = session?.source
        typeText(cleanedText)
        historyManager.addRecord(
            TranscriptionRecord(
                text: cleanedText,
                engine: .whisper,
                wasEnhanced: false,
                speechDuration: speechDuration,
                source: source
            )
        )
        overlayWindow.hide(state: overlayState)
        isSessionActive = false
        activeSession = nil
        updateStatusItemIndicator()
    }

    private func handleTranscriptionFailure(_ message: String) {
        overlayState.processingStatusText = ""
        overlayState.isEnhancing = false
        overlayWindow.hide(state: overlayState)
        isSessionActive = false
        activeSession = nil
        updateStatusItemIndicator()
        showTranscriptionError(message, openSettings: false)
    }

    private func showTranscriptionError(_ message: String, openSettings: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Whisper Transcription Failed"
            alert.informativeText = message
            alert.addButton(withTitle: openSettings ? "Open Settings" : "OK")
            alert.runModal()

            if openSettings {
                self.openSettingsWindow(initialTab: .general)
            }
        }
    }

    private func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        var output = text
        if UserDefaults.standard.bool(forKey: AppPreferenceKey.appendTrailingSpace) {
            output += " "
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)

        let vKeyCode: CGKeyCode = 0x09
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        cmdUp?.flags = .maskCommand

        cmdDown?.post(tap: .cgAnnotatedSessionEventTap)
        cmdUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func currentSourceApplication() -> TranscriptionSource? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (name?.isEmpty == false ? name : nil) ?? "Unknown App"
        return TranscriptionSource(
            bundleIdentifier: application.bundleIdentifier,
            name: resolvedName
        )
    }

    @objc private func quit() {
        hotkeyManager.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
        cancellables.removeAll()
        if let hotkeyModeObserver {
            NotificationCenter.default.removeObserver(hotkeyModeObserver)
            self.hotkeyModeObserver = nil
        }
    }

    /// Retries setting up the hotkey after the user grants Accessibility permission.
    /// Called from the onboarding flow when accessibility is detected as granted.
    func retryHotkeySetup() {
        hotkeyManager.stop()
        _ = hotkeyManager.start()
    }
}
