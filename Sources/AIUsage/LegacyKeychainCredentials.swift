import Foundation
import LocalAuthentication
import Security
import QuotaCore

protocol LegacyCredentialReading: Sendable {
    func read(_ id: ProviderID, interactive: Bool) async throws -> String
    func remove(_ id: ProviderID) throws
}

/// Reads credentials that earlier versions kept in the login Keychain, so that `CredentialVault` can move them to files.
struct LegacyKeychainCredentials: LegacyCredentialReading {
    private func query(_ id: ProviderID) -> [String: Any] {
        // Keep the original service name so existing Keychain grants and credentials remain available.
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.aiusage.menubar.coding-plan-key",
         kSecAttrAccount as String: id.rawValue,
         kSecAttrSynchronizable as String: false]
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
        case errSecSuccess:
            break
        default:
            throw VaultError.keychainMigration
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw VaultError.keychainMigration }
        return value
    }

    func remove(_ id: ProviderID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychainRemoval }
    }
}
