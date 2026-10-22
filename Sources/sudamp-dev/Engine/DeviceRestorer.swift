// SPDX-License-Identifier: GPL-3.0-or-later
import Audio
import CoreAudio
import Foundation
import Synchronization

/// A temporary, *non-private* aggregate device wrapping one real output (PLAN M0 E2). Non-private, so it can be
/// the system default output; always destroyed again by `DeviceRestorer`.
enum AggregateDevice {
    static let uidPrefix = "app.sudamp.devswitch."

    static func create(wrapping subDeviceUID: String) throws -> AudioDevice {
        let uid = uidPrefix + String(getpid())
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "sudamp devswitch (temporary)",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: 0,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: subDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: subDeviceUID]],
        ]
        var id = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != 0 else { throw CoreAudioError(operation: "AudioHardwareCreateAggregateDevice", status: status) }
        // The HAL publishes the device asynchronously; wait until it has output streams.
        var device: AudioDevice?
        Measure.wait(timeout: 3) {
            device = OutputDevices.device(id: id)
            return device?.hasOutput ?? false
        }
        guard let device, device.hasOutput else {
            _ = AudioHardwareDestroyAggregateDevice(id)
            throw ToolError("aggregate device \(uid) never published output streams")
        }
        return device
    }

    @discardableResult
    static func destroy(_ id: AudioDeviceID) -> OSStatus { AudioHardwareDestroyAggregateDevice(id) }

    /// Leftovers from a run that died before its exit trap (`devswitch --restore`).
    static func leftovers() -> [AudioDevice] { OutputDevices.all().filter { $0.uid.hasPrefix(uidPrefix) } }
}

/// Puts the user's audio configuration back on every exit path: normal return, `exit()`, SIGINT/SIGTERM/SIGHUP
/// and (best effort) crash signals. The state is also written to a file so `devswitch --restore` can repair a
/// run killed with SIGKILL.
final class DeviceRestorer: Sendable {
    static let shared = DeviceRestorer()
    static let stateFile = URL(filePath: NSTemporaryDirectory()).appending(path: "sudamp-devswitch-restore.json")

    struct State: Codable, Equatable {
        var originalOutputUID: String
        var originalSystemOutputUID: String?
        var aggregateUID: String?
        var pid: Int32
    }

    struct Result: Encodable {
        var restoredOutput: Bool
        var restoredSystemOutput: Bool
        var aggregateDestroyed: Bool
        var finalOutput: String?
        var detail: [String]
    }

    private let state = Mutex<State?>(nil)
    private let installed = Mutex(false)

    func arm(originalOutputUID: String, originalSystemOutputUID: String?) {
        let s = State(originalOutputUID: originalOutputUID, originalSystemOutputUID: originalSystemOutputUID,
                      aggregateUID: nil, pid: getpid())
        state.withLock { $0 = s }
        Self.save(s)
        installTraps()
    }

    func setAggregate(uid: String) {
        let s = state.withLock { st -> State? in
            st?.aggregateUID = uid
            return st
        }
        if let s { Self.save(s) }
    }

    /// Idempotent: the first call restores, later calls are no-ops.
    @discardableResult
    func restore() -> Result? {
        guard let s = state.withLock({ st -> State? in
            defer { st = nil }
            return st
        }) else { return nil }
        let result = Self.restore(s)
        try? FileManager.default.removeItem(at: Self.stateFile)
        return result
    }

    static func restore(_ s: State) -> Result {
        var detail: [String] = []
        var restoredOutput = false, restoredSystem = true, destroyed = s.aggregateUID == nil
        if let original = OutputDevices.device(uid: s.originalOutputUID) {
            do {
                if OutputDevices.defaultOutput() != original.id { try OutputDevices.setDefaultOutput(original.id) }
                restoredOutput = OutputDevices.defaultOutput() == original.id
            } catch {
                detail.append("\(error)")
            }
        } else {
            detail.append("original output \(s.originalOutputUID) not found")
        }
        if let systemUID = s.originalSystemOutputUID, let system = OutputDevices.device(uid: systemUID) {
            if systemOutput() != system.id { setSystemOutput(system.id) }
            restoredSystem = systemOutput() == system.id
            if !restoredSystem { detail.append("system output not restored") }
        }
        if let uid = s.aggregateUID {
            if let agg = OutputDevices.device(uid: uid) {
                let status = AggregateDevice.destroy(agg.id)
                destroyed = status == noErr
                if !destroyed { detail.append("destroy aggregate: OSStatus \(status)") }
            } else {
                destroyed = true
            }
        }
        let final = OutputDevices.defaultOutput().flatMap(OutputDevices.device(id:))?.name
        return Result(restoredOutput: restoredOutput, restoredSystemOutput: restoredSystem,
                      aggregateDestroyed: destroyed, finalOutput: final, detail: detail)
    }

    /// `devswitch --restore`: repairs from the state file and removes any leftover aggregates.
    static func restoreFromFile() -> Result {
        var result = Result(restoredOutput: true, restoredSystemOutput: true, aggregateDestroyed: true,
                            finalOutput: nil, detail: [])
        if let data = try? Data(contentsOf: stateFile), let s = try? JSONDecoder().decode(State.self, from: data) {
            result = restore(s)
            try? FileManager.default.removeItem(at: stateFile)
        } else {
            result.detail.append("no state file")
        }
        for leftover in AggregateDevice.leftovers() {
            let status = AggregateDevice.destroy(leftover.id)
            result.detail.append("destroyed leftover \(leftover.uid): \(status)")
        }
        result.finalOutput = OutputDevices.defaultOutput().flatMap(OutputDevices.device(id:))?.name
        return result
    }

    static func systemOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr ? id : nil
    }

    static func setSystemOutput(_ id: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = id
        _ = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                       UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }

    private static func save(_ s: State) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: stateFile, options: .atomic) }
    }

    private func installTraps() {
        guard installed.withLock({ done -> Bool in
            defer { done = true }
            return !done
        }) else { return }
        atexit { DeviceRestorer.shared.restore() }
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                DeviceRestorer.shared.restore()
                exit(128 + sig)
            }
            source.resume()
            Self.signalSources.withLock { $0.append(source) }
        }
        // Best effort on crashes: restore, then die with the original signal.
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                DeviceRestorer.shared.restore()
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    /// Keeps the signal sources alive for the process lifetime.
    private static let signalSources = Mutex<[any DispatchSourceSignal]>([])
}
