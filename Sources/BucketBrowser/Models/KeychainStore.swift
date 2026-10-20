import Foundation
import S3Kit
import Security

/// Stores each account's access key pair as a generic password in the user's Keychain.
enum KeychainStore {
    static let service = "com.bucketbrowser.credentials"

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

    static func save(_ credentials: S3Credentials, for accountID: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        let query = baseQuery(for: accountID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "Bucket Browser credentials",
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { $1 }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func load(for accountID: UUID) throws -> S3Credentials? {
        var query = baseQuery(for: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        return try JSONDecoder().decode(S3Credentials.self, from: data)
    }

    static func delete(for accountID: UUID) {
        SecItemDelete(baseQuery(for: accountID) as CFDictionary)
    }

    private static func baseQuery(for accountID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
    }
}
