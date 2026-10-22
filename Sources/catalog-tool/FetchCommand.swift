// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Feeds
import Foundation
import Resolver

/// `catalog-tool fetch`: a headless harness for the app's launch sequence (PLAN M7 live checks): load the bundled
/// feed, read `<profile>/feed/`, `FeedService.refresh(budget:)` against the feed URL, then (with `--choose`) let
/// EngineStore choose a yt-dlp version from the resulting active document's `pin`/`block`, recording `feed.*` and
/// `engine.choose` in `<profile>/Logs/metrics.jsonl` like the app.
enum FetchCommand {
    static let usage = """
    usage: catalog-tool fetch --profile <dir> [--url <feed.json URL>] [--budget 5] [--bundled <feed.json>] [--choose]
      The feed URL defaults to SUDAMP_FEED_URL (debug builds; http://127.0.0.1 allowed) or the production URL.
      Trust: this build's embedded keys (debug builds include Fixtures/keys/test-ed25519.pub).
    """

    struct Report: Encodable {
        var url: String?
        var outcome: String
        var detail: String
        var refreshMs: Double
        var activeRevision: Int
        var activeOrigin: String
        var bundledRevision: Int
        var cachedRevision: Int?
        var engineChoice: String?
        var engineReason: String?
        var engineChooseAtMs: Double?
        var block: [String]
        var pin: String?
        var sinceStartMs: Double
    }

    static func run(_ args: ToolArgs, started: ContinuousClock.Instant) async -> Int32 {
        guard let profile = args.string("profile") else { stderr(usage); return 64 }
        let paths = Paths.profile(URL(filePath: (profile as NSString).expandingTildeInPath, directoryHint: .isDirectory))
        do { try paths.createDirectories() } catch { stderr("fetch: \(error)"); return 1 }
        let time = SystemTimeSource()
        let metrics = MetricsLog(url: paths.metricsFile, time: time)
        metrics.record("tool.launch", ["tool": "catalog-tool fetch", "pid": Int(getpid())])

        let bundled: LoadedFeed
        do {
            bundled = try BundledFeed.loadDefault(override: args.string("bundled").map { URL(filePath: $0) })
        } catch {
            stderr("fetch: \(error)")
            return 1
        }
        let url = args.string("url").flatMap(URL.init(string:)) ?? FeedEndpoint.resolve()
        var client: (any RemoteFeedFetching)?
        if let url {
            do { client = try RemoteFeedClient(feedURL: url) } catch { stderr("fetch: \(error)"); return 1 }
        }
        let service = FeedService(bundled: bundled,
                                  configuration: FeedServiceConfiguration(trust: .embedded,
                                                                          cache: FeedCache(directory: paths.feedDirectory)),
                                  client: client, time: time, metrics: metrics)
        let budget = args.double("budget") ?? 5
        let result = await service.refresh(budget: .milliseconds(Int(budget * 1000)))
        let active = result.active
        var report = Report(url: url?.absoluteString, outcome: result.outcome.name, detail: result.outcome.description,
                            refreshMs: result.ms, activeRevision: active.document.revision,
                            activeOrigin: active.origin.rawValue, bundledRevision: bundled.document.revision,
                            cachedRevision: service.cached?.document.revision, block: active.document.engine.block,
                            pin: active.document.engine.pin?.version, sinceStartMs: 0)

        if args.flag("choose") {
            let store = EngineStore(layout: EngineLayout(paths: paths), metrics: metrics)
            let policy = EngineInstallPolicy(feed: active.document.engine)
            do {
                let (choice, _) = try await store.choose(config: policy)
                report.engineChoice = choice.version
                report.engineReason = choice.reason.rawValue
                report.engineChooseAtMs = milliseconds(ContinuousClock.now - started)
                metrics.record("engine.choose", ["version": choice.version, "reason": choice.reason.rawValue,
                                                 "feedRevision": active.document.revision,
                                                 "feedOrigin": active.origin.rawValue, "via": "catalog-tool fetch"])
            } catch {
                stderr("fetch: engine choice failed: \(error)")
                report.engineReason = "error: \(error)"
            }
        }
        report.sinceStartMs = milliseconds(ContinuousClock.now - started)
        printJSON(report)
        return 0
    }
}
