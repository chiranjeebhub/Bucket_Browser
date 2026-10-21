import SwiftUI
#if SPARKLE
import Combine
import Sparkle
#endif

/// Bucket Browser › Check for Updates… in the direct-download build, which updates itself with
/// Sparkle from the appcast on the website. The Mac App Store build has no such item.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            #if SPARKLE
            CheckForUpdatesButton(updater: Updates.controller.updater)
            #endif
        }
    }
}

#if SPARKLE
enum Updates {
    /// Starts the updater at launch. It asks before checking automatically, on the second launch.
    static let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
}

private final class UpdaterState: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}

private struct CheckForUpdatesButton: View {
    let updater: SPUUpdater
    @StateObject private var state: UpdaterState

    init(updater: SPUUpdater) {
        self.updater = updater
        _state = StateObject(wrappedValue: UpdaterState(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!state.canCheckForUpdates)
    }
}
#endif
