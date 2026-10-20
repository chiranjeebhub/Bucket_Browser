import AppKit
import Foundation
import Observation
import S3Kit
import UniformTypeIdentifiers

/// Where a window is looking: a folder inside a bucket.
struct BrowserLocation: Hashable {
    var accountID: UUID
    var bucket: String
    var prefix: String = ""
}

enum ViewMode: String, CaseIterable, Identifiable {
    case icons
    case list
    case columns

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icons: return "Icons"
        case .list: return "List"
        case .columns: return "Columns"
        }
    }

    var symbolName: String {
        switch self {
        case .icons: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .columns: return "rectangle.split.3x1"
        }
    }
}

/// State and actions for one browser window.
@MainActor
@Observable
final class BrowserModel {
    let accounts: AccountStore
    let transfers: TransferManager

    private(set) var location: BrowserLocation?
    private(set) var backStack: [BrowserLocation] = []
    private(set) var forwardStack: [BrowserLocation] = []

    /// Listings by prefix for the current bucket. The column view shows several at once.
    private(set) var listings: [String: [BrowserItem]] = [:]
    private(set) var loadingPrefixes: Set<String> = []
    private(set) var loadErrors: [String: String] = [:]

    var selection: Set<BrowserItem.ID> = []
    var viewMode: ViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    var searchText = ""
    var sortOrder: [KeyPathComparator<BrowserItem>] = [KeyPathComparator(\.name)]
    var showInspector = false

    // Sheets and alerts
    var quickLookURL: URL?
    var isPreparingQuickLook = false
    var alertMessage: String?
    var isWorking = false
    var newFolderName = ""
    var isCreatingFolder = false
    var renameTarget: BrowserItem?
    var renameText = ""
    var pendingDeletion: [BrowserItem] = []

    @ObservationIgnored private var loadTasks: [String: Task<Void, Never>] = [:]

    init(accounts: AccountStore, transfers: TransferManager) {
        self.accounts = accounts
        self.transfers = transfers
        viewMode = UserDefaults.standard.string(forKey: "viewMode").flatMap(ViewMode.init(rawValue:)) ?? .list
    }

    // MARK: - Derived state

    var account: Account? { accounts.account(id: location?.accountID) }

    var currentItems: [BrowserItem] {
        guard let location else { return [] }
        return sorted(filtered(listings[location.prefix] ?? []))
    }

    func items(in prefix: String) -> [BrowserItem] {
        sorted(listings[prefix] ?? [])
    }

    var selectedItems: [BrowserItem] {
        let all = location.map { listings[$0.prefix] ?? [] } ?? []
        return all.filter { selection.contains($0.id) }
    }

    var isLoadingCurrent: Bool {
        location.map { loadingPrefixes.contains($0.prefix) } ?? false
    }

