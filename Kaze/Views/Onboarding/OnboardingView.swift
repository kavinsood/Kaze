import SwiftUI
import AppKit
import Carbon
import AVFoundation

// MARK: - Onboarding View

#if false
struct OnboardingView: View {
    @State private var currentStep = 0
    @State private var hotkeyShortcut = HotkeyShortcut.default
    @AppStorage(AppPreferenceKey.transcriptionEngine) private var engineRaw = TranscriptionEngine.whisper.rawValue
    @AppStorage(AppPreferenceKey.hotkeyMode) private var hotkeyModeRaw = HotkeyMode.holdToTalk.rawValue
    @AppStorage(AppPreferenceKey.cloudflareAccountID) private var cloudflareAccountID = ""
    @AppStorage(AppPreferenceKey.transcriptionLanguage) private var transcriptionLanguage = "en"
    @State private var cloudflareAPITokenInput = ""
    @State private var cloudflareAPITokenSaved = false
    @State private var cloudflareAPITokenSaveFailed = false

    // Permission states
    @State private var microphoneGranted = false
    @State private var accessibilityGranted = false
    @State private var permissionPollTimer: Timer?
    @State private var activePermissionRequests = Set<PermissionKind>()

    // Model managers
    @ObservedObject var appleSpeechModelManager: AppleSpeechModelManager
    @ObservedObject var whisperModelManager: WhisperModelManager
    @ObservedObject var parakeetModelManager: FluidAudioModelManager
    @StateObject private var hotkeyRecorder = HotkeyShortcutRecorder()

    var onComplete: () -> Void

    private let totalSteps = 6

    private enum PermissionKind: Hashable {
        case microphone
        case accessibility
    }

