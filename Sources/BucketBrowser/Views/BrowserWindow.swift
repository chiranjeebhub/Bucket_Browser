import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// One browser window. Creates the window's model once the shared stores are available.
struct BrowserWindow: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(TransferManager.self) private var transfers
    @State private var model: BrowserModel?

    var body: some View {
        Group {
            if let model {
                BrowserView(model: model)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard model == nil else { return }
            let newModel = BrowserModel(accounts: accounts, transfers: transfers)
            if DemoMode.isEnabled && !DemoMode.startsEmpty { Self.applyDemoSettings(to: newModel) }
            model = newModel
        }
    }

    /// Opens the folder, view and selection that the demo environment variables ask for.
    private static func applyDemoSettings(to model: BrowserModel) {
        if let viewMode = DemoMode.viewMode { model.viewMode = viewMode }
        let owner = DemoMode.buckets.first { entry in
            entry.value.contains { bucket in bucket.name == DemoMode.bucket }
        }
        let accountID = owner?.key ?? DemoMode.r2AccountID
        model.select(accountID: accountID, bucket: DemoMode.bucket)
        if !DemoMode.prefix.isEmpty { model.goTo(prefix: DemoMode.prefix) }
        if let name = DemoMode.selectedName,
           let item = model.currentItems.first(where: { $0.name == name }) {
            model.selection = [item.id]
        }
        model.showInspector = DemoMode.showsInspector
    }
}

struct BrowserView: View {
    @Bindable var model: BrowserModel
    @Environment(AccountStore.self) private var accounts
    @Environment(TransferManager.self) private var transfers
    @State private var accountEditor: AccountEditorTarget?
    @State private var showTransfers = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model, accountEditor: $accountEditor)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 340)
        } detail: {
            // The toolbar, search field and inspector belong to the detail column. Attached to the
            // split view instead, macOS 26 lays the toolbar out in the collapsed inspector's space
            // and pushes every button into the overflow menu.
            DetailView(model: model, accountEditor: $accountEditor)
                .toolbar {
                    BrowserToolbar(model: model, showTransfers: $showTransfers, transfers: transfers)
                }
                .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search this folder")
                .inspector(isPresented: $model.showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 240, ideal: 290, max: 420)
                }
        }
        // With no accounts the sidebar and toolbar have nothing to show, so the window is just the welcome screen.
        .toolbar(accounts.accounts.isEmpty ? .hidden : .visible, for: .windowToolbar)
        .onAppear { if accounts.accounts.isEmpty { columnVisibility = .detailOnly } }
        .onChange(of: accounts.accounts.isEmpty) { _, isEmpty in
            withAnimation { columnVisibility = isEmpty ? .detailOnly : .all }
        }
        .navigationTitle(model.title)
        .navigationSubtitle(subtitle)
        .quickLookPreview($model.quickLookURL)
        .focusedSceneValue(\.browserModel, model)
        .sheet(item: $accountEditor) { target in
            AccountEditorView(target: target)
                .environment(accounts)
        }
        .alert("New Folder", isPresented: $model.isCreatingFolder) {
            TextField("Name", text: $model.newFolderName)
            Button("Create") { model.commitNewFolder() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new folder.")
        }
        .alert("Rename", isPresented: isRenaming) {
            TextField("Name", text: $model.renameText)
            Button("Rename") { model.commitRename() }
            Button("Cancel", role: .cancel) { model.renameTarget = nil }
        } message: {
            if model.renameTarget?.isFolder == true {
                Text("Renaming a folder copies every object inside it to the new name, which can take a while for large folders.")
            } else {
                Text("Enter a new name.")
            }
        }
        .confirmationDialog(model.deletionPrompt, isPresented: isConfirmingDelete) {
            Button("Delete", role: .destructive) { model.commitDelete() }
            Button("Cancel", role: .cancel) { model.pendingDeletion = [] }
        } message: {
            Text("Objects are deleted from the bucket immediately. This can’t be undone.")
        }
        .alert("Something Went Wrong", isPresented: hasAlert) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onChange(of: accounts.accounts) {
            if let location = model.location, accounts.account(id: location.accountID) == nil {
                model.reset()
            }
        }
    }

    private var subtitle: String {
        guard let location = model.location, let account = model.account else { return "" }
        return location.prefix.isEmpty ? account.name : "\(account.name) — \(location.bucket)"
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { model.renameTarget != nil }, set: { if !$0 { model.renameTarget = nil } })
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { !model.pendingDeletion.isEmpty }, set: { if !$0 { model.pendingDeletion = [] } })
    }

    private var hasAlert: Binding<Bool> {
        Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
    }
}

// MARK: - Detail

struct DetailView: View {
    @Bindable var model: BrowserModel
    @Binding var accountEditor: AccountEditorTarget?
    @Environment(AccountStore.self) private var accounts
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.location != nil {
                Divider()
                PathBar(model: model)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if accounts.accounts.isEmpty {
            WelcomeView(accountEditor: $accountEditor)
        } else if model.location == nil {
            ContentUnavailableView("Choose a Bucket", systemImage: "sidebar.left", description: Text("Select a bucket in the sidebar."))
        } else {
            browser
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    FileDrop.loadURLs(from: providers) { model.upload($0) }
                    return true
                }
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .padding(2)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    @ViewBuilder
    private var browser: some View {
        switch model.viewMode {
        case .list:
            ListBrowserView(model: model)
                .overlay { statusOverlay }
        case .icons:
            IconBrowserView(model: model)
                .overlay { statusOverlay }
        case .columns:
            ColumnBrowserView(model: model)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if model.currentItems.isEmpty {
            if model.isLoadingCurrent {
                ProgressView()
            } else if let error = model.currentError {
                ContentUnavailableView {
                    Label("Couldn’t Load Folder", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { model.refresh() }
                }
            } else if !model.searchText.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("Drag files here to upload them."))
            }
        }
    }
}

/// Collects file URLs from drag-and-drop item providers.
enum FileDrop {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func add(_ url: URL) { lock.withLock { urls.append(url) } }
        var all: [URL] { lock.withLock { urls } }
    }

    static func loadURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let collector = Collector()
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { collector.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(collector.all) }
        }
    }
}
