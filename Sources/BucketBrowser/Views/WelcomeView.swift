import AppKit
import S3Kit
import SwiftUI

/// Fills the window before any account exists: the app icon, a short welcome and one card per service.
struct WelcomeView: View {
    @Binding var accountEditor: AccountEditorTarget?
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Welcome to Bucket Browser")
                    .font(.largeTitle.weight(.semibold))
                Text("Browse your buckets the way you browse files in Finder. Choose a service to connect your first account.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 14) {
                ForEach(S3Provider.allCases) { provider in
                    ProviderCard(provider: provider) { accountEditor = .new(provider) }
                }
            }

            Label(footnote, systemImage: accounts.isSyncingWithICloud ? "checkmark.icloud" : "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footnote: String {
        accounts.isSyncingWithICloud
            ? "Keys stay in your keychain and sync with iCloud Keychain. Accounts added on your other Macs appear here."
            : "Keys stay in your keychain on this Mac."
    }
}

private struct ProviderCard: View {
    let provider: S3Provider
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 36)
                Text(provider.displayName)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(width: 180, height: 160)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isHovered ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Add a \(provider.displayName) account")
    }

    private var symbol: String {
        switch provider {
        case .aws: return "cloud"
        case .r2: return "cloud.fill"
        case .custom: return "server.rack"
        }
    }

    private var detail: String {
        switch provider {
        case .aws: return "An IAM access key and a region"
        case .r2: return "Your account ID and an R2 API token"
        case .custom: return "MinIO, Backblaze B2, Wasabi and others"
        }
    }
}
