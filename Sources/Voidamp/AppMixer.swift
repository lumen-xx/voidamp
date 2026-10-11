import AppKit
import CoreAudio
import os

// All property reads and lifecycle operations happen on the main thread.
enum HAL {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T? {
        var address = address(selector)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        return status == noErr ? result : nil
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        read(id, selector, initial: "" as CFString).map { $0 as String }
    }
    static func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? result : []
    }
}

/// The app a helper process works for. WebKit plays Safari's audio from "Safari Graphics and Media", an XPC
/// service outside Safari's bundle; macOS records Safari as the responsible process.
enum Responsibility {
    private typealias Lookup = @convention(c) (pid_t) -> pid_t
    private static let lookup: Lookup? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Lookup.self) }
    static func app(for pid: pid_t) -> NSRunningApplication? {
        guard let responsible = lookup?(pid), responsible > 0, responsible != pid else { return nil }
        return NSRunningApplication(processIdentifier: responsible)
    }
}

struct AppSource: Identifiable, Equatable {
    static let systemSoundsID = "app.voidamp.system-sounds"
    let id: String
    let name: String
    let icon: NSImage?
    let processes: [AudioObjectID]
    var gain: Double
    var muted: Bool
    var isSystem: Bool { id == Self.systemSoundsID }
    var isPlaying: Bool { !processes.isEmpty }

    static func == (lhs: AppSource, rhs: AppSource) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.processes == rhs.processes && lhs.gain == rhs.gain
            && lhs.muted == rhs.muted && (lhs.icon == nil) == (rhs.icon == nil)
    }
}

/// Why an app isn't being mixed. Its original audio keeps playing untouched.
enum RouteFailure: Equatable {
    /// The capture produced nothing: almost always the Screen & System Audio Recording permission.
    case noAudio
    case message(String)
}

struct RoutingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@available(macOS 14.2, *)
final class AppRoute {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private let gain = OSAllocatedUnfairLock(initialState: Float(1))
    private let callbacks = OSAllocatedUnfairLock(initialState: UInt64(0))
    let createdAt = Date()
    var callbackCount: UInt64 { callbacks.withLock { $0 } }
    let processes: [AudioObjectID]
    let outputUID: String
    /// Main-thread bookkeeping for the health check.
    private var observedCount: UInt64 = 0
    private var lastProgress = Date()

