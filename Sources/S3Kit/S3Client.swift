import CryptoKit
import Foundation

/// A small async client for the parts of the S3 API a file browser needs.
/// Works with Amazon S3, Cloudflare R2 and other S3-compatible services.
public final class S3Client: @unchecked Sendable {
    public let configuration: S3Configuration
    public let credentials: S3Credentials

    /// Files larger than this are uploaded in parts.
    public var multipartThreshold: Int64 = 32 * 1024 * 1024
    /// Multipart uploads in flight at once, per file.
    public var multipartConcurrency = 4

    private let session: URLSession
    private let transfers: TransferEngine
    private let lock = NSLock()
    private var bucketRegions: [String: String] = [:]

    public init(configuration: S3Configuration, credentials: S3Credentials, session: URLSession? = nil) {
        self.configuration = configuration
        self.credentials = credentials
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            return URLSession(configuration: config)
        }()
        self.transfers = .shared
    }

    // MARK: - Buckets

    public func listBuckets() async throws -> [S3Bucket] {
        let (data, _) = try await send("GET", bucket: nil, key: nil, region: configuration.region)
        return try S3ResponseParser.buckets(from: data).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The region a bucket lives in. Only meaningful for AWS; other providers use the configured region.
    public func region(forBucket bucket: String) async -> String {
        guard configuration.provider == .aws else { return configuration.region }
        if let cached = lock.withLock({ bucketRegions[bucket] }) { return cached }

        // HEAD Bucket answers with x-amz-bucket-region even on 301/403 responses.
        var region = configuration.region
        if var request = try? makeRequest("HEAD", bucket: bucket, key: nil, query: [], region: "us-east-1", forcePathStyle: true) {
            SigV4Signer(credentials: credentials, region: "us-east-1").sign(&request, payloadHash: SigV4Signer.emptyPayloadHash)
            if let result = try? await session.data(for: request),
               let http = result.1 as? HTTPURLResponse,
               let header = http.value(forHTTPHeaderField: "x-amz-bucket-region"), !header.isEmpty {
                region = header
            }
        }
        lock.withLock { bucketRegions[bucket] = region }
        return region
    }

    // MARK: - Listing

    /// Lists one "folder" level: sub-prefixes and the objects directly under `prefix`.
    public func listFolder(bucket: String, prefix: String) async throws -> S3Listing {
        try await listAll(bucket: bucket, prefix: prefix, delimiter: "/")
    }

    /// Lists every object under `prefix`, recursively.
    public func listObjectsRecursively(bucket: String, prefix: String) async throws -> [S3Object] {
        try await listAll(bucket: bucket, prefix: prefix, delimiter: nil).objects
    }

    public func listPage(bucket: String, prefix: String, delimiter: String?, continuationToken: String?, maxKeys: Int = 1000) async throws -> S3ListPage {
        var query: [(String, String?)] = [("list-type", "2"), ("max-keys", String(maxKeys))]
        if !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let continuationToken { query.append(("continuation-token", continuationToken)) }
        let (data, _) = try await send("GET", bucket: bucket, key: nil, query: query)
        return try S3ResponseParser.listPage(from: data)
    }

    private func listAll(bucket: String, prefix: String, delimiter: String?) async throws -> S3Listing {
        var listing = S3Listing()
        var token: String?
        repeat {
            try Task.checkCancellation()
            let page = try await listPage(bucket: bucket, prefix: prefix, delimiter: delimiter, continuationToken: token)
            listing.prefixes += page.listing.prefixes
            listing.objects += page.listing.objects
            token = page.isTruncated ? page.nextContinuationToken : nil
        } while token != nil
        return listing
    }

    // MARK: - Objects

    public func headObject(bucket: String, key: String) async throws -> S3ObjectMetadata {
        let (_, response) = try await send("HEAD", bucket: bucket, key: key)
        var userMetadata: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = (name as? String)?.lowercased(), name.hasPrefix("x-amz-meta-") else { continue }
            userMetadata[String(name.dropFirst("x-amz-meta-".count))] = value as? String
        }
        return S3ObjectMetadata(
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            contentLength: response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) },
            lastModified: S3Dates.parseHTTPDate(response.value(forHTTPHeaderField: "Last-Modified")),
            etag: response.value(forHTTPHeaderField: "ETag").map(S3ResponseParser.unquote),
            storageClass: response.value(forHTTPHeaderField: "x-amz-storage-class"),
            userMetadata: userMetadata
        )
    }

    /// Writes a small object from memory, e.g. the zero-byte marker for an empty folder.
    public func putObject(bucket: String, key: String, data: Data, contentType: String? = nil) async throws {
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        _ = try await send("PUT", bucket: bucket, key: key, headers: headers, body: data)
    }

    /// Creates an empty "folder" by writing a zero-byte object whose key ends in `/`.
    public func createFolder(bucket: String, prefix: String) async throws {
        try await putObject(bucket: bucket, key: S3Path.normalizedPrefix(prefix), data: Data(), contentType: "application/x-directory")
    }

    /// Uploads a local file, switching to a multipart upload for large files.
    public func uploadFile(_ fileURL: URL, bucket: String, key: String, contentType: String? = nil, progress: TransferProgress? = nil) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if size > multipartThreshold {
            try await multipartUpload(fileURL, size: size, bucket: bucket, key: key, contentType: contentType, progress: progress)
            return
        }
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        let request = try await signedRequest("PUT", bucket: bucket, key: key, headers: headers, payloadHash: SigV4Signer.unsignedPayload)
        let (data, response) = try await transfers.upload(request, fromFile: fileURL, progress: progress)
        try Self.validate(response, data: data)
    }

    /// Downloads an object to a local file.
    public func download(bucket: String, key: String, to destination: URL, progress: TransferProgress? = nil) async throws {
        let request = try await signedRequest("GET", bucket: bucket, key: key)
        _ = try await transfers.download(request, to: destination, progress: progress)
    }

    /// Server-side copy within or across buckets of the same account.
    public func copyObject(sourceBucket: String, sourceKey: String, bucket: String, key: String) async throws {
        let source = "/\(sourceBucket)/\(S3Encoding.encodePath(sourceKey))"
        let (data, response) = try await send("PUT", bucket: bucket, key: key, headers: ["x-amz-copy-source": source])
        try S3ResponseParser.throwIfErrorDocument(data, status: response.statusCode)
    }

    public func deleteObject(bucket: String, key: String) async throws {
        _ = try await send("DELETE", bucket: bucket, key: key)
    }

    /// Deletes many objects using DeleteObjects, 1000 keys per request.
    public func deleteObjects(bucket: String, keys: [String]) async throws {
        var failures: [String] = []
        for start in stride(from: 0, to: keys.count, by: 1000) {
            try Task.checkCancellation()
            let batch = keys[start..<min(start + 1000, keys.count)]
            let objects = batch.map { "<Object><Key>\(xmlEscape($0))</Key></Object>" }.joined()
            let body = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Delete><Quiet>true</Quiet>\(objects)</Delete>".utf8)
            let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
            let (data, _) = try await send(
                "POST", bucket: bucket, key: nil, query: [("delete", nil)],
                headers: ["Content-Type": "application/xml", "Content-MD5": md5],
                body: body
            )
            failures += try S3ResponseParser.deleteErrors(from: data).map { "\($0.key): \($0.message)" }
        }
        if !failures.isEmpty { throw S3Error.partialFailure(failures) }
    }

    /// A time-limited link to an object that works without credentials.
    public func presignedURL(bucket: String, key: String, expiresIn seconds: Int) async throws -> URL {
        let region = await self.region(forBucket: bucket)
        let url = try makeURL(bucket: bucket, key: key, query: [], region: region, forcePathStyle: false)
        return SigV4Signer(credentials: credentials, region: region).presign(url: url, expires: seconds)
    }

    // MARK: - Multipart upload

    private func multipartUpload(_ fileURL: URL, size: Int64, bucket: String, key: String, contentType: String?, progress: TransferProgress?) async throws {
        // Parts must be at least 5 MiB and there can be at most 10,000 of them.
        let minimumPart: Int64 = 16 * 1024 * 1024
        let partSize = max(minimumPart, (size + 9_999) / 10_000)
        let partCount = Int((size + partSize - 1) / partSize)

        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        let (initData, _) = try await send("POST", bucket: bucket, key: key, query: [("uploads", nil)], headers: headers)
        let uploadID = try S3ResponseParser.uploadID(from: initData)

        let tracker = PartProgress(total: size, report: progress)
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let reader = PartReader(handle: handle)

            var etags = [String](repeating: "", count: partCount)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                let concurrency = max(1, multipartConcurrency)
                var next = 0
                var inFlight = 0
                while next < partCount || inFlight > 0 {
                    while inFlight < concurrency, next < partCount {
                        let index = next
                        let offset = Int64(index) * partSize
                        let body = try await reader.read(offset: offset, length: Int(min(partSize, size - offset)))
                        group.addTask {
                            let etag = try await self.uploadPart(bucket: bucket, key: key, uploadID: uploadID, number: index + 1, body: body) { sent in
                                tracker.update(part: index, bytes: sent)
                            }
                            return (index, etag)
                        }
                        next += 1
                        inFlight += 1
                    }
                    if let finished = try await group.next() {
                        etags[finished.0] = finished.1
                        inFlight -= 1
                    }
                }
            }

            let parts = etags.enumerated().map { "<Part><PartNumber>\($0.offset + 1)</PartNumber><ETag>\"\(xmlEscape($0.element))\"</ETag></Part>" }.joined()
            let body = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload>\(parts)</CompleteMultipartUpload>".utf8)
            let (data, response) = try await send(
                "POST", bucket: bucket, key: key, query: [("uploadId", uploadID)],
                headers: ["Content-Type": "application/xml"], body: body
            )
            try S3ResponseParser.throwIfErrorDocument(data, status: response.statusCode)
        } catch {
            _ = try? await send("DELETE", bucket: bucket, key: key, query: [("uploadId", uploadID)])
            throw error
        }
    }

    private func uploadPart(bucket: String, key: String, uploadID: String, number: Int, body: Data, progress: @escaping @Sendable (Int64) -> Void) async throws -> String {
        let request = try await signedRequest(
            "PUT", bucket: bucket, key: key,
            query: [("partNumber", String(number)), ("uploadId", uploadID)],
            payloadHash: SigV4Signer.unsignedPayload
        )
        let (data, response) = try await transfers.upload(request, data: body) { sent, _ in progress(sent) }
        try Self.validate(response, data: data)
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            throw S3Error.invalidResponse("Part \(number) was uploaded without an ETag")
        }
        return S3ResponseParser.unquote(etag)
    }

    // MARK: - Request plumbing

    @discardableResult
    func send(_ method: String, bucket: String?, key: String?, query: [(String, String?)] = [],
              headers: [String: String] = [:], body: Data? = nil, region: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let payloadHash = SigV4Signer.sha256Hex(body ?? Data())
        var request = try await signedRequest(method, bucket: bucket, key: key, query: query, headers: headers, payloadHash: payloadHash, region: region)
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw S3Error.invalidResponse("No HTTP response")
        }
        try Self.validate(http, data: data)
        return (data, http)
    }

    private func signedRequest(_ method: String, bucket: String?, key: String?, query: [(String, String?)] = [],
                               headers: [String: String] = [:], payloadHash: String = SigV4Signer.emptyPayloadHash,
                               region: String? = nil) async throws -> URLRequest {
        let resolvedRegion: String
        if let region {
            resolvedRegion = region
        } else if let bucket {
            resolvedRegion = await self.region(forBucket: bucket)
        } else {
            resolvedRegion = configuration.region
        }
        var request = try makeRequest(method, bucket: bucket, key: key, query: query, region: resolvedRegion, forcePathStyle: false)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        SigV4Signer(credentials: credentials, region: resolvedRegion).sign(&request, payloadHash: payloadHash)
        return request
    }

    private func makeRequest(_ method: String, bucket: String?, key: String?, query: [(String, String?)], region: String, forcePathStyle: Bool) throws -> URLRequest {
        let url = try makeURL(bucket: bucket, key: key, query: query, region: region, forcePathStyle: forcePathStyle)
        var request = URLRequest(url: url)
        request.httpMethod = method
        if method == "HEAD" || method == "GET" {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        if method == "HEAD" { request.timeoutInterval = 20 }
        return request
    }

    /// Builds the request URL with path and query already in SigV4 canonical encoding.
    func makeURL(bucket: String?, key: String?, query: [(String, String?)], region: String, forcePathStyle: Bool) throws -> URL {
        var components = URLComponents()
        var basePath = ""
        let bucketAllowsVirtualHost = bucket.map(Self.isVirtualHostCompatible) ?? false
        let host: String
        let virtualHosted: Bool

        switch configuration.provider {
        case .aws:
            let regional = "s3.\(region).amazonaws.com"
            // Dotted bucket names do not match the wildcard TLS certificate, so they use path style.
            virtualHosted = !forcePathStyle && bucketAllowsVirtualHost
            host = virtualHosted ? "\(bucket!).\(regional)" : regional
            components.scheme = "https"
        case .r2, .custom:
            guard let endpoint = configuration.endpoint, let endpointHost = endpoint.host else {
                throw S3Error.invalidConfiguration("This account has no endpoint URL.")
            }
            virtualHosted = !forcePathStyle && !configuration.usePathStyle && bucketAllowsVirtualHost
            host = virtualHosted ? "\(bucket!).\(endpointHost)" : endpointHost
            components.scheme = endpoint.scheme ?? "https"
            components.port = endpoint.port
            basePath = endpoint.path.hasSuffix("/") ? String(endpoint.path.dropLast()) : endpoint.path
        }
        components.host = host

        var path = basePath
        if let bucket, !virtualHosted { path += "/" + S3Encoding.encode(bucket) }
        if let key { path += "/" + S3Encoding.encodePath(key) }
        components.percentEncodedPath = path.isEmpty ? "/" : path
        if !query.isEmpty { components.percentEncodedQuery = S3Encoding.canonicalQuery(query) }

        guard let url = components.url else {
            throw S3Error.invalidConfiguration("Could not build a URL for \(bucket ?? "")/\(key ?? "")")
        }
        return url
    }

    static func isVirtualHostCompatible(_ bucket: String) -> Bool {
        guard (3...63).contains(bucket.count), !bucket.contains(".") else { return false }
        guard bucket.first != "-", bucket.last != "-" else { return false }
        return bucket.allSatisfy { character in
            character.isLowercase || character.isNumber || character == "-"
        }
    }

    static func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw S3Error.from(status: response.statusCode, data: data)
        }
    }
}

/// Serializes reads from the file being uploaded so concurrent parts don't race on the handle.
private actor PartReader {
    let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func read(offset: Int64, length: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }
}

/// Adds up per-part progress into one figure for the whole file.
private final class PartProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Int: Int64] = [:]
    private let total: Int64
    private let report: TransferProgress?

    init(total: Int64, report: TransferProgress?) {
        self.total = total
        self.report = report
    }

    func update(part: Int, bytes: Int64) {
        guard let report else { return }
        let completed = lock.withLock { () -> Int64 in
            sent[part] = bytes
            return sent.values.reduce(0, +)
        }
        report(completed, total)
    }
}
