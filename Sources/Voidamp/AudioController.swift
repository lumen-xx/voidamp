import Foundation
import CoreAudio
import Combine
import AppKit

struct AudioSource: Identifiable {
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
    private var routes: [String: AppRoute] = [:]
    private var appSettings: [String: AppSetting] = [:]
    private var nativeMuteStates: [String: UInt32] = [:]
    private var mutedDevices: [String: Double] = [:]
    private var failedRoutes: Set<String> = []
    private var routeOutputUID: String?
    private var routeProcesses: [String: [AudioObjectID]] = [:]
    private let preferences: UserDefaults
    private var terminationObserver: NSObjectProtocol?
    private var timer: Timer?
    private var savedVolumes: [String: Double] = [:]

    init(preferences: UserDefaults = .standard, autoStartMixing: Bool = true) {
        self.preferences = preferences
        self.deviceNames = preferences.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
        self.mixingEnabled = autoStartMixing
        if let data = preferences.data(forKey: "profiles"), let stored = try? JSONDecoder().decode([MixerProfile].self, from: data) { profiles = stored }
        refresh()
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
        sources = result.sorted {
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.id < $1.id
        }
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

struct AppSetting: Codable {
    var gain: Double
    var muted: Bool
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
        if !input { for app in apps { routes[app.id]?.setGain(soundMuted || app.muted ? 0 : app.gain) } }
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

    func enableMixing() {
        mixingEnabled = true
        failedRoutes.removeAll()
        refreshApps()
    }
    func disableMixing() {
        routes.removeAll() // Destroying taps restores the original application audio.
        mixingEnabled = false
        failedRoutes.removeAll()
    }
    private func refreshApps() {
        let ids = HAL.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        var groups: [String: (String, NSImage?, [AudioObjectID])] = [:]
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for id in ids {
            guard let pid = HAL.read(id, kAudioProcessPropertyPID, initial: pid_t(0)), pid != getpid(),
                  HAL.read(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) == 1 else { continue }
            let processApp = NSRunningApplication(processIdentifier: pid)
            let bundle = HAL.string(id, kAudioProcessPropertyBundleID) ?? processApp?.bundleIdentifier ?? "process.\(pid)"
            // Browser audio often belongs to a helper process. Match the owning app bundle.
            let owner = running.filter { app in
                guard let appID = app.bundleIdentifier else { return false }
                return bundle == appID || bundle.hasPrefix(appID + ".") || (processApp?.bundleURL?.path.hasPrefix((app.bundleURL?.path ?? "\0") + "/") ?? false)
            }.max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            let key = owner?.bundleIdentifier ?? bundle
            if groups[key] == nil { groups[key] = (owner?.localizedName ?? processApp?.localizedName ?? bundle, owner?.icon ?? processApp?.icon, []) }
            groups[key]?.2.append(id)
        }
        apps = groups.map { key, value in
            let setting = appSettings[key] ?? AppSetting(gain: 1, muted: false)
            return AppSource(id: key, name: value.0, icon: value.1, processes: value.2.sorted(), gain: setting.gain, muted: setting.muted)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard mixingEnabled, let output = sources.first(where: { !$0.input && $0.isDefault }) else { routes.removeAll(); return }
        if routeOutputUID != output.uid {
            failedRoutes.removeAll()
            routeOutputUID = output.uid
        }
        let active = Set(apps.map(\.id))
        for key in Array(routes.keys) where !active.contains(key) { routes.removeValue(forKey: key) }
        for app in apps {
            if routeProcesses[app.id] != app.processes {
                failedRoutes.remove(app.id)
                routeProcesses[app.id] = app.processes
            }
            if let route = routes[app.id], route.processes == app.processes, route.outputUID == output.uid {
                if Date().timeIntervalSince(route.createdAt) > 10, route.callbackCount == 0 {
                    routes.removeValue(forKey: app.id)
                    failedRoutes.insert(app.id)
                    error = "No audio arrived from \(app.name). Original playback has been restored. Allow Voidamp in System Settings → Privacy & Security → Screen & System Audio Recording, then retry mixing."
                }
                continue
            }
            routes.removeValue(forKey: app.id)
            guard !failedRoutes.contains(app.id) else { continue }
            do {
                routes[app.id] = try AppRoute(processes: app.processes, output: output.device, gain: soundMuted || app.muted ? 0 : app.gain)
            } catch {
                failedRoutes.insert(app.id)
                self.error = error.localizedDescription
            }
        }
    }
    func routingDiagnostics() -> [String] {
        apps.map { app in
            if let route = routes[app.id] { return "\(app.name): \(route.callbackCount) audio callbacks" }
            return "\(app.name): not routed"
        }
    }
    func appIsRouted(_ app: AppSource) -> Bool { routes[app.id] != nil }
    func setAppGain(_ app: AppSource, _ value: Double, snapping: Bool = false) {
        guard routes[app.id] != nil else { return }
        let gain = MixerGain.adjusted(value, snapping: snapping)
        appSettings[app.id] = AppSetting(gain: gain, muted: app.muted)
        if let index = apps.firstIndex(where: { $0.id == app.id }) { apps[index].gain = gain }
        routes[app.id]?.setGain(soundMuted || app.muted ? 0 : gain)
    }
    func toggleAppMute(_ app: AppSource) {
        guard routes[app.id] != nil else { return }
        appSettings[app.id] = AppSetting(gain: app.gain, muted: !app.muted)
        if let index = apps.firstIndex(where: { $0.id == app.id }) { apps[index].muted.toggle() }
        routes[app.id]?.setGain(soundMuted || !app.muted ? 0 : app.gain)
    }
    func saveProfile(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let profile = MixerProfile(name: name,
            devices: Dictionary(uniqueKeysWithValues: sources.filter { !$0.channels.isEmpty }.map { ($0.id, mutedDevices[$0.id] ?? $0.volume) }),
            outputUID: sources.first { !$0.input && $0.isDefault }?.uid,
            inputUID: sources.first { $0.input && $0.isDefault }?.uid,
            apps: appSettings, soundMuted: soundMuted, micMuted: micMuted, mixingEnabled: mixingEnabled)
        profiles.append(profile)
        selectedProfile = profile.id
        persistProfiles()
    }
    func applyProfile(_ profile: MixerProfile) {
        if profile.mixingEnabled == false { disableMixing() }
        if soundMuted { toggleSoundMute() }
        if micMuted { toggleMicMute() }
        appSettings = profile.apps
        for source in sources {
            if let volume = profile.devices[source.id] { writeVolume(source, volume) }
        }
        if let output = sources.first(where: { !$0.input && $0.uid == profile.outputUID }) { select(output) }
        if let input = sources.first(where: { $0.input && $0.uid == profile.inputUID }) { select(input) }
        if profile.mixingEnabled == true { enableMixing() } else { refreshApps() }
        for app in apps { routes[app.id]?.setGain(app.muted ? 0 : app.gain) }
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
        disableMixing()
        if soundMuted { toggleSoundMute() }
        if micMuted { toggleMicMute() }
        timer?.invalidate()
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