    init(processes: [AudioObjectID], output: AudioDeviceID, gain: Double) throws {
        self.processes = processes
        guard let uid = HAL.string(output, kAudioDevicePropertyDeviceUID) else { throw RoutingError(message: "No output device is available.") }
        outputUID = uid
        self.gain.withLock { $0 = Float(gain) }
        do {
            let description = CATapDescription(processes: processes, deviceUID: uid, stream: 0)
            description.name = "Voidamp app audio"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(description, &tap), "Capturing the app’s audio")
            guard let tapUID = HAL.string(tap, kAudioTapPropertyUID),
                  let format = HAL.read(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()),
                  format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else { throw RoutingError(message: "This output’s audio format can’t be mixed.") }
            let streams = HAL.ids(output, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            guard let stream = streams.first,
                  let outputFormat = HAL.read(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()),
                  outputFormat.mFormatID == kAudioFormatLinearPCM,
                  outputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  outputFormat.mBitsPerChannel == 32,
                  outputFormat.mSampleRate == format.mSampleRate else { throw RoutingError(message: "This output’s audio format can’t be mixed.") }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Voidamp route",
                kAudioAggregateDeviceUIDKey: "app.voidamp.route.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid, kAudioSubDeviceInputChannelsKey: 0]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Creating the audio route")
            let gainState = self.gain
            let callbackState = self.callbacks
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, nil) { _, input, _, output, _ in
                let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                let outputs = UnsafeMutableAudioBufferListPointer(output)
                // Tap buffers follow hardware inputs. Support interleaved and planar Float32.
                let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
                let tapChannels = Int(format.mChannelsPerFrame)
                let tapBufferCount = planar ? tapChannels : 1
                guard tapChannels > 0, inputs.count >= tapBufferCount else { return }
                let firstTapBuffer = inputs.count - tapBufferCount
                guard inputs[firstTapBuffer].mData != nil else { return }
                callbackState.withLock { $0 += 1 }
                let multiplier = gainState.withLock { $0 }
                var channelOffset = 0
                for buffer in outputs {
                    guard let destination = buffer.mData else { continue }
                    let result = destination.assumingMemoryBound(to: Float.self)
                    let channels = Int(buffer.mNumberChannels)
                    guard channels > 0 else { continue }
                    let outputFrames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
                    for channel in 0..<channels {
                        let sourceChannel = channelOffset + channel
                        if sourceChannel >= tapChannels {
                            for frame in 0..<outputFrames { result[frame * channels + channel] = 0 }
                            continue
                        }
                        let source = inputs[firstTapBuffer + (planar ? sourceChannel : 0)]
                        let sourceChannels = Int(source.mNumberChannels)
                        guard let data = source.mData, sourceChannels > 0 else {
                            for frame in 0..<outputFrames { result[frame * channels + channel] = 0 }
                            continue
                        }
                        let samples = data.assumingMemoryBound(to: Float.self)
                        let frames = Int(source.mDataByteSize) / MemoryLayout<Float>.size / sourceChannels
                        for frame in 0..<outputFrames {
                            let sample: Float = frame < frames ? samples[frame * sourceChannels + (planar ? 0 : sourceChannel)] * multiplier : 0
                            result[frame * channels + channel] = min(1, max(-1, sample))
                        }
                    }
                    channelOffset += channels
                }
            }, "Starting the app mixer")
            try check(AudioDeviceStart(aggregate, io), "Playing the app’s audio")
        } catch {
            stop()
            throw error
        }
    }

    /// The route runs its own clock, so callbacks keep arriving even while the app is silent. When they stop
    /// (sleep, a device reset) the tapped app would stay muted, so the caller replaces the route.
    enum Health { case starting, healthy, neverStarted, stalled }
    func health(now: Date = Date(), timeout: TimeInterval = 2) -> Health {
        let count = callbackCount
        if count != observedCount { observedCount = count; lastProgress = now; return .healthy }
        guard now.timeIntervalSince(lastProgress) > timeout else { return count == 0 ? .starting : .healthy }
        return count == 0 ? .neverStarted : .stalled
    }

    func setGain(_ value: Double) { gain.withLock { $0 = Float(value) } }
    func stop() {
        if let io {
            AudioDeviceStop(aggregate, io)
            AudioDeviceDestroyIOProcID(aggregate, io)
            self.io = nil
        }
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
    deinit { stop() }
    private func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw RoutingError(message: "\(operation) failed (\(status)).") }
    }
}

/// Calls back on the main queue as soon as any process starts or stops playing, so routes follow audio
/// within milliseconds instead of waiting for the next poll.
@MainActor
final class ProcessWatcher {
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?
    private let onChange: @MainActor () -> Void
    private var pending = false

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.processListChanged() }
        }
        var address = HAL.address(kAudioHardwarePropertyProcessObjectList)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            listListener = block
        }
        processListChanged()
    }

    private func processListChanged() {
        let current = Set(HAL.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList))
        for (id, block) in listeners where !current.contains(id) {
            var address = HAL.address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
            listeners.removeValue(forKey: id)
        }
        for id in current where listeners[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
            var address = HAL.address(kAudioProcessPropertyIsRunningOutput)
            if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr { listeners[id] = block }
        }
        schedule()
    }

    private func schedule() {
        guard !pending else { return }
        pending = true
        // Coalesce bursts: several helpers often start together.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                self.onChange()
            }
        }
    }

    func stop() {
        for (id, block) in listeners {
            var address = HAL.address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        listeners.removeAll()
        if let listListener {
            var address = HAL.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listListener)
            self.listListener = nil
        }
    }
}

// A small center detent during pointer drags; keyboard adjustment remains continuous.
enum MixerGain {
    static func adjusted(_ value: Double, snapping: Bool) -> Double {
        let clamped = min(2, max(0, value))
        return snapping && abs(clamped - 1) <= 0.04 ? 1 : clamped
    }
}
