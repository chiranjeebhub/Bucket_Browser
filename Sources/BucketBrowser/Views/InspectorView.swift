import S3Kit
import SwiftUI

/// The Get Info panel for the current selection.
struct InspectorView: View {
    let model: BrowserModel
    @State private var metadata: S3ObjectMetadata?
    @State private var metadataError: String?

    var body: some View {
        let items = model.selectedItems
        Group {
            if items.count == 1, let item = items.first {
                details(for: item)
            } else if items.isEmpty {
                folderSummary
            } else {
                multipleSummary(items)
            }
        }
        .task(id: items.count == 1 ? items.first : nil) {
            metadata = nil
            metadataError = nil
            guard items.count == 1, let item = items.first, !item.isFolder else { return }
            do {
                metadata = try await model.metadata(for: item)
            } catch {
                metadataError = error.localizedDescription
            }
        }
    }

    private func details(for item: BrowserItem) -> some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: item.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                    Text(item.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Text(item.isFolder ? "Folder" : "\(item.kindDescription) — \(item.formattedSize)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            Section("General") {
                LabeledContent("Kind", value: item.kindDescription)
                if let size = item.size {
                    LabeledContent("Size") {
                        Text("\(item.formattedSize) (\(size.formatted()) bytes)")
                    }
                }
                if item.lastModified != nil {
                    LabeledContent("Modified", value: item.formattedDate)
                }
                if let storageClass = metadata?.storageClass ?? item.storageClass {
                    LabeledContent("Storage Class", value: storageClass)
                }
                if let contentType = metadata?.contentType {
                    LabeledContent("Content Type", value: contentType)
                }
                if let etag = metadata?.etag ?? item.etag {
                    LabeledContent("ETag") {
                        Text(etag).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                }
            }

            Section("Location") {
                LabeledContent("Bucket", value: model.location?.bucket ?? "")
                LabeledContent("Key") {
                    Text(item.key).textSelection(.enabled).multilineTextAlignment(.trailing)
                }
            }

            if let metadata, !metadata.userMetadata.isEmpty {
                Section("Metadata") {
                    ForEach(metadata.userMetadata.keys.sorted(), id: \.self) { key in
                        LabeledContent(key) {
                            Text(metadata.userMetadata[key] ?? "").textSelection(.enabled)
                        }
                    }
                }
            }

            if let metadataError {
                Section {
                    Label(metadataError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Section {
                if !item.isFolder {
                    Button("Quick Look") { model.quickLook([item]) }
                }
                Button("Download…") { model.download([item]) }
                Button("Copy S3 URI") { model.copyKeys([item]) }
                if !item.isFolder {
                    Menu("Copy Shareable Link") {
                        Button("Expires in 1 Hour") { model.copyPresignedLink(item, expiresIn: 3600) }
                        Button("Expires in 1 Day") { model.copyPresignedLink(item, expiresIn: 86400) }
                        Button("Expires in 7 Days") { model.copyPresignedLink(item, expiresIn: 604_800) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var folderSummary: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: FileIcons.bucket)
                        .resizable()
                        .frame(width: 72, height: 72)
                    Text(model.title).font(.headline)
                    Text(model.statusText).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            if let location = model.location, let account = model.account {
                Section("Location") {
                    LabeledContent("Account", value: account.name)
                    LabeledContent("Service", value: account.provider.displayName)
                    LabeledContent("Bucket", value: location.bucket)
                    LabeledContent("Prefix", value: location.prefix.isEmpty ? "/" : location.prefix)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func multipleSummary(_ items: [BrowserItem]) -> some View {
        let bytes = items.compactMap(\.size).reduce(0, +)
        let folders = items.filter(\.isFolder).count
        return Form {
            Section {
                LabeledContent("Selected", value: "\(items.count) items")
                if folders > 0 { LabeledContent("Folders", value: "\(folders)") }
                LabeledContent("Size of Files", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
            Section {
                Button("Download \(items.count) Items…") { model.download(items) }
                Button("Copy S3 URIs") { model.copyKeys(items) }
            }
        }
        .formStyle(.grouped)
    }
}
