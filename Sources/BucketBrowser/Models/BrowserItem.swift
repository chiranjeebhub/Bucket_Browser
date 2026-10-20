import AppKit
import Foundation
import S3Kit
import UniformTypeIdentifiers

/// A row in the browser: either a "folder" (common prefix) or an object.
struct BrowserItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case folder
        case file
    }

    /// Full key for files, full prefix ending in `/` for folders.
    let key: String
    let name: String
    let kind: Kind
    let size: Int64?
    let lastModified: Date?
    let etag: String?
    let storageClass: String?

    var id: String { key }
    var isFolder: Bool { kind == .folder }

    init(folder prefix: String) {
        key = prefix
        name = S3Path.name(of: prefix)
        kind = .folder
        size = nil
        lastModified = nil
        etag = nil
        storageClass = nil
    }

    init(object: S3Object) {
        key = object.key
        name = S3Path.name(of: object.key)
        kind = .file
        size = object.size
        lastModified = object.lastModified
        etag = object.etag
        storageClass = object.storageClass
    }

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    var contentType: UTType {
        if isFolder { return .folder }
        return UTType(filenameExtension: fileExtension) ?? .data
    }

    var kindDescription: String {
        if isFolder { return "Folder" }
        return contentType.localizedDescription ?? (fileExtension.isEmpty ? "Document" : "\(fileExtension.uppercased()) file")
    }

    // Sort keys for Table columns. Folders have no size or date, so they sort first ascending.
    var sortSize: Int64 { size ?? -1 }
    var sortDate: Date { lastModified ?? .distantPast }

    var formattedSize: String {
        guard let size else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var formattedDate: String {
        guard let lastModified else { return "--" }
        return lastModified.formatted(date: .abbreviated, time: .shortened)
    }

    var icon: NSImage { FileIcons.icon(for: self) }

    static func items(from listing: S3Listing, prefix: String) -> [BrowserItem] {
        let folders = listing.prefixes.filter { $0 != prefix }.map(BrowserItem.init(folder:))
        // A zero-byte object whose key equals the prefix is the folder's own marker, not a file.
        let files = listing.objects.filter { $0.key != prefix && !$0.key.hasSuffix("/") }.map(BrowserItem.init(object:))
        return folders + files
    }
}

/// Finder's own icons for file types, cached by type.
enum FileIcons {
    private static let lock = NSLock()
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: BrowserItem) -> NSImage {
        icon(key: item.contentType.identifier) { NSWorkspace.shared.icon(for: item.contentType) }
    }

    static var bucket: NSImage {
        icon(key: "bucket") { NSWorkspace.shared.icon(for: .volume) }
    }

    private static func icon(key: String, make: () -> NSImage) -> NSImage {
        if let cached = lock.withLock({ cache[key] }) { return cached }
        let image = make()
        lock.withLock { cache[key] = image }
        return image
    }
}
