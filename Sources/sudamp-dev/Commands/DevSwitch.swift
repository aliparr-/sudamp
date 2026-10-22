// SPDX-License-Identifier: GPL-3.0-or-later
import Audio
import Core
import CoreAudio
import Foundation
import MPV
import Synchronization

/// `sudamp-dev devswitch [--cycles N] [--json] [--hold S] [--detect-timeout S] [--no-fallback] [--fixture <wav>]`,
/// and `devswitch --restore` (repairs the default output and removes leftover aggregates after a killed run).
///
/// PLAN M0 E2: creates a non-private aggregate device around the built-in output (destroyed in an exit trap),
/// then toggles `kAudioHardwarePropertyDefaultOutputDevice` between it and the built-in output while the ramp
/// fixture plays silently. A detection step first checks that toggles produce `AVAudioEngineConfigurationChange`;
/// if they don't (macOS 27, docs/spikes/E2.md), the engine follows the default output itself by binding
/// `kAudioOutputUnitProperty_CurrentDevice` on its output unit (AudioEngine.setFollowsDefaultOutput), and the
/// toggles continue. Reports crashes (finishing means none), ms from each switch to non-silent audio at the
/// render callback on the target device, and mpv API p99. The original default (and system) output is always
/// restored.
enum DevSwitchCommand {
    enum Mode: String, Encodable { case defaultDevice, currentDevice }

    struct Switch: Encodable {
        var cycle: Int
        var to: String
        var mode: Mode
        var configChanges: Int
        /// Switch → first AVAudioEngineConfigurationChange.
        var configChangeMs: Double?
        /// Longest gap between render callbacks in the 2 s after the switch (the engine stopped meanwhile).
        var renderGapMaxMs: Double?
        /// Longest run without audible callbacks in the 2 s after the switch.
        var audioGapMaxMs: Double?
        var recovered: Bool
        /// Switch → host pause lifted by the recovery (nil if the recovery never paused).
        var recoveryMs: Double?
        /// Switch → the output unit first reported the target device (kAudioOutputUnitProperty_CurrentDevice).
        var onTargetMs: Double?
        /// Whether the recovery host-paused audio (nil without a recovery).
        var pausedAudio: Bool?
        /// Switch → audio back on the target device for good (first audible callback after the last >= 25 ms gap).
        var audioMs: Double?
        /// Gaps of >= 25 ms between audible callbacks after audio first returned on the target device.
        var dropoutsAfterFirstAudio: Int?
        var startAttempts: Int?
        var rebuilt: Bool?
        var action: String?
        var error: String?
        var engineOnTarget: Bool
        var engineRunning: Bool
        var engineDevice: String?
    }

    struct Report: Encodable {
        var cycles: Int
        var switches: Int
        var mode: Mode
        var detection: Detection
        var crashes: Int
        var switchesWithAudioWithin500ms: Int
        var audioMsP50: Double
        var audioMsP95: Double
        var audioMsMax: Double
        var mpvApiP99Ms: Double
        var mpvApiMaxMs: Double
        var mpvApiSamples: Int
        var configChangeNotifications: Int
        var defaultOutputChanges: Int
        var ignoredDuringRecovery: Int
        var recoveries: Int
        var failedRecoveries: Int
        var shortReads: UInt64
        var aoErrorCount: Int64
        /// Resident memory before the first and after the last switch (every move replaces the AVAudioEngine).
        var residentMBBefore: Double
        var residentMBAfter: Double
        var builtIn: String
        var aggregate: String
        var originalDefault: String
        var restore: DeviceRestorer.Result?
        var restoredOriginalDefault: Bool
        var detail: [Switch]
        var ok: Bool
    }

    static func run(_ args: Args) async throws -> Int32 {
        if args.flag("restore") {
            printReport(DeviceRestorer.restoreFromFile(), pretty: !args.flag("json"))
            return 0
        }
        let cycles = args.int("cycles") ?? 20
        let hold = args.double("hold") ?? 2.0
        let detect = args.double("detect-timeout") ?? 3.0
        let fallback = !args.flag("no-fallback")
        let file = try EngineHarness.fixture(args.string("fixture"))

        guard let originalID = OutputDevices.defaultOutput(), let original = OutputDevices.device(id: originalID) else {
            throw ToolError("no default output device")
        }
        guard let builtIn = OutputDevices.builtInOutput() else { throw ToolError("no built-in output device") }
        let systemUID = DeviceRestorer.systemOutput().flatMap(OutputDevices.device(id:))?.uid
        DeviceRestorer.shared.arm(originalOutputUID: original.uid, originalSystemOutputUID: systemUID)
        let report: Report
        do {
            let aggregate = try AggregateDevice.create(wrapping: builtIn.uid)
            DeviceRestorer.shared.setAggregate(uid: aggregate.uid)
            if OutputDevices.defaultOutput() != builtIn.id { try OutputDevices.setDefaultOutput(builtIn.id) }
            report = try exercise(cycles: cycles, hold: hold, detect: detect, fallback: fallback, file: file,
                                  builtIn: builtIn, aggregate: aggregate, original: original)
        } catch {
            let restore = DeviceRestorer.shared.restore()
            stderr("devswitch failed: \(error); restore: \(String(describing: restore))")
            return 1
        }
        printReport(report, pretty: !args.flag("json"))
        return report.ok ? 0 : 1
    }

