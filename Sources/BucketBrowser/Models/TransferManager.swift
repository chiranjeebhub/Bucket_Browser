import Foundation
import Observation
import S3Kit
import UniformTypeIdentifiers

/// One upload or download shown in the Transfers popover.
@MainActor
@Observable
final class Transfer: Identifiable {
    enum Direction {
        case upload
        case download
    }

    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let name: String
    let direction: Direction
    let destinationDescription: String
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var state: State = .running
    /// Where a finished download landed, so it can be revealed in Finder.
    var localURL: URL?

    @ObservationIgnored var task: Task<Void, Never>?

    init(name: String, direction: Direction, destinationDescription: String) {
        self.name = name
        self.direction = direction
        self.destinationDescription = destinationDescription
    }

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return state == .finished ? 1 : 0 }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }

    var isActive: Bool { state == .running }

    func cancel() {
        task?.cancel()
    }
}

/// Queues and tracks uploads and downloads for all windows.
@MainActor
@Observable
final class TransferManager {
    private(set) var transfers: [Transfer] = []

    var activeCount: Int { transfers.filter(\.isActive).count }

    var overallFraction: Double {
        let active = transfers.filter(\.isActive)
        let total = active.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard total > 0 else { return 0 }
        return Double(active.reduce(Int64(0)) { $0 + $1.completedBytes }) / Double(total)
    }

    func clearFinished() {
        transfers.removeAll { !$0.isActive }
    }

    // MARK: - Uploads

    /// Uploads local files and folders into `prefix`, keeping folder structure.
    /// `onComplete` runs on the main actor after each dropped item finishes.
    func upload(_ urls: [URL], client: S3Client, bucket: String, prefix: String, onComplete: @escaping @MainActor () -> Void) {
        for url in urls {
            let transfer = Transfer(name: url.lastPathComponent, direction: .upload, destinationDescription: "\(bucket)/\(prefix)")
            transfers.insert(transfer, at: 0)

            transfer.task = Task {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    // Walking a large folder can take a while, so keep it off the main actor.
                    let plan = await Task.detached { Self.plan(for: url, keyPrefix: prefix) }.value
                    transfer.totalBytes = plan.files.reduce(0) { $0 + $1.size }
                    for folder in plan.emptyFolders {
                        try Task.checkCancellation()
                        try await client.createFolder(bucket: bucket, prefix: folder)
                    }
                    var done: Int64 = 0
                    for file in plan.files {
                        try Task.checkCancellation()
                        let base = done
                        let throttle = ProgressThrottle()
                        try await client.uploadFile(file.url, bucket: bucket, key: file.key, contentType: file.contentType) { sent, _ in
                            guard throttle.shouldReport() else { return }
                            Task { @MainActor in transfer.completedBytes = base + sent }
                        }
                        done += file.size
                        transfer.completedBytes = done
                    }
                    transfer.state = .finished
                } catch is CancellationError {
                    transfer.state = .cancelled
                } catch let error as URLError where error.code == .cancelled {
                    transfer.state = .cancelled
                } catch {
                    transfer.state = .failed(error.localizedDescription)
                }
                onComplete()
            }
        }
    }

    struct LocalFile: Sendable {
        let url: URL
        let key: String
        let size: Int64
        let contentType: String?
    }

    struct UploadPlan: Sendable {
        var files: [LocalFile] = []
        /// Folder keys (ending in `/`) for directories with nothing in them, so they survive the upload.
        var emptyFolders: [String] = []
    }

    nonisolated static func plan(for url: URL, keyPrefix: String) -> UploadPlan {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentTypeKey]
        var plan = UploadPlan()

        func add(_ item: URL, key: String) {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { return }
            if values.isDirectory == true {
                let children = (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                if children.isEmpty { plan.emptyFolders.append(key + "/") }
            } else if values.isRegularFile == true {
                plan.files.append(LocalFile(url: item, key: key, size: Int64(values.fileSize ?? 0), contentType: values.contentType?.preferredMIMEType))
            }
        }

        let rootKey = keyPrefix + url.lastPathComponent
        add(url, key: rootKey)
        guard isDirectory(url) else { return plan }

        let root = url.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        while let item = enumerator?.nextObject() as? URL {
            let path = item.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            add(item, key: rootKey + "/" + path.dropFirst(root.count + 1))
        }
        return plan
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    // MARK: - Downloads

    /// Downloads files and folders into a local directory. Returns the transfers it started.
    @discardableResult
    func download(_ items: [BrowserItem], client: S3Client, bucket: String, to directory: URL) -> [Transfer] {
        items.map { item in
            let destination = Self.uniqueURL(for: item.name, in: directory)
            let transfer = Transfer(name: item.name, direction: .download, destinationDescription: directory.path)
            transfer.totalBytes = item.size ?? 0
            transfers.insert(transfer, at: 0)
            transfer.task = Task {
                do {
                    try await Self.fetch(item, client: client, bucket: bucket, to: destination) { completed, total in
                        Task { @MainActor in
                            transfer.completedBytes = completed
                            if total > 0 { transfer.totalBytes = total }
                        }
                    }
                    transfer.completedBytes = transfer.totalBytes
                    transfer.localURL = destination
                    transfer.state = .finished
                } catch is CancellationError {
                    transfer.state = .cancelled
                } catch let error as URLError where error.code == .cancelled {
                    transfer.state = .cancelled
                } catch {
                    transfer.state = .failed(error.localizedDescription)
                }
            }
            return transfer
        }
    }

    /// Downloads one file, or every object under a folder, to `destination`.
    /// Progress is reported as total bytes so far across the whole item.
    nonisolated static func fetch(_ item: BrowserItem, client: S3Client, bucket: String, to destination: URL,
                                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        if !item.isFolder {
            let throttle = ProgressThrottle()
            try await client.download(bucket: bucket, key: item.key, to: destination) { completed, total in
                if throttle.shouldReport() { progress(completed, total) }
            }
            return
        }

        let objects = try await client.listObjectsRecursively(bucket: bucket, prefix: item.key)
        let total = objects.reduce(Int64(0)) { $0 + $1.size }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var done: Int64 = 0
        progress(0, total)
        for object in objects {
            try Task.checkCancellation()
            let relative = String(object.key.dropFirst(item.key.count))
            guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else { continue }
            let target = destination.appendingPathComponent(relative)
            if object.key.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let base = done
            let throttle = ProgressThrottle()
            try await client.download(bucket: bucket, key: object.key, to: target) { completed, _ in
                if throttle.shouldReport() { progress(base + completed, total) }
            }
            done += object.size
            progress(done, total)
        }
    }

    /// `name`, or `name 2`, `name 3`… if something already exists there, like Finder.
    nonisolated static func uniqueURL(for name: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }
}

/// Limits progress callbacks (which arrive for every network packet) to about 10 per second.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func shouldReport() -> Bool {
        lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(last) >= 0.1 else { return false }
            last = now
            return true
        }
    }
}
