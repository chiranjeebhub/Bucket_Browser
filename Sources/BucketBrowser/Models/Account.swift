import Foundation
import S3Kit

/// A saved connection. Credentials are kept in the Keychain, never in this struct.
struct Account: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var provider: S3Provider
    /// AWS: default region. Custom: signing region.
    var region: String = "us-east-1"
    /// Cloudflare account ID (R2 only).
    var r2AccountID: String = ""
    var r2Jurisdiction: R2Jurisdiction = .default
    /// Endpoint URL (custom providers only), e.g. `http://localhost:9000`.
    var customEndpoint: String = ""
    var usePathStyle: Bool = true
    /// Buckets to show even if the credentials can't list buckets
    /// (common with bucket-scoped R2 API tokens).
    var pinnedBuckets: [String] = []

    var configuration: S3Configuration {
        switch provider {
        case .aws:
            return .aws(region: region)
        case .r2:
            return .r2(accountID: r2AccountID, jurisdiction: r2Jurisdiction)
        case .custom:
            return S3Configuration(
                provider: .custom,
                region: region.isEmpty ? "us-east-1" : region,
                endpoint: URL(string: customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
                usePathStyle: usePathStyle
            )
        }
    }

    var symbolName: String {
        switch provider {
        case .aws: return "cloud"
        case .r2: return "cloud.fill"
        case .custom: return "server.rack"
        }
    }

    /// Problems that would stop the account from working, for the editor to show.
    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name for this account." }
        switch provider {
        case .aws:
            if region.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a region." }
        case .r2:
            if r2AccountID.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter your Cloudflare account ID." }
        case .custom:
            guard let url = URL(string: customEndpoint), url.scheme != nil, url.host != nil else {
                return "Enter an endpoint URL such as https://s3.example.com."
            }
        }
        return nil
    }
}

extension Account {
    static let awsRegions = [
        "us-east-1", "us-east-2", "us-west-1", "us-west-2",
        "ca-central-1", "sa-east-1",
        "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1", "eu-central-2", "eu-north-1", "eu-south-1",
        "ap-south-1", "ap-southeast-1", "ap-southeast-2", "ap-northeast-1", "ap-northeast-2", "ap-northeast-3", "ap-east-1",
        "me-south-1", "af-south-1",
    ]
}
