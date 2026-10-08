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

struct AppSource: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let processes: [AudioObjectID]
    var gain: Double
    var muted: Bool
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
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create app audio capture")
            guard let tapUID = HAL.string(tap, kAudioTapPropertyUID),
                  let format = HAL.read(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()),
                  format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else { throw RoutingError(message: "This output’s audio format isn’t supported for app mixing.") }
            let streams = HAL.ids(output, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            guard let stream = streams.first,
                  let outputFormat = HAL.read(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()),
                  outputFormat.mFormatID == kAudioFormatLinearPCM,
                  outputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  outputFormat.mBitsPerChannel == 32,
                  outputFormat.mSampleRate == format.mSampleRate else { throw RoutingError(message: "This output’s audio format isn’t supported for app mixing.") }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Voidamp route",
                kAudioAggregateDeviceUIDKey: "app.voidamp.route.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid, kAudioSubDeviceInputChannelsKey: 0]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Create audio route")
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
            }, "Start app mixer")
            try check(AudioDeviceStart(aggregate, io), "Play app audio")
        } catch {
            stop()
            throw error
        }
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
        if status != noErr { throw RoutingError(message: "\(operation) failed (\(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording.") }
    }
}

// A small center detent during pointer drags; keyboard adjustment remains continuous.
enum MixerGain {
    static func adjusted(_ value: Double, snapping: Bool) -> Double {
        let clamped = min(2, max(0, value))
        return snapping && abs(clamped - 1) <= 0.04 ? 1 : clamped
    }
}
