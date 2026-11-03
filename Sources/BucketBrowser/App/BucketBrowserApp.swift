import AppKit
import SwiftUI

@main
struct BucketBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var accounts: AccountStore { appDelegate.accounts }
    private var transfers: TransferManager { appDelegate.transfers }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("Bucket Browser") {
            BrowserWindow()
                .environment(accounts)
                .environment(transfers)
        }
        .defaultSize(width: 1100, height: 680)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { accounts.reloadFromICloud() }
        }
        .commands {
            SidebarCommands()
            ToolbarCommands()
            BrowserCommands()
            UpdateCommands()
        }

        Settings {
            SettingsView()
                .environment(accounts)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Owned here rather than by the App so the menu bar item can reach them too.
    let accounts = AccountStore()
    let transfers = TransferManager()
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run`, which starts the binary outside an app bundle.
        NSApp.setActivationPolicy(.regular)
        if let appearance = DemoMode.appearance { NSApp.appearance = appearance }
        #if SPARKLE
        _ = Updates.controller
        #endif
        menuBar = MenuBarController(accounts: accounts, transfers: transfers)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Menu commands

struct BrowserModelKey: FocusedValueKey {
    typealias Value = BrowserModel
}

extension FocusedValues {
    var browserModel: BrowserModel? {
        get { self[BrowserModelKey.self] }
        set { self[BrowserModelKey.self] = newValue }
    }
}

struct BrowserCommands: Commands {
    @FocusedValue(\.browserModel) private var model

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { model?.beginNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model?.location == nil)
            Button("Upload…") { model?.chooseFilesToUpload() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(model?.location == nil)
            Button("Download…") { if let model { model.download(model.selectedItems) } }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(model?.selection.isEmpty ?? true)
            Divider()
            Button("Open") { model?.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model?.selection.isEmpty ?? true)
            Button("Quick Look") { model?.quickLook() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(model?.selection.isEmpty ?? true)
            Button("Get Info") { model?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(model?.location == nil)
            Button("Rename") { if let item = model?.selectedItems.first { model?.beginRename(item) } }
                .disabled(model?.selection.count != 1)
            Button("Delete…") { if let model { model.requestDelete(model.selectedItems) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model?.selection.isEmpty ?? true)
        }

        CommandGroup(after: .pasteboard) {
            Button("Copy S3 URI") { if let model { model.copyKeys(model.selectedItems) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model?.selection.isEmpty ?? true)
        }

        CommandGroup(before: .toolbar) {
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Button("as \(mode.title)") { model?.viewMode = mode }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            Button("Refresh") { model?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model?.location == nil)
            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(model?.canGoBack ?? false))
            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(model?.canGoForward ?? false))
            Button("Enclosing Folder") { model?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!(model?.canGoUp ?? false))
        }
    }
}