    var currentError: String? {
        location.flatMap { loadErrors[$0.prefix] }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { !(location?.prefix.isEmpty ?? true) }

    var title: String {
        guard let location else { return "Bucket Browser" }
        return location.prefix.isEmpty ? location.bucket : S3Path.name(of: location.prefix)
    }

    var statusText: String {
        let count = currentItems.count
        var text = count == 1 ? "1 item" : "\(count) items"
        if !selection.isEmpty { text = "\(selection.count) of \(count) selected" }
        let bytes = selectedItems.compactMap(\.size).reduce(0, +)
        if bytes > 0 { text += ", " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        return text
    }

    private func filtered(_ items: [BrowserItem]) -> [BrowserItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Sorted by the chosen column, with folders kept on top like Finder's "Keep folders on top".
    private func sorted(_ items: [BrowserItem]) -> [BrowserItem] {
        let ordered = items.sorted(using: sortOrder)
        return ordered.filter(\.isFolder) + ordered.filter { !$0.isFolder }
    }

    // MARK: - Navigation

    func select(accountID: UUID, bucket: String) {
        navigate(to: BrowserLocation(accountID: accountID, bucket: bucket))
    }

    func navigate(to newLocation: BrowserLocation, recordHistory: Bool = true) {
        guard newLocation != location else { return }
        if let location, recordHistory {
            backStack.append(location)
            forwardStack.removeAll()
        }
        if newLocation.accountID != location?.accountID || newLocation.bucket != location?.bucket {
            loadTasks.values.forEach { $0.cancel() }
            loadTasks.removeAll()
            listings.removeAll()
            loadErrors.removeAll()
            loadingPrefixes.removeAll()
        }
        location = newLocation
        selection.removeAll()
        searchText = ""
        // The column view needs every level from the root down.
        for prefix in S3Path.ancestors(of: newLocation.prefix) where listings[prefix] == nil {
            load(prefix)
        }
    }

    func open(_ item: BrowserItem) {
        if item.isFolder {
            guard var next = location else { return }
            next.prefix = item.key
            navigate(to: next)
        } else {
            quickLook([item])
        }
    }

    func openSelection() {
        let items = selectedItems
        if items.count == 1, let item = items.first {
            open(item)
        } else if !items.isEmpty {
            quickLook(items.filter { !$0.isFolder })
        }
    }

    func goTo(prefix: String) {
        guard var next = location else { return }
        next.prefix = prefix
        navigate(to: next)
    }

    func goUp() {
        guard let location, canGoUp else { return }
        let child = location.prefix
        goTo(prefix: S3Path.parent(of: child))
        selection = [child]
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let location { forwardStack.append(location) }
        navigate(to: previous, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let location { backStack.append(location) }
        navigate(to: next, recordHistory: false)
    }

    /// Called when the account behind this window is removed or its bucket disappears.
    func reset() {
        location = nil
        backStack.removeAll()
        forwardStack.removeAll()
        listings.removeAll()
        selection.removeAll()
    }

    // MARK: - Loading

    func refresh() {
        guard let location else { return }
        for prefix in S3Path.ancestors(of: location.prefix) { load(prefix) }
    }

    func load(_ prefix: String) {
        if DemoMode.isEnabled, let location {
            listings[prefix] = BrowserItem.items(from: DemoMode.listing(bucket: location.bucket, prefix: prefix), prefix: prefix)
            return
        }
        guard let location, let client = try? accounts.client(for: location.accountID) else {
            if let location { loadErrors[location.prefix] = "Could not read this account’s credentials from the Keychain." }
            return
        }
        loadTasks[prefix]?.cancel()
        loadingPrefixes.insert(prefix)
        loadErrors[prefix] = nil
        let bucket = location.bucket
        loadTasks[prefix] = Task {
            do {
                let listing = try await client.listFolder(bucket: bucket, prefix: prefix)
                guard !Task.isCancelled else { return }
                listings[prefix] = BrowserItem.items(from: listing, prefix: prefix)
                let valid = Set(listings[self.location?.prefix ?? ""]?.map(\.id) ?? [])
                selection.formIntersection(valid)
            } catch {
                guard !Task.isCancelled else { return }
                loadErrors[prefix] = error.localizedDescription
                if listings[prefix] == nil { listings[prefix] = [] }
            }
            loadingPrefixes.remove(prefix)
        }
    }

    private func resolveClient() throws -> (S3Client, BrowserLocation) {
        guard let location else { throw S3Error.invalidConfiguration("Choose a bucket first.") }
        return (try accounts.client(for: location.accountID), location)
    }

    /// Runs a bucket-changing operation, shows any error, then reloads the affected folders.
    private func perform(reloading prefixes: [String], _ operation: @escaping (S3Client, BrowserLocation) async throws -> Void) {
        do {
            let (client, location) = try resolveClient()
            isWorking = true
            Task {
                do {
                    try await operation(client, location)
                } catch {
                    alertMessage = error.localizedDescription
                }
                isWorking = false
                guard self.location?.bucket == location.bucket else { return }
                for prefix in Set(prefixes) { load(prefix) }
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - File operations

    func beginNewFolder() {
        guard location != nil else { return }
        newFolderName = uniqueName("untitled folder")
        isCreatingFolder = true
    }

    func commitNewFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreatingFolder = false
        guard let location, Self.isValidName(name) else {
            if !name.isEmpty { alertMessage = "“\(name)” can’t be used as a folder name." }
            return
        }
        let prefix = location.prefix
        perform(reloading: [prefix]) { client, location in
            try await client.createFolder(bucket: location.bucket, prefix: prefix + name + "/")
        }
    }

    func beginRename(_ item: BrowserItem) {
        renameTarget = item
        renameText = item.name
    }

    func commitRename() {
        guard let item = renameTarget else { return }
        renameTarget = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != item.name else { return }
        guard Self.isValidName(name) else {
            alertMessage = "“\(name)” can’t be used as a name."
            return
        }
        let parent = S3Path.parent(of: item.key)
        let newKey = parent + name + (item.isFolder ? "/" : "")
        if (listings[parent] ?? []).contains(where: { $0.key == newKey }) {
            alertMessage = "The name “\(name)” is already taken. Please choose a different name."
            return
        }
        perform(reloading: [parent]) { client, location in
            try await Self.move(item, to: newKey, client: client, bucket: location.bucket)
        }
    }

    /// S3 has no rename, so this copies every affected object to its new key and deletes the original.
    nonisolated static func move(_ item: BrowserItem, to newKey: String, client: S3Client, bucket: String) async throws {
        if !item.isFolder {
            try await client.copyObject(sourceBucket: bucket, sourceKey: item.key, bucket: bucket, key: newKey)
            try await client.deleteObject(bucket: bucket, key: item.key)
            return
        }
        let objects = try await client.listObjectsRecursively(bucket: bucket, prefix: item.key)
        if objects.isEmpty {
            try await client.createFolder(bucket: bucket, prefix: newKey)
            return
        }
        for object in objects {
            try Task.checkCancellation()
            let destination = newKey + object.key.dropFirst(item.key.count)
            try await client.copyObject(sourceBucket: bucket, sourceKey: object.key, bucket: bucket, key: destination)
        }
        try await client.deleteObjects(bucket: bucket, keys: objects.map(\.key))
    }

    func requestDelete(_ items: [BrowserItem]) {
        guard !items.isEmpty else { return }
        pendingDeletion = items
    }

    func commitDelete() {
        let items = pendingDeletion
        pendingDeletion = []
        guard let prefix = location?.prefix, !items.isEmpty else { return }
        selection.subtract(items.map(\.id))
        perform(reloading: [prefix]) { client, location in
            var keys: [String] = []
            for item in items {
                if item.isFolder {
                    keys += try await client.listObjectsRecursively(bucket: location.bucket, prefix: item.key).map(\.key)
                    keys.append(item.key)
                } else {
                    keys.append(item.key)
                }
            }
            try await client.deleteObjects(bucket: location.bucket, keys: Array(Set(keys)))
        }
    }

    var deletionPrompt: String {
        if pendingDeletion.count == 1, let item = pendingDeletion.first {
            return item.isFolder
                ? "Delete the folder “\(item.name)” and everything in it?"
                : "Delete “\(item.name)”?"
        }
        return "Delete \(pendingDeletion.count) items?"
    }

    // MARK: - Transfers

    func upload(_ urls: [URL], into prefix: String? = nil) {
        guard !urls.isEmpty else { return }
        do {
            let (client, location) = try resolveClient()
            let target = prefix ?? location.prefix
            transfers.upload(urls, client: client, bucket: location.bucket, prefix: target) { [weak self] in
                guard let self, self.location?.bucket == location.bucket else { return }
                self.load(target)
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func chooseFilesToUpload() {
        guard location != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to “\(title)”."
        guard panel.runModal() == .OK else { return }
        upload(panel.urls)
    }

    func download(_ items: [BrowserItem]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download"
        panel.message = items.count == 1 ? "Choose where to save “\(items[0].name)”." : "Choose where to save \(items.count) items."
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let (client, location) = try resolveClient()
            transfers.download(items, client: client, bucket: location.bucket, to: directory)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// A file promise for dragging an item out to Finder or another app.
    func itemProvider(for item: BrowserItem) -> NSItemProvider {
        guard let resolved = try? resolveClient() else {
            let provider = NSItemProvider()
            provider.suggestedName = item.name
            return provider
        }
        return Self.filePromise(for: item, client: resolved.0, bucket: resolved.1.bucket)
    }

    /// Kept off the main actor: the item provider calls the load handler on a background thread.
    nonisolated private static func filePromise(for item: BrowserItem, client: S3Client, bucket: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        provider.registerFileRepresentation(forTypeIdentifier: item.contentType.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: max(item.size ?? 1, 1))
            Task.detached {
                do {
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("BucketBrowser-Drag", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    let destination = directory.appendingPathComponent(item.name, isDirectory: item.isFolder)
                    try await TransferManager.fetch(item, client: client, bucket: bucket, to: destination) { completed, total in
                        progress.totalUnitCount = max(total, 1)
                        progress.completedUnitCount = completed
                    }
                    completion(destination, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    // MARK: - Quick Look

    func quickLook(_ items: [BrowserItem]? = nil) {
        guard let item = (items ?? selectedItems).first(where: { !$0.isFolder }) else { return }
        guard let resolved = try? resolveClient() else { return }
        let (client, location) = resolved
        isPreparingQuickLook = true
        Task {
            do {
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("BucketBrowser/QuickLook", isDirectory: true)
                    .appendingPathComponent(Self.cacheKey(location: location, item: item), isDirectory: true)
                let destination = directory.appendingPathComponent(item.name)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try await client.download(bucket: location.bucket, key: item.key, to: destination)
                }
                quickLookURL = destination
            } catch {
                alertMessage = "Couldn’t preview “\(item.name)”: \(error.localizedDescription)"
            }
            isPreparingQuickLook = false
        }
    }

    /// The preview cache is keyed by object version (ETag), so changed objects are fetched again.
    private static func cacheKey(location: BrowserLocation, item: BrowserItem) -> String {
        let raw = "\(location.accountID)/\(location.bucket)/\(item.key)/\(item.etag ?? "")"
        return SigV4Signer.sha256Hex(Data(raw.utf8))
    }

    // MARK: - Pasteboard

    func copyKeys(_ items: [BrowserItem]) {
        guard let location else { return }
        let text = items.map { "s3://\(location.bucket)/\($0.key)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyPresignedLink(_ item: BrowserItem, expiresIn seconds: Int) {
        guard let resolved = try? resolveClient() else { return }
        let (client, location) = resolved
        Task {
            do {
                let url = try await client.presignedURL(bucket: location.bucket, key: item.key, expiresIn: seconds)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func metadata(for item: BrowserItem) async throws -> S3ObjectMetadata {
        if DemoMode.isEnabled { return DemoMode.metadata(for: item) }
        let (client, location) = try resolveClient()
        return try await client.headObject(bucket: location.bucket, key: item.key)
    }

    // MARK: - Helpers

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    private func uniqueName(_ base: String) -> String {
        let existing = Set((location.flatMap { listings[$0.prefix] } ?? []).map(\.name))
        guard existing.contains(base) else { return base }
        var counter = 2
        while existing.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }
}
