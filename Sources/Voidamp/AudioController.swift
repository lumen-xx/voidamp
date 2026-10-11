import Foundation
import CoreAudio
import Combine
import AppKit

struct AudioSource: Identifiable, Equatable {
    let device: AudioDeviceID
    let uid: String
    let name: String
    let input: Bool
    let channels: [UInt32]
    var volume: Double
    var isDefault: Bool
    var isBuiltIn: Bool = false
    var id: String { "\(uid)-\(input)" }
}

@MainActor
final class AudioController: ObservableObject {
    @Published var sources: [AudioSource] = []
    @Published var error: String?
    @Published var apps: [AppSource] = []
    @Published var mixingEnabled = false
    @Published var soundMuted = false
    @Published var micMuted = false
    @Published var profiles: [MixerProfile] = []
    @Published var selectedProfile: UUID?
    @Published private var deviceNames: [String: String] = [:]
    /// Apps Voidamp couldn't mix; their original audio keeps playing.
    @Published private(set) var routeFailures: [String: RouteFailure] = [:]
    /// Set when no route has ever delivered audio this session, which points at the
    /// Screen & System Audio Recording permission. No new routes start until Retry.
    @Published private(set) var captureBlocked = false
    /// One "System Sounds" row that is always listed, or never listed and never mixed.
    @Published var showSystemSounds: Bool {
        didSet { preferences.set(showSystemSounds, forKey: "showSystemSounds"); refreshApps() }
    }
    private var routes: [String: AppRoute] = [:]
    private var appSettings: [String: AppSetting] = [:]
    private var nativeMuteStates: [String: UInt32] = [:]
    private var mutedDevices: [String: Double] = [:]
    private var failedProcesses: [String: Set<AudioObjectID>] = [:]
    private var captureConfirmed = false
    private var routeOutputUID: String?
    private var lastPlayed: [String: Date] = [:]
    private var recentApps: [String: AppSource] = [:]
    private var watcher: ProcessWatcher?
    private let preferences: UserDefaults
    private var terminationObserver: NSObjectProtocol?
    private var timer: Timer?
    private var savedVolumes: [String: Double] = [:]

