import AppKit
import Observation
import Sparkle

/// Over-the-air updates through Sparkle. Every 6 hours, and from the menu,
/// it reads `appcast.xml` from the latest GitHub release. A newer version is
/// downloaded, checked against the public key in Info.plist (`SUPublicEDKey`)
/// and Apple's notarization, installed over this copy, and relaunched.
@MainActor
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    /// A version that was found but not installed yet, for the menu.
    private(set) var available: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Menu: check now and show the result, even "you're up to date".
    func checkForUpdates() {
        // A menu bar app isn't active, so the update window would open behind.
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Mac Utility lives in the menu bar, so an update found in the
    /// background must not grab focus. Sparkle shows its window quietly;
    /// the HUD and the menu say an update is there.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            available = version
            if !userInitiated { HUD.show("Mac Utility \(version) is ready to install") }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { available = nil }
    }
}
