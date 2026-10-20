import SwiftUI

struct BrowserToolbar: ToolbarContent {
    @Bindable var model: BrowserModel
    @Binding var showTransfers: Bool
    let transfers: TransferManager

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
                .help("See folders you viewed previously")
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
                .help("See folders you viewed next")
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $model.viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Change how items are shown")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.beginNewFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .disabled(model.location == nil)
                .help("New Folder")
            Button { model.chooseFilesToUpload() } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                .disabled(model.location == nil)
                .help("Upload files or folders")
            Button { model.download(model.selectedItems) } label: { Label("Download", systemImage: "square.and.arrow.down") }
                .disabled(model.selection.isEmpty)
                .help("Download the selected items")
            Button(role: .destructive) { model.requestDelete(model.selectedItems) } label: { Label("Delete", systemImage: "trash") }
                .disabled(model.selection.isEmpty)
                .help("Delete the selected items")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { showTransfers.toggle() } label: {
                if transfers.activeCount > 0 {
                    ProgressView(value: transfers.overallFraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Label("Transfers", systemImage: "arrow.up.arrow.down.circle")
                }
            }
            .help("Show uploads and downloads")
            .popover(isPresented: $showTransfers, arrowEdge: .bottom) {
                TransfersView()
                    .environment(transfers)
            }

            Button { model.showInspector.toggle() } label: { Label("Get Info", systemImage: "info.circle") }
                .disabled(model.location == nil)
                .help("Show info about the selection")
        }
    }
}