    init(preferences: UserDefaults = .standard, autoStartMixing: Bool = true) {
        self.preferences = preferences
        self.deviceNames = preferences.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
        self.mixingEnabled = autoStartMixing
        self.showSystemSounds = preferences.object(forKey: "showSystemSounds") as? Bool ?? true
        if let data = preferences.data(forKey: "profiles"), let stored = try? JSONDecoder().decode([MixerProfile].self, from: data) { profiles = stored }
        if let data = preferences.data(forKey: "appSettings"), let stored = try? JSONDecoder().decode([String: AppSetting].self, from: data) { appSettings = stored }
        refresh()
        if autoStartMixing { watcher = ProcessWatcher { [weak self] in self?.refreshApps() } }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDown() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func address(_ selector: AudioObjectPropertySelector, input: Bool = false, channel: UInt32 = 0) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: channel)
    }

    private func scalar<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) -> T? {
        var property = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &property, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value
    }

    private func global(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    func refresh() {
        var property = global(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else {
            error = "Couldn’t read audio devices. Try refreshing."
            return
        }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return }
        var result: [AudioSource] = []
        for input in [false, true] {
            let defaultID = scalar(AudioObjectID(kAudioObjectSystemObject), global(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice), initial: AudioDeviceID(0))
            for device in devices {
                var streams = address(kAudioDevicePropertyStreams, input: input)
                var streamSize: UInt32 = 0
                guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }
                var nameAddress = global(kAudioObjectPropertyName)
                var name: CFString = "Audio device" as CFString
                var nameSize = UInt32(MemoryLayout<CFString>.size)
                let nameStatus = withUnsafeMutablePointer(to: &name) { pointer in
                    AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, pointer)
                }
                guard nameStatus == noErr else { continue }
                let channels = volumeChannels(device, input: input)
                let values = channels.compactMap { scalar(device, address(kAudioDevicePropertyVolumeScalar, input: input, channel: $0), initial: Float32(0)) }
                let volume = values.isEmpty ? 1 : Double(values.reduce(0, +) / Float(values.count))
                let uid = HAL.string(device, kAudioDevicePropertyDeviceUID) ?? String(device)
                if uid.hasPrefix("app.voidamp.route.") { continue }
                result.append(AudioSource(device: device, uid: uid, name: name as String, input: input, channels: channels, volume: volume, isDefault: device == defaultID, isBuiltIn: scalar(device, global(kAudioDevicePropertyTransportType), initial: UInt32(0)) == kAudioDeviceTransportTypeBuiltIn))
            }
        }
        let sorted = result.sorted {
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.id < $1.id
        }
        // Publishing identical values every second re-rendered the panel and menu bar icon for nothing.
        if sorted != sources { sources = sorted }
        enforceMute()
        refreshApps()
    }

    private func volumeChannels(_ device: AudioDeviceID, input: Bool) -> [UInt32] {
        func writable(_ channel: UInt32) -> Bool {
            var property = address(kAudioDevicePropertyVolumeScalar, input: input, channel: channel)
            var settable: DarwinBoolean = false
            return AudioObjectHasProperty(device, &property) && AudioObjectIsPropertySettable(device, &property, &settable) == noErr && settable.boolValue
        }
        if writable(0) { return [0] }
        var property = address(kAudioDevicePropertyStreamConfiguration, input: input)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, memory) == noErr else { return [] }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        let count = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        return count > 0 ? (1...UInt32(count)).filter(writable) : []
    }

    /// The level to show for a device: while a software mute holds the device at 0, this is the level it returns to.
    func displayVolume(_ source: AudioSource) -> Double {
        let live = sources.first(where: { $0.id == source.id }) ?? source
        if (live.input ? micMuted : soundMuted), nativeMuteStates[live.id] == nil, let held = mutedDevices[live.id] { return held }
        return live.volume
    }
    func setVolume(_ source: AudioSource, _ volume: Double) {
        if (source.input ? micMuted : soundMuted) && nativeMuteStates[source.id] == nil { mutedDevices[source.id] = min(1, max(0, volume)); objectWillChange.send(); return }
        writeVolume(source, volume)
    }

    private func writeVolume(_ source: AudioSource, _ volume: Double) {
        let clamped = min(1, max(0, volume))
        for channel in source.channels {
            var property = address(kAudioDevicePropertyVolumeScalar, input: source.input, channel: channel)
            var value = Float32(clamped)
            let status = AudioObjectSetPropertyData(source.device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
            if status != noErr { error = "Couldn’t change \(source.name)’s volume (\(status))."; refresh(); return }
        }
        if let index = sources.firstIndex(where: { $0.id == source.id }) { sources[index].volume = clamped }
    }

    func toggleMute(_ source: AudioSource) {
        if source.volume > 0 {
            savedVolumes[source.id] = source.volume
            setVolume(source, 0)
        } else {
            setVolume(source, savedVolumes[source.id] ?? 0.5)
        }
    }

    func select(_ source: AudioSource) {
        var property = global(source.input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var value = source.device
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        if status != noErr { error = "Couldn’t switch to \(source.name) (\(status))." }
        refresh()
    }
}

struct AppSetting: Codable, Equatable {
    var gain: Double
    var muted: Bool
    static let unchanged = AppSetting(gain: 1, muted: false)
}
struct MixerProfile: Codable, Identifiable {
    var id = UUID()
    var name: String
    var devices: [String: Double]
    var outputUID: String?
    var inputUID: String?
    var apps: [String: AppSetting]
    var soundMuted: Bool
    var micMuted: Bool
    var mixingEnabled: Bool?
}

extension AudioController {
    func toggleSoundMute() { soundMuted.toggle(); updateMute(input: false) }
    func toggleMicMute() { micMuted.toggle(); updateMute(input: true) }

    private func updateMute(input: Bool) {
        let muted = input ? micMuted : soundMuted
        for source in sources where source.input == input {
            if useHardwareMute(source, muted: muted) { continue }
            guard !source.channels.isEmpty else { continue }
            if muted {
                if mutedDevices[source.id] == nil { mutedDevices[source.id] = source.volume }
                writeVolume(source, 0)
            } else if let previous = mutedDevices.removeValue(forKey: source.id) {
                writeVolume(source, previous)
            }
        }
        if !input { applyRouteGains() }
    }

    private func enforceMute() {
        for source in sources where (source.input ? micMuted : soundMuted) {
            if useHardwareMute(source, muted: true) { continue }
            guard !source.channels.isEmpty else { continue }
            if mutedDevices[source.id] == nil { mutedDevices[source.id] = source.volume }
            if source.volume != 0 { writeVolume(source, 0) }
        }
    }

    private func useHardwareMute(_ source: AudioSource, muted: Bool) -> Bool {
        var property = address(kAudioDevicePropertyMute, input: source.input)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(source.device, &property),
              AudioObjectIsPropertySettable(source.device, &property, &settable) == noErr,
              settable.boolValue,
              let current = scalar(source.device, property, initial: UInt32(0)) else { return false }
        if muted, nativeMuteStates[source.id] == nil { nativeMuteStates[source.id] = current }
        var value: UInt32 = muted ? 1 : (nativeMuteStates.removeValue(forKey: source.id) ?? current)
        if value != current {
            let status = AudioObjectSetPropertyData(source.device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            if status != noErr { error = "Couldn’t mute \(source.name) (\(status))."; return false }
        }
        return true
    }

    // MARK: App mixing
    //
    // An app only gets a route (a process tap that silences it, replayed at its own gain) once its level or
    // mute differs from normal. Untouched apps play exactly as macOS plays them, so a capture problem can
    // never silence them. A route that never delivers audio is removed within two seconds and the app is
    // marked instead of interrupting with an alert.

    /// How long an app stays listed, and keeps its route, after it stops playing. Pausing and resuming
    /// then neither flickers the row nor briefly plays at the original level.
    private static let lingerInterval: TimeInterval = 20

    func enableMixing() {
        mixingEnabled = true
        clearFailures()
        refreshApps()
    }
    func disableMixing() {
        routes.removeAll() // Destroying taps restores the original application audio.
        mixingEnabled = false
        clearFailures()
    }
    /// Tries every app again, for example after allowing audio access in System Settings.
    func retryMixing() {
        clearFailures()
        refreshApps()
    }
    private func clearFailures() {
        failedProcesses.removeAll()
        if !routeFailures.isEmpty { routeFailures.removeAll() }
        if captureBlocked { captureBlocked = false }
    }

    func refreshApps() {
        let now = Date()
        let liveObjects = HAL.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        let running = NSWorkspace.shared.runningApplications
        var groups: [String: (name: String, icon: NSImage?, processes: [AudioObjectID])] = [:]
        for id in liveObjects {
            guard let pid = HAL.read(id, kAudioProcessPropertyPID, initial: pid_t(0)), pid != getpid(),
                  HAL.read(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) == 1,
                  HAL.string(id, kAudioProcessPropertyBundleID) != "app.voidamp.mac" else { continue }
            switch AudioOwner(pid: pid, processObject: id, running: running) {
            case .app(let key, let name, let icon):
                groups[key, default: (name, icon, [])].processes.append(id)
            case .system:
                guard showSystemSounds else { continue }
                groups[AppSource.systemSoundsID, default: ("System Sounds", nil, [])].processes.append(id)
            }
        }
        let live = Set(liveObjects)
        var listed: [AppSource] = groups.map { key, group in
            let setting = appSettings[key] ?? .unchanged
            let source = AppSource(id: key, name: group.name, icon: group.icon, processes: group.processes.sorted(), gain: setting.gain, muted: setting.muted)
            lastPlayed[key] = now
            recentApps[key] = source
            return source
        }
        for (key, recent) in recentApps where groups[key] == nil {
            let quiet = now.timeIntervalSince(lastPlayed[key] ?? .distantPast)
            // Keep a paused app briefly, but drop it at once when it quits or when system sounds are hidden.
            let stillRunning = recent.processes.contains(where: live.contains)
            if quiet < Self.lingerInterval, stillRunning, !recent.isSystem || showSystemSounds {
                listed.append(idle(recent))
            } else {
                recentApps.removeValue(forKey: key)
                lastPlayed.removeValue(forKey: key)
            }
        }
        if showSystemSounds, !listed.contains(where: \.isSystem) {
            listed.append(idle(AppSource(id: AppSource.systemSoundsID, name: "System Sounds", icon: nil, processes: [], gain: 1, muted: false)))
        }
        listed.sort {
            if $0.isSystem != $1.isSystem { return $1.isSystem }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if listed != apps { apps = listed }
        updateRoutes(live: live, now: now)
    }

    private func idle(_ source: AppSource) -> AppSource {
        let setting = appSettings[source.id] ?? .unchanged
        return AppSource(id: source.id, name: source.name, icon: source.icon, processes: [], gain: setting.gain, muted: setting.muted)
    }

    private func needsRoute(_ id: String) -> Bool {
        let setting = appSettings[id] ?? .unchanged
        return setting.muted || abs(setting.gain - 1) > 0.001
    }
    private func effectiveGain(_ id: String) -> Double {
        let setting = appSettings[id] ?? .unchanged
        return soundMuted || setting.muted ? 0 : setting.gain
    }
    private func applyRouteGains() {
        for (id, route) in routes { route.setGain(effectiveGain(id)) }
    }

    private func updateRoutes(live: Set<AudioObjectID>, now: Date) {
        guard mixingEnabled, let output = sources.first(where: { !$0.input && $0.isDefault }) else {
            routes.removeAll()
            return
        }
        if routeOutputUID != output.uid {
            // A new output can behave differently, so give every app another chance.
            routeOutputUID = output.uid
            failedProcesses.removeAll()
            if !routeFailures.isEmpty { routeFailures.removeAll() }
        }
        let listed = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        for (id, route) in routes where listed[id] == nil || route.outputUID != output.uid {
            routes.removeValue(forKey: id)
        }
        for app in apps {
            var keep: Set<AudioObjectID> = []
            if let route = routes[app.id] {
                switch route.health(now: now) {
                case .neverStarted:
                    routes.removeValue(forKey: app.id)
                    fail(app, captureConfirmed ? .message("No audio arrived from \(app.name).") : .noAudio)
                    continue
                case .stalled:
                    // Callbacks stopped after working, e.g. after sleep. Rebuild so the app isn't left silent.
                    routes.removeValue(forKey: app.id)
                case .healthy:
                    captureConfirmed = true
                    let current = route.processes.filter(live.contains)
                    if current.count != route.processes.count {
                        routes.removeValue(forKey: app.id) // A helper quit; its tap can't be reused.
                        keep = Set(current)
                    } else if Set(app.processes).isSubset(of: route.processes) {
                        continue // Paused apps keep their route until they leave the list.
                    } else {
                        routes.removeValue(forKey: app.id)
                        keep = Set(current)
                    }
                case .starting:
                    continue
                }
            }
            // An app back at 100% and unmuted plays directly again; nothing to rebuild.
            guard app.isPlaying, needsRoute(app.id) else { continue }
            startRoute(for: app, including: keep, output: output)
        }
    }

    private func startRoute(for app: AppSource, including extra: Set<AudioObjectID> = [], output: AudioSource) {
        let processes = Set(app.processes).union(extra)
        guard !captureBlocked, !processes.isEmpty else { return }
        if let failed = failedProcesses[app.id] {
            guard failed != processes else { return }
            // Different processes play now (a helper restarted), so try once more.
            failedProcesses.removeValue(forKey: app.id)
            routeFailures.removeValue(forKey: app.id)
        }
        do {
            routes[app.id] = try AppRoute(processes: processes.sorted(), output: output.device, gain: effectiveGain(app.id))
        } catch {
            fail(app, .message(error.localizedDescription))
        }
    }

    private func fail(_ app: AppSource, _ failure: RouteFailure) {
        failedProcesses[app.id] = Set(app.processes)
        routeFailures[app.id] = failure
        if failure == .noAudio {
            // Nothing has ever been captured: every other route would fail the same way and briefly
            // silence its app. Hold off until Retry.
            captureBlocked = true
            routes.removeAll()
        }
    }

    func routingDiagnostics() -> [String] {
        apps.map { app in
            if let route = routes[app.id] { return "\(app.name): \(route.callbackCount) audio callbacks" }
            if let failure = routeFailures[app.id] { return "\(app.name): not routed (\(failure))" }
            return "\(app.name): plays directly"
        }
    }
    /// Whether the app's controls work: mixing is on and Voidamp hasn't failed to capture it.
    func canAdjust(_ app: AppSource) -> Bool {
        mixingEnabled && !captureBlocked && routeFailures[app.id] == nil
    }
    func setAppGain(_ app: AppSource, _ value: Double, snapping: Bool = false) {
        guard canAdjust(app) else { return }
        let gain = MixerGain.adjusted(value, snapping: snapping)
        updateSetting(app) { $0.gain = gain }
    }
    func toggleAppMute(_ app: AppSource) {
        guard canAdjust(app) else { return }
        updateSetting(app) { $0.muted.toggle() }
    }
    private func updateSetting(_ app: AppSource, _ change: (inout AppSetting) -> Void) {
        var setting = appSettings[app.id] ?? .unchanged
        change(&setting)
        appSettings[app.id] = setting
        persistAppSettings()
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].gain = setting.gain
            apps[index].muted = setting.muted
        }
        if let route = routes[app.id] {
            route.setGain(effectiveGain(app.id))
        } else if let live = apps.first(where: { $0.id == app.id }), live.isPlaying, needsRoute(app.id),
                  let output = sources.first(where: { !$0.input && $0.isDefault }) {
            startRoute(for: live, output: output)
        }
    }
    private func persistAppSettings() {
        // Normal levels need no entry; dropping them keeps the stored list to apps the user changed.
        let changed = appSettings.filter { $0.value != .unchanged }
        if let data = try? JSONEncoder().encode(changed) { preferences.set(data, forKey: "appSettings") }
    }
    func saveProfile(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let profile = MixerProfile(name: name,
            devices: Dictionary(uniqueKeysWithValues: sources.filter { !$0.channels.isEmpty }.map { ($0.id, mutedDevices[$0.id] ?? $0.volume) }),
            outputUID: sources.first { !$0.input && $0.isDefault }?.uid,
            inputUID: sources.first { $0.input && $0.isDefault }?.uid,
            apps: appSettings.filter { $0.value != .unchanged }, soundMuted: soundMuted, micMuted: micMuted, mixingEnabled: mixingEnabled)
        profiles.append(profile)
        selectedProfile = profile.id
        persistProfiles()
    }
    func applyProfile(_ profile: MixerProfile) {
        if profile.mixingEnabled == false { disableMixing() }
        if soundMuted { toggleSoundMute() }
        if micMuted { toggleMicMute() }
        appSettings = profile.apps
        persistAppSettings()
        for source in sources {
            if let volume = profile.devices[source.id] { writeVolume(source, volume) }
        }
        if let output = sources.first(where: { !$0.input && $0.uid == profile.outputUID }) { select(output) }
        if let input = sources.first(where: { $0.input && $0.uid == profile.inputUID }) { select(input) }
        if profile.mixingEnabled == true, !mixingEnabled { enableMixing() } else { refreshApps() }
        applyRouteGains()
        if profile.soundMuted { toggleSoundMute() }
        if profile.micMuted { toggleMicMute() }
        selectedProfile = profile.id
    }
    func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if selectedProfile == id { selectedProfile = nil }
        persistProfiles()
    }
    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { preferences.set(data, forKey: "profiles") }
    }
    func shutDown() {
        watcher?.stop()
        watcher = nil
        disableMixing()
        if soundMuted { toggleSoundMute() }
        if micMuted { toggleMicMute() }
        timer?.invalidate()
    }
}

