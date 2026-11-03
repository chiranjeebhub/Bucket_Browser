import FileProvider
import S3Kit
import UniformTypeIdentifiers

/// One object or "folder" (common prefix) as the system sees it.
///
/// Identifiers are the S3 key itself: a folder's ends in `/`, the bucket root is
/// `.rootContainer`. So the identifier alone says where an item lives.
final class FileProviderItem: NSObject, NSFileProviderItem {
    let key: String
    let isFolder: Bool
    let size: Int64?
    let modified: Date?
    let etag: String?

    init(folder prefix: String) {
        key = prefix
        isFolder = true
        size = nil
        modified = nil
        etag = nil
    }

    init(object: S3Object) {
        key = object.key
        isFolder = false
        size = object.size
        modified = object.lastModified
        etag = object.etag
    }

    init(key: String, metadata: S3ObjectMetadata) {
        self.key = key
        isFolder = false
        size = metadata.contentLength
        modified = metadata.lastModified
        etag = metadata.etag
    }

    static let root = FileProviderItem(folder: "")

    static func identifier(for key: String) -> NSFileProviderItemIdentifier {
        key.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(rawValue: key)
    }

    /// The key (or prefix) an identifier stands for. Nil for the trash, which buckets don't have.
    static func key(for identifier: NSFileProviderItemIdentifier) -> String? {
        if identifier == .rootContainer { return "" }
        if identifier == .trashContainer || identifier == .workingSet { return nil }
        return identifier.rawValue
    }

    var itemIdentifier: NSFileProviderItemIdentifier { Self.identifier(for: key) }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        key.isEmpty ? .rootContainer : Self.identifier(for: S3Path.parent(of: key))
    }

    var filename: String { key.isEmpty ? "" : S3Path.name(of: key) }

    var contentType: UTType {
        if isFolder { return .folder }
        return UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
    }

    var documentSize: NSNumber? { size.map { NSNumber(value: $0) } }
    var contentModificationDate: Date? { modified }
    var creationDate: Date? { modified }

    var capabilities: NSFileProviderItemCapabilities {
        if isFolder {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsDeleting, .allowsRenaming, .allowsReparenting]
        }
        return [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting]
    }

    /// The ETag changes whenever the object's bytes do, so it doubles as the content version.
    var itemVersion: NSFileProviderItemVersion {
        let content = Data((etag ?? key).utf8)
        return NSFileProviderItemVersion(contentVersion: content, metadataVersion: content)
    }
}
