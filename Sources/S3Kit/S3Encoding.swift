import Foundation

/// Percent-encoding rules used by AWS Signature Version 4.
public enum S3Encoding {
    /// RFC 3986 unreserved characters: the only ones SigV4 leaves unencoded.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Encodes every character except the unreserved set (so `/` becomes `%2F`).
    public static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    /// Encodes an object key for use in a URL path, keeping `/` separators.
    public static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0)) }
            .joined(separator: "/")
    }

    /// Builds a canonical (sorted, strictly encoded) query string.
    public static func canonicalQuery(_ items: [(String, String?)]) -> String {
        items
            .map { (encode($0.0), encode($0.1 ?? "")) }
            .sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }
}

/// Helpers for treating `/`-delimited keys as a folder hierarchy.
public enum S3Path {
    /// The last path component of a key or prefix, without a trailing slash.
    public static func name(of key: String) -> String {
        var trimmed = Substring(key)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        if let slash = trimmed.lastIndex(of: "/") {
            return String(trimmed[trimmed.index(after: slash)...])
        }
        return String(trimmed)
    }

    /// The prefix that contains `key`, ending in `/`, or `""` at the bucket root.
    public static func parent(of key: String) -> String {
        var trimmed = Substring(key)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[...slash])
    }

    /// Every ancestor prefix from the root down to and including `prefix`.
    /// `"a/b/"` gives `["", "a/", "a/b/"]`.
    public static func ancestors(of prefix: String) -> [String] {
        var result = [""]
        var current = ""
        for part in prefix.split(separator: "/") {
            current += part + "/"
            result.append(current)
        }
        return result
    }

    /// Makes sure a non-empty prefix ends with `/`.
    public static func normalizedPrefix(_ prefix: String) -> String {
        guard !prefix.isEmpty, !prefix.hasSuffix("/") else { return prefix }
        return prefix + "/"
    }
}
