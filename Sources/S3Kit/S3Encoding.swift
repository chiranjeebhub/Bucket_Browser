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
        let encoded: [(name: String, value: String)] = items.map { item in
            (name: encode(item.0), value: encode(item.1 ?? ""))
        }
        let sorted = encoded.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }
}

/// Helpers for treating `/`-delimited keys as a folder hierarchy.
public enum S3Path {
    /// The last path component of a key or prefix, without its trailing slash.
    /// Empty components are kept, so the folder `a//` is named `""`.
    public static func name(of key: String) -> String {
        let trimmed = key.hasSuffix("/") ? key.dropLast() : Substring(key)
        if let slash = trimmed.lastIndex(of: "/") {
            return String(trimmed[trimmed.index(after: slash)...])
        }
        return String(trimmed)
    }

    /// The prefix that contains `key`, ending in `/`, or `""` at the bucket root.
    public static func parent(of key: String) -> String {
        let trimmed = key.hasSuffix("/") ? key.dropLast() : Substring(key)
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[...slash])
    }

    /// Every ancestor prefix from the root down to and including `prefix`.
    /// `"a/b/"` gives `["", "a/", "a/b/"]`; empty components are kept, so `"a//"`
    /// gives `["", "a/", "a//"]`.
    public static func ancestors(of prefix: String) -> [String] {
        var result = [""]
        for index in prefix.indices where prefix[index] == "/" {
            result.append(String(prefix[...index]))
        }
        return result
    }

    /// Makes sure a non-empty prefix ends with `/`.
    public static func normalizedPrefix(_ prefix: String) -> String {
        guard !prefix.isEmpty, !prefix.hasSuffix("/") else { return prefix }
        return prefix + "/"
    }
}
