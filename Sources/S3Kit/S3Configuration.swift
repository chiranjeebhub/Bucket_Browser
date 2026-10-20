import Foundation

/// The kind of S3-compatible service an account talks to.
public enum S3Provider: String, Codable, CaseIterable, Sendable, Identifiable {
    case aws
    case r2
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .aws: return "Amazon S3"
        case .r2: return "Cloudflare R2"
        case .custom: return "S3-Compatible"
        }
    }
}

/// Access keys for an S3-compatible service.
public struct S3Credentials: Codable, Hashable, Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

/// Where requests go and how they are addressed.
public struct S3Configuration: Hashable, Sendable {
    public var provider: S3Provider
    /// Signing region. For AWS this is the default region used for account-level
    /// calls; each bucket's own region is discovered automatically. R2 uses "auto".
    public var region: String
    /// Service endpoint. Required for R2 and custom providers, ignored for AWS.
    public var endpoint: URL?
    /// Use `https://endpoint/bucket/key` instead of `https://bucket.endpoint/key`.
    public var usePathStyle: Bool

    public init(provider: S3Provider, region: String, endpoint: URL? = nil, usePathStyle: Bool = true) {
        self.provider = provider
        self.region = region
        self.endpoint = endpoint
        self.usePathStyle = usePathStyle
    }

    public static func aws(region: String) -> S3Configuration {
        S3Configuration(provider: .aws, region: region.isEmpty ? "us-east-1" : region, usePathStyle: false)
    }

    public static func r2(accountID: String, jurisdiction: R2Jurisdiction = .default) -> S3Configuration {
        S3Configuration(provider: .r2, region: "auto", endpoint: jurisdiction.endpoint(accountID: accountID), usePathStyle: true)
    }
}

/// Cloudflare R2 data-location jurisdictions, each with its own endpoint.
public enum R2Jurisdiction: String, Codable, CaseIterable, Sendable, Identifiable {
    case `default`
    case eu
    case fedramp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .default: return "Default"
        case .eu: return "European Union"
        case .fedramp: return "FedRAMP"
        }
    }

    public func endpoint(accountID: String) -> URL? {
        let id = accountID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return nil }
        switch self {
        case .default: return URL(string: "https://\(id).r2.cloudflarestorage.com")
        case .eu: return URL(string: "https://\(id).eu.r2.cloudflarestorage.com")
        case .fedramp: return URL(string: "https://\(id).fedramp.r2.cloudflarestorage.com")
        }
    }
}
