// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Feeds
import Foundation
import Picker
import Playback
import Resolver
import Synchronization

/// `sudamp-dev ttfa --source radio,radio-http,soundcloud,mixcloud,youtube,youtube-live -n N [--profile P]
///  [--feed <path>] [--no-engine] [--json]` (PLAN M1).
///
/// End-to-end time to first audio per source through the real `PlaybackController`: a genre pick → Picker →
/// resolve → loadfile → the first non-silent sample at the render callback. Every pick is cold: prefetch is off and
/// the resolution cache is cleared before each run. `radio-http` plays the feed's stations over plain `http://`
/// (most of them serve both). Picks rotate through the genres that have the source. YouTube runs are spaced at
/// least 3 s apart. Each source's p50 is compared with its DESIGN §2 row. AUDIO SAFETY as for `play`.
enum TTFACommand {
    static let usage = """
    usage: sudamp-dev ttfa --source radio,radio-http,soundcloud,mixcloud,youtube,youtube-live -n N [--profile P]
                           [--feed <path>] [--no-engine] [--timeout S] [--radio-redirects=false] [--json]
    """

    /// DESIGN §2 targets (p50; p90 for YouTube).
    struct Target: Encodable {
        var row: String
        var p50Ms: Double
        var p90Ms: Double?
    }

    struct Run: Encodable {
        var genre: String
        var ok: Bool
        var ms: Double?
        var attemptMs: Double?
        var streamId: String?
        var tier: Int?
        var failuresBeforeStart: Int
        var error: String?
    }

    struct SourceResult: Encodable {
        var source: String
        var n: Int
        var ok: Int
        var p50Ms: Double?
        var p90Ms: Double?
        var minMs: Double?
        var maxMs: Double?
        var target: Target
        var meetsTarget: Bool
        var runs: [Run]
    }

    struct Report: Encodable {
        var profile: String
        var engine: EngineStatus?
        var results: [SourceResult]
        var allMeetTargets: Bool
        var metricsFile: String
    }

    static func target(for source: String, noEngine: Bool) -> Target {
        switch source {
        case "radio", "radio-http":
            noEngine ? Target(row: "First launch, engine downloading (radio)", p50Ms: 2000)
                : Target(row: "Radio (HTTP or HTTPS)", p50Ms: 1500)
        case "soundcloud": Target(row: "Cold SoundCloud pick", p50Ms: 2000)
        case "mixcloud": Target(row: "Cold Mixcloud pick", p50Ms: 2500)
        default: Target(row: "Cold YouTube pick (VOD or /live)", p50Ms: 3000, p90Ms: 3500)
        }
    }