    /// The first audible callback (at or after `from`) that follows the last gap of at least `gapMs` without audible
    /// callbacks, and how many such gaps came after the first audible callback.
    static func settledAudio(after from: UInt64, audible: [UInt64], gapMs: Double = 25) -> (at: UInt64, dropouts: Int)? {
        let times = audible.filter { $0 >= from }
        guard let first = times.first else { return nil }
        var at = first
        var dropouts = 0
        for (previous, next) in zip(times, times.dropFirst()) where Measure.ms(from: previous, to: next) >= gapMs {
            at = next
            dropouts += 1
        }
        return (at, dropouts)
    }

    /// The PLAN's assertion, made explicit: do default-output toggles produce AVAudioEngineConfigurationChange?
    struct Detection: Encodable {
        var toggles: Int
        var notifications: Int
        var engineFollowedDefault: Bool
        var waitedMsPerToggle: Double
    }

    static func exercise(cycles: Int, hold: Double, detect: Double, fallback: Bool, file: URL, builtIn: AudioDevice,
                         aggregate: AudioDevice, original: AudioDevice) throws -> Report {
        let h = try EngineHarness(probeCapacity: Int(Double(cycles) * 2 * (hold + 3) * 100) + Int(detect * 400) + 4000)
        try h.start()
        try h.mpv.loadfile(file.path, options: LoadFileOptions(extra: [MPVOption("loop-file", "inf")]))
        guard Measure.wait(timeout: 3, { h.bridge.counters.silentCallbacks < h.bridge.counters.callbacks }) else {
            h.shutdown()
            throw ToolError("no audio before switching")
        }
        Measure.sleep(seconds: 0.5)
        let monitor = PropertyMonitor(mpv: h.mpv)

        // Detection: toggle to the aggregate and back, without any fallback.
        var detection = Detection(toggles: 0, notifications: 0, engineFollowedDefault: false, waitedMsPerToggle: detect * 1000)
        for target in [aggregate, builtIn] {
            let before = h.audio.configurationStats.notifications
            try OutputDevices.setDefaultOutput(target.id)
            detection.toggles += 1
            if Measure.wait(timeout: detect, { h.audio.configurationStats.notifications > before }) {
                detection.notifications += 1
                Measure.wait(timeout: 3) { h.audio.configurationStats.recoveries >= detection.notifications }
            }
            if target.id == aggregate.id { detection.engineFollowedDefault = h.audio.outputDevice == aggregate.id }
        }
        var mode = Mode.defaultDevice
        if detection.notifications < detection.toggles, fallback {
            // PLAN E2 fallback: bind kAudioOutputUnitProperty_CurrentDevice ourselves, driven by a HAL listener on
            // the default output so the tool keeps toggling the default device.
            mode = .currentDevice
            h.audio.setFollowsDefaultOutput(true)
        }

        var switches: [Switch] = []
        let rssBefore = Measure.processInfo().residentMB
        for cycle in 0..<cycles {
            for target in [aggregate, builtIn] {
                let before = h.audio.configurationStats
                let ts = monotonicNanos()
                let watch = DeviceWatch(audio: h.audio, target: target.id)
                try OutputDevices.setDefaultOutput(target.id)
                var problem: String?
                var recovery: RecoveryReport?
                let triggered = Measure.wait(timeout: detect) {
                    let now = h.audio.configurationStats
                    return now.notifications > before.notifications || now.defaultOutputChanges > before.defaultOutputChanges
                }
                if triggered {
                    if Measure.wait(timeout: 3.0, { h.audio.configurationStats.recoveries > before.recoveries }) {
                        // Let a self-inflicted late notification's (soft) recovery settle too.
                        Measure.sleep(seconds: 0.3)
                        recovery = h.audio.configurationStats.last
                        if recovery?.succeeded == false { problem = recovery?.error ?? "recovery failed" }
                    } else {
                        problem = "no recovery within 3 s"
                    }
                } else {
                    problem = "toggle produced no trigger within \(detect) s"
                    if mode == .defaultDevice, fallback {
                        mode = .currentDevice
                        h.audio.setFollowsDefaultOutput(true)
                        h.audio.followDefaultOutputNow()
                        Measure.wait(timeout: 3.0) { h.audio.configurationStats.recoveries > before.recoveries }
                        recovery = h.audio.configurationStats.last
                    }
                }
                let resumeNanos = recovery?.resumedNanos ?? 0
                Measure.wait(timeout: 2.0) { watch.onTargetNanos != nil }
                Measure.sleep(until: ts + 2_000_000_000)
                watch.stop()
                let onTarget = watch.onTargetNanos
                let after = h.audio.configurationStats
                let window = ProbeAnalysis(records: h.bridge.probeRecords(from: max(0, h.bridge.probeCount - 600)))
                    .records(from: ts, to: ts + 2_000_000_000)
                let callbackTimes = [ts] + window.map(\.nanos)
                let audibleTimes = [ts] + window.filter(ProbeAnalysis.audible).map(\.nanos)
                func maxGap(_ t: [UInt64]) -> Double? { zip(t.dropFirst(), t).map { Measure.ms(from: $1, to: $0) }.max() }
                // Audio is back once the output unit reports the target device and audible callbacks follow without
                // another gap: the first audible callback after the last gap of >= 25 ms. Counting from the first
                // audible callback alone would hide a later dropout (E2's self-inflicted restart on the first move),
                // and counting without the device condition would count audio still playing on the old device.
                let settled = onTarget.flatMap { Self.settledAudio(after: $0, audible: window.filter(ProbeAnalysis.audible).map(\.nanos)) }
                let audioAt = settled?.at
                let notified = after.notifications > before.notifications && after.lastNotificationNanos > ts
                switches.append(Switch(
                    cycle: cycle, to: target.name, mode: mode, configChanges: after.notifications - before.notifications,
                    configChangeMs: notified ? Measure.round(Measure.ms(from: ts, to: after.lastNotificationNanos), 1) : nil,
                    renderGapMaxMs: maxGap(callbackTimes).map { Measure.round($0, 1) },
                    audioGapMaxMs: maxGap(audibleTimes).map { Measure.round($0, 1) },
                    recovered: recovery?.succeeded ?? false,
                    recoveryMs: resumeNanos > 0 ? Measure.round(Measure.ms(from: ts, to: resumeNanos), 1) : nil,
                    onTargetMs: onTarget.map { Measure.round(Measure.ms(from: ts, to: $0), 1) },
                    pausedAudio: recovery?.pausedAudio,
                    audioMs: audioAt.map { Measure.round(Measure.ms(from: ts, to: $0), 1) },
                    dropoutsAfterFirstAudio: settled?.dropouts,
                    startAttempts: recovery?.startAttempts, rebuilt: recovery?.rebuilt,
                    action: recovery?.action.rawValue, error: problem,
                    engineOnTarget: h.audio.outputDevice == target.id, engineRunning: h.audio.isRunning,
                    engineDevice: h.audio.outputDevice.flatMap(OutputDevices.device(id:))?.name))
                Measure.sleep(until: ts + UInt64(max(hold, 2.0) * 1e9))
            }
        }
        let latencies = monitor.stop()
        let rssAfter = Measure.processInfo().residentMB
        let stats = h.audio.configurationStats
        let counters = h.bridge.counters
        let aoErrors = PullAO.errorCount
        h.audio.setFollowsDefaultOutput(false)
        h.shutdown()
        let restore = DeviceRestorer.shared.restore()
        let restored = OutputDevices.defaultOutput() == original.id
        let audio = switches.compactMap(\.audioMs)
        let within = switches.filter { ($0.audioMs ?? .infinity) <= 500 && $0.engineOnTarget }.count
        let apiP99 = Measure.percentile(latencies, 99)
        return Report(
            cycles: cycles, switches: switches.count, mode: mode, detection: detection, crashes: 0,
            switchesWithAudioWithin500ms: within, audioMsP50: Measure.round(Measure.percentile(audio, 50), 1),
            audioMsP95: Measure.round(Measure.percentile(audio, 95), 1), audioMsMax: Measure.round(audio.max() ?? .nan, 1),
            mpvApiP99Ms: Measure.round(apiP99, 4), mpvApiMaxMs: Measure.round(latencies.max() ?? .nan, 3),
            mpvApiSamples: latencies.count, configChangeNotifications: stats.notifications,
            defaultOutputChanges: stats.defaultOutputChanges, ignoredDuringRecovery: stats.ignoredDuringRecovery,
            recoveries: stats.recoveries, failedRecoveries: stats.failedRecoveries, shortReads: counters.shortReads,
            aoErrorCount: aoErrors, residentMBBefore: Measure.round(rssBefore, 1),
            residentMBAfter: Measure.round(rssAfter, 1), builtIn: builtIn.name, aggregate: aggregate.name, originalDefault: original.name,
            restore: restore, restoredOriginalDefault: restored, detail: switches,
            ok: within == switches.count && apiP99 < 5 && restored && stats.failedRecoveries == 0 && aoErrors == 0)
    }
}

/// Polls the engine's output device every 2 ms on its own thread and records when it first equals `target`.
final class DeviceWatch: Sendable {
    private let first = Atomic<UInt64>(0)
    private let running = Atomic<Bool>(true)
    private let done = DispatchSemaphore(value: 0)

    init(audio: AudioEngine, target: AudioDeviceID) {
        let thread = Thread { [self] in
            while running.load(ordering: .acquiring) {
                if first.load(ordering: .relaxed) == 0, audio.outputDevice == target {
                    first.store(monotonicNanos(), ordering: .releasing)
                }
                usleep(2000)
            }
            done.signal()
        }
        thread.name = "sudamp-dev.device-watch"
        thread.start()
    }

    var onTargetNanos: UInt64? {
        let t = first.load(ordering: .acquiring)
        return t == 0 ? nil : t
    }

    func stop() {
        if running.exchange(false, ordering: .acquiringAndReleasing) { done.wait() }
    }
}
