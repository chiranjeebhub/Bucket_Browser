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
                Button(files.count == 1 && BrowserModel.canStream(files[0]) ? "Play" : "Quick Look") { model.quickLook(files) }
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
            if !files.isEmpty {
                Menu(files.count == 1 ? "Copy Shareable Link" : "Copy \(files.count) Shareable Links") {
                    Button("Expires in 1 Hour") { model.copyPresignedLinks(files, expiresIn: 3600) }
                    Button("Expires in 1 Day") { model.copyPresignedLinks(files, expiresIn: 86400) }
                    Button("Expires in 7 Days") { model.copyPresignedLinks(files, expiresIn: 604_800) }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { model.requestDelete(items) }
        }
    }
}
