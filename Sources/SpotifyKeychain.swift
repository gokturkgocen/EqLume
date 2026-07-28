// Excluded from the Mac App Store build: the Spotify OAuth / Web API pre-fetch path
// needs a loopback HTTP listener (network.server) and Keychain storage. The App Store
// build ships neither entitlement, and Spotify still works there via AppleScript
// (now-playing + transport) — only queue pre-fetch is unavailable.
#if !APP_STORE
import Foundation
import Security

/// Tiny keychain wrapper for storing Spotify OAuth tokens and the user-supplied Client ID.
/// All entries share the `com.gokturkgocen.Eqlume` service so they're easy to wipe via Keychain Access.
enum SpotifyKeychain {
    private static let service = "com.gokturkgocen.Eqlume"
    private static let legacyService = "com.gokturkgocen.SesEQ"

    enum Account: String {
        case clientID     = "spotify.client_id"
        case accessToken  = "spotify.access_token"
        case refreshToken = "spotify.refresh_token"
        case expiresAt    = "spotify.expires_at"      // ISO 8601 string
    }

    static func set(_ value: String?, for account: Account) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        // Delete first to keep the API idempotent and avoid duplicate items.
        SecItemDelete(query as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func get(_ account: Account) -> String? {
        if let value = read(account, service: service) { return value }
        // One-time, non-destructive migration from the development-name build.
        if let legacyValue = read(account, service: legacyService) {
            set(legacyValue, for: account)
            return legacyValue
        }
        return nil
    }

    private static func read(_ account: Account, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clearAll() {
        for a in [Account.clientID, .accessToken, .refreshToken, .expiresAt] {
            set(nil, for: a)
        }
    }
}
#endif
