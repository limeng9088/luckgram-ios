import Foundation
import Security

/// Minimal generic-password Keychain storage for the Luckgram device token.
enum LuckgramKeychain {
    static let service = "com.luckgram.messenger.luckgram"
    static let deviceTokenAccount = "device_token"

    private static func query(account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func get(account: String) -> String? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(account: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let q = query(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // This device only, never in backups or iCloud Keychain.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            for (k, v) in attributes {
                add[k] = v
            }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
