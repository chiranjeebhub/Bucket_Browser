import AppKit
import S3Kit
import SwiftUI

struct SidebarSelection: Hashable {
    var accountID: UUID
    var bucket: String
}

/// Accounts as sidebar sections, each listing its buckets like Finder's Locations.
struct SidebarView: View {
    let model: BrowserModel
    @Binding var accountEditor: AccountEditorTarget?
    @Environment(AccountStore.self) private var accounts
    @State private var accountToRemove: Account?

    var body: some View {
        List(selection: selection) {
            ForEach(accounts.accounts) { account in
                Section {
                    bucketRows(for: account)
                } header: {
                    HStack(spacing: 4) {
                        Text(account.name)
                        Spacer()
                        if case .loading? = accounts.bucketStates[account.id] {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .contextMenu { accountMenu(account) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    accountEditor = .new
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add an S3 or R2 account")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear {
            for account in accounts.accounts { accounts.loadBucketsIfNeeded(for: account.id) }
        }
        .confirmationDialog(
            "Remove “\(accountToRemove?.name ?? "")”?",
            isPresented: Binding(get: { accountToRemove != nil }, set: { if !$0 { accountToRemove = nil } })
        ) {
            Button("Remove Account", role: .destructive) {
                if let account = accountToRemove { accounts.remove(account.id) }
                accountToRemove = nil
            }
        } message: {
            Text("Its credentials are deleted from your Keychain. Nothing in the buckets is changed.")
        }
    }

    @ViewBuilder
    private func bucketRows(for account: Account) -> some View {
        switch accounts.bucketStates[account.id] ?? .idle {
        case .idle, .loading:
            Text("Loading…")
                .foregroundStyle(.secondary)
        case let .failed(message, _):
            VStack(alignment: .leading, spacing: 4) {
                Label("Couldn’t list buckets", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                HStack {
                    Button("Retry") { accounts.refreshBuckets(for: account.id) }
                    Button("Edit…") { accountEditor = .edit(account) }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        case let .loaded(buckets):
            if buckets.isEmpty {
                Text("No buckets")
                    .foregroundStyle(.secondary)
            }
            ForEach(buckets) { bucket in
                Label {
                    Text(bucket.name)
                } icon: {
                    Image(nsImage: FileIcons.bucket)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .tag(SidebarSelection(accountID: account.id, bucket: bucket.name))
                .contextMenu {
                    Button("Copy Bucket Name") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bucket.name, forType: .string)
                    }
                    Divider()
                    accountMenu(account)
                }
            }
        }
    }

    @ViewBuilder
    private func accountMenu(_ account: Account) -> some View {
        Button("Refresh Buckets") { accounts.refreshBuckets(for: account.id) }
        Button("Edit Account…") { accountEditor = .edit(account) }
        Divider()
        Button("Remove Account…", role: .destructive) { accountToRemove = account }
    }

    private var selection: Binding<SidebarSelection?> {
        Binding {
            model.location.map { SidebarSelection(accountID: $0.accountID, bucket: $0.bucket) }
        } set: { newValue in
            guard let newValue else { return }
            if newValue.accountID == model.location?.accountID, newValue.bucket == model.location?.bucket {
                model.goTo(prefix: "")
            } else {
                model.select(accountID: newValue.accountID, bucket: newValue.bucket)
            }
        }
    }
}
