// SPDX-License-Identifier: GPL-3.0-or-later
import CoreAudio
import Foundation

/// A CoreAudio device as seen by the device-change code (E2, M3).
public struct AudioDevice: Sendable, Equatable, Codable {
    public var id: AudioDeviceID
    public var uid: String
    public var name: String
    /// `kAudioDeviceTransportType*` four-char code (e.g. 'bltn', 'grup' for aggregates).
    public var transportType: UInt32
    public var outputChannels: Int
    public var nominalSampleRate: Double

    public var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }
    public var isAggregate: Bool { transportType == kAudioDeviceTransportTypeAggregate }
    public var hasOutput: Bool { outputChannels > 0 }
}

/// A CoreAudio call failed.
public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public var operation: String
    public var status: OSStatus
    public var description: String { "\(operation) failed (OSStatus \(status))" }

    public init(operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }
}

/// Thin, thread-safe wrappers over the CoreAudio HAL property API.
public enum OutputDevices {
    public static func all() -> [AudioDevice] {
        var size: UInt32 = 0
        var address = globalAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device(id:))
    }

    public static func device(id: AudioDeviceID) -> AudioDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? "?",
                           transportType: uint32(id, kAudioDevicePropertyTransportType) ?? 0,
                           outputChannels: outputChannelCount(id),
                           nominalSampleRate: nominalSampleRate(id) ?? 0)
    }

    public static func device(uid: String) -> AudioDevice? { all().first { $0.uid == uid } }

    /// The built-in output (speakers or headphone jack), if present.
    public static func builtInOutput() -> AudioDevice? { all().first { $0.isBuiltIn && $0.hasOutput } }

    public static func defaultOutput() -> AudioDeviceID? {
        uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    }

    public static func setDefaultOutput(_ id: AudioDeviceID) throws(CoreAudioError) {
        var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        if status != noErr { throw CoreAudioError(operation: "set default output device \(id)", status: status) }
    }

    /// IO buffer size in frames (output scope).
    public static func bufferFrameSize(_ id: AudioDeviceID) -> UInt32? {
        uint32(id, kAudioDevicePropertyBufferFrameSize, scope: kAudioObjectPropertyScopeOutput)
    }

    public static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var address = globalAddress(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    public static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: Helpers

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
