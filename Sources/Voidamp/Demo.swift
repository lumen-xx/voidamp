#if DEBUG
import Foundation

/// Sample data for screenshots, in development builds only: `--demo` with `--panel-preview` or `--suite-preview`.
enum Demo {
    static let isOn = CommandLine.arguments.contains("--demo")
    /// Preferences that are never saved, so the sample board and view never replace the real ones.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        let suite = "app.voidamp.demo-board"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set([0.92, 30.0, 50.0], forKey: "suiteBoardView")
        return defaults
    }()
}
#endif
