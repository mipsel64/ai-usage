import Foundation
import LocalAuthentication
import Security
import QuotaCore

enum VaultError: LocalizedError {
    case inaccessible
    var errorDescription: String? { "Cannot access the login Keychain. Unlock it and try again." }
}

protocol CredentialVaulting: Sendable {
    func store(_ value: String, for id: ProviderID) throws
    func read(_ id: ProviderID, interactive: Bool) async throws -> String
    func remove(_ id: ProviderID) throws
}

struct CredentialVault: CredentialVaulting {
    init() {}

    private func query(_ id: ProviderID) -> [String: Any] {
        // Keep the original service name so existing Keychain grants and credentials remain available.
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.aiusage.menubar.coding-plan-key",
         kSecAttrAccount as String: id.rawValue,
         kSecAttrSynchronizable as String: false]
    }

    func store(_ value: String, for id: ProviderID) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let selector = query(id)
        let status = SecItemUpdate(selector as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = selector.merging(attributes) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw VaultError.inaccessible }
        } else if status != errSecSuccess {
            throw VaultError.inaccessible
        }
    }

    func read(_ id: ProviderID, interactive: Bool) async throws -> String {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = !interactive
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            throw QuotaError.notConfigured
        case errSecInteractionNotAllowed:
            throw VaultError.inaccessible
        case errSecSuccess:
            break
        default:
            throw VaultError.inaccessible
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw VaultError.inaccessible }
        return value
    }

    func remove(_ id: ProviderID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.inaccessible }
    }
}
