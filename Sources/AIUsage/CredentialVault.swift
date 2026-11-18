import Foundation
import Security
import QuotaCore

enum VaultError: LocalizedError {
    case inaccessible
    var errorDescription: String? { "Cannot access the login Keychain. Unlock it and try again." }
}

enum CredentialVault {
    private static func query(_ id: ProviderID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.aiusage.menubar.coding-plan-key",
         kSecAttrAccount as String: id.rawValue,
         kSecAttrSynchronizable as String: false]
    }

    static func store(_ key: String, for id: ProviderID) throws {
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let selector = query(id)
        let status = SecItemUpdate(selector as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = selector.merging(attributes) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw VaultError.inaccessible }
        } else if status != errSecSuccess {
            throw VaultError.inaccessible
        }
    }

    static func read(_ id: ProviderID) async throws -> String {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { throw QuotaError.notConfigured }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw VaultError.inaccessible }
        return key
    }

    static func remove(_ id: ProviderID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.inaccessible }
    }
}
