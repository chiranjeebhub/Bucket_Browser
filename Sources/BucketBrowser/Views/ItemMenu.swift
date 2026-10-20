import SwiftUI

/// The context menu for items (or for empty space when `items` is empty), shared by all views.
struct ItemMenu: View {
    let model: BrowserModel
    let items: [BrowserItem]
    /// The folder that "New Folder" and "Upload" act on when no item was clicked.
    var folderPrefix: String?

    var body: some View {
        if items.isEmpty {
            Button("New Folder") {
                if let folderPrefix { model.goTo(prefix: folderPrefix) }
                model.beginNewFolder()
            }
            Button("Upload…") {
                if let folderPrefix { model.goTo(prefix: folderPrefix) }
                model.chooseFilesToUpload()
            }
            Divider()
            Button("Refresh") { model.refresh() }
            Button("Get Info") { model.showInspector = true }
        } else {
            let files = items.filter { !$0.isFolder }
            if items.count == 1, let item = items.first {
                Button("Open") { model.open(item) }
            }
            if !files.isEmpty {
                Button("Quick Look") { model.quickLook(files) }
            }
            Divider()
            Button(items.count == 1 ? "Download “\(items[0].name)”…" : "Download \(items.count) Items…") {
                model.download(items)
            }
            Divider()
            if items.count == 1, let item = items.first {
                Button("Rename…") { model.beginRename(item) }
            }
            Button("Get Info") {
                model.selection = Set(items.map(\.id))
                model.showInspector = true
            }
            Button(items.count == 1 ? "Copy S3 URI" : "Copy \(items.count) S3 URIs") { model.copyKeys(items) }
            if items.count == 1, let file = files.first {
                Menu("Copy Shareable Link") {
                    Button("Expires in 1 Hour") { model.copyPresignedLink(file, expiresIn: 3600) }
                    Button("Expires in 1 Day") { model.copyPresignedLink(file, expiresIn: 86400) }
                    Button("Expires in 7 Days") { model.copyPresignedLink(file, expiresIn: 604_800) }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { model.requestDelete(items) }
        }
    }
}
