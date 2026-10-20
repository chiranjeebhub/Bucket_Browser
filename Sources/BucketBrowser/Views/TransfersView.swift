import AppKit
import SwiftUI

/// The popover listing uploads and downloads, like Safari's downloads list.
struct TransfersView: View {
    @Environment(TransferManager.self) private var transfers

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear") { transfers.clearFinished() }
                    .disabled(!transfers.transfers.contains { !$0.isActive })
            }
            if transfers.transfers.isEmpty {
                Text("Uploads and downloads appear here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(transfers.transfers) { transfer in
                            TransferRow(transfer: transfer)
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

private struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if transfer.isActive {
                    ProgressView(value: transfer.fractionCompleted)
                        .controlSize(.small)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(status)
            }
            Spacer(minLength: 4)
            if transfer.isActive {
                Button { transfer.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel")
            } else if let url = transfer.localURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Show in Finder")
            }
        }
    }

    private var iconColor: Color {
        switch transfer.state {
        case .running: return .accentColor
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private var status: String {
        let total = ByteCountFormatter.string(fromByteCount: transfer.totalBytes, countStyle: .file)
        switch transfer.state {
        case .running:
            let done = ByteCountFormatter.string(fromByteCount: transfer.completedBytes, countStyle: .file)
            return "\(done) of \(total)"
        case .finished:
            let verb = transfer.direction == .upload ? "Uploaded to" : "Saved to"
            return "\(total) — \(verb) \(transfer.destinationDescription)"
        case let .failed(message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }
}
