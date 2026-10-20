import SwiftUI

/// Finder's list view: a sortable table of the current folder.
struct ListBrowserView: View {
    @Bindable var model: BrowserModel

    var body: some View {
        Table(of: BrowserItem.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 6) {
                    Image(nsImage: item.icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 160, ideal: 320)

            TableColumn("Date Modified", value: \.sortDate) { item in
                Text(item.formattedDate)
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 170)

            TableColumn("Size", value: \.sortSize) { item in
                Text(item.formattedSize)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80)

            TableColumn("Kind", value: \.kindDescription) { item in
                Text(item.kindDescription)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 150)
        } rows: {
            ForEach(model.currentItems) { item in
                TableRow(item)
                    .itemProvider { model.itemProvider(for: item) }
                    .dropDestination(for: URL.self) { urls in
                        // Dropping onto a folder row uploads into that folder.
                        model.upload(urls, into: item.isFolder ? item.key : nil)
                    }
            }
        }
        .contextMenu(forSelectionType: BrowserItem.ID.self) { ids in
            ItemMenu(model: model, items: items(for: ids))
        } primaryAction: { ids in
            let selected = items(for: ids)
            if selected.count == 1, let item = selected.first {
                model.open(item)
            } else {
                model.quickLook(selected)
            }
        }
        .onKeyPress(.space) {
            model.quickLook()
            return .handled
        }
    }

    private func items(for ids: Set<BrowserItem.ID>) -> [BrowserItem] {
        model.currentItems.filter { ids.contains($0.id) }
    }
}
