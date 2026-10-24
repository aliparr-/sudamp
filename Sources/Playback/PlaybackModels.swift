// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import MPV
import Picker
import Resolver

/// The stream on screen (marquee, Playlist row, Now Playing).
nonisolated public struct StreamInfo: Sendable, Equatable, Codable {
    public var id: StreamID
    public var source: SourceKind
    /// `YT`, `SC`, `MC` or `FM`.
    public var tag: String
    public var title: String
    public var creator: String
    public var kind: StreamKind
    public var isLive: Bool
    /// The feed's duration (mpv's, once known, is `PlayerSnapshot.duration`).
    public var durationSec: Int?
    /// Where Copy Link points (the canonical page, or the station's homepage).
    public var link: URL?

    public init(_ s: StreamRef) {
        id = s.id
        source = s.source
        tag = s.source.tag
        title = s.title
        creator = s.creator
        kind = s.kind
        isLive = s.kind.isLive
        durationSec = s.durationSec
        link = s.isRadio ? s.homepage : s.url
    }
}

/// The stream engine (yt-dlp) as the status line shows it (DESIGN §3: `PREPARING STREAM ENGINE 63%`).
nonisolated public struct EngineStatus: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable {
        case unknown, checking, ready, missing, corrupt, installing, failed
        /// `--no-engine`: radio only by choice.
        case disabled
    }

    public var state: State
    public var version: String?
    /// 0...1 while downloading.
    public var progress: Double?
    /// The install phase (`downloading`, `verifying`, …) or the failure kind (`unreachable`, `noSpace`, `failed`).
    public var download: String?
    public var message: String?
    /// After a failed install: when the next automatic retry runs (DESIGN §6.1 "retried with backoff").
    public var retryAt: Date?
    /// Failed installs in a row.
    public var attempts: Int?
    /// `repair` while a corrupt tree is reinstalled (the notice reads `UPDATING STREAM ENGINE`).
    public var purpose: String?
    /// The last update check: `checking`, or its result (`upToDate`, `switched`, `canaryFailed`, …).
    public var update: String?

    public init(state: State, version: String? = nil, progress: Double? = nil, download: String? = nil,
                message: String? = nil, retryAt: Date? = nil, attempts: Int? = nil) {
        self.state = state
        self.version = version
        self.progress = progress
        self.download = download
        self.message = message
        self.retryAt = retryAt
        self.attempts = attempts
    }

    public var isReady: Bool { state == .ready }

    /// The status-line notice while only radio can play, nil when the engine is ready.
    public var notice: String? {
        switch state {
        case .ready, .unknown, .checking, .disabled: nil
        case .installing:
            purpose == "repair" ? "UPDATING STREAM ENGINE \(Int(((progress ?? 0) * 100).rounded()))%"
                : "PREPARING STREAM ENGINE \(Int(((progress ?? 0) * 100).rounded()))%"
        case .missing, .corrupt: "STREAM ENGINE MISSING - RADIO ONLY"
        case .failed: download == "noSpace" ? "STREAM ENGINE NEEDS 180 MB FREE - RADIO ONLY" : "ENGINE DOWNLOAD FAILED - RADIO ONLY"
        }
    }
}

/// The last thing that went wrong, for the status line and `state.json` (`.lastError.kind`).
nonisolated public struct PlaybackErrorInfo: Sendable, Equatable, Codable {
    /// A failure class (`unavailable`, `transient`, `engine`, `botCheck`), or `audioEngine`, `timeout`, `deferred`,
    /// `internal`.
    public var kind: String
    public var message: String
    public var streamId: StreamID?
    /// `resolve`, `load`, `firstAudio`, `guard`, …
    public var stage: String
    public var at: Date

    public init(kind: String, message: String, streamId: StreamID?, stage: String, at: Date) {
        self.kind = kind
        self.message = message
        self.streamId = streamId
        self.stage = stage
        self.at = at
    }
}

