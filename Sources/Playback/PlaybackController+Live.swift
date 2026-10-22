// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Feeds
import Foundation
import Resolver

/// Options for the real stack that aren't controller policy.
nonisolated public struct LivePlaybackOptions: Sendable {
    /// AUDIO SAFETY for tools and tests: mixer volume 0 and the bridge output zeroed after measurement.
    public var silent = false
    /// QuickJS-NG for tier 2 (`defaultQuickJS()` finds the app's or the dev cache's).
    public var quickJS: URL?
    public var mpvLogLevel = "warn"
    /// Debug-only `SUDAMP_FAULT` resolver faults.
    public var faults = ResolverFaults.from()
    /// Debug-only `SUDAMP_FAULT` engine faults (`engine:unreachable`, `engine:abort-at=<pct>`, `disk:full`,
    /// `engine:corrupt`, `engine:bad-update`).
    public var engineFaults = EngineFaults.from()
    /// Debug-only `SUDAMP_FAULT=net:offline[=<s>[@<after>]]`.
    public var networkFaults = NetworkFaults.from()
    /// Debug-only `SUDAMP_FAULT=stream:expire[=<refresh>/<fail>]`.
    public var playbackFaults = PlaybackFaults.from()
    /// Probe progressive YouTube prefetches with a 64 KB range GET.
    public var rangeProbe = true

    public init(silent: Bool = false, quickJS: URL? = nil) {
        self.silent = silent
        self.quickJS = quickJS
    }
}

extension PlaybackController {
    /// The real stack for `configuration.paths` (DESIGN §4): ResolverService + StreamResolver (bucket, cache, tiers,
    /// proxy, probe; `resolver.json` in the profile), EngineStore, mpv + the pull AO + AVAudioEngine, NWPathMonitor,
    /// the system proxy and DNS, and `metrics.jsonl`. Call `prepare()` before the first action.
    public static func live(configuration: PlaybackConfiguration, feed: LoadedFeed,
                            options: LivePlaybackOptions = LivePlaybackOptions()) throws -> PlaybackController {
        let paths = configuration.paths
        try paths.createDirectories()
        let time = SystemTimeSource()
        let metrics = MetricsLog(url: paths.metricsFile, time: time)
        let layout = EngineLayout(paths: paths)
        let service = ResolverService(layout: layout, engine: nil, qjs: options.quickJS,
                                      settings: ResolverSettings(engine: feed.document.engine), time: time, metrics: metrics)
        let resolver = StreamResolver(backend: service, time: time, stateFile: Self.resolverStateFile(paths),
                                      probe: options.rangeProbe ? URLSessionMediaProbe() : nil, metrics: metrics,
                                      faults: options.faults)
        let player = try MPVPlayerEngine(volume: configuration.volume, silent: options.silent, logLevel: options.mpvLogLevel)
        let ef = options.engineFaults, rf = options.faults
        if ef.isActive || rf.isActive || options.networkFaults.isActive || options.playbackFaults != .none {
            metrics.record("faults", ["unreachable": ef.unreachable, "abortAtPercent": ef.abortAtPercent ?? 0,
                                      "diskFull": ef.diskFull, "engineCorrupt": ef.corrupt, "badUpdate": ef.badUpdate,
                                      "youtube403": rf.youtube403, "youtubeBotCheck": rf.youtubeBotCheck,
                                      "youtubeTimeout": rf.youtubeTimeout, "mixcloudRepeatPlay": rf.mixcloudRepeatPlay,
                                      "resolveDelay": rf.resolveDelay ?? 0,
                                      "netOffline": options.networkFaults.offlineFor ?? 0,
                                      "streamExpire": options.playbackFaults.streamExpire])
        }
        var engines: (any EngineProviding)?
        if configuration.engineMode != .disabled {
            let store = EngineStore(layout: layout, releases: ef.releases(GitHubReleases()),
                                    freeSpace: ef.freeSpace { DiskSpace.available(at: $0) }, time: time, metrics: metrics)
            let canary = EngineCanary(layout: layout, qjs: options.quickJS,
                                      probe: options.rangeProbe ? URLSessionMediaProbe() : nil,
                                      tokens: { [resolver] purpose in await resolver.spendToken(for: purpose) },
                                      faults: rf, badUpdate: ef.badUpdate, metrics: metrics)
            let updater = EngineUpdater(store: store, stable: ef.releases(GitHubReleases()),
                                        nightly: ef.releases(GitHubReleases(repo: GitHubReleases.nightlyRepo)),
                                        canary: canary, time: time, metrics: metrics, badUpdate: ef.badUpdate)
            engines = EngineService(store: store, updater: updater, faults: ef, metrics: metrics)
        }
        var configuration = configuration
        configuration.faults = options.playbackFaults
        let dependencies = PlaybackDependencies(
            feed: feed, resolver: resolver, player: player, engines: engines,
            network: options.networkFaults.observer(SystemNetworkPathMonitor()), scheduler: TaskScheduler(), time: time,
            metrics: metrics)
        return PlaybackController(configuration: configuration, dependencies: dependencies)
    }

    /// `<profile>/resolver.json`: the tier-2 preference and the bot-check pause.
    nonisolated public static func resolverStateFile(_ paths: Paths) -> URL { paths.appSupport.appending(path: "resolver.json") }

    /// QuickJS-NG for tier 2: the app's `Contents/Helpers/qjs`, else `$SUDAMP_QJS`, else the copy
    /// `scripts/fetch-qjs.sh` caches in `~/Library/Caches/sudamp-dev`. Nil when none is executable.
    nonisolated public static func defaultQuickJS(bundle: Bundle = .main,
                                                  environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        candidates.append(bundle.bundleURL.appending(path: "Contents/Helpers/qjs"))
        if let env = environment["SUDAMP_QJS"], !env.isEmpty { candidates.append(URL(filePath: env)) }
        candidates.append(fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/sudamp-dev/qjs-v0.17.0/qjs-darwin-arm64"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}
