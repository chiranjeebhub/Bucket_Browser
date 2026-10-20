import Foundation
import S3Kit
import Security

/// Stores each account's access key pair, and the list of accounts itself, as generic passwords.
///
/// When the app is signed with a developer team and a provisioning profile, items go in the
/// data protection keychain and sync through iCloud Keychain, so accounts come back after a
/// reinstall and appear on the user's other Macs. Unsigned builds (`swift run`, ad-hoc signed
/// apps) lack the entitlement for that, so they fall back to the local login keychain.
enum KeychainStore {
    static let service = "com.bucketbrowser.credentials"
    static let accountListService = "com.bucketbrowser.accounts"
    private static let accountListKey = "accounts.v1"

    enum KeychainError: LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .status(status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
                return "Keychain error: \(message) (\(status))"
            }
        }
    }

    /// Whether this build can use iCloud Keychain. Checked once, by probing the data protection
    /// keychain, which answers `errSecMissingEntitlement` when the app isn't entitled to it.
    static let isSyncAvailable: Bool = {
        var query = syncedQuery(service: accountListService, account: "probe")
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status != errSecMissingEntitlement
    }()

    // MARK: Credentials

    static func save(_ credentials: S3Credentials, for accountID: UUID) throws {
        try write(JSONEncoder().encode(credentials), service: service, account: accountID.uuidString, label: "Bucket Browser credentials")
    }

    static func load(for accountID: UUID) throws -> S3Credentials? {
        guard let data = try read(service: service, account: accountID.uuidString) else { return nil }
        return try JSONDecoder().decode(S3Credentials.self, from: data)
    }

    static func delete(for accountID: UUID) {
        remove(service: service, account: accountID.uuidString)
    }

    // MARK: Account list

    /// The synced account list, or nil if sync is unavailable or nothing has been saved yet.
    static func loadAccountList() -> [Account]? {
        guard isSyncAvailable,
              let data = try? read(service: accountListService, account: accountListKey) else { return nil }
        return try? JSONDecoder().decode([Account].self, from: data)
    }

    static func saveAccountList(_ accounts: [Account]) {
        guard isSyncAvailable, let data = try? JSONEncoder().encode(accounts) else { return }
        try? write(data, service: accountListService, account: accountListKey, label: "Bucket Browser accounts")
    }

    // MARK: Primitives

    private static func write(_ data: Data, service: String, account: String, label: String) throws {
        let query = isSyncAvailable ? syncedQuery(service: service, account: account) : localQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: label,
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { $1 }
            // Synced items can't be device-only, and "after first unlock" lets them sync in the background.
            item[kSecAttrAccessible as String] = isSyncAvailable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        if isSyncAvailable {
            // Drop any copy left in the login keychain by an earlier, unsigned build.
            SecItemDelete(localQuery(service: service, account: account) as CFDictionary)
        }
    }

    private static func read(service: String, account: String) throws -> Data? {
        if isSyncAvailable {
            if let data = try copyData(syncedQuery(service: service, account: account)) { return data }
            // Move items saved by an earlier, unsigned build into iCloud Keychain.
            if let legacy = try? copyData(localQuery(service: service, account: account)) {
                try? write(legacy, service: service, account: account, label: "Bucket Browser credentials")
                return legacy
            }
            return nil
        }
        return try copyData(localQuery(service: service, account: account))
    }

    private static func copyData(_ base: [String: Any]) throws -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        return data
    }

    private static func remove(service: String, account: String) {
        if isSyncAvailable { SecItemDelete(syncedQuery(service: service, account: account) as CFDictionary) }
        SecItemDelete(localQuery(service: service, account: account) as CFDictionary)
    }

    private static func localQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func syncedQuery(service: String, account: String) -> [String: Any] {
        var query = localQuery(service: service, account: account)
        query[kSecUseDataProtectionKeychain as String] = true
        query[kSecAttrSynchronizable as String] = true
        return query
    }
}
