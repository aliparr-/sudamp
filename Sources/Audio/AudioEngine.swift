// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AudioToolbox
import Core
import CoreAudio
import Foundation
import Synchronization

/// Pauses and resumes whatever feeds the bridge (mpv) around a device-change recovery.
public struct SourceControl: Sendable {
    public var pause: @Sendable () -> Void
    public var resume: @Sendable () -> Void

    public init(pause: @escaping @Sendable () -> Void, resume: @escaping @Sendable () -> Void) {
        self.pause = pause
        self.resume = resume
    }
}

/// One debounced recovery from `AVAudioEngineConfigurationChange` (DESIGN §5.5; spike E2).
public struct RecoveryReport: Sendable, Codable, Equatable {
    public enum Action: String, Sendable, Codable {
        /// The engine was still running on the right device: nothing restarted.
        case none
        /// Stop, reset, reconnect, start.
        case restart
        /// As restart, after binding the output unit to the new default output.
        case moveDevice
    }

    public var action: Action
    /// Triggers (notifications or default-output changes) collapsed into this recovery.
    public var notifications: Int
    public var firstNotificationNanos: UInt64
    public var recoveryStartNanos: UInt64
    /// When the host pause was lifted (0 if the user had paused, or recovery failed).
    public var resumedNanos: UInt64
    public var startAttempts: Int
    /// The AVAudioEngine was replaced: on every device move (bound before its first start), or after
    /// `maxStartAttempts` failed starts.
    public var rebuilt: Bool
    public var succeeded: Bool
    public var error: String?
    public var outputDevice: UInt32?
    public var outputSampleRate: Double
    /// Whether this recovery host-paused audio (and paused the source) while it worked. M3: only recoveries that
    /// restart the engine pause; one that finds the output unit already on the right device (it followed the
    /// default output by itself) leaves audio playing.
    public var pausedAudio: Bool = false
    /// The quiet window this recovery waited for, in ms (150, or 10 for a notification that closely followed one of
    /// our own engine starts, which E2 found to be self-inflicted).
    public var debounceMs: Double = 0
}

public struct ConfigurationStats: Sendable, Codable, Equatable {
    /// AVAudioEngineConfigurationChange notifications.
    public var notifications = 0
    public var lastNotificationNanos: UInt64 = 0
    /// Default-output changes seen by the HAL listener (only while following the default output).
    public var defaultOutputChanges = 0
    public var lastDefaultOutputChangeNanos: UInt64 = 0
    /// Notifications that arrived while a recovery was running. They are not lost: the recovery checks the engine
    /// again shortly after it finishes.
    public var ignoredDuringRecovery = 0
    public var recoveries = 0
    public var failedRecoveries = 0
    public var last: RecoveryReport?
}

