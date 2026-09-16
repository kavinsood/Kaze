import Foundation
import Security

/// Manages secure storage of API keys in the macOS Keychain.
enum KeychainManager {

    private static let service = "com.kavin.KazeCloud"
    private static let cloudflareAPITokenAccount = "cloudflare-workers-ai-api-token"

    /// Saves the Cloudflare Workers AI API token to the Keychain.
    /// Overwrites any token previously saved by Kaze.
    @discardableResult
    static func saveCloudflareAPIToken(_ token: String) -> Bool {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { return false }
        let saved = saveSecret(normalizedToken, account: cloudflareAPITokenAccount)
        if saved {
            NotificationCenter.default.post(name: .cloudflareConfigurationDidChange, object: nil)
        }
        return saved
    }

    /// Retrieves the Cloudflare Workers AI API token from the Keychain.
    static func getCloudflareAPIToken() -> String? {
        getSecret(account: cloudflareAPITokenAccount)
    }

    /// Deletes the Cloudflare Workers AI API token from the Keychain.
    @discardableResult
    static func deleteCloudflareAPIToken() -> Bool {
        let deleted = deleteSecret(account: cloudflareAPITokenAccount)
        if deleted {
            NotificationCenter.default.post(name: .cloudflareConfigurationDidChange, object: nil)
        }
        return deleted
    }

    /// Checks whether a Cloudflare Workers AI API token is stored.
    static func hasCloudflareAPIToken() -> Bool {
        getCloudflareAPIToken() != nil
    }

    private static func saveSecret(_ secret: String, account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }

        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    private static func getSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func deleteSecret(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
