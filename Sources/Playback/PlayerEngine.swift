// SPDX-License-Identifier: GPL-3.0-or-later
import Audio
import Foundation
import MPV
import Picker

/// One `loadfile` issued by the controller. Events about older loads are ignored, so a late end-file for a stream
/// the user already skipped can't advance the new one.
nonisolated public struct PlayerLoadID: Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
    public var description: String { "load#\(raw)" }
}

/// What to open and how (per-file mpv options, DESIGN §5.2).
nonisolated public struct PlayerLoadRequest: Sendable, Equatable {
    public var url: URL
    public var options: LoadFileOptions

    public init(url: URL, options: LoadFileOptions) {
        self.url = url
        self.options = options
    }
}

nonisolated public enum PlayerEndReason: Sendable, Equatable {
    /// A finite stream ended (or a live one closed for good).
    case endOfFile
    /// mpv failed to open or lost the stream; classified for health and backoff.
    case error(String, FailureClass)
}

/// Engine events, tagged with the load they belong to.
nonisolated public enum PlayerEvent: Sendable, Equatable {
    /// The first non-silent sample of this load reached the render callback (`CLOCK_UPTIME_RAW` nanoseconds, the
    /// C-side TTFA stamp, DESIGN §2).
    case firstAudio(PlayerLoadID, nanos: UInt64)
    case ended(PlayerLoadID, PlayerEndReason)
}

/// Observed playback values for the UI (VOD position, ICY titles).
nonisolated public struct PlayerPosition: Sendable, Equatable, Codable {
    public var timePos: Double?
    public var duration: Double?
    public var seekable: Bool?
    public var mediaTitle: String?
    public var icyTitle: String?
    /// mpv's `audio-bitrate`, bits per second.
    public var audioBitrate: Double?
    public var pausedForCache: Bool?
    /// The decoder's output rate and channel count (`audio-params`: what the skin's kHz and stereo fields show).
    public var sampleRate: Int?
    public var channelCount: Int?

    public init(timePos: Double? = nil, duration: Double? = nil, seekable: Bool? = nil, mediaTitle: String? = nil,
                icyTitle: String? = nil, audioBitrate: Double? = nil, pausedForCache: Bool? = nil,
                sampleRate: Int? = nil, channelCount: Int? = nil) {
        self.timePos = timePos
        self.duration = duration
        self.seekable = seekable
        self.mediaTitle = mediaTitle
        self.icyTitle = icyTitle
        self.audioBitrate = audioBitrate
        self.pausedForCache = pausedForCache
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// Engine counters for reports (`sudamp-dev play`).
nonisolated public struct PlayerDiagnostics: Sendable, Equatable, Codable {
    public var callbacks: UInt64 = 0
    public var shortReads: UInt64 = 0
    public var silentCallbacks: UInt64 = 0
    public var aoInitCount: Int64 = 0
    public var aoErrorCount: Int64 = 0
    public var outputRunning = false
    public var mixerVolume: Float = 0
    public var outputMuted = false

    public init() {}
}

/// The audio side of playback as the controller sees it: mpv + the pull AO + AVAudioEngine in the app
/// (`MPVPlayerEngine`), a recording fake in tests. Main-actor bound; implementations hop off-main themselves.
public protocol PlayerEngine: AnyObject {
    /// Every event, in order. Finishes at shutdown.
    var events: AsyncStream<PlayerEvent> { get }
    /// DESIGN §5.3 startup guard (`mpv-version` starts with `mpv v0.41.`); empty when fine.
    func startupGuardFailures() -> [String]
    /// DESIGN §5.3 first-file and every-read guards; empty when fine. Checked after each first audio.
    func guardFailures() -> [String]
    /// Opens `request`, replacing whatever plays, unpausing if paused. The first audio is reported as an event.
    func load(_ request: PlayerLoadRequest) throws -> PlayerLoadID
    /// Silence behind the 5 ms ramp first, then mpv's pause once the ramp has rendered (engine integration rule).
    func pause() async
    /// mpv first, then the host flag (with an optional fade).
    func resume(fadeSeconds: Double)
    /// Stops the file; the engine stays ready.
    func stop()
    func setVolume(_ volume: Double)
    func setBalance(_ balance: Double)
    func position() -> PlayerPosition
    func diagnostics() -> PlayerDiagnostics
    /// Stops the audio output after 30 s paused or idle (DESIGN §5.2); the next load or resume restarts it.
    func suspendOutput()
    var isOutputSuspended: Bool { get }
    /// Engine shutdown order: audio engine first, then mpv (DESIGN §5.2). Idempotent.
    func shutdown()
    /// Fades the next delivered audio in from silence over `seconds` (the 1.5 s launch fade of an auto-resume,
    /// DESIGN §3). The fade advances only while audio is delivered, so it can be requested before the load.
    func fadeIn(seconds: Double)
    /// Seeks the current file to `seconds` (VOD only; the controller checks). Just the command: mpv's `ao_reset`
    /// clears its queue (DESIGN §5.2 Lifecycle).
    func seek(to seconds: Double)
    /// The ten-band EQ, preamp and on/off (DESIGN §5.4: gains live in the AVAudioUnitEQ, never in mpv).
    func applyEqualizer(_ settings: EQSettings)
    /// The render bridge whose mono ring feeds the visualiser analyser (nil for engines without audio output).
    var renderBridge: RenderBridge? { get }
}

extension PlayerEngine {
    /// Engines without a fade start at full level.
    public func fadeIn(seconds: Double) {}
    /// Engines without seeking ignore it.
    public func seek(to seconds: Double) {}
    /// Engines without an EQ ignore it.
    public func applyEqualizer(_ settings: EQSettings) {}
    public var renderBridge: RenderBridge? { nil }
}
