import S3Kit
import SwiftUI

enum AccountEditorTarget: Identifiable {
    case new(S3Provider)
    case edit(Account)

    var id: String {
        switch self {
        case .new: return "new"
        case let .edit(account): return account.id.uuidString
        }
    }
}

/// Add or edit an account. Keys are written to the Keychain on save.
struct AccountEditorView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    @State private var account: Account
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var pinnedBuckets = ""
    @State private var testStatus: TestStatus = .idle
    @State private var saveError: String?

    private enum TestStatus: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    init(target: AccountEditorTarget) {
        switch target {
        case let .new(provider):
            isNew = true
            _account = State(initialValue: Account(name: provider.displayName, provider: provider))
        case let .edit(existing):
            isNew = false
            _account = State(initialValue: existing)
            _pinnedBuckets = State(initialValue: existing.pinnedBuckets.joined(separator: ", "))
            if let credentials = try? KeychainStore.load(for: existing.id) {
                _accessKeyID = State(initialValue: credentials.accessKeyID)
                _secretAccessKey = State(initialValue: credentials.secretAccessKey)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Service", selection: $account.provider) {
                        ForEach(S3Provider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    TextField("Name", text: $account.name)
                }

                Section("Connection") {
                    connectionFields
                }

                Section {
                    TextField("Access Key ID", text: $accessKeyID)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                    SecureField("Secret Access Key", text: $secretAccessKey)
                        .textContentType(.password)
                } header: {
                    Text("Credentials")
                } footer: {
                    Text(credentialsHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Always Show", text: $pinnedBuckets, prompt: Text("bucket-one, bucket-two"))
                        .autocorrectionDisabled()
                } header: {
                    Text("Buckets")
                } footer: {
                    Text("Buckets listed here appear in the sidebar even if these keys aren’t allowed to list buckets, which is common for bucket-scoped R2 API tokens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 10) {
                Button("Test Connection") { test() }
                    .disabled(!canSave || testStatus == .testing)
                testStatusView
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Account" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 540, height: 600)
        .onChange(of: account.provider) { oldValue, newValue in
            if account.name.isEmpty || account.name == oldValue.displayName {
                account.name = newValue.displayName
            }
            testStatus = .idle
        }
        .alert("Couldn’t Save Account", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    @ViewBuilder
    private var connectionFields: some View {
        switch account.provider {
        case .aws:
            Picker("Default Region", selection: $account.region) {
                ForEach(regionChoices, id: \.self) { Text($0).tag($0) }
            }
            Text("Each bucket’s own region is detected automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .r2:
            TextField("Account ID", text: $account.r2AccountID, prompt: Text("From the Cloudflare dashboard"))
                .autocorrectionDisabled()
            Picker("Jurisdiction", selection: $account.r2Jurisdiction) {
                ForEach(R2Jurisdiction.allCases) { Text($0.displayName).tag($0) }
            }
            LabeledContent("Endpoint") {
                Text(account.configuration.endpoint?.absoluteString ?? "—")
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        case .custom:
            TextField("Endpoint URL", text: $account.customEndpoint, prompt: Text("https://s3.example.com"))
                .autocorrectionDisabled()
            TextField("Region", text: $account.region, prompt: Text("us-east-1"))
                .autocorrectionDisabled()
            Toggle("Path-style URLs", isOn: $account.usePathStyle)
            Text("Turn this on for MinIO, Ceph and most self-hosted services.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(1)
        case let .failure(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
        }
    }

    private var credentialsHelp: String {
        switch account.provider {
        case .aws: return "Create an access key in the IAM console. Keys are stored in your login Keychain."
        case .r2: return "Create an R2 API token under R2 › Manage API Tokens and use its S3 access key ID and secret. Keys are stored in your login Keychain."
        case .custom: return "Keys are stored in your login Keychain."
        }
    }

    private var regionChoices: [String] {
        Account.awsRegions.contains(account.region) ? Account.awsRegions : [account.region] + Account.awsRegions
    }

    private var credentials: S3Credentials {
        S3Credentials(
            accessKeyID: accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var preparedAccount: Account {
        var result = account
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.r2AccountID = result.r2AccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.customEndpoint = result.customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        result.pinnedBuckets = pinnedBuckets
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        return result
    }

    private var canSave: Bool {
        preparedAccount.validationMessage == nil && !credentials.accessKeyID.isEmpty && !credentials.secretAccessKey.isEmpty
    }

    private func test() {
        let account = preparedAccount
        let client = S3Client(configuration: account.configuration, credentials: credentials)
        testStatus = .testing
        Task {
            do {
                let buckets = try await client.listBuckets()
                testStatus = .success(buckets.count == 1 ? "Connected — 1 bucket" : "Connected — \(buckets.count) buckets")
            } catch {
                // Bucket-scoped keys can't list buckets; try listing a pinned bucket instead.
                if let bucket = account.pinnedBuckets.first,
                   (try? await client.listPage(bucket: bucket, prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)) != nil {
                    testStatus = .success("Connected to \(bucket)")
                } else {
                    testStatus = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func save() {
        do {
            try accounts.save(preparedAccount, credentials: credentials)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
