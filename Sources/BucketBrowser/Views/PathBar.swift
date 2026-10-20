import AppKit
import S3Kit
import SwiftUI

/// Finder's path bar and status bar: clickable breadcrumbs plus an item count.
struct PathBar: View {
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 4) {
            if let location = model.location, let account = model.account {
                Label(account.name, systemImage: account.symbolName)
                    .foregroundStyle(.secondary)
                separator
                crumb(location.bucket, prefix: "", icon: Image(nsImage: FileIcons.bucket))
                ForEach(S3Path.ancestors(of: location.prefix).dropFirst(), id: \.self) { prefix in
                    separator
                    crumb(S3Path.name(of: prefix), prefix: prefix, icon: Image(nsImage: FileIcons.icon(for: BrowserItem(folder: prefix))))
                }
            }
            Spacer(minLength: 12)
            if model.isWorking || model.isPreparingQuickLook || model.isLoadingCurrent {
                ProgressView().controlSize(.mini)
            }
            Text(model.statusText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private func crumb(_ title: String, prefix: String, icon: Image) -> some View {
        Button {
            model.goTo(prefix: prefix)
        } label: {
            HStack(spacing: 3) {
                icon.resizable().frame(width: 14, height: 14)
                Text(title)
            }
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            model.upload(urls, into: prefix)
            return true
        }
        .help("Go to \(title) — drop files here to upload into it")
    }
}
