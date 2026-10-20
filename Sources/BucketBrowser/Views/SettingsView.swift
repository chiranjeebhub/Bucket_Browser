import SwiftUI

/// Settings › Accounts: add, edit, reorder and remove accounts.
struct SettingsView: View {
    @Environment(AccountStore.self) private var accounts
    @State private var selection: UUID?
    @State private var editor: AccountEditorTarget?

    private var syncStatus: String {
        accounts.isSyncingWithICloud
            ? "Accounts and keys sync to your other Macs with iCloud Keychain."
            : "iCloud sync is off because this copy of the app isn’t signed with a developer certificate."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(accounts.accounts) { account in
                    HStack {
                        Label(account.name, systemImage: account.symbolName)
                        Spacer()
                        Text(account.provider.displayName)
                            .foregroundStyle(.secondary)
                    }
                    .tag(account.id)
                }
                .onMove { accounts.move(fromOffsets: $0, toOffset: $1) }
            }
            .contextMenu(forSelectionType: UUID.self) { _ in
                EmptyView()
            } primaryAction: { ids in
                if let id = ids.first, let account = accounts.account(id: id) { editor = .edit(account) }
            }
            .overlay {
                if accounts.accounts.isEmpty {
                    Text("No accounts").foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                Button { editor = .new } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                Button {
                    if let selection { accounts.remove(selection) }
                    selection = nil
                } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                .disabled(selection == nil)
                Spacer()
                Button("Edit…") {
                    if let account = accounts.account(id: selection) { editor = .edit(account) }
                }
                .disabled(selection == nil)
            }
            .buttonStyle(.borderless)
            .padding(8)

            Divider()
            Label(syncStatus, systemImage: accounts.isSyncingWithICloud ? "checkmark.icloud" : "icloud.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(width: 480, height: 350)
        .sheet(item: $editor) { target in
            AccountEditorView(target: target)
                .environment(accounts)
        }
    }
}
