// SPDX-License-Identifier: GPL-3.0-or-later
import Audio
import Core
import Foundation
import MPV
import Picker
import os

/// The live engine: libmpv with the sudamp pull AO feeding `AudioEngine` (DESIGN §5). It follows the engine agent's
/// integration rules: pause = `hostPauseAndWaitForRamp()` then `setPause(true)`; resume = `setPause(false)` then
/// `hostResume`; shutdown = `AudioEngine.stop()` then `MPVClient.shutdown()`; the output follows the default device.
///
/// TTFA: the render bridge is armed on mpv's `start-file` for the new entry (off the main actor, after mpv has cut
/// the previous file's audio, E1 "stale quanta 0"), and the C-side stamp is polled until it appears. Loads are
/// matched to mpv playlist entries through `loadfile`'s `playlist_entry_id` reply, so a late `end-file` of a
/// replaced file is never mistaken for the new one's.
///
/// AUDIO SAFETY: `silent` (every tool and test) forces mixer volume 0 and zeroes the bridge output after the TTFA
/// measurement, so nothing reaches the device.
public final class MPVPlayerEngine: PlayerEngine {
    public let audio: AudioEngine
    public let mpv: MPVClient
    public let events: AsyncStream<PlayerEvent>
    public let silent: Bool

    private let continuation: AsyncStream<PlayerEvent>.Continuation
    private let log = Log.logger("player")
    private var nextLoad: UInt64 = 1
    private var current: PlayerLoadID?
    private var requestToLoad: [UInt64: PlayerLoadID] = [:]
    private var entryToLoad: [Int64: PlayerLoadID] = [:]
    private var unclaimedStarts: [Int64] = []
    private var awaitingFirstAudio: PlayerLoadID?
    private var resumeHostOnStart = false
    private var mpvPaused = false
    /// Bumped by every resume/load/stop, so a pause whose ramp wait finishes late doesn't re-pause.
    private var transportGeneration: UInt64 = 0
    private var outputSuspended = false
    private var isShutDown = false
    private var pumpTask: Task<Void, Never>?
    private var relayTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    public init(volume: Double, silent: Bool, logLevel: String = "warn", followDefaultOutput: Bool = true) throws {
        self.silent = silent
        audio = try AudioEngine(volume: silent ? 0 : volume)
        if silent { audio.bridge.setOutputMuted(true) }
        let (relayStream, relay) = AsyncStream.makeStream(of: MPVEvent.self, bufferingPolicy: .unbounded)
        // No `eventHandler`: MPVClient keeps it in a Mutex and reads it with `withLock { $0 }` per event, which on
        // Swift 6.4 wraps the stored closure in two more reabstraction thunks every time, until the 512 KB event
        // thread overflows (~100 s of playback). The `events` stream has no such problem.
        mpv = try MPVClient(options: MPVOptions.defaults, logLevel: logLevel)
        relayTask = Task.detached { [mpv = mpv, bridge = audio.bridge] in
            await MPVEventRelay.pump(mpv.events, bridge: bridge, relay: relay)
        }
        (events, continuation) = AsyncStream.makeStream(of: PlayerEvent.self, bufferingPolicy: .unbounded)
        let mpv = self.mpv
        audio.setSourceControl(SourceControl(pause: { _ = try? mpv.setPause(true) },
                                             resume: { _ = try? mpv.setPause(false) }))
        if followDefaultOutput { audio.setFollowsDefaultOutput(true) }
        try audio.start()
        pumpTask = Task { [weak self] in
            for await event in relayStream { self?.handle(event) }
        }
    }

    // MARK: Guards

    public func startupGuardFailures() -> [String] {
        let g = mpv.guards()
        return g.versionOK ? [] : ["mpv-version \(g.mpvVersion ?? "nil") does not start with \(EngineGuards.versionPrefix)"]
    }

    public func guardFailures() -> [String] { mpv.guards().failures }

    // MARK: Transport

    public func load(_ request: PlayerLoadRequest) throws -> PlayerLoadID {
        try ensureOutput()
        transportGeneration &+= 1
        let id = PlayerLoadID(nextLoad)
        nextLoad += 1
        current = id
        awaitingFirstAudio = nil
        pollTask?.cancel()
        let requestID = try mpv.loadfile(request.url.absoluteString, options: request.options)
        requestToLoad[requestID] = id
        if mpvPaused {
            try mpv.setPause(false)
            mpvPaused = false
        }
        // Stay silent until mpv has switched files, so nothing of the paused stream leaks out.
        resumeHostOnStart = audio.bridge.isHostPaused
        return id
    }

