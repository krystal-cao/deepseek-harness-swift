import Combine
import Sparkle

/// The single Sparkle updater owned by the native app.
///
/// The Swift shell uses one updater instance for automatic checks, the app
/// menu, and the About settings page. DSH service versions and plugin versions
/// remain managed by their existing version managers.
public final class AppUpdateManager: ObservableObject {
    public static let shared = AppUpdateManager()

    public let updaterController: SPUStandardUpdaterController

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // M1 packages are ad-hoc signed and are not publishable Sparkle
        // artifacts. A persisted automatic-check preference can otherwise
        // launch Sparkle's SwiftUI user-driver window during application
        // startup; on macOS 26 that window currently enters an AppKit
        // safe-area constraint loop and aborts the host process. Keep manual
        // “Check for Updates” available without presenting update UI on boot.
        updaterController.updater.automaticallyChecksForUpdates = false
        updaterController.startUpdater()
    }

    public var updater: SPUUpdater {
        updaterController.updater
    }
}

/// Publishes Sparkle's KVO-backed check availability for SwiftUI controls.
public final class CheckForUpdatesViewModel: ObservableObject {
    @Published public private(set) var canCheckForUpdates = false

    public init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }
}
