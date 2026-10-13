#if DEBUG
import AppKit

/// Sample data for screenshots, in development builds only: `--demo` with `--panel-preview` or `--suite-preview`.
enum Demo {
    static let isOn = CommandLine.arguments.contains("--demo")
    /// Preferences that are never saved, so the sample board and view never replace the real ones.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        let suite = "app.voidamp.demo-board"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        // The video's window is larger, so its board is zoomed in to fill it.
        defaults.set(CommandLine.arguments.contains("--demo-play") ? [1.25, 22.0, 90.0] : [0.92, 30.0, 50.0], forKey: "suiteBoardView")
        return defaults
    }()
    /// The Suite's view, so the demo video can drag a wire on it.
    @MainActor static weak var viewport: SuiteViewport?
    @MainActor private static var signal: DispatchSourceSignal?
    @MainActor private static var timer: Timer?

    /// With `--demo-play`, plays a 7-second sequence once the recorder sends SIGUSR1: Spotify's level goes up, then
    /// a wire is dragged from Safari to the AirPods and one from Spotify to the display speakers.
    @MainActor static func waitToPlay() {
        guard CommandLine.arguments.contains("--demo-play") else { return }
        Darwin.signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { play() } }
        source.resume()
        signal = source
    }

    @MainActor private static func play() {
        guard timer == nil else { return }
        let audio = VoidampRuntime.shared.audio
        let start = Date()
        func eased(_ t: Double, from: Double, to: Double) -> Double? {
            guard t >= from else { return nil }
            let x = min(1, (t - from) / (to - from))
            return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
        }
        var connected: Set<String> = []
        func drag(_ from: String, _ to: String, _ t: Double, between a: Double, and b: Double) {
            guard let progress = eased(t, from: a, to: b), !connected.contains(from + to) else { return }
            if progress < 1 { viewport?.demoDrag = (from, to, CGFloat(progress)); return }
            viewport?.demoDrag = nil
            connected.insert(from + to)
            let id = String(from.dropFirst(4)), uid = String(to.dropFirst(4))
            if let app = audio.apps.first(where: { $0.id == id }), let output = audio.sources.first(where: { !$0.input && $0.uid == uid }) {
                audio.connect(app, to: output)
            }
        }
        let tick = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let t = Date().timeIntervalSince(start)
                if let x = eased(t, from: 0.8, to: 1.9), let spotify = audio.apps.first(where: { $0.id == "com.spotify.client" }) {
                    audio.setAppGain(spotify, 0.8 + 0.5 * x)
                }
                drag("app:com.apple.Safari", "out:demo.airpods", t, between: 2.3, and: 3.2)
                drag("app:com.spotify.client", "out:demo.display", t, between: 4.1, and: 5.0)
                if t > 7.5 { timer?.invalidate() }
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }
}
#endif
