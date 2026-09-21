import AppKit
import Combine
import Sparkle

/// Sparkle-based updates. The feed (`SUFeedURL`) and EdDSA public key
/// (`SUPublicEDKey`) live in Info.plist; every archive in the feed must be
/// signed with the matching private key, and the new app must carry the same
/// code signature identity or Sparkle refuses to install it.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    @Published var automaticallyChecks = true {
        didSet { if automaticallyChecks != oldValue { updater.automaticallyChecksForUpdates = automaticallyChecks } }
    }
    @Published var automaticallyInstalls = true {
        didSet { if automaticallyInstalls != oldValue { updater.automaticallyDownloadsUpdates = automaticallyInstalls } }
    }

    /// Returns true while an update install would interrupt the user (e.g. the
    /// translation window is open); the install is retried later.
    var isBusy: () -> Bool = { false }

    private var controller: SPUStandardUpdaterController!
    private var retry: Timer?

    var updater: SPUUpdater { controller.updater }

    /// False for bare `swift build` binaries that have no feed configured.
    var isAvailable: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    func start() {
        guard isAvailable else { return }
        controller.startUpdater()
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyInstalls = updater.automaticallyDownloadsUpdates
        if ProcessInfo.processInfo.environment["QEVIGO_CHECK_UPDATES_ON_LAUNCH"] == "1" {
            updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        guard isAvailable else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    private func installWhenIdle(_ install: @escaping () -> Void) {
        retry?.invalidate()
        guard isBusy() else {
            install()
            return
        }
        retry = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.installWhenIdle(install) }
        }
    }
}

extension UpdateController: SPUUpdaterDelegate {
    /// Test hook: point an installed build at a local feed.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["QEVIGO_FEED_URL"]
    }

    /// Sparkle normally installs a downloaded update when the app quits, but a
    /// menu bar app rarely quits. Install right away (once idle) and relaunch.
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated { installWhenIdle(immediateInstallHandler) }
        return true
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Update windows of a Dock-less app would otherwise open behind other apps.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        MainActor.assumeIsolated { NSApp.activate(ignoringOtherApps: true) }
    }
}
