import Foundation
import Security

/// Secrets store backed by the iOS/macOS Keychain. Passwords and tokens NEVER touch
/// UserDefaults — they live here, encrypted at rest and only available after first unlock.
struct KeychainStore: Sendable {
    enum Account: String {
        case mqttPassword = "mqtt.password"
        case basicAuthPassword = "basicauth.password"
        case apiToken = "api.token"
        case pushSecret = "push.secret"
    }

    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.tesstats.app") {
        self.service = service
    }

    func set(_ value: String?, for account: Account) { setRaw(value, account: account.rawValue) }

    func get(_ account: Account) -> String? { getRaw(account: account.rawValue) }

    func has(_ account: Account) -> Bool { get(account) != nil }

    /// Per-profile / arbitrary-account variants used by multi-profile support.
    func setRaw(_ value: String?, account acct: String) {
        // Always delete first to keep writes idempotent.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Remove every secret this app stored (global accounts + all per-profile accounts).
    func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    func getRaw(account acct: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
