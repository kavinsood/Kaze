import Foundation

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case whisper

    var id: String { rawValue }

    var isConfigured: Bool {
        let accountID = UserDefaults.standard.string(forKey: AppPreferenceKey.cloudflareAccountID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return accountID.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil
            && KeychainManager.hasCloudflareAPIToken()
    }
}

enum HotkeyMode: String, CaseIterable, Identifiable {
    case holdToTalk
    case toggle
    case hybrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holdToTalk: return "Hold to Talk"
        case .toggle: return "Press to Toggle"
        case .hybrid: return "Hybrid"
        }
    }

    var description: String {
        switch self {
        case .holdToTalk: return "Hold the hotkey to record, release to stop."
        case .toggle: return "Press the hotkey once to start, press again to stop."
        case .hybrid: return "Hold the hotkey to record, or double-press it to toggle recording on and off."
        }
    }
}
