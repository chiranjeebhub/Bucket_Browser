import AppKit
import S3Kit
import UniformTypeIdentifiers

/// Where files dropped on the menu bar icon go: the folder last opened in any browser window,
/// or a bucket picked from the icon's menu. Kept in UserDefaults so it survives a relaunch.
enum QuickUploadDestination {
    private static let key = "quickUpload.destination.v1"

    private struct Stored: Codable {
        var accountID: UUID
        var bucket: String
        var prefix: String
    }

    static var current: BrowserLocation? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return BrowserLocation(accountID: stored.accountID, bucket: stored.bucket, prefix: stored.prefix)
    }

    static func remember(_ location: BrowserLocation) {
        let stored = Stored(accountID: location.accountID, bucket: location.bucket, prefix: location.prefix)
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: key)
    }
}

/// The menu bar icon. Drop files on it to upload them to the destination above; its menu shows
/// upload progress, lets you pick another destination and copies links to recent uploads.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    static let visibilityKey = "showsMenuBarItem"

    private struct RecentUpload {
        let name: String
        let location: BrowserLocation
        let key: String
    }

    private let accounts: AccountStore
    private let transfers: TransferManager
    private var statusItem: NSStatusItem?
    private var recentUploads: [RecentUpload] = []
    private var activeUploads: [Transfer] = []
    private var defaultsObserver: NSObjectProtocol?

    init(accounts: AccountStore, transfers: TransferManager) {
        self.accounts = accounts
        self.transfers = transfers
        super.init()
        UserDefaults.standard.register(defaults: [Self.visibilityKey: true])
        updateVisibility()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
    }

    private func updateVisibility() {
        let shouldShow = UserDefaults.standard.bool(forKey: Self.visibilityKey) && !DemoMode.isEnabled
        if shouldShow, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Self.icon(uploading: false)
            item.button?.toolTip = "Bucket Browser — drop files here to upload them"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            // The status button's window forwards drag events to its delegate.
            item.button?.window?.registerForDraggedTypes([.fileURL])
            item.button?.window?.delegate = self
            statusItem = item
        } else if !shouldShow, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private static func icon(uploading: Bool) -> NSImage? {
        let image = NSImage(
            systemSymbolName: uploading ? "arrow.up.circle.fill" : "externaldrive.fill.badge.icloud",
            accessibilityDescription: "Bucket Browser"
        )
        image?.isTemplate = true
        return image
    }

    // MARK: - Destination

    /// The remembered destination, if its account still exists.
    private var destination: BrowserLocation? {
        guard let location = QuickUploadDestination.current, accounts.account(id: location.accountID) != nil else { return nil }
        return location
    }

    private func describe(_ location: BrowserLocation) -> String {
        location.prefix.isEmpty ? location.bucket : "\(location.bucket)/\(location.prefix)"
    }

    // MARK: - Dragging

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard destination != nil, !fileURLs(from: sender).isEmpty else { return [] }
        statusItem?.button?.highlight(true)
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        statusItem?.button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusItem?.button?.highlight(false)
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        upload(urls)
        return true
    }

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    // MARK: - Uploading

    private func upload(_ urls: [URL]) {
        guard let location = destination else {
            alert("Choose where uploads go first: open a folder in Bucket Browser, or pick a bucket from the menu bar icon.")
            return
        }
        let client: S3Client
        do {
            client = try accounts.client(for: location.accountID)
        } catch {
            alert(error.localizedDescription)
            return
        }
        let started = transfers.upload(urls, client: client, bucket: location.bucket, prefix: location.prefix) { [weak self] in
            DriveMounts.shared.bucketChanged(accountID: location.accountID, bucket: location.bucket)
            self?.uploadsChanged()
        }
        for (url, transfer) in zip(urls, started) where !TransferManager.isDirectory(url) {
            pending[ObjectIdentifier(transfer)] = RecentUpload(name: url.lastPathComponent, location: location, key: location.prefix + url.lastPathComponent)
        }
        activeUploads += started
        uploadsChanged()
    }

    /// Finished single-file uploads waiting to be added to the recent list, keyed by transfer.
    private var pending: [ObjectIdentifier: RecentUpload] = [:]

    private func uploadsChanged() {
        for transfer in activeUploads where !transfer.isActive {
            if transfer.state == .finished, let recent = pending[ObjectIdentifier(transfer)] {
                recentUploads.insert(recent, at: 0)
            }
            pending[ObjectIdentifier(transfer)] = nil
        }
        activeUploads.removeAll { !$0.isActive }
        recentUploads = Array(recentUploads.prefix(8))
        statusItem?.button?.image = Self.icon(uploading: !activeUploads.isEmpty)
    }

    @objc private func chooseFiles() {
        guard let location = destination else {
            alert("Choose where uploads go first: open a folder in Bucket Browser, or pick a bucket from this menu.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Upload to \(describe(location))"
        guard panel.runModal() == .OK else { return }
        upload(panel.urls)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        uploadsChanged()
        menu.removeAllItems()

        if let location = destination {
            let account = accounts.account(id: location.accountID)?.name ?? ""
            menu.addItem(header("Drop files on the icon to upload to"))
            let target = NSMenuItem(title: "\(describe(location)) — \(account)", action: nil, keyEquivalent: "")
            target.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            target.isEnabled = false
            menu.addItem(target)
        } else {
            menu.addItem(header("Open a folder in Bucket Browser to upload there from here"))
        }
        menu.addItem(item("Upload Files…", #selector(chooseFiles)))
        menu.addItem(destinationMenu())

        if !activeUploads.isEmpty {
            menu.addItem(.separator())
            let completed = activeUploads.reduce(Int64(0)) { $0 + $1.completedBytes }
            let total = activeUploads.reduce(Int64(0)) { $0 + $1.totalBytes }
            let percent = total > 0 ? " — \(Int(Double(completed) / Double(total) * 100))%" : ""
            let count = activeUploads.count
            menu.addItem(header("Uploading \(count == 1 ? "1 item" : "\(count) items")\(percent)"))
        }

        if !recentUploads.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Copy a 7-day link to a recent upload"))
            for (index, upload) in recentUploads.enumerated() {
                let entry = item(upload.name, #selector(copyRecentLink(_:)))
                entry.tag = index
                entry.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: (upload.name as NSString).pathExtension) ?? .data)
                entry.image?.size = NSSize(width: 16, height: 16)
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Open Bucket Browser", #selector(openApp)))
        menu.addItem(item("Hide Menu Bar Icon", #selector(hideIcon)))
    }

    private func destinationMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Upload To", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for account in accounts.accounts {
            submenu.addItem(header(account.name))
            let buckets = accounts.bucketStates[account.id]?.buckets.map(\.name) ?? []
            let names = buckets.isEmpty ? account.pinnedBuckets : buckets
            if names.isEmpty {
                let none = NSMenuItem(title: "No buckets loaded", action: nil, keyEquivalent: "")
                none.isEnabled = false
                submenu.addItem(none)
            }
            for name in names {
                let entry = item(name, #selector(chooseDestination(_:)))
                entry.representedObject = BucketChoice(accountID: account.id, bucket: name)
                if let current = destination, current.accountID == account.id, current.bucket == name, current.prefix.isEmpty {
                    entry.state = .on
                }
                submenu.addItem(entry)
            }
        }
        if accounts.accounts.isEmpty {
            submenu.addItem(header("Add an account in Bucket Browser first"))
        }
        parent.submenu = submenu
        return parent
    }

    private final class BucketChoice: NSObject {
        let accountID: UUID
        let bucket: String
        init(accountID: UUID, bucket: String) {
            self.accountID = accountID
            self.bucket = bucket
        }
    }

    private func header(_ title: String) -> NSMenuItem {
        NSMenuItem.sectionHeader(title: title)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func chooseDestination(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? BucketChoice else { return }
        QuickUploadDestination.remember(BrowserLocation(accountID: choice.accountID, bucket: choice.bucket))
    }

    @objc private func copyRecentLink(_ sender: NSMenuItem) {
        guard recentUploads.indices.contains(sender.tag) else { return }
        let upload = recentUploads[sender.tag]
        Task {
            do {
                let client = try accounts.client(for: upload.location.accountID)
                let url = try await client.presignedURL(bucket: upload.location.bucket, key: upload.key, expiresIn: 604_800)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            } catch {
                alert(error.localizedDescription)
            }
        }
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            // Opening the running app sends it a reopen event, and SwiftUI answers that with a new window.
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }

    @objc private func hideIcon() {
        UserDefaults.standard.set(false, forKey: Self.visibilityKey)
    }

    private func alert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn’t Upload"
        alert.informativeText = message
        alert.runModal()
    }
}