    private var selectedEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: engineRaw) ?? .whisper
    }

    /// Whether the engine step requires a model download and the model isn't already downloaded.
    private var needsModelDownload: Bool {
        selectedEngine.requiresModelDownload && !isModelReady
    }

    /// Whether the selected model is currently downloading.
    private var isModelDownloading: Bool {
        selectedEngine.isModelDownloading(
            appleManager: appleSpeechModelManager,
            whisperManager: whisperModelManager,
            parakeetManager: parakeetModelManager
        )
    }

    /// Whether the selected model has been downloaded (or doesn't need one).
    private var isModelReady: Bool {
        selectedEngine.isModelReady(
            appleManager: appleSpeechModelManager,
            whisperManager: whisperModelManager,
            parakeetManager: parakeetModelManager
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content area
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: permissionsStep
                case 2: hotkeyStep
                case 3: engineStep
                case 4: modelDownloadStep
                case 5: doneStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: currentStep)

            Divider()

            // Navigation bar
            HStack {
                // Step indicators
                HStack(spacing: 6) {
                    ForEach(0..<totalSteps, id: \.self) { step in
                        Circle()
                            .fill(step == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }

                Spacer()

                if currentStep > 0 && currentStep < totalSteps - 1 {
                    Button("Back") {
                        hotkeyRecorder.stop()
                        currentStep -= 1
                    }
                    .controlSize(.regular)
                }

                if currentStep < totalSteps - 1 {
                    Button("Continue") {
                        hotkeyRecorder.stop()
                        if currentStep == 2 {
                            // Save hotkey before advancing
                            hotkeyShortcut.saveToDefaults()
                        }
                        currentStep += 1
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
                    .disabled(currentStep == 4 && (!isModelReady || isModelDownloading))
                } else {
                    Button("Get Started") {
                        hotkeyShortcut.saveToDefaults()
                        UserDefaults.standard.set(true, forKey: AppPreferenceKey.hasCompletedOnboarding)
                        onComplete()
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 540)
        .onAppear {
            cloudflareAPITokenSaved = KeychainManager.hasCloudflareAPIToken()
            hotkeyRecorder.onShortcutRecorded = { shortcut in
                hotkeyShortcut = shortcut
            }
        }
        .onDisappear {
            hotkeyRecorder.stop()
            stopPermissionPolling()
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()

            if let icon = NSImage(named: "kaze-icon") {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
            } else {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)
            }

            Text("Welcome to Kaze")
                .font(.title.bold())

            Text("Speech-to-text that runs entirely on your Mac.\nNo cloud, no subscription, no data leaves your device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Permissions")
                .font(.title2.bold())

            Text("Kaze needs a few permissions to work.\nGrant them below, then continue.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 12) {
                // Microphone Permission
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Required to capture your voice for transcription.",
                    isGranted: microphoneGranted,
                    isRequesting: activePermissionRequests.contains(.microphone),
                    action: requestMicrophonePermission
                )

                // Accessibility Permission
                permissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Required to detect your global hotkey.",
                    isGranted: accessibilityGranted,
                    isRequesting: activePermissionRequests.contains(.accessibility),
                    action: requestAccessibilityPermission
                )
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .onAppear {
            checkPermissionStates()
            startPermissionPolling()
        }
        .onDisappear {
            stopPermissionPolling()
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        isGranted: Bool,
        isRequesting: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .frame(width: 32, height: 32)
                .foregroundStyle(isGranted ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button(isRequesting ? "Opening…" : "Grant") {
                    action()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(isRequesting)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isGranted ? Color.green.opacity(0.06) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isGranted ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func checkPermissionStates() {
        // Check microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
            activePermissionRequests.remove(.microphone)
        default:
            microphoneGranted = false
        }

        // Check accessibility (silent check, no prompt)
        accessibilityGranted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        )
        if accessibilityGranted {
            activePermissionRequests.remove(.accessibility)
        }
    }

    private func requestMicrophonePermission() {
        activePermissionRequests.insert(.microphone)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
            activePermissionRequests.remove(.microphone)
        case .notDetermined:
            DispatchQueue.main.async {
                Task {
                    let granted = await AVCaptureDevice.requestAccess(for: .audio)
                    await MainActor.run {
                        microphoneGranted = granted
                        if !granted {
                            openPrivacySettingsPane(anchor: "Privacy_Microphone")
                        }
                        activePermissionRequests.remove(.microphone)
                    }
                }
            }
        case .denied, .restricted:
            openPrivacySettingsPane(anchor: "Privacy_Microphone")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                activePermissionRequests.remove(.microphone)
            }
        @unknown default:
            openPrivacySettingsPane(anchor: "Privacy_Microphone")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                activePermissionRequests.remove(.microphone)
            }
        }
    }

    private func requestAccessibilityPermission() {
        activePermissionRequests.insert(.accessibility)
        DispatchQueue.main.async {
            // Opening System Settings during the button's click event can leave AppKit
            // rendering the button as permanently pressed. Defer the prompt until the
            // next run loop so the click fully completes before focus changes.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            accessibilityGranted = trusted

            if trusted {
                activePermissionRequests.remove(.accessibility)
                return
            }

            openPrivacySettingsPane(anchor: "Privacy_Accessibility")

            // The permission is granted manually in System Settings, so only keep the
            // "Opening…" state long enough to reflect the handoff without trapping the button.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                activePermissionRequests.remove(.accessibility)
            }
        }
    }

    private func openPrivacySettingsPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func startPermissionPolling() {
        stopPermissionPolling()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                checkPermissionStates()
            }
        }
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    // MARK: - Step 3: Hotkey Setup

    private var hotkeyStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "keyboard")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Set Your Hotkey")
                .font(.title2.bold())

            Text("Choose how you want to trigger Kaze.")
                .font(.body)
                .foregroundStyle(.secondary)

            // Mode picker
            VStack(alignment: .leading, spacing: 8) {
                Picker("Mode", selection: $hotkeyModeRaw) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 200)

                let selectedMode = HotkeyMode(rawValue: hotkeyModeRaw) ?? .holdToTalk
                Text(selectedMode.description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 4)

            // Hotkey display + record
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(hotkeyShortcut.displayTokens, id: \.self) { token in
                        OnboardingKeyCapView(token)
                    }
                }

                Button(hotkeyRecorder.isRecording ? "Press keys..." : "Change") {
                    if hotkeyRecorder.isRecording {
                        hotkeyRecorder.stop()
                    } else {
                        hotkeyRecorder.start()
                    }
                }
                .controlSize(.small)

                Button("Reset") {
                    hotkeyShortcut = .default
                    hotkeyRecorder.stop()
                }
                .controlSize(.small)
            }

            if hotkeyRecorder.isRecording {
                Text("Press a key combination with at least one modifier. Press Esc to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
    }

    // MARK: - Step 4: Engine Selection

    private var engineStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "brain.head.profile")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Choose an Engine")
                .font(.title2.bold())

            Text("This build uses Cloudflare-hosted Whisper Large V3 Turbo.\nNo speech model runs on your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 4) {
                // This fork intentionally offers Cloudflare-hosted Whisper only.
                ForEach(TranscriptionEngine.onboardingOrder, id: \.self) { engine in
                    Button {
                        engineRaw = engine.rawValue
                    } label: {
                        HStack(spacing: 10) {
                            engineIconView(engine)
                                .frame(width: 20)
                                .foregroundStyle(engineRaw == engine.rawValue ? .white : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(engine.title)
                                        .font(.system(size: 13, weight: .medium))
                                    if engine == .parakeet {
                                        Text("Recommended")
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(
                                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                    .fill(engineRaw == engine.rawValue ? Color.white.opacity(0.2) : Color.accentColor.opacity(0.12))
                                            )
                                            .foregroundStyle(engineRaw == engine.rawValue ? .white : .accentColor)
                                    }
                                }
                                Text(engine.onboardingDescription)
                                    .font(.caption2)
                                    .lineLimit(2)
                                    .opacity(0.8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if engineRaw == engine.rawValue {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(engineRaw == engine.rawValue ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(engineRaw == engine.rawValue ? .white : .primary)
                }
            }
            .padding(.horizontal, 60)

            Spacer()
        }
    }

    // MARK: - Step 5: Model Download

    private var modelDownloadStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "cloud.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Connect Cloudflare")
                .font(.title2.bold())

            Text("Enter credentials for Cloudflare Workers AI.\nYour API token is stored in macOS Keychain.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Model download status
            VStack(spacing: 12) {
                modelDownloadStatusView
            }
            .padding(.horizontal, 60)

            Spacer()
        }
    }

    @ViewBuilder
    private var modelDownloadStatusView: some View {
        switch selectedEngine {
        case .dictation:
            onboardingAppleSpeechStatus
        case .whisper:
            onboardingCloudflareStatus
        case .parakeet:
            onboardingFluidAudioStatus(manager: parakeetModelManager, model: .parakeet)
        }
    }

    private var onboardingCloudflareStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Cloudflare Account ID", text: $cloudflareAccountID)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))

            HStack(spacing: 8) {
                SecureField(
                    cloudflareAPITokenSaved ? "Token saved in Keychain" : "Cloudflare API token",
                    text: $cloudflareAPITokenInput
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onChange(of: cloudflareAPITokenInput) {
                    cloudflareAPITokenSaveFailed = false
                }

                Button("Save") {
                    let token = cloudflareAPITokenInput
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else { return }
                    if KeychainManager.saveCloudflareAPIToken(token) {
                        cloudflareAPITokenInput = ""
                        cloudflareAPITokenSaved = true
                        cloudflareAPITokenSaveFailed = false
                    } else {
                        cloudflareAPITokenSaveFailed = true
                    }
                }
                .disabled(cloudflareAPITokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextField("Language hint (for example, en)", text: $transcriptionLanguage)
                .textFieldStyle(.roundedBorder)

            if cloudflareAPITokenSaveFailed {
                Label("The API token could not be saved to Keychain.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if isModelReady {
                Label("Cloudflare is configured", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Use a 32-character Account ID and an API token with Workers AI Read permission.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var onboardingAppleSpeechStatus: some View {
        switch appleSpeechModelManager.state {
        case .checking:
            VStack(spacing: 8) {
                ProgressView()
                Text("Checking the system model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .notDownloaded:
            VStack(spacing: 10) {
                Text("Apple Speech system model")
                    .font(.system(size: 13, weight: .medium))
                Button("Download Model") {
                    Task { await appleSpeechModelManager.downloadModel() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        case .downloading(let progress):
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(maxWidth: 240)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel", role: .destructive) {
                    appleSpeechModelManager.cancelDownload()
                }
                .controlSize(.small)
            }
        case .ready:
            Label("System model ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.green)
        case .unsupported:
            Label("Apple Speech does not support this Mac or system language.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .error(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry") {
                    Task { await appleSpeechModelManager.downloadModel() }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var onboardingWhisperStatus: some View {
        switch whisperModelManager.state {
        case .notDownloaded:
            VStack(spacing: 10) {
                Text("Whisper \(whisperModelManager.selectedVariant.title) (\(whisperModelManager.selectedVariant.sizeDescription))")
                    .font(.system(size: 13, weight: .medium))
                Button("Download Model") {
                    Task { await whisperModelManager.downloadModel() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

        case .downloading(let progress):
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(maxWidth: 240)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel", role: .destructive) {
                    whisperModelManager.cancelDownload()
                }
                .controlSize(.small)
            }

        case .downloaded, .ready:
            Label("Model downloaded", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.green)

        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text("Warming up model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .error(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry") {
                    whisperModelManager.deleteModel()
                    Task { await whisperModelManager.downloadModel() }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func onboardingFluidAudioStatus(manager: FluidAudioModelManager, model: FluidAudioModel) -> some View {
        switch manager.state {
        case .notDownloaded:
            VStack(spacing: 10) {
                Text("\(model.title) (\(model.sizeDescription))")
                    .font(.system(size: 13, weight: .medium))
                Button("Download Model") {
                    Task { await manager.downloadModel() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

        case .downloading(let progress):
            VStack(spacing: 8) {
                ProgressView(value: max(progress, 0))
                    .frame(maxWidth: 240)
                Text("Downloading \(model.title)... \(Int(max(progress, 0) * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel", role: .destructive) {
                    manager.cancelDownload()
                }
                .controlSize(.small)
            }

        case .downloaded, .ready:
            Label("Model downloaded", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.green)

        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text("Warming up model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .error(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry") {
                    manager.deleteModel()
                    Task { await manager.downloadModel() }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Step 6: Done

    private var doneStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.title2.bold())

            let shortcutDisplay = hotkeyShortcut.displayString
            let modeDisplay = (HotkeyMode(rawValue: hotkeyModeRaw) ?? .holdToTalk).title.lowercased()

            Text("Press **\(shortcutDisplay)** (\(modeDisplay)) to start dictating.\nKaze lives in your menu bar.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func engineIconView(_ engine: TranscriptionEngine) -> some View {
        switch engine {
        case .dictation:
            Text("\u{F8FF}")
                .font(.system(size: 16))
        case .whisper:
            Image("openai-icon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        case .parakeet:
            Image("nvidia-icon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        }
    }

}

// MARK: - Onboarding Key Cap View

private struct OnboardingKeyCapView: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .font(.system(size: 14, weight: .medium))
            .frame(minWidth: 26, minHeight: 24)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }
}
#endif

struct OnboardingView: View {
    @State private var step = 0
    @State private var microphoneGranted = false
    @State private var accessibilityGranted = false
    @State private var shortcut = HotkeyShortcut.default
    @State private var tokenInput = ""
    @State private var tokenSaved = false
    @State private var tokenSaveFailed = false
    @AppStorage(AppPreferenceKey.cloudflareAccountID) private var accountID = ""
    @AppStorage(AppPreferenceKey.transcriptionLanguage) private var language = "en"
    @StateObject private var hotkeyRecorder = HotkeyShortcutRecorder()

    let onComplete: () -> Void

    private let stepCount = 5

    private var cloudflareConfigured: Bool {
        accountID.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil
            && tokenSaved
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: hotkey
                case 3: cloudflare
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<stepCount, id: \.self) { index in
                        Circle()
                            .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                if step > 0 && step < stepCount - 1 {
                    Button("Back") { step -= 1 }
                }
                if step < stepCount - 1 {
                    Button("Continue") {
                        if step == 2 { shortcut.saveToDefaults() }
                        step += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(step == 1 && (!microphoneGranted || !accessibilityGranted)
                        || step == 3 && !cloudflareConfigured)
                } else {
                    Button("Start Dictating") {
                        UserDefaults.standard.set(true, forKey: AppPreferenceKey.hasCompletedOnboarding)
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .onAppear {
            tokenSaved = KeychainManager.hasCloudflareAPIToken()
            refreshPermissions()
            shortcut = HotkeyShortcut.loadFromDefaults()
            hotkeyRecorder.onShortcutRecorded = { newShortcut in
                shortcut = newShortcut
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onDisappear { hotkeyRecorder.stop() }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text("Welcome to Kaze")
                .font(.largeTitle.bold())
            Text("Fast macOS dictation using Cloudflare-hosted Whisper Large V3 Turbo.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
        }
        .padding(32)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Permissions")
                .font(.title.bold())
            Text("Kaze needs the microphone to hear you and Accessibility access to paste the transcript into the active app.")
                .foregroundStyle(.secondary)

            permissionRow(
                title: "Microphone",
                granted: microphoneGranted,
                actionTitle: "Allow"
            ) {
                Task {
                    microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
                }
            }

            permissionRow(
                title: "Accessibility",
                granted: accessibilityGranted,
                actionTitle: "Open Settings"
            ) {
                requestAccessibilityAccess()
            }

            Button("Refresh") { refreshPermissions() }

            Text("Enable Kaze Cloud in Privacy & Security → Accessibility, then return here. Move the app to Applications first so the permission remains tied to a stable location.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 380)
        .padding(32)
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .primary)
            Spacer()
            if !granted { Button(actionTitle, action: action) }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var hotkey: some View {
        VStack(spacing: 20) {
            Text("Choose a Shortcut")
                .font(.title.bold())
            Text("Hold the shortcut while speaking, then release it to transcribe and paste.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(shortcut.displayTokens.joined(separator: " "))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            Button(hotkeyRecorder.isRecording ? "Press your shortcut…" : "Record Shortcut") {
                if hotkeyRecorder.isRecording { hotkeyRecorder.stop() }
                else { hotkeyRecorder.start() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    private var cloudflare: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Cloudflare")
                .font(.title.bold())
            Text("Enter your Cloudflare Account ID and a token made with Cloudflare's Workers AI API Token template. The token is stored in Keychain.")
                .foregroundStyle(.secondary)

            TextField("32-character Account ID", text: $accountID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            SecureField(tokenSaved ? "Token saved in Keychain" : "API token", text: $tokenInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack {
                Button("Save Token") { saveToken() }
                    .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if tokenSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            TextField("Language hint (optional, e.g. en)", text: $language)
                .textFieldStyle(.roundedBorder)
            if tokenSaveFailed {
                Label("The token could not be saved to Keychain.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: 400)
        .padding(32)
    }

    private var done: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 68))
                .foregroundStyle(.green)
            Text("Ready to Dictate")
                .font(.title.bold())
            Text("Kaze records only while your shortcut is active, sends the audio to Whisper Large V3 Turbo on Cloudflare Workers AI, and pastes the returned text.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
        }
        .padding(32)
    }

    private func refreshPermissions() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
    }

    private func requestAccessibilityAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        guard !accessibilityGranted,
              let settingsURL = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
              ) else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    private func saveToken() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenSaved = KeychainManager.saveCloudflareAPIToken(token)
        tokenSaveFailed = !tokenSaved
        if tokenSaved { tokenInput = "" }
    }
}