/// Who a playing process belongs to: an app the user knows, or macOS itself (alerts, notifications,
/// Control Centre), which shares the single System Sounds row.
private enum AudioOwner {
    case app(key: String, name: String, icon: NSImage?)
    case system

    init(pid: pid_t, processObject: AudioObjectID, running: [NSRunningApplication]) {
        let process = NSRunningApplication(processIdentifier: pid)
        if let owner = Responsibility.app(for: pid), Self.isUserApp(owner) { self = .init(owner); return }
        if let process, Self.isUserApp(process) { self = .init(process); return }
        // Helpers inside an app bundle, or named after its bundle identifier.
        let bundle = HAL.string(processObject, kAudioProcessPropertyBundleID) ?? process?.bundleIdentifier ?? ""
        let processPath = process?.bundleURL?.path ?? Self.executablePath(pid) ?? ""
        let container = running.filter { app in
            guard let appID = app.bundleIdentifier, Self.isUserApp(app) else { return false }
            if !bundle.isEmpty, bundle == appID || bundle.hasPrefix(appID + ".") { return true }
            guard let appPath = app.bundleURL?.path else { return false }
            return processPath.hasPrefix(appPath + "/")
        }.max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
        if let container { self = .init(container); return }
        if let process, let id = process.bundleIdentifier, let path = process.bundleURL?.path, !Self.isSystemPath(path) {
            self = .app(key: id, name: process.localizedName ?? id, icon: process.icon); return
        }
        // Unbundled programs outside the system, such as games running through Wine.
        if let path = Self.executablePath(pid), !Self.isSystemPath(path) {
            let name = (path as NSString).lastPathComponent
            self = .app(key: "process.\(name)", name: name, icon: NSWorkspace.shared.icon(forFile: path)); return
        }
        self = .system
    }

