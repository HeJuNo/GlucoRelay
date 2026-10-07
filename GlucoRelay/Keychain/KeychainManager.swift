import Foundation
import Security

/// Generic-password Keychain wrapper. Same scheme as nightscout-remote's `KeychainHelper`
/// (one service, account = key), with GlucoRelay's own service name.
enum KeychainManager {
    private static let service = "glucorelay.app"

    /// Account names – identical to nightscout-remote ("nightscout_url" / "access_token").
    static let nightscoutURLKey = "nightscout_url"
    static let accessTokenKey = "access_token"

    static var nightscoutURL: String? {
        get { read(key: nightscoutURLKey) }
        set { write(key: nightscoutURLKey, value: newValue) }
    }

    static var accessToken: String? {
        get { read(key: accessTokenKey) }
        set { write(key: accessTokenKey, value: newValue) }
    }

    private static func write(key: String, value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { save(key: key, value: trimmed) } else { delete(key: key) }
    }

    static func save(key: String, value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(base as CFDictionary)
        guard let data = value.data(using: .utf8) else { return }
        var attrs = base
        attrs[kSecValueData as String] = data
        // Readable while the phone is locked after first unlock – required for background BLE uploads.
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
