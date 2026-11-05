#if os(macOS)
import Foundation
import Security
import TagenCore

/// Generic-password Keychain storage for API keys and tokens.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    let service: String
    public init(service: String = "dev.tagen.Tagen") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    public func get(_ key: String) throws -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess, let d = out as? Data else { throw KeychainError(status: st) }
        return String(decoding: d, as: UTF8.self)
    }

    public func set(_ key: String, value: String) throws {
        let data = Data(value.utf8)
        let st = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecItemNotFound {
            var q = query(key)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let add = SecItemAdd(q as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError(status: add) }
        } else if st != errSecSuccess { throw KeychainError(status: st) }
    }

    public func delete(_ key: String) throws {
        let st = SecItemDelete(query(key) as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw KeychainError(status: st) }
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "")" }
}
#endif
