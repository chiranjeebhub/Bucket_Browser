import AppKit
import SwiftUI

/// Finder's icon view: a grid of large icons.
struct IconBrowserView: View {
    @Bindable var model: BrowserModel

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 124), spacing: 8, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(model.currentItems) { item in
                    IconCell(item: item, isSelected: model.selection.contains(item.id))
                        .onTapGesture(count: 2) { model.open(item) }
                        .onTapGesture { select(item) }
                        .contextMenu { ItemMenu(model: model, items: menuItems(for: item)) }
                        .onDrag { model.itemProvider(for: item) }
                        .dropDestination(for: URL.self) { urls, _ in
                            model.upload(urls, into: item.isFolder ? item.key : nil)
                            return true
                        }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection.removeAll() }
        .contextMenu { ItemMenu(model: model, items: []) }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            model.quickLook()
            return .handled
        }
        .onKeyPress(.return) {
            model.openSelection()
            return .handled
        }
    }

    /// Click selects one item, ⌘-click toggles, ⇧-click adds, like Finder.
    private func select(_ item: BrowserItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.selection.contains(item.id) {
                model.selection.remove(item.id)
            } else {
                model.selection.insert(item.id)
            }
        } else if flags.contains(.shift) {
            model.selection.insert(item.id)
        } else {
            model.selection = [item.id]
        }
    }

    /// Right-clicking a selected item acts on the whole selection; otherwise just that item.
    private func menuItems(for item: BrowserItem) -> [BrowserItem] {
        model.selection.contains(item.id) ? model.selectedItems : [item]
    }
}

private struct IconCell: View {
    let item: BrowserItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.primary.opacity(0.12) : .clear)
                )
            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor : .clear)
                )
        }
        .frame(width: 104)
        .contentShape(Rectangle())
        .help(item.isFolder ? item.name : "\(item.name)\n\(item.formattedSize) — \(item.formattedDate)")
    }
}
