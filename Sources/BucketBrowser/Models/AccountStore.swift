import Foundation
import Observation
import S3Kit

/// The saved accounts and their bucket lists, shared by every window.
@MainActor
@Observable
final class AccountStore {
    enum BucketState {
        case idle
        case loading
        case loaded([S3Bucket])
        case failed(String, pinned: [S3Bucket])

        var buckets: [S3Bucket] {
            switch self {
            case let .loaded(buckets): return buckets
            case let .failed(_, pinned): return pinned
            case .idle, .loading: return []
            }
        }
    }

    private(set) var accounts: [Account] = []
    private(set) var bucketStates: [UUID: BucketState] = [:]

    @ObservationIgnored private var clients: [UUID: S3Client] = [:]
    @ObservationIgnored private let defaultsKey = "accounts.v1"

    init() {
        if DemoMode.isEnabled {
            accounts = DemoMode.startsEmpty ? [] : DemoMode.accounts
            for (id, buckets) in DemoMode.buckets { bucketStates[id] = .loaded(buckets) }
            return
        }
        if let synced = KeychainStore.loadAccountList() {
            accounts = synced
            saveToDefaults()
        } else {
            if let data = UserDefaults.standard.data(forKey: defaultsKey),
               let saved = try? JSONDecoder().decode([Account].self, from: data) {
                accounts = saved
            }
            // First launch of a build that can sync: upload the accounts this Mac already has.
            if !accounts.isEmpty { KeychainStore.saveAccountList(accounts) }
        }
    }

    /// Whether accounts and keys sync through iCloud Keychain in this build.
    var isSyncingWithICloud: Bool { !DemoMode.isEnabled && KeychainStore.isSyncAvailable }

    /// Picks up accounts added, edited or removed on another Mac. Called when the app becomes active.
    func reloadFromICloud() {
        guard isSyncingWithICloud, let synced = KeychainStore.loadAccountList(), synced != accounts else { return }
        let previous = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        accounts = synced
        saveToDefaults()
        let current = Set(synced.map(\.id))
        for id in previous.keys where !current.contains(id) {
            bucketStates[id] = nil
            clients[id] = nil
        }
        for account in synced where previous[account.id] != account {
            // New or changed elsewhere: its keys may have changed too.
            clients[account.id] = nil
            if previous[account.id] != nil { refreshBuckets(for: account.id) }
        }
    }

    func account(id: UUID?) -> Account? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    func credentials(for account: Account) -> S3Credentials? {
        try? KeychainStore.load(for: account.id)
    }

    /// Adds or replaces an account and saves its credentials to the Keychain.
    func save(_ account: Account, credentials: S3Credentials) throws {
        try KeychainStore.save(credentials, for: account.id)
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        clients[account.id] = nil
        persist()
        refreshBuckets(for: account.id)
    }

    func remove(_ accountID: UUID) {
        accounts.removeAll { $0.id == accountID }
        bucketStates[accountID] = nil
        clients[accountID] = nil
        KeychainStore.delete(for: accountID)
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func client(for accountID: UUID) throws -> S3Client {
        if let client = clients[accountID] { return client }
        guard let account = self.account(id: accountID) else {
            throw S3Error.invalidConfiguration("This account no longer exists.")
        }
        guard let credentials = try KeychainStore.load(for: accountID) else {
            throw S3Error.invalidConfiguration("No credentials were found in the Keychain for “\(account.name)”. Edit the account to enter them again.")
        }
        let client = S3Client(configuration: account.configuration, credentials: credentials)
        clients[accountID] = client
        return client
    }

    func refreshAllBuckets() {
        for account in accounts { refreshBuckets(for: account.id) }
    }

    func loadBucketsIfNeeded(for accountID: UUID) {
        if case .none = bucketStates[accountID] { refreshBuckets(for: accountID) }
        if case .idle? = bucketStates[accountID] { refreshBuckets(for: accountID) }
    }

    func refreshBuckets(for accountID: UUID) {
        guard let account = self.account(id: accountID) else { return }
        if DemoMode.isEnabled {
            bucketStates[accountID] = .loaded(DemoMode.buckets[accountID] ?? [])
            return
        }
        bucketStates[accountID] = .loading
        let pinned = account.pinnedBuckets.map { S3Bucket(name: $0) }
        Task {
            do {
                let client = try self.client(for: accountID)
                let listed = try await client.listBuckets()
                let names = Set(listed.map(\.name))
                bucketStates[accountID] = .loaded(listed + pinned.filter { !names.contains($0.name) })
            } catch {
                bucketStates[accountID] = pinned.isEmpty
                    ? .failed(error.localizedDescription, pinned: [])
                    : .loaded(pinned)
            }
        }
    }

    private func persist() {
        guard !DemoMode.isEnabled else { return }
        saveToDefaults()
        KeychainStore.saveAccountList(accounts)
    }

    private func saveToDefaults() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
