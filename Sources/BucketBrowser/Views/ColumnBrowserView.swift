import S3Kit
import SwiftUI
import UniformTypeIdentifiers

/// Finder's column view: one column per folder level, with a preview of the selected file at the end.
struct ColumnBrowserView: View {
    @Bindable var model: BrowserModel

    private var prefixes: [String] {
        S3Path.ancestors(of: model.location?.prefix ?? "")
    }

    private var previewItem: BrowserItem? {
        let selected = model.selectedItems
        guard selected.count == 1, let item = selected.first, !item.isFolder else { return nil }
        return item
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(prefixes, id: \.self) { prefix in
                        BrowserColumn(model: model, prefix: prefix)
                            .frame(width: 240)
                        Divider()
                    }
                    if let previewItem {
                        FilePreviewColumn(model: model, item: previewItem)
                            .frame(width: 280)
                        Divider()
                    }
                    Color.clear
                        .frame(width: 1)
                        .id("end")
                }
            }
            .onChange(of: model.location) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .trailing) }
            }
            .onChange(of: previewItem) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .trailing) }
            }
        }
    }
}

private struct BrowserColumn: View {
    @Bindable var model: BrowserModel
    let prefix: String
    @State private var isDropTargeted = false

    private var isLast: Bool { prefix == model.location?.prefix }

    /// In earlier columns, the folder that leads to the next column stays highlighted.
    private var pathChild: String? {
        guard let current = model.location?.prefix, current.hasPrefix(prefix), current != prefix else { return nil }
        return S3Path.ancestors(of: current).first { $0.count > prefix.count }
    }

    private var items: [BrowserItem] { model.items(in: prefix) }

    var body: some View {
        List(selection: selection) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Image(nsImage: item.icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if item.isFolder {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(item.id)
                .onDrag { model.itemProvider(for: item) }
            }
        }
        .contextMenu(forSelectionType: BrowserItem.ID.self) { ids in
            ItemMenu(model: model, items: items.filter { ids.contains($0.id) }, folderPrefix: prefix)
        } primaryAction: { ids in
            let selected = items.filter { ids.contains($0.id) }
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
        .overlay {
            if items.isEmpty {
                if model.loadingPrefixes.contains(prefix) {
                    ProgressView().controlSize(.small)
                } else if let error = model.loadErrors[prefix] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    Text("Empty")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            FileDrop.loadURLs(from: providers) { model.upload($0, into: prefix) }
            return true
        }
        .overlay {
            if isDropTargeted {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
            }
        }
    }

    private var selection: Binding<Set<BrowserItem.ID>> {
        Binding {
            if isLast { return model.selection }
            return pathChild.map { [$0] } ?? []
        } set: { newValue in
            choose(newValue)
        }
    }

    /// Selecting a folder opens it as the next column; selecting files selects them in this column.
    private func choose(_ ids: Set<BrowserItem.ID>) {
        if ids.count == 1, let id = ids.first, let item = items.first(where: { $0.id == id }), item.isFolder {
            model.goTo(prefix: item.key)
            return
        }
        if ids.isEmpty {
            if isLast { model.selection = [] }
            return
        }
        if !isLast { model.goTo(prefix: prefix) }
        model.selection = ids
    }
}

private struct FilePreviewColumn: View {
    let model: BrowserModel
    let item: BrowserItem

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
            Text(item.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text("\(item.kindDescription) — \(item.formattedSize)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Modified").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(item.formattedDate)
                }
                if let storageClass = item.storageClass {
                    GridRow {
                        Text("Storage").foregroundStyle(.secondary)
                        Text(storageClass)
                    }
                }
            }
            .font(.caption)
            HStack {
                Button("Quick Look") { model.quickLook([item]) }
                Button("Download…") { model.download([item]) }
            }
            .controlSize(.small)
            Spacer()
        }
        .padding()
    }
}
