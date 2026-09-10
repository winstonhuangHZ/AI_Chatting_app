import Foundation
import Security

/// Small generic-password wrapper used to keep API keys out of UserDefaults.
///
/// Each relay profile stores its key under `service = com.aichat.app` with an
/// account equal to the profile's UUID, so keys survive backups and are only
/// readable by processes that can access this Mac's login keychain.
enum KeychainService {

    static let service = "com.aichat.app"

    /// Single Keychain account that holds the JSON map of all API keys
    /// (profile UUID → key). One item means macOS asks for authorization once
    /// per app build instead of once per relay profile.
    static let apiKeysAccount = "api-keys-v1"

    /// Saves (or replaces) a secret for the given account.
    @discardableResult
    static func save(_ secret: String, account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        var query = baseQuery
        query[kSecValueData as String] = data
        let addStatus = SecItemAdd(query as CFDictionary, nil)

        if addStatus == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            return SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary) == errSecSuccess
        }
        return addStatus == errSecSuccess
    }

    /// Returns the stored secret for an account, or nil when absent/failed.
    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the stored secret for an account, if any.
    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Saves the whole profile-key map as one JSON payload.
    @discardableResult
    static func saveSecrets(_ secrets: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(secrets),
              let json = String(data: data, encoding: .utf8) else {
            return false
        }
        return save(json, account: apiKeysAccount)
    }

    /// Loads the profile-key map, or nil when absent/corrupt.
    static func loadSecrets() -> [String: String]? {
        guard let json = load(account: apiKeysAccount),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    /// Removes the shared API-key map.
    @discardableResult
    static func deleteSecrets() -> Bool {
        delete(account: apiKeysAccount)
    }
}