    public func pause() async {
        transportGeneration &+= 1
        let generation = transportGeneration
        let audio = self.audio
        await TransportOrder.pause(
            hostPauseAndWaitForRamp: { _ = await Task.detached { audio.hostPauseAndWaitForRamp() }.value },
            pauseDecoder: { [self] in
                guard generation == transportGeneration, !isShutDown else { return }
                do {
                    try mpv.setPause(true)
                    mpvPaused = true
                } catch {
                    log.error("mpv pause failed: \(error, privacy: .public)")
                }
            })
    }

    public func resume(fadeSeconds: Double) {
        transportGeneration &+= 1
        do { try ensureOutput() } catch { log.error("audio engine restart failed: \(error, privacy: .public)") }
        TransportOrder.resume(
            resumeDecoder: { [self] in
                if mpvPaused {
                    _ = try? mpv.setPause(false)
                    mpvPaused = false
                }
            },
            hostResume: { [audio] in audio.hostResume(fadeSeconds: fadeSeconds) })
    }

    public func stop() {
        transportGeneration &+= 1
        current = nil
        awaitingFirstAudio = nil
        pollTask?.cancel()
        _ = try? mpv.stop()
    }

    public func setVolume(_ volume: Double) {
        guard !silent else { return }
        audio.setVolume(volume)
    }

    public func setBalance(_ balance: Double) { audio.setBalance(balance) }

    public func fadeIn(seconds: Double) { audio.bridge.fadeIn(seconds: seconds) }

    public func seek(to seconds: Double) {
        guard !isShutDown, seconds.isFinite else { return }
        do { _ = try mpv.seek(to: max(0, seconds)) } catch { log.error("mpv seek failed: \(error, privacy: .public)") }
    }

    public func applyEqualizer(_ settings: EQSettings) { audio.apply(settings) }

    public var renderBridge: RenderBridge? { audio.bridge }

    public func position() -> PlayerPosition {
        let s = mpv.snapshot
        return PlayerPosition(timePos: s.timePos, duration: s.duration, seekable: s.seekable, mediaTitle: s.mediaTitle,
                              icyTitle: s.icyTitle, audioBitrate: s.audioBitrate, pausedForCache: s.pausedForCache,
                              sampleRate: s.audioParams?.samplerate, channelCount: s.audioParams?.channelCount)
    }

    public func diagnostics() -> PlayerDiagnostics {
        let c = audio.bridge.counters
        var d = PlayerDiagnostics()
        d.callbacks = c.callbacks
        d.shortReads = c.shortReads
        d.silentCallbacks = c.silentCallbacks
        d.aoInitCount = PullAO.initCount
        d.aoErrorCount = PullAO.errorCount
        d.outputRunning = audio.isRunning
        d.mixerVolume = audio.mixerOutputVolume
        d.outputMuted = silent
        return d
    }

    public var isOutputSuspended: Bool { outputSuspended }

