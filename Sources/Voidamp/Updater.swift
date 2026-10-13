import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    /// Set while Sparkle quits Voidamp to install an update and open it again.
    private(set) var relaunching = false
    private let controller: SPUStandardUpdaterController
    private let delegate = UpdaterDelegate()

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        delegate.willRelaunch = { [weak self] in self?.relaunching = true }
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        // Command-line diagnostics have no application bundle configuration.
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            controller.startUpdater()
        }
    }

    func checkForUpdates() {
        NSApplication.shared.activate()
        controller.checkForUpdates(nil)
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var willRelaunch: @MainActor () -> Void = {}
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { willRelaunch() }
    }
}
