import Foundation
import S3Kit
import Security

/// Reads the accounts and keys the app saved in iCloud Keychain. The extension shares the app's
/// keychain access group, so it sees the same items without an app group.
///
/// The app's `Account` type lives in the app target; this mirrors just the fields needed to
/// connect, all optional so a newer app adding fields never breaks decoding here.
struct SharedAccount: Decodable {
    var id: UUID
    var name: String?
    var provider: S3Provider
    var region: String?
    var r2AccountID: String?
    var r2Jurisdiction: R2Jurisdiction?
    var customEndpoint: String?
    var usePathStyle: Bool?

    var configuration: S3Configuration {
        switch provider {
        case .aws:
            return .aws(region: region ?? "us-east-1")
        case .r2:
            return .r2(accountID: r2AccountID ?? "", jurisdiction: r2Jurisdiction ?? .default)
        case .custom:
            let endpoint = (customEndpoint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return S3Configuration(
                provider: .custom,
                region: (region ?? "").isEmpty ? "us-east-1" : region!,
                endpoint: URL(string: endpoint),
                usePathStyle: usePathStyle ?? true
            )
        }
    }
}

enum SharedAccounts {
    // Keep in step with KeychainStore in the app.
    private static let credentialsService = "com.bucketbrowser.credentials"
    private static let accountListService = "com.bucketbrowser.accounts"
    private static let accountListKey = "accounts.v1"

    static func client(accountID: UUID) throws -> S3Client {
        guard let data = read(service: accountListService, account: accountListKey),
              let accounts = try? JSONDecoder().decode([SharedAccount].self, from: data),
              let account = accounts.first(where: { $0.id == accountID }) else {
            throw S3Error.invalidConfiguration("This account was removed from Bucket Browser.")
        }
        guard let keyData = read(service: credentialsService, account: accountID.uuidString),
              let credentials = try? JSONDecoder().decode(S3Credentials.self, from: keyData) else {
            throw S3Error.invalidConfiguration("No access keys were found for “\(account.name ?? "this account")”.")
        }
        return S3Client(configuration: account.configuration, credentials: credentials)
    }

    private static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

/// A mounted bucket. The domain identifier is "<account UUID>/<bucket>"; bucket names can't
/// contain a slash, so the split is unambiguous. The app builds the same string.
struct MountedBucket {
    let accountID: UUID
    let bucket: String

    init?(domainIdentifier: String) {
        guard let slash = domainIdentifier.firstIndex(of: "/"),
              let id = UUID(uuidString: String(domainIdentifier[..<slash])) else { return nil }
        accountID = id
        bucket = String(domainIdentifier[domainIdentifier.index(after: slash)...])
        guard !bucket.isEmpty else { return nil }
    }
}
