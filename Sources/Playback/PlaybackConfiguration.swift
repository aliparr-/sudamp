// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Feeds
import Foundation
import Picker
import Resolver

/// How the controller treats the stream engine (yt-dlp).
nonisolated public enum EngineMode: String, Sendable, Codable {
    /// Use it when installed and verified; radio only otherwise.
    case automatic
    /// As `automatic`, and install it in the background when missing or corrupt (the app's first launch).
    case install
    /// Radio only (`sudamp-dev play --no-engine`).
    case disabled
}

/// Every delay the controller uses (DESIGN §3, §5.2, §6.3), so tests and tools can shorten them.
nonisolated public struct PlaybackTimings: Sendable, Equatable {
    /// A user pick whose resolve takes longer fails as transient and the next pick plays.
    public var resolveTimeout: TimeInterval = 15
    /// A load with no first audio by then fails as transient.
    public var firstAudioTimeout: TimeInterval = 20
    /// Prefetch the next pick this long after first audio (depth 1).
    public var prefetchDelay: TimeInterval = 10
    /// session.json and library.json are written at most this often.
    public var persistDebounce: TimeInterval = 2
    /// Live streams and radio paused longer than this rejoin the live edge on resume.
    public var liveReloadAfter: TimeInterval = 30
    /// The audio engine stops after this long paused or idle.
    public var suspendOutputAfter: TimeInterval = 30
    public var debugStateDebounce: TimeInterval = 0.25
    /// state.json rewrites for position-only changes (the 1 s tick while playing) happen at most this often.
    public var debugStateProgressInterval: TimeInterval = 5
    /// Position refresh while playing.
    public var positionRefresh: TimeInterval = 1
    /// How long `SKIPPING - UNAVAILABLE` stays in the status text.
    public var flashDuration: TimeInterval = 2
    /// A lost network path must stay lost this long before the session goes `offline` (Wi-Fi roaming blips).
    public var offlineDebounce: TimeInterval = 2
    /// … and this long while a stream is playing, whose demuxer cache (`cache-secs=30`) carries it through a short
    /// outage. A playback failure while the path is down goes offline at once.
    public var offlineDebouncePlaying: TimeInterval = 10
    /// A playing stream's URL is re-resolved this long before it expires (DESIGN §6.3: 10 min).
    public var refreshBeforeExpiry: TimeInterval = 600
    /// A failed background re-resolve is retried after this long (at most `refreshAttempts` times).
    public var refreshRetry: TimeInterval = 60
    public var refreshAttempts = 3
    /// A stream must have played this long since its last (re)load before a mid-stream error reloads it again.
    public var recoveryMinimumPlay: TimeInterval = 5
    /// At most this many mid-stream recoveries per stream within `recoveryWindow`; then it moves on.
    public var recoveryLimit = 3
    public var recoveryWindow: TimeInterval = 600
    /// A VOD that ends more than this before mpv's duration ended early (a dead URL can read as EOF): recover.
    public var prematureEndMargin: TimeInterval = 30
    /// The launch update check waits this long after the engine is ready, so it never competes with the first pick.
    public var launchUpdateDelay: TimeInterval = 30
    /// The daily update check (DESIGN §6.1).
    public var dailyUpdateInterval: TimeInterval = 24 * 3600

    public init() {}
}

/// Debug-only playback faults (`SUDAMP_FAULT`, PLAN M6). `stream:expire[=<refresh>/<fail>]`: on a VOD, `refresh`
/// seconds (default 15) after first audio the background re-resolve runs as if the URL were 10 min from expiry, and
/// `fail` seconds (default 25) after first audio the stream dies with a mid-stream HTTP 403, as an expired URL would.
nonisolated public struct PlaybackFaults: Sendable, Equatable {
    public var streamExpire = false
    public var expireRefreshAfter: TimeInterval = 15
    public var expireFailAfter: TimeInterval = 25

    public init(streamExpire: Bool = false, refreshAfter: TimeInterval = 15, failAfter: TimeInterval = 25) {
        self.streamExpire = streamExpire
        expireRefreshAfter = refreshAfter
        expireFailAfter = failAfter
    }

    public static let none = PlaybackFaults()

    public static func from(environment: [String: String] = ProcessInfo.processInfo.environment) -> PlaybackFaults {
        #if DEBUG
        parse(environment["SUDAMP_FAULT"] ?? "")
        #else
        .none
        #endif
    }

    public static func parse(_ value: String) -> PlaybackFaults {
        var f = PlaybackFaults()
        for item in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard item == "stream:expire" || item.hasPrefix("stream:expire=") else { continue }
            f.streamExpire = true
            guard let eq = item.firstIndex(of: "=") else { continue }
            let parts = item[item.index(after: eq)...].split(separator: "/").compactMap { TimeInterval($0) }
            if parts.count == 2, parts[0] > 0, parts[1] > parts[0], parts[1] < 3600 {
                f.expireRefreshAfter = parts[0]
                f.expireFailAfter = parts[1]
            }
        }
        return f
    }
}

