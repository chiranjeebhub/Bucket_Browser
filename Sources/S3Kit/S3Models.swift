import Foundation

public struct S3Bucket: Hashable, Sendable, Identifiable {
    public var name: String
    public var creationDate: Date?

    public var id: String { name }

    public init(name: String, creationDate: Date? = nil) {
        self.name = name
        self.creationDate = creationDate
    }
}

public struct S3Object: Hashable, Sendable {
    public var key: String
    public var size: Int64
    public var lastModified: Date?
    public var etag: String?
    public var storageClass: String?

    public init(key: String, size: Int64, lastModified: Date? = nil, etag: String? = nil, storageClass: String? = nil) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.etag = etag
        self.storageClass = storageClass
    }
}

/// One level of a bucket: the "folders" (common prefixes) and objects directly under a prefix.
public struct S3Listing: Sendable {
    public var prefixes: [String]
    public var objects: [S3Object]

    public init(prefixes: [String] = [], objects: [S3Object] = []) {
        self.prefixes = prefixes
        self.objects = objects
    }
}

/// One page of a ListObjectsV2 response.
public struct S3ListPage: Sendable {
    public var listing: S3Listing
    public var isTruncated: Bool
    public var nextContinuationToken: String?
}

public struct S3ObjectMetadata: Sendable {
    public var contentType: String?
    public var contentLength: Int64?
    public var lastModified: Date?
    public var etag: String?
    public var storageClass: String?
    /// `x-amz-meta-*` user metadata, keyed without the prefix.
    public var userMetadata: [String: String]
}

enum S3ResponseParser {
    static func buckets(from data: Data) throws -> [S3Bucket] {
        let root = try S3XMLNode.parse(data)
        let list = root.child("Buckets")?.children(named: "Bucket") ?? []
        return list.compactMap { node in
            guard let name = node.value("Name") else { return nil }
            return S3Bucket(name: name, creationDate: S3Dates.parseISO8601(node.value("CreationDate")))
        }
    }

    static func listPage(from data: Data) throws -> S3ListPage {
        let root = try S3XMLNode.parse(data)
        let objects = root.children(named: "Contents").compactMap { node -> S3Object? in
            guard let key = node.value("Key") else { return nil }
            return S3Object(
                key: key,
                size: Int64(node.value("Size") ?? "") ?? 0,
                lastModified: S3Dates.parseISO8601(node.value("LastModified")),
                etag: node.value("ETag").map(unquote),
                storageClass: node.value("StorageClass")
            )
        }
        let prefixes = root.children(named: "CommonPrefixes").compactMap { $0.value("Prefix") }
        let token = root.value("NextContinuationToken")
        return S3ListPage(
            listing: S3Listing(prefixes: prefixes, objects: objects),
            isTruncated: root.value("IsTruncated") == "true",
            nextContinuationToken: (token?.isEmpty ?? true) ? nil : token
        )
    }

    static func uploadID(from data: Data) throws -> String {
        let root = try S3XMLNode.parse(data)
        guard let id = root.value("UploadId"), !id.isEmpty else {
            throw S3Error.invalidResponse("CreateMultipartUpload returned no UploadId")
        }
        return id
    }

    /// Keys that failed in a DeleteObjects response, with their error messages.
    static func deleteErrors(from data: Data) throws -> [(key: String, message: String)] {
        guard !data.isEmpty else { return [] }
        let root = try S3XMLNode.parse(data)
        return root.children(named: "Error").map { node in
            (node.value("Key") ?? "", [node.value("Code"), node.value("Message")].compactMap { $0 }.joined(separator: ": "))
        }
    }

    /// Some S3 operations (CopyObject, CompleteMultipartUpload) can return HTTP 200 with an
    /// `<Error>` document. Throws if `data` is one.
    static func throwIfErrorDocument(_ data: Data, status: Int) throws {
        guard !data.isEmpty, let root = try? S3XMLNode.parse(data), root.name == "Error" else { return }
        throw S3Error.service(status: status, code: root.value("Code"), message: root.value("Message"), requestID: root.value("RequestId"))
    }

    static func unquote(_ string: String) -> String {
        string.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