/// One time-to-first-audio measurement (also logged as the `ttfa` metrics event).
nonisolated public struct TTFAInfo: Sendable, Equatable, Codable {
    /// From the user action (genre pick, Next, …) to the first non-silent sample.
    public var ms: Double
    /// From this stream's own pick (differs from `ms` after skipped failures).
    public var attemptMs: Double
    public var source: SourceKind
    public var streamId: StreamID
    public var tier: Int?
    /// The pick came from the prefetch.
    public var prefetched: Bool
    /// Its resolution came from the cache (prefetch or an earlier resolve).
    public var fromCache: Bool
    /// What started it: `selectGenre`, `next`, `previous`, `auto`, `retry`, `liveReload`, …
    public var trigger: String
    public var at: Date
}

/// What the decoder delivers, for the skin's kbps / kHz / stereo fields (mpv's `audio-bitrate` and `audio-params`).
nonisolated public struct AudioFormatInfo: Sendable, Equatable, Codable {
    public var kbps: Int?
    /// Hz (44100, 48000, …).
    public var sampleRate: Int?
    public var channels: Int?

    public init(kbps: Int? = nil, sampleRate: Int? = nil, channels: Int? = nil) {
        self.kbps = kbps
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// From an engine position sample; nil when it carries nothing.
    public init?(_ p: PlayerPosition) {
        let kbps = p.audioBitrate.flatMap { $0.isFinite && $0 > 0 ? Int(($0 / 1000).rounded()) : nil }
        guard kbps != nil || p.sampleRate != nil || p.channelCount != nil else { return nil }
        self.init(kbps: kbps, sampleRate: p.sampleRate, channels: p.channelCount)
    }
}

/// Everything a UI needs to draw playback, published on every change (`PlaybackController.snapshots()`).
nonisolated public struct PlayerSnapshot: Sendable, Equatable, Codable {
    public var phase: PlaybackPhase
    public var genre: GenreID?
    public var genreName: String?
    public var stream: StreamInfo?
    public var icyTitle: String?
    /// VOD position and duration in seconds (refreshed about once a second while playing).
    public var position: Double?
    public var duration: Double?
    public var seekable: Bool?
    public var engine: EngineStatus
    /// Only radio can play (engine missing, installing or disabled).
    public var radioOnly: Bool
    /// The audio engine guard failed: playback is refused (`AUDIO ENGINE ERROR`).
    public var audioEngineError: String?
    public var offline: Bool
    public var lastError: PlaybackErrorInfo?
    public var lastTTFA: TTFAInfo?
    public var statusText: String
    public var volume: Double
    public var balance: Double
    public var streamsStarted: Int
    public var failuresInARow: Int
    /// Bitrate, rate and channels of what plays (playing, paused or buffering).
    public var audioFormat: AudioFormatInfo?
    /// The current stream is a favourite (⌘F).
    public var isFavourite = false
    /// ★ Favourites is playing: picks come from the favourites, at random.
    public var favouritesMode = false
    /// Shuffle ("Surprise-genre mode"): Next and auto-advance move to a random genre.
    public var shuffleGenres = false
    /// Repeat: a finished VOD plays again instead of the next pick.
    public var repeatStream = false
    /// The position slider works: a VOD with a known length (live streams and radio can't seek).
    public var canSeek = false

    public init(phase: PlaybackPhase = .idle, genre: GenreID? = nil, genreName: String? = nil, stream: StreamInfo? = nil,
                icyTitle: String? = nil, position: Double? = nil, duration: Double? = nil, seekable: Bool? = nil,
                engine: EngineStatus = EngineStatus(state: .unknown), radioOnly: Bool = true,
                audioEngineError: String? = nil, offline: Bool = false, lastError: PlaybackErrorInfo? = nil,
                lastTTFA: TTFAInfo? = nil, statusText: String = PlayerSnapshot.idleText, volume: Double = 100,
                balance: Double = 0, streamsStarted: Int = 0, failuresInARow: Int = 0) {
        self.phase = phase
        self.genre = genre
        self.genreName = genreName
        self.stream = stream
        self.icyTitle = icyTitle
        self.position = position
        self.duration = duration
        self.seekable = seekable
        self.engine = engine
        self.radioOnly = radioOnly
        self.audioEngineError = audioEngineError
        self.offline = offline
        self.lastError = lastError
        self.lastTTFA = lastTTFA
        self.statusText = statusText
        self.volume = volume
        self.balance = balance
        self.streamsStarted = streamsStarted
        self.failuresInARow = failuresInARow
    }

    /// Equal apart from what moves while a stream plays (position, length, bitrate).
    public func sameExceptProgress(_ other: PlayerSnapshot) -> Bool {
        var a = self, b = other
        a.position = nil
        b.position = nil
        a.duration = nil
        b.duration = nil
        a.audioFormat = nil
        b.audioFormat = nil
        return a == b
    }

    public static let idleText = "*** CLICK HERE TO PICK A GENRE ***"
    public static let audioEngineErrorText = "AUDIO ENGINE ERROR"

    /// `state.json`'s `.state`: the phase, or `audioEngineError`.
    public var stateName: String { audioEngineError != nil ? "audioEngineError" : phase.rawValue }
}

/// `<profile>/debug/state.json` (DESIGN §9 agent hooks): flat keys the PLAN's `jq` checks read (`.state`, `.genre`,
/// `.source`, `.ttfaMs`, `.stream.id`, `.engine.download`, `.lastError.kind`, `.resumed`), plus internals.
nonisolated public struct PlaybackDebugState: Sendable, Equatable, Codable {
    public struct Counters: Sendable, Equatable, Codable {
        public var streamsStarted = 0
        public var failures = 0
        public var deferrals = 0
        public var liveReloads = 0
        public var prefetches = 0
        public var unhandledErrors = 0
        /// Mid-stream reloads at the current position (DESIGN §6.3).
        public var recoveries = 0
        /// Background re-resolves before expiry.
        public var refreshes = 0
        public var breakerTrips = 0
        public var updateChecks = 0
        public var offlineEpisodes = 0
    }

    public var state: String
    public var genre: GenreID?
    public var source: SourceKind?
    public var ttfaMs: Double?
    public var stream: StreamInfo?
    public var engine: EngineStatus
    public var lastError: PlaybackErrorInfo?
    /// This launch auto-resumed the last session (DESIGN §3 "Returning launch").
    public var resumed: Bool
    /// The returning-launch decision, when one was made (`ResumePlan.description`).
    public var resumePlan: String?
    /// What Shell last published to the system's Now Playing (`.nowPlaying.playbackState`, PLAN M2).
    public var nowPlaying: NowPlayingInfo?
    public var snapshot: PlayerSnapshot
    public var resolver: ResolverStatus
    public var prefetched: StreamID?
    public var network: NetworkPathStatus?
    public var proxy: String?
    public var counters: Counters
    public var recentTTFA: [TTFAInfo]
    public var player: PlayerDiagnostics
    public var pid: Int32
    public var updatedAt: Date
    /// The skin on screen (`.skin.id`, PLAN M5), set by Shell.
    public var skin: AppSkinDebugInfo?
    /// The front end's state (`.ui`: skinned or plain, windows, scale, menus, EQ, toggles), set by Shell.
    public var ui: AppUIDebugInfo?
    /// favourites and bans (library.json).
    public var library: LibraryDebugInfo?
    /// Source breakers by platform (DESIGN §6.4; session.json `.breakers`).
    public var breakers: [String: BreakerSummary]?
    /// The last engine update check (DESIGN §6.1).
    public var engineUpdate: EngineUpdateOutcome?
    /// The launch `--version` warm-up.
    public var engineWarmUp: EngineWarmUp?
}

/// `state.json` `.skin`.
nonisolated public struct AppSkinDebugInfo: Sendable, Equatable, Codable {
    /// `sudamp-dark`, `andamp-dark`, `andamp-light`, `andamp-spot`, `museum:<md5>` for the bundled Winamp Skin Museum
    /// skins, or `user:<file name>` for skins in `<profile>/Skins`.
    public var id: String
    public var name: String
    /// `builtIn`, `bundled`, `museum` or `user`.
    public var origin: String
    public var path: String?
    /// Sheets drawn from sudamp Dark because the skin lacks them.
    public var fallbackSheets: [String]
    /// region.txt sections the skin has (applied unless the kill switch is off).
    public var regions: [String]

    public init(id: String, name: String, origin: String, path: String? = nil, fallbackSheets: [String] = [],
                regions: [String] = []) {
        self.id = id
        self.name = name
        self.origin = origin
        self.path = path
        self.fallbackSheets = fallbackSheets
        self.regions = regions
    }
}

/// `state.json` `.ui`.
nonisolated public struct AppUIDebugInfo: Sendable, Equatable, Codable {
    nonisolated public struct Window: Sendable, Equatable, Codable {
        public var open: Bool
        public var shaded: Bool
        public var visible: Bool
        /// AppKit frame: x, y, width, height in points.
        public var frame: [Double]

        public init(open: Bool, shaded: Bool, visible: Bool, frame: [Double]) {
            self.open = open
            self.shaded = shaded
            self.visible = visible
            self.frame = frame
        }
    }

    nonisolated public struct Equalizer: Sendable, Equatable, Codable {
        public var enabled: Bool
        public var auto: Bool
        public var preamp: Double
        public var bands: [Double]
        /// The preset last chosen from the presets menu or loaded from an .eqf file.
        public var preset: String?

        public init(enabled: Bool, auto: Bool, preamp: Double, bands: [Double], preset: String? = nil) {
            self.enabled = enabled
            self.auto = auto
            self.preamp = preamp
            self.bands = bands
            self.preset = preset
        }
    }

    /// `skinned` (a classic skin), `modern` or `plain`.
    public var mode: String
    public var scale: Double?
    public var windows: [String: Window]?
    public var alwaysOnTop: Bool?
    /// region.txt shaping (spike S1's kill switch).
    public var regionEnabled: Bool?
    /// The first-launch genre menu opened by itself (DESIGN §3).
    public var menuAutoOpened: Bool
    /// The menu open right now (`genre`, `presets`, `context`, …), if any.
    public var openMenu: String?
    public var equalizer: Equalizer?
    public var timeDisplay: String?
    public var visualizerMode: String?
    /// The last alert sheet shown (e.g. a rejected skin), with whether it is still up.
    public var lastSheet: String?
    public var sheetOpen: Bool
    /// `modern` or `classic` (nil with `--plain`).
    public var skinClass: String?
    /// The modern skin's appearance, tint and open panels (`equalizer`, `stations`).
    public var appearance: String?
    public var tint: String?
    public var panels: [String]?
    /// The modern visualiser's rotation (seconds per scene), what colours its artwork (`genre`, `window`, …) and the
    /// effect over it (`none`, `vhs`, `kaleidoscope`).
    public var visualizerInterval: Double?
    public var artworkColors: String?
    public var visualizerEffect: String?
    /// Whether the modern visualiser is drawing, and why it is or isn't (the window's visibility, the output latency).
    public var visualizerRunning: Bool?
    public var visualizerDetail: String?

    public init(mode: String, scale: Double? = nil, windows: [String: Window]? = nil, alwaysOnTop: Bool? = nil,
                regionEnabled: Bool? = nil, menuAutoOpened: Bool = false, openMenu: String? = nil,
                equalizer: Equalizer? = nil, timeDisplay: String? = nil, visualizerMode: String? = nil,
                lastSheet: String? = nil, sheetOpen: Bool = false, skinClass: String? = nil, appearance: String? = nil,
                tint: String? = nil, panels: [String]? = nil, visualizerInterval: Double? = nil,
                artworkColors: String? = nil, visualizerEffect: String? = nil, visualizerRunning: Bool? = nil,
                visualizerDetail: String? = nil) {
        self.mode = mode
        self.scale = scale
        self.windows = windows
        self.alwaysOnTop = alwaysOnTop
        self.regionEnabled = regionEnabled
        self.menuAutoOpened = menuAutoOpened
        self.openMenu = openMenu
        self.equalizer = equalizer
        self.timeDisplay = timeDisplay
        self.visualizerMode = visualizerMode
        self.lastSheet = lastSheet
        self.sheetOpen = sheetOpen
        self.skinClass = skinClass
        self.appearance = appearance
        self.tint = tint
        self.panels = panels
        self.visualizerInterval = visualizerInterval
        self.artworkColors = artworkColors
        self.visualizerEffect = visualizerEffect
        self.visualizerRunning = visualizerRunning
        self.visualizerDetail = visualizerDetail
    }
}

/// `state.json` `.library`: favourites and bans in library.json.
nonisolated public struct LibraryDebugInfo: Sendable, Equatable, Codable {
    public var favourites: [StreamID]
    public var banned: [StreamID]
    public var historyCount: Int

    public init(favourites: [StreamID], banned: [StreamID], historyCount: Int) {
        self.favourites = favourites
        self.banned = banned
        self.historyCount = historyCount
    }
}
