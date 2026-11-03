import AppKit
import FileProvider
import Observation

/// Buckets mounted as drives through the File Provider extension. Each mounted bucket is a
/// File Provider domain, which macOS lists under Locations with its own folder in
/// ~/Library/CloudStorage. Files show up from the bucket listing and download when opened.
@MainActor
@Observable
final class DriveMounts {
    static let shared = DriveMounts()

    /// Domain identifiers of the buckets mounted now.
    private(set) var mounted: Set<String> = []

    private init() {
        Task { await refresh() }
    }

    /// The extension reads the access keys from iCloud Keychain, which only signed builds can use.
    var isAvailable: Bool { KeychainStore.isSyncAvailable && !DemoMode.isEnabled }

    /// "<account UUID>/<bucket>". The extension parses the same format; bucket names have no slash.
    static func identifier(accountID: UUID, bucket: String) -> String {
        "\(accountID.uuidString)/\(bucket)"
    }

    func isMounted(accountID: UUID, bucket: String) -> Bool {
        mounted.contains(Self.identifier(accountID: accountID, bucket: bucket))
    }

    func refresh() async {
        guard isAvailable else { return }
        let domains = (try? await Self.domains()) ?? []
        mounted = Set(domains.map(\.identifier.rawValue))
    }

    func mount(_ account: Account, bucket: String) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: Self.identifier(accountID: account.id, bucket: bucket)),
            displayName: "\(bucket) — \(account.name)"
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.add(domain) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        mounted.insert(domain.identifier.rawValue)
        try await reveal(accountID: account.id, bucket: bucket)
    }

    func unmount(accountID: UUID, bucket: String) async throws {
        guard let domain = try await domain(accountID: accountID, bucket: bucket) else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.remove(domain) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        mounted.remove(domain.identifier.rawValue)
    }

    /// Opens the mounted bucket's folder.
    func reveal(accountID: UUID, bucket: String) async throws {
        guard let domain = try await domain(accountID: accountID, bucket: bucket),
              let manager = NSFileProviderManager(for: domain) else { return }
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            manager.getUserVisibleURL(for: .rootContainer) { url, error in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile)) }
            }
        }
        NSWorkspace.shared.open(url)
    }

    /// Tells the drive to look for changes, after the app uploaded, deleted or renamed something.
    func bucketChanged(accountID: UUID, bucket: String) {
        let identifier = Self.identifier(accountID: accountID, bucket: bucket)
        guard mounted.contains(identifier) else { return }
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: identifier), displayName: bucket)
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }

    /// Unmounts every bucket of an account that was removed.
    func removeAll(accountID: UUID) {
        let prefix = accountID.uuidString + "/"
        for identifier in mounted where identifier.hasPrefix(prefix) {
            let bucket = String(identifier.dropFirst(prefix.count))
            Task { try? await unmount(accountID: accountID, bucket: bucket) }
        }
    }

    private func domain(accountID: UUID, bucket: String) async throws -> NSFileProviderDomain? {
        let identifier = Self.identifier(accountID: accountID, bucket: bucket)
        return try await Self.domains().first { $0.identifier.rawValue == identifier }
    }

    private static func domains() async throws -> [NSFileProviderDomain] {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: domains) }
            }
        }
    }
}
