import FileProvider
import S3Kit

/// Lists a folder for the system, or (for the working set) reports what changed in the bucket.
///
/// S3 can't say what changed since a point in time, so changes are found by listing again each
/// folder the system has already seen and comparing it with what was reported last time: every
/// item present is an update, anything missing is a deletion.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let client: S3Client
    private let bucket: String
    /// The folder to list, or nil for the working set.
    private let prefix: String?
    private let snapshots: SnapshotStore
    private var task: Task<Void, Never>?

    init(client: S3Client, bucket: String, prefix: String?, snapshots: SnapshotStore) {
        self.client = client
        self.bucket = bucket
        self.prefix = prefix
        self.snapshots = snapshots
    }

    func invalidate() {
        task?.cancel()
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard let prefix else {
            // Everything in the working set is reported through folder listings and changes.
            observer.finishEnumerating(upTo: nil)
            return
        }
        let token = Self.isInitial(page) ? nil : String(data: page.rawValue, encoding: .utf8)
        task = Task {
            do {
                let result = try await client.listPage(bucket: bucket, prefix: prefix, delimiter: "/", continuationToken: token)
                let items = Self.items(in: result.listing, prefix: prefix)
                snapshots.add(items.map(\.key), for: prefix, replacing: token == nil)
                observer.didEnumerate(items)
                if result.isTruncated, let next = result.nextContinuationToken {
                    observer.finishEnumerating(upTo: NSFileProviderPage(Data(next.utf8)))
                } else {
                    observer.finishEnumerating(upTo: nil)
                }
            } catch {
                observer.finishEnumeratingWithError(FileProviderExtension.fileProviderError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let prefixes = prefix.map { [$0] } ?? snapshots.knownPrefixes
        task = Task {
            var updated: [FileProviderItem] = []
            var deleted: [NSFileProviderItemIdentifier] = []
            for prefix in prefixes {
                if Task.isCancelled { break }
                // A folder that has since been deleted shows up as missing from its parent's listing.
                guard let listing = try? await client.listFolder(bucket: bucket, prefix: prefix) else { continue }
                let items = Self.items(in: listing, prefix: prefix)
                let current = Set(items.map(\.key))
                let gone = snapshots.keys(for: prefix).subtracting(current)
                snapshots.add(Array(current), for: prefix, replacing: true)
                for key in gone where key.hasSuffix("/") { snapshots.forget(prefix: key) }
                updated += items
                deleted += gone.map(FileProviderItem.identifier(for:))
            }
            snapshots.save()
            if !updated.isEmpty { observer.didUpdate(updated) }
            if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
            observer.finishEnumeratingChanges(upTo: Self.anchorNow(), moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchorNow())
    }

    static func anchorNow() -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8))
    }

    private static func isInitial(_ page: NSFileProviderPage) -> Bool {
        // The form Apple's sample code uses; the constants import as NSData-backed values.
        page == NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
            || page == NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage
    }

    static func items(in listing: S3Listing, prefix: String) -> [FileProviderItem] {
        let folders = listing.prefixes
            .filter { $0 != prefix && !S3Path.name(of: $0).isEmpty }
            .map(FileProviderItem.init(folder:))
        // Skip the zero-byte marker that stands for the folder itself.
        let files = listing.objects
            .filter { $0.key != prefix && !$0.key.hasSuffix("/") }
            .map(FileProviderItem.init(object:))
        return folders + files
    }
}

/// The keys last reported for each folder the system has listed, saved in the extension's
/// container so change detection survives the extension being relaunched.
final class SnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var keysByPrefix: [String: Set<String>]
    private let fileURL: URL?

    init(domainIdentifier: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let directory = support?.appendingPathComponent("Snapshots", isDirectory: true)
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let name = SigV4Signer.sha256Hex(Data(domainIdentifier.utf8))
        fileURL = directory?.appendingPathComponent("\(name).json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            keysByPrefix = saved
        } else {
            keysByPrefix = [:]
        }
    }

    var knownPrefixes: [String] { lock.withLock { Array(keysByPrefix.keys) } }

    func keys(for prefix: String) -> Set<String> {
        lock.withLock { keysByPrefix[prefix] ?? [] }
    }

    func add(_ keys: [String], for prefix: String, replacing: Bool) {
        lock.withLock {
            if replacing { keysByPrefix[prefix] = Set(keys) } else { keysByPrefix[prefix, default: []].formUnion(keys) }
        }
    }

    func insert(_ key: String) {
        lock.withLock { _ = keysByPrefix[S3Path.parent(of: key), default: []].insert(key) }
    }

    func remove(_ key: String) {
        lock.withLock { _ = keysByPrefix[S3Path.parent(of: key)]?.remove(key) }
    }

    /// Drops a deleted folder and everything below it.
    func forget(prefix: String) {
        lock.withLock { keysByPrefix = keysByPrefix.filter { !$0.key.hasPrefix(prefix) } }
    }

    func save() {
        guard let fileURL else { return }
        let data = lock.withLock { try? JSONEncoder().encode(keysByPrefix) }
        try? data?.write(to: fileURL, options: .atomic)
    }
}
