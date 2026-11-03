import FileProvider
import S3Kit
import UniformTypeIdentifiers

/// Mounts one bucket as a drive. Files appear right away from the bucket listing and are
/// downloaded when opened; files saved or dropped into the drive are uploaded.
@objc(FileProviderExtension)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let mount: MountedBucket?
    private let snapshots: SnapshotStore
    private lazy var manager = NSFileProviderManager(for: domain)

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        mount = MountedBucket(domainIdentifier: domain.identifier.rawValue)
        snapshots = SnapshotStore(domainIdentifier: domain.identifier.rawValue)
        super.init()
    }

    func invalidate() {
        snapshots.save()
    }

    // MARK: - Plumbing

    private func client() throws -> (S3Client, String) {
        guard let mount else { throw NSFileProviderError(.providerNotFound) }
        do {
            return (try SharedAccounts.client(accountID: mount.accountID), mount.bucket)
        } catch {
            throw NSFileProviderError(.notAuthenticated)
        }
    }

    /// Runs async work and hands back a Progress the system can cancel.
    private func run(_ work: @escaping @Sendable () async throws -> Void, onError: @escaping @Sendable (Error) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = Task {
            do {
                try await work()
            } catch {
                onError(Self.fileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// Maps S3 and network errors to the File Provider errors the system knows how to present.
    static func fileProviderError(_ error: Error) -> Error {
        if error is NSFileProviderError { return error }
        if error is CancellationError { return CocoaError(.userCancelled) }
        if let s3 = error as? S3Error {
            switch s3.statusCode {
            case 404: return NSFileProviderError(.noSuchItem)
            case 401, 403: return NSFileProviderError(.notAuthenticated)
            default: break
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut, .cannotFindHost:
                return NSFileProviderError(.serverUnreachable)
            case .cancelled:
                return CocoaError(.userCancelled)
            default: break
            }
        }
        return error
    }

    /// Finder's own bookkeeping files would clutter the bucket, so they stay on this Mac only.
    private static func isExcluded(_ filename: String) -> Bool {
        filename == ".DS_Store" || filename.hasPrefix("._") || filename == ".localized"
    }

    private func key(for identifier: NSFileProviderItemIdentifier) throws -> String {
        guard let key = FileProviderItem.key(for: identifier) else { throw NSFileProviderError(.noSuchItem) }
        return key
    }

    /// Asks the system to pick up changes, after this extension changed the bucket itself.
    private func signalChanges() {
        snapshots.save()
        manager?.signalEnumerator(for: .workingSet) { _ in }
    }

    // MARK: - Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        run({ [self] in
            let key = try self.key(for: identifier)
            if key.isEmpty {
                completionHandler(FileProviderItem.root, nil)
            } else if key.hasSuffix("/") {
                completionHandler(FileProviderItem(folder: key), nil)
            } else {
                let (client, bucket) = try client()
                let metadata = try await client.headObject(bucket: bucket, key: key)
                completionHandler(FileProviderItem(key: key, metadata: metadata), nil)
            }
        }, onError: { completionHandler(nil, $0) })
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let task = Task { [self] in
            do {
                let key = try self.key(for: itemIdentifier)
                let (client, bucket) = try client()
                let directory = (try? manager?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
                let destination = directory.appendingPathComponent(UUID().uuidString)
                let metadata = try await client.headObject(bucket: bucket, key: key)
                try await client.download(bucket: bucket, key: key, to: destination) { completed, total in
                    guard total > 0 else { return }
                    progress.completedUnitCount = Int64(Double(completed) / Double(total) * 100)
                }
                progress.completedUnitCount = 100
                completionHandler(destination, FileProviderItem(key: key, metadata: metadata), nil)
            } catch {
                completionHandler(nil, nil, Self.fileProviderError(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - Changes from this Mac

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        if Self.isExcluded(itemTemplate.filename) {
            completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
            return Progress()
        }
        let type = itemTemplate.contentType ?? .data
        if type.conforms(to: .symbolicLink) {
            completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
            return Progress()
        }
        return run({ [self] in
            let parent = try self.key(for: itemTemplate.parentItemIdentifier)
            let (client, bucket) = try client()
            if type.conforms(to: .directory) {
                let prefix = parent + itemTemplate.filename + "/"
                // A folder that already exists in the bucket (say, created elsewhere) is fine as it is.
                if !options.contains(.mayAlreadyExist) {
                    try await client.createFolder(bucket: bucket, prefix: prefix)
                }
                snapshots.insert(prefix)
                completionHandler(FileProviderItem(folder: prefix), [], false, nil)
            } else {
                let key = parent + itemTemplate.filename
                if let url {
                    try await client.uploadFile(url, bucket: bucket, key: key, contentType: type.preferredMIMEType)
                } else {
                    try await client.putObject(bucket: bucket, key: key, data: Data(), contentType: type.preferredMIMEType)
                }
                let metadata = try await client.headObject(bucket: bucket, key: key)
                snapshots.insert(key)
                completionHandler(FileProviderItem(key: key, metadata: metadata), [], false, nil)
            }
            snapshots.save()
        }, onError: { completionHandler(nil, [], false, $0) })
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        run({ [self] in
            let oldKey = try self.key(for: item.itemIdentifier)
            let (client, bucket) = try client()
            let isFolder = oldKey.hasSuffix("/")
            var key = oldKey

            if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                let parent = try self.key(for: item.parentItemIdentifier)
                key = parent + item.filename + (isFolder ? "/" : "")
                if key != oldKey {
                    try await move(from: oldKey, to: key, isFolder: isFolder, client: client, bucket: bucket)
                }
            }
            if changedFields.contains(.contents), let newContents, !isFolder {
                let type = item.contentType ?? UTType(filenameExtension: (item.filename as NSString).pathExtension) ?? .data
                try await client.uploadFile(newContents, bucket: bucket, key: key, contentType: type.preferredMIMEType)
            }

            let updated: FileProviderItem
            if isFolder {
                updated = FileProviderItem(folder: key)
            } else {
                updated = FileProviderItem(key: key, metadata: try await client.headObject(bucket: bucket, key: key))
            }
            if key != oldKey {
                // Identifiers are keys, and a moved object has a new key. Report the item under its
                // old identifier now; the next change listing swaps it for the one at the new key.
                completionHandler(RenamedItem(updated, keepingIdentifier: item.itemIdentifier), [], false, nil)
                signalChanges()
            } else {
                completionHandler(updated, [], false, nil)
            }
        }, onError: { completionHandler(nil, [], false, $0) })
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        run({ [self] in
            let key = try self.key(for: identifier)
            guard !key.isEmpty else { throw NSFileProviderError(.deletionRejected) }
            let (client, bucket) = try client()
            if key.hasSuffix("/") {
                let keys = try await client.listObjectsRecursively(bucket: bucket, prefix: key).map(\.key)
                if keys.contains(where: { $0 != key }), !options.contains(.recursive) {
                    throw NSFileProviderError(.directoryNotEmpty)
                }
                try await client.deleteObjects(bucket: bucket, keys: keys)
                snapshots.forget(prefix: key)
            } else {
                try await client.deleteObject(bucket: bucket, key: key)
            }
            snapshots.remove(key)
            snapshots.save()
            completionHandler(nil)
        }, onError: { completionHandler($0) })
    }

    /// S3 has no rename, so copy each object to its new key and then delete the originals.
    private func move(from oldKey: String, to newKey: String, isFolder: Bool, client: S3Client, bucket: String) async throws {
        if !isFolder {
            try await client.copyObject(sourceBucket: bucket, sourceKey: oldKey, bucket: bucket, key: newKey)
            try await client.deleteObject(bucket: bucket, key: oldKey)
            return
        }
        let objects = try await client.listObjectsRecursively(bucket: bucket, prefix: oldKey)
        for object in objects {
            try Task.checkCancellation()
            let destination = newKey + object.key.dropFirst(oldKey.count)
            try await client.copyObject(sourceBucket: bucket, sourceKey: object.key, bucket: bucket, key: destination)
        }
        if objects.isEmpty { try await client.createFolder(bucket: bucket, prefix: newKey) }
        try await client.deleteObjects(bucket: bucket, keys: objects.map(\.key))
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        let (client, bucket) = try client()
        if containerItemIdentifier == .workingSet {
            return FileProviderEnumerator(client: client, bucket: bucket, prefix: nil, snapshots: snapshots)
        }
        let prefix = try key(for: containerItemIdentifier)
        guard prefix.isEmpty || prefix.hasSuffix("/") else { throw NSFileProviderError(.noSuchItem) }
        return FileProviderEnumerator(client: client, bucket: bucket, prefix: prefix, snapshots: snapshots)
    }
}

/// An item reported under the identifier the system already has for it, after a move gave it a new key.
private final class RenamedItem: NSObject, NSFileProviderItem {
    private let base: FileProviderItem
    let itemIdentifier: NSFileProviderItemIdentifier

    init(_ base: FileProviderItem, keepingIdentifier identifier: NSFileProviderItemIdentifier) {
        self.base = base
        itemIdentifier = identifier
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier { base.parentItemIdentifier }
    var filename: String { base.filename }
    var contentType: UTType { base.contentType }
    var documentSize: NSNumber? { base.documentSize }
    var contentModificationDate: Date? { base.contentModificationDate }
    var capabilities: NSFileProviderItemCapabilities { base.capabilities }
    var itemVersion: NSFileProviderItemVersion { base.itemVersion }
}