    public func suspendOutput() {
        guard !outputSuspended, !isShutDown else { return }
        // idleStopNow, not stop(): device recovery treats a plain stop as a dead engine and restarts it.
        audio.idleStopNow()
        outputSuspended = true
        log.info("audio output suspended (paused or idle for 30 s)")
    }

    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        pollTask?.cancel()
        TransportOrder.shutdown(stopAudio: { [audio] in audio.stop() }, shutdownDecoder: { [mpv] in mpv.shutdown() })
        continuation.finish()
        pumpTask?.cancel()
        relayTask?.cancel()
    }

    private func ensureOutput() throws {
        guard outputSuspended || !audio.isRunning else { return }
        // resumeFromIdleStop rebinds the current default device and reconnects with its format; a plain start()
        // would not after a device change while suspended.
        if !(try audio.resumeFromIdleStop()), !audio.isRunning {
            try audio.start()
        }
        outputSuspended = false
    }

    // MARK: mpv events (main actor, in order)

    private func handle(_ event: MPVEvent) {
        switch event {
        case let .commandReply(requestID, error, result):
            guard let id = requestToLoad.removeValue(forKey: requestID) else { return }
            if error < 0 {
                if id == current {
                    continuation.yield(.ended(id, .error("loadfile failed: \(MPVClient.errorString(error))", .transient)))
                }
                return
            }
            if let entry = result["playlist_entry_id"]?.int {
                entryToLoad[entry] = id
                if let i = unclaimedStarts.firstIndex(of: entry) {
                    unclaimedStarts.remove(at: i)
                    didStart(id)
                }
            } else if !unclaimedStarts.isEmpty {
                // Older libmpv without the reply field: entries start in command order.
                let entry = unclaimedStarts.removeFirst()
                entryToLoad[entry] = id
                didStart(id)
            }
        case let .startFile(entry):
            if let id = entryToLoad[entry] {
                didStart(id)
            } else {
                unclaimedStarts.append(entry)
                if unclaimedStarts.count > 8 { unclaimedStarts.removeFirst(unclaimedStarts.count - 8) }
            }
        case let .endFile(end):
            guard let id = entryToLoad.removeValue(forKey: end.playlistEntryID), id == current else { return }
            switch end.reason {
            case .eof:
                current = nil
                continuation.yield(.ended(id, .endOfFile))
            case .error:
                current = nil
                let lines = mpv.recentErrors
                let message = ([end.errorDescription ?? "error \(end.error)"] + lines.suffix(3)).joined(separator: " | ")
                continuation.yield(.ended(id, .error(message, Self.classify(errorLines: lines.suffix(6)))))
            case .stop, .quit, .redirect, .unknown:
                break
            }
        default:
            break
        }
    }

    private func didStart(_ id: PlayerLoadID) {
        guard id == current else { return }
        if resumeHostOnStart {
            resumeHostOnStart = false
            audio.hostResume()
        }
        awaitingFirstAudio = id
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.checkFirstAudio() == false else { return }
                try? await Task.sleep(for: .milliseconds(4))
            }
        }
    }

    /// True once reported (or nothing is awaited).
    private func checkFirstAudio() -> Bool {
        guard let id = awaitingFirstAudio else { return true }
        guard let nanos = audio.bridge.ttfaNanos else { return false }
        awaitingFirstAudio = nil
        continuation.yield(.firstAudio(id, nanos: nanos))
        return true
    }

    /// mpv/FFmpeg error lines → failure class: a 403 is an engine problem (DESIGN §6.4: "403 on a fresh URL"), gone
    /// or unplayable media is unavailable, anything else (timeouts, resets, 5xx) is transient.
    nonisolated static func classify<S: Sequence>(errorLines: S) -> FailureClass where S.Element == String {
        let text = errorLines.joined(separator: " ").lowercased()
        if text.contains("403") { return .engine }
        if text.contains("404") || text.contains("410") || text.contains("failed to recognize file format")
            || text.contains("unrecognized file format") || text.contains("no audio") {
            return .unavailable
        }
        return .transient
    }
}

/// Filters mpv's event stream off the main actor: arms the TTFA stamp the moment a file starts, and forwards the
/// few events the engine needs (DESIGN §5.5: callbacks hop via a stream), so property changes (`time-pos` many
/// times a second) never reach the main actor.
nonisolated enum MPVEventRelay {
    static func pump(_ events: AsyncStream<MPVEvent>, bridge: RenderBridge, relay: AsyncStream<MPVEvent>.Continuation) async {
        for await event in events {
            switch event {
            case .startFile:
                bridge.armTTFA()
                relay.yield(event)
            case .endFile, .commandReply:
                relay.yield(event)
            case .shutdown:
                relay.finish()
                return
            default:
                break
            }
        }
        relay.finish()
    }
}

/// The engine integration rules as code, so their order is unit-tested (DESIGN §5.2 Lifecycle):
/// - pause: the host flag first and wait until the 5 ms ramp has rendered, then mpv (pausing mpv first empties the
///   AO read and cuts the ramp, E1);
/// - resume: mpv first, then the host flag (so the first callbacks read fresh audio);
/// - shutdown: the audio engine first, then mpv's stop → wakeup → join → destroy (the wrong order crashed the spike).
enum TransportOrder {
    static func pause(hostPauseAndWaitForRamp: () async -> Void, pauseDecoder: () -> Void) async {
        await hostPauseAndWaitForRamp()
        pauseDecoder()
    }

    static func resume(resumeDecoder: () -> Void, hostResume: () -> Void) {
        resumeDecoder()
        hostResume()
    }

    static func shutdown(stopAudio: () -> Void, shutdownDecoder: () -> Void) {
        stopAudio()
        shutdownDecoder()
    }
}
