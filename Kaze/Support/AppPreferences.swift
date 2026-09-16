import Foundation

enum AppPreferenceKey {
    static let transcriptionEngine = "transcriptionEngine"
    static let enhancementMode = "enhancementMode"
    static let smartFormattingEnabled = "smartFormattingEnabled"
    static let hotkeyMode = "hotkeyMode"
    static let hotkeyShortcut = "hotkeyShortcut"
    static let notchMode = "notchMode"
    static let selectedMicrophoneID = "selectedMicrophoneID"
    static let appendTrailingSpace = "appendTrailingSpace"
    static let removeFillerWords = "removeFillerWords"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let cloudflareAccountID = "cloudflareAccountID"
    static let transcriptionLanguage = "transcriptionLanguage"
}

extension Notification.Name {
    static let cloudflareConfigurationDidChange = Notification.Name(
        "cloudflareConfigurationDidChange"
    )
}