    private init(_ app: NSRunningApplication) {
        let id = app.bundleIdentifier ?? "process.\(app.processIdentifier)"
        self = .app(key: id, name: app.localizedName ?? id, icon: app.icon)
    }

    private static func isUserApp(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier != nil, !app.isTerminated else { return false }
        switch app.activationPolicy {
        case .regular: return true
        case .accessory: return !isSystemPath(app.bundleURL?.path ?? "/System/")
        default: return false
        }
    }
    private static func isSystemPath(_ path: String) -> Bool {
        if path.hasPrefix("/usr/local/") { return false }
        return ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains(where: path.hasPrefix)
    }
    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}


extension AudioController {
    func displayName(_ source: AudioSource) -> String { deviceNames[source.uid] ?? source.name }
    func renameDevice(_ source: AudioSource, to name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == source.name { deviceNames.removeValue(forKey: source.uid) }
        else { deviceNames[source.uid] = cleaned }
        preferences.set(deviceNames, forKey: "deviceNames")
    }
}


extension AudioController {
    private var activeOutput: AudioSource? { sources.first { !$0.input && $0.isDefault } }
    var outputIsMuted: Bool {
        guard let source = activeOutput else { return soundMuted }
        return soundMuted || (!source.channels.isEmpty && source.volume == 0)
            || scalar(source.device, address(kAudioDevicePropertyMute), initial: UInt32(0)) == 1
    }
    var statusSymbol: String {
        guard let source = activeOutput else { return "speaker.slash.fill" }
        if outputIsMuted { return "speaker.slash.fill" }
        let name = source.name.lowercased()
        let port = scalar(source.device, address(kAudioDevicePropertyDataSource), initial: UInt32(0))
        let headphoneTerminal = HAL.ids(source.device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput).contains { stream in
            HAL.read(stream, kAudioStreamPropertyTerminalType, initial: UInt32(0)) == kAudioStreamTerminalTypeHeadphones
        }
        if headphoneTerminal || port == 0x6864706e || ["headphone", "headset", "airpod", "earbud", "nothing ear", "evolve2", "arctis"].contains(where: name.contains) {
            return "headphones"
        }
        if source.volume < 0.34 { return "speaker.wave.1.fill" }
        if source.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
    var statusDescription: String {
        guard let source = activeOutput else { return "No output device" }
        return "\(displayName(source)) · \(outputIsMuted ? "Muted" : "\(Int((source.volume * 100).rounded()))%")"
    }
}
