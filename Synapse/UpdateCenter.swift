import Sparkle
import SwiftUI

/// Sparkle reads the appcast published with each GitHub release (SUFeedURL in Info.plist) and shows its own update window.
@MainActor @Observable
final class UpdateCenter {
    @ObservationIgnored private let delegate = FeedOverride()
    @ObservationIgnored private let controller: SPUStandardUpdaterController

    var automatic: Bool { didSet { controller.updater.automaticallyChecksForUpdates = automatic } }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        automatic = controller.updater.automaticallyChecksForUpdates
        #if DEBUG
        // `-checkForUpdatesOnLaunch YES` (with `-testFeedURL` and `-SUAutomaticallyUpdate YES`) runs a full update without clicks.
        if UserDefaults.standard.bool(forKey: "checkForUpdatesOnLaunch") { controller.updater.checkForUpdatesInBackground() }
        #endif
    }

    func check() { controller.checkForUpdates(nil) }
}

/// DEBUG builds can point Sparkle at a local appcast with `-testFeedURL <url>`; release builds always use Info.plist.
private final class FeedOverride: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "testFeedURL")
        #else
        nil
        #endif
    }
}

/// Opens Sparkle's check window; it reports "up to date" or offers the update.
struct CheckForUpdatesCommand: View {
    @Environment(AppState.self) private var state
    var body: some View {
        Button("Check for Updates…") { state.updates.check() }
    }
}