    @MainActor
    static func run(_ args: Args) async throws -> Int32 {
        let names = (args.string("source") ?? "").split(separator: ",").map(String.init)
        let valid = Set(["radio", "radio-http", "soundcloud", "mixcloud", "youtube", "youtube-live"])
        guard !names.isEmpty, names.allSatisfy(valid.contains) else {
            stderr(usage)
            return 64
        }
        let n = max(1, args.int("n") ?? 3)
        let timeout = args.double("timeout") ?? 30
        let noEngine = args.flag("no-engine")
        let json = args.flag("json")
        let paths = Paths.resolve()
        let lock: InstanceLock
        do {
            lock = try InstanceLock.acquire(paths: paths)
        } catch {
            stderr("sudamp-dev ttfa: \(error)")
            return 75
        }
        defer { lock.release() }
        let baseFeed = try DevFeed.load(args)
        let interrupted = Atomic<Bool>(false)
        let signals = SignalWatcher { _ in interrupted.store(true, ordering: .relaxed) }
        defer { signals.cancel() }

        var results: [SourceResult] = []
        var engine: EngineStatus?
        for name in names where !interrupted.load(ordering: .relaxed) {
            let kind: SourceKind = name == "radio-http" ? .radio : SourceKind(rawValue: name)!
            let feed = name == "radio-http" ? try httpRadioFeed(baseFeed) : baseFeed
            let genres = feed.document.catalog.genres.map(\.id).filter { g in
                feed.document.catalog.streams(in: g).contains { $0.source == kind }
            }
            guard !genres.isEmpty else {
                stderr("ttfa: no \(name) streams in the feed")
                continue
            }
            var config = PlaybackConfiguration(paths: paths)
            config.volume = 0
            config.prefetchEnabled = false
            config.allowedSources = [kind]
            config.engineMode = noEngine ? .disabled : .automatic
            config.writeDebugState = false
            // Measurements stay clean: no background update check (M6) competes with the picks.
            config.engineUpdates = false
            // `--radio-redirects=false`: let FFmpeg follow station redirects itself (the pre-M6 behaviour), to measure
            // what the M6 redirect walk costs.
            if args.string("radio-redirects") == "false" { config.radioRedirectCheck = false }
            let controller = try PlaybackController.live(
                configuration: config, feed: feed,
                options: LivePlaybackOptions(silent: true, quickJS: PlaybackController.defaultQuickJS()))
            await controller.prepare()
            engine = controller.snapshot.engine
            var runs: [Run] = []
            for i in 0..<n where !interrupted.load(ordering: .relaxed) {
                await controller.clearResolutionCache()
                let genre = genres[i % genres.count]
                let before = controller.ttfaHistory.count
                let failuresBefore = controller.debugCounters.failures
                controller.start(genre: genre)
                let deadline = monotonicNanos() + UInt64(timeout * 1e9)
                var run = Run(genre: genre.rawValue, ok: false, failuresBeforeStart: 0)
                while monotonicNanos() < deadline, !interrupted.load(ordering: .relaxed) {
                    try? await Task.sleep(for: .milliseconds(20))
                    if controller.ttfaHistory.count > before, let t = controller.ttfaHistory.last {
                        run.ok = true
                        run.ms = t.ms
                        run.attemptMs = t.attemptMs
                        run.streamId = t.streamId.rawValue
                        run.tier = t.tier
                        break
                    }
                    if controller.phase == .failed || controller.snapshot.audioEngineError != nil { break }
                }
                run.failuresBeforeStart = controller.debugCounters.failures - failuresBefore
                if !run.ok { run.error = controller.snapshot.lastError.map { "\($0.kind)/\($0.stage): \($0.message)" } ?? "timeout" }
                if !json {
                    stderr("\(name) \(i + 1)/\(n) \(genre): \(run.ok ? String(format: "%.0f ms", run.ms ?? 0) : "failed") "
                           + "\(run.streamId ?? "")\(run.failuresBeforeStart > 0 ? " after \(run.failuresBeforeStart) failure(s)" : "")"
                           + "\(run.error.map { " — \($0)" } ?? "")")
                }
                runs.append(run)
                controller.stop()
                // Settle between runs; YouTube resolves stay ≥ 3 s apart.
                try? await Task.sleep(for: .seconds(kind.platform == .youtube ? 3 : 1))
            }
            await controller.shutdown()
            let times = runs.filter(\.ok).compactMap(\.ms)
            let t = target(for: name, noEngine: noEngine)
            let p50 = Stats.p50(times), p90 = Stats.percentile(times, 90)
            let meets = p50.map { $0 <= t.p50Ms } ?? false && (t.p90Ms == nil || (p90.map { $0 <= t.p90Ms! } ?? false))
            results.append(SourceResult(source: name, n: runs.count, ok: times.count, p50Ms: p50, p90Ms: p90,
                                        minMs: times.min(), maxMs: times.max(), target: t, meetsTarget: meets, runs: runs))
        }
        let report = Report(profile: paths.appSupport.path, engine: engine, results: results,
                            allMeetTargets: !results.isEmpty && results.allSatisfy(\.meetsTarget),
                            metricsFile: paths.metricsFile.path)
        if json {
            printReport(report, pretty: true)
        } else {
            for r in results {
                print("\(r.source): \(r.ok)/\(r.n) ok, p50 \(Stats.text(r.p50Ms)), p90 \(Stats.text(r.p90Ms)) "
                      + "(target p50 ≤ \(Int(r.target.p50Ms)) ms\(r.target.p90Ms.map { ", p90 ≤ \(Int($0)) ms" } ?? ""): "
                      + (r.meetsTarget ? "meets" : "MISSES"))
            }
        }
        return report.allMeetTargets ? 0 : 1
    }

    /// The feed with every radio station rewritten to plain `http://` (IDs get a `-http` suffix).
    static func httpRadioFeed(_ feed: LoadedFeed) throws -> LoadedFeed {
        let catalog = feed.document.catalog
        var streams: [StreamRef] = []
        for s in catalog.streams where s.source == .radio {
            guard var c = URLComponents(url: s.url, resolvingAgainstBaseURL: false) else { continue }
            c.scheme = "http"
            if c.port == 443 { c.port = nil }
            guard let url = c.url, let ref = try? Canonicaliser.canonicalRef(url.absoluteString, for: .radio),
                  let id = StreamID(rawValue: s.id.rawValue + "-http") else { continue }
            streams.append(StreamRef(id: id, source: .radio, ref: ref, kind: s.kind, title: s.title, creator: s.creator,
                                     genres: s.genres, durationSec: s.durationSec, weight: s.weight, homepage: s.homepage))
        }
        let document = FeedDocument(schema: feed.document.schema, revision: feed.document.revision,
                                    generatedAt: feed.document.generatedAt, expiresAt: feed.document.expiresAt,
                                    catalog: FeedCatalog(genres: catalog.genres, streams: streams), engine: feed.document.engine)
        return LoadedFeed(document: document, origin: feed.origin, url: feed.url)
    }
}
