import CryptoKit
import Foundation

/// Signs requests with AWS Signature Version 4, as used by S3 and R2.
public struct SigV4Signer: Sendable {
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"

    public let credentials: S3Credentials
    public let region: String
    public let service: String

    /// Headers that intermediaries or URLSession may add or rewrite, so they are never signed.
    private static let unsignedHeaders: Set<String> = [
        "user-agent", "content-length", "accept", "accept-encoding", "accept-language",
        "connection", "expect", "authorization",
    ]

    public init(credentials: S3Credentials, region: String, service: String = "s3") {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    // MARK: - Header signing

    /// Adds `x-amz-date`, `x-amz-content-sha256` and `Authorization` headers to `request`.
    public func sign(_ request: inout URLRequest, payloadHash: String, date: Date = Date()) {
        guard let url = request.url else { return }
        let (amzDate, dateStamp) = Self.timestamps(for: date)

        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let token = credentials.sessionToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }

        var headers: [String: String] = ["host": Self.hostHeader(for: url)]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            guard !Self.unsignedHeaders.contains(lower), lower != "host" else { continue }
            headers[lower] = Self.normalizeHeaderValue(value)
        }
        let signedHeaderNames = headers.keys.sorted()
        let canonicalHeaders = signedHeaderNames.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = signedHeaderNames.joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            Self.canonicalURI(for: url),
            Self.canonicalQuery(for: url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let signature = self.signature(canonicalRequest: canonicalRequest, amzDate: amzDate, dateStamp: dateStamp, scope: scope)
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    // MARK: - Presigned URLs

    /// Returns a query-string-signed URL that anyone can use until it expires.
    /// `expires` is in seconds; S3 allows at most 7 days (604800).
    public func presign(url: URL, method: String = "GET", expires: Int, date: Date = Date()) -> URL {
        let (amzDate, dateStamp) = Self.timestamps(for: date)
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"

        var items = Self.decodedQueryItems(for: url)
        items.append(("X-Amz-Algorithm", "AWS4-HMAC-SHA256"))
        items.append(("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"))
        items.append(("X-Amz-Date", amzDate))
        items.append(("X-Amz-Expires", String(min(max(expires, 1), 604_800))))
        items.append(("X-Amz-SignedHeaders", "host"))
        if let token = credentials.sessionToken, !token.isEmpty {
            items.append(("X-Amz-Security-Token", token))
        }
        let query = S3Encoding.canonicalQuery(items)

        let canonicalRequest = [
            method,
            Self.canonicalURI(for: url),
            query,
            "host:\(Self.hostHeader(for: url))\n",
            "host",
            Self.unsignedPayload,
        ].joined(separator: "\n")

        let signature = self.signature(canonicalRequest: canonicalRequest, amzDate: amzDate, dateStamp: dateStamp, scope: scope)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query + "&X-Amz-Signature=" + signature
        return components.url!
    }

    // MARK: - Internals

    private func signature(canonicalRequest: String, amzDate: String, dateStamp: String, scope: String) -> String {
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [dateStamp, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        return Self.hex(Data(mac))
    }

    static func timestamps(for date: Date) -> (amzDate: String, dateStamp: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let dateStamp = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        let amzDate = dateStamp + String(format: "T%02d%02d%02dZ", c.hour!, c.minute!, c.second!)
        return (amzDate, dateStamp)
    }

    static func hostHeader(for url: URL) -> String {
        let host = url.host ?? ""
        if let port = url.port, !((url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)) {
            return "\(host):\(port)"
        }
        return host
    }

    /// The path exactly as it goes on the wire. Callers build paths with
    /// `S3Encoding.encodePath`, so this is already in canonical form.
    static func canonicalURI(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? ""
        return path.isEmpty ? "/" : path
    }

    static func decodedQueryItems(for url: URL) -> [(String, String?)] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return (components?.percentEncodedQueryItems ?? []).map {
            ($0.name.removingPercentEncoding ?? $0.name, $0.value?.removingPercentEncoding ?? $0.value)
        }
    }

    static func canonicalQuery(for url: URL) -> String {
        S3Encoding.canonicalQuery(decodedQueryItems(for: url))
    }

    static func normalizeHeaderValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    public static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
