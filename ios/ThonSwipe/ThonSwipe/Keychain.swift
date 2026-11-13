import Foundation
import Security

/// Tiny Keychain store for the pairing token (one string per key).
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "thon-swipe", kSecAttrAccount as String: key]
    }

    static func set(_ value: String, for key: String) {
        var q = query(key)
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func remove(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}