/// The output graph: source node (C render bridge) → AVAudioUnitEQ (10 bands) → main mixer (volume) → output
/// device (DESIGN §5.2/§5.4). Nonisolated; callable from any thread.
///
/// - **EQ** (`setEQBand`, `setPreamp`, `setEQEnabled`, `apply(_:)`, `apply(preset:)`): gains live in the
///   AVAudioUnitEQ, never in mpv, so they survive seeks and new files. `EQHeadroom.default` caps the combined boost
///   at +6 dB by lowering the applied preamp (docs/spikes/M3-audio.md: AUPeakLimiter is not shipped).
/// - **Balance** (`setBalance`): per-channel gains in the C render bridge.
/// - **Device changes**: `AVAudioEngineConfigurationChange` and, with `setFollowsDefaultOutput(true)`, default-output
///   changes (E2: AVAudioEngine doesn't follow those itself) run one debounced recovery: 150 ms quiet window (10 ms
///   for a notification within 1.5 s of our own engine start), then, only if the engine must restart, host pause +
///   source pause, then either a move (a fresh engine bound to the new default before its first start) or stop +
///   reset + reconnect + start (3 tries, then rebuild), and resume with a 50 ms fade. If the output unit already
///   followed the default by itself, nothing pauses.
/// - **Idle stop** (`scheduleIdleStop`, `resumeFromIdleStop`): stops the AVAudioEngine after 30 s paused or idle.
/// - **Offline** (`RenderingMode.offline`): the same graph in manual rendering mode, for eq-selftest and tests.
// The CoreAudio IO thread never touches this object, only RenderBridge's C atomics. Graph objects and EQ/balance
// state are guarded by `graphLock`, configuration-change and idle state by `config` (lock order: `config` may be
// taken inside `graphLock`, never the reverse).
// SAFETY: every mutable stored property is only accessed under one of those two locks.
public final class AudioEngine: @unchecked Sendable {
    public static let eqFrequencies: [Float] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]
    public static let eqBandwidthOctaves: Float = 1
    public static let eqGainRange: ClosedRange<Float> = -12...12
    public static let debounceInterval: TimeInterval = 0.150
    /// Quiet window for a configuration change that closely follows our own engine start (E2's self-inflicted
    /// notification ~100 ms after binding a freshly used device).
    public static let selfInflictedDebounceInterval: TimeInterval = 0.010
    /// How long after our own engine start a configuration change counts as self-inflicted.
    public static let selfInflictedWindow: TimeInterval = 1.5
    public static let maxStartAttempts = 3
    public static let recoveryFadeSeconds = 0.050
    /// DESIGN §5.2: the audio engine stops after 30 s paused or idle.
    public static let idleStopDelay: TimeInterval = 30

    /// Live output to a device, or the same graph rendered on demand without one.
    public enum RenderingMode: Sendable, Equatable {
        case live
        /// `enableManualRenderingMode(.offline)` at 48 kHz stereo; render with `renderOffline(_:to:)`.
        case offline(maximumFrameCount: AVAudioFrameCount)
    }

    /// Where `installTap` listens (tools: measurements and the inaudibility check).
    public enum TapPoint: Sendable, Equatable {
        /// The render bridge's output: post-balance, pre-EQ.
        case sourceOutput
        /// The EQ's output: post-EQ, pre-volume.
        case eqOutput
        /// The main mixer's output: what goes to the device (post-volume).
        case mixerOutput
    }

    /// Winamp-style volume 0...100 → mixer gain `(v/100)²` (DESIGN §5.4).
    public static func mixerVolume(forVolume volume: Double) -> Float {
        let v = min(max(volume.isNaN ? 0 : volume, 0), 100) / 100
        return Float(v * v)
    }

    public let bridge: RenderBridge
    public let renderingMode: RenderingMode
    let eq: AVAudioUnitEQ
    private let graphLock = NSRecursiveLock()
    private var engine: AVAudioEngine
    private var volume: Double
    private var eqState = EQSettings.flat
    private var headroom = EQHeadroom.default
    private var balanceValue = 0.0
    private var observer: (any NSObjectProtocol)?
    /// The HAL default-output listener while following the default output (guarded by `graphLock`).
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private let config = Mutex(ConfigState())
    private let configQueue = DispatchQueue(label: "sudamp.audio.config", qos: .userInitiated)
    private let log = Log.logger("audio")

    private struct ConfigState {
        var stats = ConfigurationStats()
        var generation = 0
        var burstStart: UInt64 = 0
        var burstCount = 0
        var burstDebounce: TimeInterval = AudioEngine.debounceInterval
        var recovering = false
        /// A trigger arrived while recovering: check again once the recovery is done.
        var recheck = false
        var automatic = true
        var sourceControl: SourceControl?
        var handler: (@Sendable (RecoveryReport) -> Void)?
        var followsDefault = false
        /// When we last started the engine ourselves (start, recovery, idle resume).
        var lastOwnStartNanos: UInt64 = 0
        var idleStopped = false
        var idleGeneration = 0
    }

    /// Builds (but does not start) the live graph. `volume` is 0...100; tools and tests pass 0.
    public convenience init(volume: Double) throws {
        try self.init(volume: volume, renderingMode: .live)
    }

    /// Builds (but does not start) the graph in `renderingMode`.
    public init(volume: Double, renderingMode: RenderingMode) throws {
        bridge = RenderBridge()
        eq = Self.makeEQ()
        self.renderingMode = renderingMode
        self.volume = volume
        engine = try Self.makeEngine(renderingMode, format: bridge.format)
        try wire(engine)
        if renderingMode == .live { observe(engine) }
        applyEQLocked()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let block = defaultListener {
            var address = OutputDevices.globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, configQueue, block)
        }
        engine.stop()
    }

    // MARK: Transport

    public func start() throws {
        try graphLock.withLock {
            engine.prepare()
            try engine.start()
            let now = monotonicNanos()
            config.withLock { s in
                s.idleStopped = false
                s.idleGeneration += 1
                s.lastOwnStartNanos = now
            }
        }
        refreshLatency()
    }

    /// Stops the engine (shutdown order: before `MPVClient.shutdown()`). Cancels a pending idle stop.
    public func stop() {
        graphLock.withLock {
            engine.stop()
            config.withLock { s in
                s.idleStopped = false
                s.idleGeneration += 1
            }
        }
    }

    public var isRunning: Bool { graphLock.withLock { engine.isRunning } }

    /// Silence within one IO buffer behind a 5 ms ramp (set before pausing mpv, DESIGN §5.2).
    public func hostPause() { bridge.setHostPaused(true) }

    /// Host-pauses, then blocks until the ramp has been rendered (about one IO buffer) or `timeout` passes, so the
    /// caller can pause mpv without truncating the ramp: mpv's pause makes the AO return silence at once, and
    /// issued immediately it beat the ramp in every E1 sample (an abrupt cut). Returns whether the ramp settled.
    @discardableResult
    public func hostPauseAndWaitForRamp(timeout: TimeInterval = 0.05) -> Bool {
        bridge.setHostPaused(true)
        let deadline = monotonicNanos() + UInt64(max(0, timeout) * 1e9)
        while !bridge.isHostPauseSettled {
            if monotonicNanos() >= deadline { return false }
            usleep(500)
        }
        return true
    }

    /// Resumes reading the AO; `fadeSeconds` > 0 adds a fade-in (1.5 s launch fade).
    public func hostResume(fadeSeconds: Double = 0) {
        if fadeSeconds > 0 { bridge.fadeIn(seconds: fadeSeconds) }
        bridge.setHostPaused(false)
    }

    // MARK: Idle stop (DESIGN §5.2: the audio engine stops after 30 s paused or idle)

    /// Stops the AVAudioEngine after `delay` unless cancelled first. Call when playback becomes paused or idle
    /// (after `hostPauseAndWaitForRamp()` and pausing mpv); a later `scheduleIdleStop` replaces this one.
    public func scheduleIdleStop(after delay: TimeInterval = AudioEngine.idleStopDelay) {
        let generation = config.withLock { s -> Int in
            s.idleGeneration += 1
            return s.idleGeneration
        }
        configQueue.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            self?.idleStopIfStillPending(generation)
        }
    }

    /// Cancels a pending idle stop (it does not restart an engine that already stopped: `resumeFromIdleStop`).
    public func cancelIdleStop() { config.withLock { $0.idleGeneration += 1 } }

    /// The idle stop, now (for callers that time the 30 s themselves). Unlike `stop()`, a device change while
    /// idle-stopped only rebinds the device instead of restarting the engine, and `resumeFromIdleStop()` restarts
    /// with the current device's format. Cancels a pending `scheduleIdleStop`.
    public func idleStopNow() {
        let stopped = graphLock.withLock { () -> Bool in
            let proceed = config.withLock { s -> Bool in
                s.idleGeneration += 1
                guard !s.idleStopped else { return false }
                s.idleStopped = true
                return true
            }
            if proceed { engine.stop() }
            return proceed
        }
        if stopped { log.info("audio engine stopped (idle)") }
    }

    /// The idle stop happened and nothing has restarted the engine since.
    public var isIdleStopped: Bool { config.withLock { $0.idleStopped } }

    /// Cancels a pending idle stop and, if the engine was idle-stopped, restarts it (rebinding the default output
    /// if it changed meanwhile and following it is on). Call before `MPVClient.setPause(false)` and `hostResume`.
    /// Returns whether it restarted the engine.
    @discardableResult
    public func resumeFromIdleStop() throws -> Bool {
        let restarted = try graphLock.withLock { () throws -> Bool in
            let (stopped, follow) = config.withLock { s -> (Bool, Bool) in
                s.idleGeneration += 1
                return (s.idleStopped, s.followsDefault)
            }
            guard stopped else { return false }
            if renderingMode == .live, follow, let wanted = OutputDevices.defaultOutput(),
               wanted != Self.currentDevice(of: engine), let error = Self.bind(engine, to: wanted) {
                log.error("idle resume: \(error, privacy: .public)")
            }
            try connectAll(engine)
            engine.prepare()
            try engine.start()
            let now = monotonicNanos()
            config.withLock { s in
                s.idleStopped = false
                s.lastOwnStartNanos = now
            }
            return true
        }
        if restarted {
            refreshLatency()
            log.info("audio engine restarted after idle stop")
        }
        return restarted
    }

    /// Runs on `configQueue`, like `recover()`, so the two never interleave.
    private func idleStopIfStillPending(_ generation: Int) {
        let stopped = graphLock.withLock { () -> Bool in
            let proceed = config.withLock { s -> Bool in
                guard s.idleGeneration == generation, !s.idleStopped else { return false }
                s.idleStopped = true
                return true
            }
            if proceed { engine.stop() }
            return proceed
        }
        if stopped { log.info("audio engine stopped after idle") }
    }

    // MARK: Volume, balance and EQ

    public func setVolume(_ volume: Double) {
        graphLock.withLock {
            self.volume = volume
            engine.mainMixerNode.outputVolume = Self.mixerVolume(forVolume: volume)
        }
    }

    public var mixerOutputVolume: Float { graphLock.withLock { engine.mainMixerNode.outputVolume } }

    /// Balance -1 (left only) ... +1 (right only); see `RenderBridge.setBalance` for the law.
    public func setBalance(_ balance: Double) {
        let b = balance.isNaN ? 0 : min(max(balance, -1), 1)
        graphLock.withLock { balanceValue = b }
        bridge.setBalance(b)
    }

    public var balance: Double { graphLock.withLock { balanceValue } }

    /// Sets one band's gain in dB (clamped to ±12).
    public func setEQBand(_ index: Int, gain: Float) {
        guard (0..<EQSettings.bandCount).contains(index) else { return }
        graphLock.withLock {
            eqState.bands[index] = EQSettings.clamp(gain)
            applyEQLocked()
        }
    }

    /// Preamp in dB (`globalGain`, clamped to ±12). The headroom cap may apply less (`appliedPreamp`).
    public func setPreamp(_ gain: Float) {
        graphLock.withLock {
            eqState.preamp = EQSettings.clamp(gain)
            applyEQLocked()
        }
    }

    /// On/off (`bypass`): off passes audio untouched, preamp included.
    public func setEQEnabled(_ enabled: Bool) {
        graphLock.withLock {
            eqState.enabled = enabled
            applyEQLocked()
        }
    }

    /// Replaces the whole EQ state at once.
    public func apply(_ settings: EQSettings) {
        graphLock.withLock {
            eqState = EQSettings(enabled: settings.enabled, preamp: settings.preamp, bands: settings.bands)
            applyEQLocked()
        }
    }

    /// Loads a preset's preamp and bands; the on/off state is unchanged.
    public func apply(preset: EQPreset) {
        graphLock.withLock {
            eqState = EQSettings(enabled: eqState.enabled, preamp: preset.preamp, bands: preset.bands)
            applyEQLocked()
        }
    }

    /// The requested EQ state (what the sliders show).
    public var eqSettings: EQSettings { graphLock.withLock { eqState } }

    /// The requested band gains in dB.
    public var eqBandGains: [Float] { graphLock.withLock { eqState.bands } }

    /// How boosts are kept from clipping; `.default` caps the combined boost at +6 dB.
    public func setEQHeadroom(_ headroom: EQHeadroom) {
        graphLock.withLock {
            self.headroom = headroom
            applyEQLocked()
        }
    }

    public var eqHeadroom: EQHeadroom { graphLock.withLock { headroom } }

    /// The preamp actually applied to the unit (`globalGain`): the requested preamp, lowered by the headroom cap.
    public var appliedPreamp: Float { graphLock.withLock { eq.globalGain } }

    private func applyEQLocked() {
        for (i, gain) in eqState.bands.enumerated() where i < eq.bands.count { eq.bands[i].gain = gain }
        eq.globalGain = headroom.appliedPreamp(for: eqState)
        eq.bypass = !eqState.enabled
    }

    // MARK: Offline rendering (RenderingMode.offline)

    /// The format `renderOffline` produces (48 kHz stereo deinterleaved Float32).
    public var manualRenderingFormat: AVAudioFormat { graphLock.withLock { engine.manualRenderingFormat } }

    /// Renders `frames` (≤ the mode's maximumFrameCount) of the started offline graph into `buffer`, pulling the
    /// render bridge on the calling thread.
    public func renderOffline(_ frames: AVAudioFrameCount, to buffer: AVAudioPCMBuffer) throws
        -> AVAudioEngineManualRenderingStatus {
        try graphLock.withLock { try engine.renderOffline(frames, to: buffer) }
    }

    // MARK: Taps (tools)

    /// Installs (replacing) a tap at `point`; `block` runs on an AVAudioEngine thread, never the IO thread. A tap
    /// does not survive an engine rebuild after repeated failed starts.
    public func installTap(at point: TapPoint, bufferSize: AVAudioFrameCount = 4096,
                           block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        graphLock.withLock {
            let node = tapNode(point)
            GraphCompat.removeTap(node)
            GraphCompat.installTap(node, bufferSize: bufferSize, block: block)
        }
    }

    public func removeTap(at point: TapPoint) {
        graphLock.withLock { GraphCompat.removeTap(tapNode(point)) }
    }

    private func tapNode(_ point: TapPoint) -> AVAudioNode {
        switch point {
        case .sourceOutput: return bridge.sourceNode
        case .eqOutput: return eq
        case .mixerOutput: return engine.mainMixerNode
        }
    }

    // MARK: Latency

    /// Output node presentation latency (device latency + safety offset).
    public var outputLatency: TimeInterval { graphLock.withLock { engine.outputNode.presentationLatency } }

    /// The device the output unit is currently bound to.
    public var outputDevice: AudioDeviceID? {
        guard renderingMode == .live else { return nil }
        return graphLock.withLock { Self.currentDevice(of: engine) }
    }

    /// The output device's IO buffer duration (512 frames at 48 kHz is 10.7 ms).
    public var ioBufferDuration: TimeInterval {
        guard let device = outputDevice, let frames = OutputDevices.bufferFrameSize(device),
              let rate = OutputDevices.nominalSampleRate(device), rate > 0 else { return 512.0 / 48000.0 }
        return Double(frames) / rate
    }

    /// Callback start → first sample audible: output latency + IO buffer (DESIGN §5.2, §5.4). Offline: 0.
    public var presentationLatency: TimeInterval {
        renderingMode == .live ? outputLatency + ioBufferDuration : 0
    }

    /// Re-queries the latency and hands it to the render bridge (and so to the visualiser's lag). Called on start,
    /// after every recovery and after an idle resume.
    @discardableResult
    public func refreshLatency() -> TimeInterval {
        let latency = presentationLatency
        bridge.setLatency(seconds: latency)
        return latency
    }

    // MARK: Devices

    /// Binds the output unit to `device` (kAudioOutputUnitProperty_CurrentDevice), restarting if it was running.
    /// For an explicit device choice: turn `setFollowsDefaultOutput` off first, or the next recovery moves the
    /// engine back to the default output.
    public func setOutputDevice(_ device: AudioDeviceID) throws {
        try graphLock.withLock {
            let wasRunning = engine.isRunning
            engine.stop()
            guard let unit = engine.outputNode.audioUnit else {
                throw CoreAudioError(operation: "output node audio unit", status: -1)
            }
            var id = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                              0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { throw CoreAudioError(operation: "set CurrentDevice \(device)", status: status) }
            try connectAll(engine)
            if wasRunning {
                engine.prepare()
                try engine.start()
                let now = monotonicNanos()
                config.withLock { $0.lastOwnStartNanos = now }
            }
        }
        refreshLatency()
    }

    // MARK: Configuration changes

    /// What to pause/resume (mpv) around a recovery.
    public func setSourceControl(_ control: SourceControl?) { config.withLock { $0.sourceControl = control } }

    /// Called (on a private queue) after each recovery.
    public func setRecoveryHandler(_ handler: (@Sendable (RecoveryReport) -> Void)?) {
        config.withLock { $0.handler = handler }
    }

    /// When false, notifications are only counted (tests of the detection itself).
    public func setAutomaticRecovery(_ enabled: Bool) { config.withLock { $0.automatic = enabled } }

    public var configurationStats: ConfigurationStats { config.withLock { $0.stats } }

    private func observe(_ engine: AVAudioEngine) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.configurationChanged()
        }
    }

    /// E2 finding (docs/spikes/E2.md): on macOS 27 AVAudioEngine neither follows nor reports a change of the
    /// system default output to a same-format device; it keeps rendering to the old one. When enabled, a HAL
    /// listener on `kAudioHardwarePropertyDefaultOutputDevice` drives the same debounced recovery, which then binds
    /// the output unit to the new default (`kAudioOutputUnitProperty_CurrentDevice`).
    public func setFollowsDefaultOutput(_ enabled: Bool) {
        guard renderingMode == .live else { return }
        config.withLock { $0.followsDefault = enabled }
        graphLock.withLock {
            var address = OutputDevices.globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
            let system = AudioObjectID(kAudioObjectSystemObject)
            if enabled, defaultListener == nil {
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.trigger(.defaultOutput) }
                if AudioObjectAddPropertyListenerBlock(system, &address, configQueue, block) == noErr {
                    defaultListener = block
                }
            } else if !enabled, let block = defaultListener {
                AudioObjectRemovePropertyListenerBlock(system, &address, configQueue, block)
                defaultListener = nil
            }
        }
    }

    /// Runs the debounced recovery as if the default output had just changed (callers that changed it before
    /// enabling `setFollowsDefaultOutput`).
    public func followDefaultOutputNow() { trigger(.defaultOutput) }

    enum Trigger { case configurationChange, defaultOutput, recheck }

    private func configurationChanged() { trigger(.configurationChange) }

    /// Debounce for a trigger at `now`: short for a configuration change that closely follows our own engine start.
    static func debounce(for trigger: Trigger, now: UInt64, lastOwnStart: UInt64) -> TimeInterval {
        switch trigger {
        case .recheck:
            return selfInflictedDebounceInterval
        case .configurationChange where lastOwnStart > 0 && now >= lastOwnStart
            && Double(now - lastOwnStart) < selfInflictedWindow * 1e9:
            return selfInflictedDebounceInterval
        default:
            return debounceInterval
        }
    }

    /// Runs on whatever thread posts (AVAudioEngine's, or the HAL listener queue); never takes `graphLock`, since
    /// AVAudioEngine may post from inside a graph call on another thread. Nothing pauses here: `recover()` pauses only
    /// if it has to restart the engine (a configuration change has already stopped it; a default-output change
    /// leaves it playing on the old device until the move).
    private func trigger(_ trigger: Trigger) {
        let now = monotonicNanos()
        let (generation, first, debounce, proceed) = config.withLock { s -> (Int, Bool, TimeInterval, Bool) in
            switch trigger {
            case .configurationChange:
                s.stats.notifications += 1
                s.stats.lastNotificationNanos = now
            case .defaultOutput:
                s.stats.defaultOutputChanges += 1
                s.stats.lastDefaultOutputChangeNanos = now
            case .recheck:
                break
            }
            if s.recovering {
                if trigger != .recheck { s.stats.ignoredDuringRecovery += 1 }
                s.recheck = true
                return (s.generation, false, 0, false)
            }
            s.generation += 1
            let first = s.burstCount == 0
            let debounce = Self.debounce(for: trigger, now: now, lastOwnStart: s.lastOwnStartNanos)
            if first {
                s.burstStart = now
                s.burstDebounce = debounce
            } else {
                // A burst keeps the window of its first trigger unless a later one needs a longer one.
                s.burstDebounce = max(s.burstDebounce, debounce)
            }
            s.burstCount += 1
            return (s.generation, first, s.burstDebounce, s.automatic)
        }
        log.info("audio configuration trigger \(String(describing: trigger), privacy: .public) (first in burst: \(first, privacy: .public), debounce \(Int(debounce * 1000)) ms)")
        guard proceed else { return }
        configQueue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self, self.config.withLock({ $0.generation }) == generation else { return }
            self.recover()
        }
    }

    /// After the quiet window. If the engine is idle-stopped, only rebinds the device. If it is still running on
    /// the device it should use, nothing happens and nothing paused (the output unit can follow the default output
    /// by itself, and our own device switch can post a late notification). Otherwise: host pause (waiting for the
    /// ramp if audio is flowing) and source pause, then stop + reset (avoids -10868), bind the new default if
    /// following it, reconnect, start (3 tries, then rebuild), and resume with a short fade.
    private func recover() {
        let startNanos = monotonicNanos()
        let (burstStart, burstCount, debounce, control, handler, follow, idle) = config.withLock { s in
            s.recovering = true
            s.recheck = false
            defer { s.burstCount = 0 }
            return (s.burstStart, s.burstCount, s.burstDebounce, s.sourceControl, s.handler, s.followsDefault,
                    s.idleStopped)
        }
        var action = RecoveryReport.Action.restart
        var attempts = 0
        var rebuilt = false
        var succeeded = false
        var lastError: String?
        var pausedAudio = false

        // Decide.
        let callbacksRecent = monotonicNanos() < bridge.counters.lastCallbackNanos + 100_000_000
        let (moveTo, healthy) = graphLock.withLock { () -> (AudioDeviceID?, Bool) in
            let current = Self.currentDevice(of: engine)
            let wanted = follow ? OutputDevices.defaultOutput() : nil
            return (wanted.flatMap { $0 != current ? $0 : nil }, engine.isRunning && callbacksRecent)
        }
        if idle {
            // The engine stays stopped; resumeFromIdleStop() reconnects with the new device's format.
            action = moveTo == nil ? .none : .moveDevice
            if let device = moveTo { lastError = graphLock.withLock { Self.bind(engine, to: device) } }
            succeeded = lastError == nil
        } else if moveTo == nil, healthy {
            action = .none
            succeeded = true
        } else {
            // Silence first, then the source: mpv's pause empties the AO read, so it waits for the ramp (E1).
            if !bridge.isHostPaused {
                if healthy { hostPauseAndWaitForRamp(timeout: 0.03) } else { bridge.setHostPaused(true) }
                pausedAudio = true
                control?.pause()
            }
            graphLock.withLock {
                // An idle stop (idleStopNow, from another thread) may have landed since the decision: stay stopped.
                if config.withLock({ $0.idleStopped }) {
                    if let device = moveTo { lastError = Self.bind(engine, to: device) }
                    action = moveTo == nil ? .none : .moveDevice
                    succeeded = lastError == nil
                    return
                }
                engine.stop()
                if let device = moveTo {
                    // A move binds the device before the first start of a fresh engine. Rebinding the running
                    // engine's output unit instead made the HAL post a configuration change ~100 ms after the
                    // restart on a device's first use, stopping the engine again (E2: first move 465-498 ms; this
                    // way 236 ms with no notification; docs/spikes/M3-audio.md).
                    action = .moveDevice
                    do {
                        try rebuildLocked(bindingTo: device)
                        attempts = 1
                        try engine.start()
                        succeeded = true
                        rebuilt = true
                        return
                    } catch {
                        lastError = "move: \(error)"
                        if let error = Self.bind(engine, to: device) { lastError = error }
                    }
                }
                engine.reset()
                for attempt in 1...Self.maxStartAttempts {
                    attempts = attempt
                    do {
                        try connectAll(engine)
                        engine.prepare()
                        try engine.start()
                        succeeded = true
                        break
                    } catch {
                        lastError = "\(error)"
                        usleep(50_000)
                    }
                }
                if !succeeded {
                    do {
                        try rebuildLocked(bindingTo: moveTo)
                        attempts += 1
                        try engine.start()
                        succeeded = true
                        rebuilt = true
                    } catch {
                        lastError = "rebuild: \(error)"
                    }
                }
            }
        }
        let idleNow = config.withLock { $0.idleStopped }
        let restarted = succeeded && action != .none && !idleNow
        if restarted { config.withLock { $0.lastOwnStartNanos = monotonicNanos() } }
        refreshLatency()
        var resumed: UInt64 = 0
        if pausedAudio, succeeded, !idleNow {
            control?.resume()
            hostResume(fadeSeconds: Self.recoveryFadeSeconds)
            resumed = monotonicNanos()
        }
        let device = outputDevice
        let report = RecoveryReport(
            action: action, notifications: burstCount, firstNotificationNanos: burstStart,
            recoveryStartNanos: startNanos, resumedNanos: resumed, startAttempts: attempts, rebuilt: rebuilt,
            succeeded: succeeded, error: lastError, outputDevice: device,
            outputSampleRate: device.flatMap(OutputDevices.nominalSampleRate) ?? 0, pausedAudio: pausedAudio,
            debounceMs: debounce * 1000)
        let recheck = config.withLock { s -> Bool in
            s.recovering = false
            s.stats.recoveries += 1
            if !succeeded { s.stats.failedRecoveries += 1 }
            s.stats.last = report
            return s.recheck
        }
        if succeeded {
            log.info("audio engine recovery: \(String(describing: action), privacy: .public), \(attempts) start attempt(s), paused: \(pausedAudio, privacy: .public)")
        } else {
            log.error("audio engine recovery failed: \(lastError ?? "?", privacy: .public)")
        }
        handler?(report)
        // A trigger that arrived mid-recovery may mean the engine stopped again (e.g. a self-inflicted change right
        // after our start): look again after the short window instead of dropping it.
        if recheck { trigger(.recheck) }
    }

    /// Binds the (stopped) engine's output unit to `device`; returns an error description on failure.
    private static func bind(_ engine: AVAudioEngine, to device: AudioDeviceID) -> String? {
        guard let unit = engine.outputNode.audioUnit else { return "no output audio unit" }
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        return status == noErr ? nil : "set CurrentDevice \(device): OSStatus \(status)"
    }

    // MARK: Graph

    static func makeEQ() -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: eqFrequencies.count)
        for (i, frequency) in eqFrequencies.enumerated() {
            let band = eq.bands[i]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = eqBandwidthOctaves
            band.gain = 0
            band.bypass = false
        }
        eq.globalGain = 0
        eq.bypass = false
        return eq
    }

    private static func makeEngine(_ mode: RenderingMode, format: AVAudioFormat) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        if case .offline(let frames) = mode {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frames)
        }
        return engine
    }

    private func wire(_ engine: AVAudioEngine) throws {
        engine.attach(bridge.sourceNode)
        engine.attach(eq)
        try connectAll(engine)
    }

    /// source → EQ → main mixer at 48 kHz stereo; main mixer → output at the device's current format.
    private func connectAll(_ engine: AVAudioEngine) throws {
        let format = bridge.format
        try GraphCompat.connect(engine, bridge.sourceNode, to: eq, format: format)
        try GraphCompat.connect(engine, eq, to: engine.mainMixerNode, format: format)
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        if hardware.sampleRate > 0, hardware.channelCount > 0,
           let output = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                      channels: hardware.channelCount) {
            try GraphCompat.connect(engine, engine.mainMixerNode, to: engine.outputNode, format: output)
        }
        engine.mainMixerNode.outputVolume = Self.mixerVolume(forVolume: volume)
    }

    /// Replaces the AVAudioEngine, moving the source and EQ nodes over (after repeated start failures). The new
    /// output unit is bound to `device` before anything is connected or started.
    private func rebuildLocked(bindingTo device: AudioDeviceID?) throws {
        engine.stop()
        engine.detach(bridge.sourceNode)
        engine.detach(eq)
        let fresh = try Self.makeEngine(renderingMode, format: bridge.format)
        if let device, let error = Self.bind(fresh, to: device) { log.error("rebuild: \(error, privacy: .public)") }
        engine = fresh
        try wire(fresh)
        if renderingMode == .live { observe(fresh) }
        applyEQLocked()
        fresh.prepare()
    }

    static func currentDevice(of engine: AVAudioEngine) -> AudioDeviceID? {
        guard let unit = engine.outputNode.audioUnit else { return nil }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, &size)
        return status == noErr && device != 0 ? device : nil
    }

    /// Test seam: the underlying engine (graph introspection only).
    var avEngine: AVAudioEngine { graphLock.withLock { engine } }
}