/// What a controller instance does (the profile, the engine mode, source restrictions, debug output).
nonisolated public struct PlaybackConfiguration: Sendable {
    public var paths: Paths
    public var timings = PlaybackTimings()
    public var engineMode: EngineMode = .automatic
    public var prefetchEnabled = true
    /// Restricts picks to these sources (`sudamp-dev play --source`); nil allows every source the feed enables.
    public var allowedSources: Set<SourceKind>?
    /// Write `<profile>/debug/state.json` on changes (debounced).
    public var writeDebugState = true
    /// Load and save session.json and library.json.
    public var persistState = true
    /// A failed engine guard asserts (debug builds, DESIGN §5.3). Tests that inject guard failures turn it off.
    public var assertOnGuardFailure: Bool
    /// Initial volume 0...100.
    public var volume: Double = 100
    /// Deferrals in a row before the next one counts as a failure (keeps a genre of ad-gated items from spinning).
    public var maxDeferralsInARow = 8
    /// Fixed seed for the Picker's randomness (tests); nil uses the system generator.
    public var randomSeed: UInt64?
    /// Debug-only playback faults (`stream:expire`).
    public var faults = PlaybackFaults()
    /// Engine updates (DESIGN §6.1): launch after 24 h, daily, after a pin first install, after engine failures.
    public var engineUpdates = true
    /// Follow radio redirects ourselves before mpv opens a station, checking every hop's host with the private-
    /// address rule, then let FFmpeg follow none (`max_redirects=0`).
    public var radioRedirectCheck = true

    public init(paths: Paths) {
        self.paths = paths
        #if DEBUG
        assertOnGuardFailure = true
        #else
        assertOnGuardFailure = false
        #endif
    }
}

/// The controller's collaborators. `PlaybackController.live(…)` builds the real ones; tests pass fakes.
public struct PlaybackDependencies {
    public var feed: LoadedFeed
    public var resolver: any StreamResolving
    public var player: any PlayerEngine
    /// Nil: no engine store (radio only).
    public var engines: (any EngineProviding)?
    public var network: (any NetworkPathObserving)?
    public var scheduler: any PlaybackScheduler
    public var time: any TimeSource
    public var metrics: MetricsLog?
    /// The radio DNS rule (DESIGN §7.1).
    public var hosts: any HostResolving
    /// Read before every load (DESIGN §6.2: the system proxy goes to mpv as `http-proxy`).
    public var proxy: @Sendable () -> ProxyResolution
    /// The radio redirect walk's requests (M6 security item).
    public var redirects: any RedirectFetching

    public init(feed: LoadedFeed, resolver: any StreamResolving, player: any PlayerEngine,
                engines: (any EngineProviding)?, network: (any NetworkPathObserving)?, scheduler: any PlaybackScheduler,
                time: any TimeSource, metrics: MetricsLog?, hosts: any HostResolving = SystemHostResolver(),
                proxy: @escaping @Sendable () -> ProxyResolution = { SystemProxy.current() },
                redirects: any RedirectFetching = URLSessionRedirectFetcher()) {
        self.redirects = redirects
        self.feed = feed
        self.resolver = resolver
        self.player = player
        self.engines = engines
        self.network = network
        self.scheduler = scheduler
        self.time = time
        self.metrics = metrics
        self.hosts = hosts
        self.proxy = proxy
    }
}

extension FailureClass {
    /// The Resolver's classes are the Picker's (same names, DESIGN §6.4).
    nonisolated init(_ c: ResolveFailureClass) {
        self = FailureClass(rawValue: c.rawValue) ?? .engine
    }
}

/// The Picker's randomness: seeded in tests, the system generator otherwise.
nonisolated struct PlaybackRandom: RandomNumberGenerator {
    private var seeded: SeededRandom?
    private var system = SystemRandomNumberGenerator()

    init(seed: UInt64?) { seeded = seed.map { SeededRandom(seed: $0) } }

    mutating func next() -> UInt64 {
        if seeded != nil { return seeded!.next() }
        return system.next()
    }
}
