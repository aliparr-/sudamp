// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Feeds
import Foundation
import Resolver

/// `catalog-tool probe` (PLAN M7): resolves catalog items with the installed engine through the Resolver package
/// (the production argv, tier ladder and media-host allowlist), then range-GETs the result (64 KB for progressive
/// URLs, the playlist for HLS); radio gets RadioCheck. YouTube is rationed: at most `--youtube-limit` resolves
/// (default 5), at least `--youtube-interval` seconds apart (default 8), and a bot-check, LOGIN_REQUIRED or 429
/// stops all further YouTube requests.
enum ProbeCommand {
    static let usage = """
    usage: catalog-tool probe [<catalog-dir> | <feed.json>] --profile <dir> [--source k[,k…]] [--limit n]
                              [--youtube-limit 5] [--interval 1] [--youtube-interval 8] [--min-pass 0.95] [--json]
                              [--qjs <path>] [--ladder] [--install-engine]
      Items are taken round-robin across genres (feed order within a genre) so a --limit is a cross-section.
      The engine is the profile's (sudamp-dev engine install --profile <dir>, or --install-engine for the feed's pin).
      Tier 1 only; --ladder retries a YouTube engine-class failure at tier 2 (QuickJS), counted in the budget.
      Exit 0 when at least --min-pass of the attempted items pass.
    """

    struct Item: Encodable {
        var id: String
        var source: String
        var genre: String
        var ok: Bool
        var skipped: String?
        var ms: Double?
        var failureClass: String?
        var reason: String?
        var tier: Int?
        var format: String?
        var proto: String?
        var mediaHost: String?
        var rangeStatus: Int?
        var rangeBytes: Int?
        var durationSec: Double?
        var feedDurationSec: Int?
        var title: String?
        var radio: RadioCheck.Result?
    }

    struct Summary: Encodable {
        var attempted: Int
        var passed: Int
        var failed: Int
        var skipped: Int
        var passRate: Double
        var youtubeRequests: Int
        var youtubeStopped: String?
        var bySource: [String: [String: Int]]
    }

    struct Report: Encodable {
        var feed: String
        var revision: Int
        var engineVersion: String?
        var startedAt: String
        var summary: Summary
        var items: [Item]
    }

    static func run(_ args: ToolArgs) async -> Int32 {
        guard let profile = args.string("profile") else { stderr(usage); return 64 }
        let target = args.positionals.first.map { URL(filePath: ($0 as NSString).expandingTildeInPath) } ?? catalogDirectory(nil)
        guard let target else { stderr(usage); return 64 }
        let feedURL = isDirectory(target) ? target.appending(path: CatalogSource.feedFile) : target
        let feed: LoadedFeed
        do { feed = try BundledFeed.load(from: feedURL) } catch { stderr("probe: \(error)"); return 1 }
        let doc = feed.document

        var kinds = Set(SourceKind.allCases)
        if let list = args.list("source") {
            let parsed = list.compactMap(SourceKind.init(rawValue:))
            guard parsed.count == list.count else { stderr("probe: unknown --source \(list)"); return 64 }
            kinds = Set(parsed)
        }
        let limit = args.int("limit") ?? Int.max
        let youtubeLimit = args.int("youtube-limit") ?? 5
        let interval = args.double("interval") ?? 1
        let youtubeInterval = max(args.double("youtube-interval") ?? 8, 5)
        let minPass = args.double("min-pass") ?? 0.95
        let items = crossSection(doc.catalog, kinds: kinds)

        // The engine (only if a resolver source is selected).
        let paths = Paths.profile(URL(filePath: (profile as NSString).expandingTildeInPath, directoryHint: .isDirectory))
        let layout = EngineLayout(paths: paths)
        var service: ResolverService?
        var engineVersion: String?
        if kinds.contains(where: \.needsResolver) {
            let store = EngineStore(layout: layout, metrics: MetricsLog(url: paths.metricsFile))
            if await store.current() == nil, args.flag("install-engine") {
                do {
                    let report = try await store.install(config: EngineInstallPolicy(feed: doc.engine))
                    stderr("probe: installed yt-dlp \(report.version) (\(report.reason.rawValue)) into \(paths.appSupport.path)")
                } catch { stderr("probe: engine install failed: \(error)"); return 1 }
            }
            guard let current = await store.current() else {
                stderr("probe: no engine in \(paths.appSupport.path)")
                stderr("  run `sudamp-dev engine install --profile \(profile)` or pass --install-engine")
                return 1
            }
            do {
                let check = try await store.verifyTree()
                guard check.ok else { stderr("probe: engine tree mismatch, refusing to run it: \(check)"); return 1 }
            } catch { stderr("probe: \(error)"); return 1 }
            engineVersion = current.version
            let qjs = args.string("qjs") ?? ProcessInfo.processInfo.environment["SUDAMP_QJS"]
                ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Caches/sudamp-dev/qjs-v0.17.0/qjs-darwin-arm64").path
            service = ResolverService(layout: layout, engine: current.executableURL(in: layout),
                                      qjs: FileManager.default.isExecutableFile(atPath: qjs) ? URL(filePath: qjs) : nil,
                                      settings: ResolverSettings(engine: doc.engine), proxy: SystemProxy.current().url,
                                      metrics: MetricsLog(url: paths.metricsFile))
        }

        var out: [Item] = []
        var youtubeRequests = 0
        var youtubeStopped: String?
        var lastResolveEnd: ContinuousClock.Instant?
        var lastYouTubeEnd: ContinuousClock.Instant?
        var attempted = 0
        let startedAt = Date()
        for (stream, genre) in items {
            guard attempted < limit else { break }
            var item = Item(id: stream.id.rawValue, source: stream.source.rawValue, genre: genre.rawValue, ok: false,
                            feedDurationSec: stream.durationSec)
            let isYouTube = stream.source.platform == .youtube
            if isYouTube {
                if let why = youtubeStopped { item.skipped = why; out.append(item); continue }
                if youtubeRequests >= youtubeLimit { item.skipped = "youtube budget (\(youtubeLimit))"; out.append(item); continue }
            }
            attempted += 1
            if stream.isRadio {
                let r = await RadioCheck.check(stream.url)
                item.radio = r
                item.ok = r.ok
                item.ms = r.ms
                item.reason = r.error
            } else if let service {
                // Spacing: >= interval between resolves, >= youtubeInterval (>= 5 s) between YouTube requests.
                await pause(after: lastResolveEnd, seconds: interval)
                if isYouTube { await pause(after: lastYouTubeEnd, seconds: youtubeInterval); youtubeRequests += 1 }
                // Every yt-dlp run counts against the YouTube budget, so tier 2 (QuickJS) only runs with --ladder.
                await resolve(stream, tier: .jsless, service: service, into: &item)
                if isYouTube, args.flag("ladder"), item.failureClass == ResolveFailureClass.engine.rawValue,
                   youtubeRequests < youtubeLimit, await service.qjs != nil {
                    await pause(after: .now, seconds: youtubeInterval)
                    youtubeRequests += 1
                    item = Item(id: item.id, source: item.source, genre: item.genre, ok: false, feedDurationSec: stream.durationSec)
                    await resolve(stream, tier: .quickjs, service: service, into: &item)
                }
                lastResolveEnd = .now
                if isYouTube {
                    lastYouTubeEnd = .now
                    if item.failureClass == ResolveFailureClass.botCheck.rawValue {
                        let why = "stopped after a bot-check/429 on \(stream.id)"
                        youtubeStopped = why
                        stderr("probe: \(why): no further YouTube requests")
                    }
                }
            }
            stderr("probe: \(item.ok ? "ok  " : "FAIL") \(item.id) \(item.ms.map { "\(Int($0)) ms" } ?? "") \(item.reason ?? "")")
            out.append(item)
        }

        let tried = out.filter { $0.skipped == nil }
        let passed = tried.filter(\.ok).count
        var bySource: [String: [String: Int]] = [:]
        for i in out {
            let key = i.skipped != nil ? "skipped" : i.ok ? "passed" : "failed"
            bySource[i.source, default: [:]][key, default: 0] += 1
        }
        let summary = Summary(attempted: tried.count, passed: passed, failed: tried.count - passed,
                              skipped: out.count - tried.count,
                              passRate: tried.isEmpty ? 0 : (Double(passed) / Double(tried.count) * 1000).rounded() / 1000,
                              youtubeRequests: youtubeRequests, youtubeStopped: youtubeStopped, bySource: bySource)
        let report = Report(feed: feedURL.path, revision: doc.revision, engineVersion: engineVersion,
                            startedAt: startedAt.formatted(.iso8601), summary: summary, items: out)
        if args.flag("json") {
            printJSON(report)
        } else {
            print("probe r\(doc.revision): \(passed)/\(tried.count) passed (\(Int(summary.passRate * 100))%), "
                + "\(summary.skipped) skipped, \(youtubeRequests) YouTube request(s)")
        }
        return !tried.isEmpty && summary.passRate >= minPass ? 0 : 1
    }

    /// Round-robin across genres (menu order); within a genre, round-robin across sources (feed order inside each),
    /// so a small `--limit` still samples every genre and source. Deduplicated.
    static func crossSection(_ catalog: FeedCatalog, kinds: Set<SourceKind>) -> [(StreamRef, GenreID)] {
        func interleave<T>(_ groups: [[T]]) -> [T] {
            var groups = groups.filter { !$0.isEmpty }
            var out: [T] = []
            while !groups.isEmpty {
                for i in groups.indices { out.append(groups[i].removeFirst()) }
                groups.removeAll { $0.isEmpty }
            }
            return out
        }
        var queues = catalog.genres.map { g in
            let streams = catalog.streams(in: g.id).filter { kinds.contains($0.source) }
            return interleave(SourceKind.allCases.map { k in streams.filter { $0.source == k } }).map { ($0, g.id) }
        }
        var out: [(StreamRef, GenreID)] = []
        var seen = Set<StreamID>()
        while queues.contains(where: { !$0.isEmpty }) {
            for i in queues.indices where !queues[i].isEmpty {
                let next = queues[i].removeFirst()
                if seen.insert(next.0.id).inserted { out.append(next) }
            }
        }
        return out
    }

    static func pause(after last: ContinuousClock.Instant?, seconds: Double) async {
        guard let last else { return }
        let wait = Duration.milliseconds(Int(seconds * 1000)) - (ContinuousClock.now - last)
        if wait > .zero { try? await Task.sleep(for: wait) }
    }

    static func resolve(_ stream: StreamRef, tier: ResolveTier, service: ResolverService, into item: inout Item) async {
        do {
            let outcome = try await service.resolve(ResolveRequest(source: stream.source, url: stream.url), tier: tier)
            let s = outcome.stream
            item.ms = outcome.elapsedMs.rounded()
            item.tier = s.tier
            item.format = s.formatID
            item.proto = s.protocol
            item.mediaHost = s.url.host
            item.durationSec = s.duration
            item.title = s.title
            // Progressive YouTube URLs may not be served before `available_at` (DESIGN §6.3).
            let wait = s.wait(now: Date())
            if wait > 30 {
                item.reason = "available_at is \(Int(wait)) s ahead"
                return
            }
            if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 250)) }
            let range = await rangeGET(s)
            item.rangeStatus = range.status
            item.rangeBytes = range.bytes
            if let error = range.error {
                item.reason = "range GET: \(error)"
            } else if stream.kind == .mix, let d = s.duration, let feedD = stream.durationSec, abs(d - Double(feedD)) > 120 {
                // A 30 s SoundCloud preview or a re-upload: not the curated mix.
                item.reason = "duration \(Int(d)) s, feed says \(feedD) s"
            } else {
                item.ok = true
            }
        } catch let f as ResolveFailure {
            item.ms = f.elapsedMs.rounded()
            item.tier = f.tier
            item.failureClass = f.failureClass.rawValue
            item.reason = "\(f.reason): \(f.message.prefix(200))"
        } catch {
            item.reason = "\(error)"
        }
    }

    /// 64 KB range GET for progressive URLs; for HLS, the playlist itself must load and start with `#EXTM3U`.
    static func rangeGET(_ s: ResolvedStream) async -> (status: Int?, bytes: Int?, error: String?) {
        if s.isHLS {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.httpCookieAcceptPolicy = .never
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: s.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            for (k, v) in s.httpHeaders { request.setValue(v, forHTTPHeaderField: k) }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode
                guard status == 200 else { return (status, data.count, "HTTP \(status ?? 0)") }
                guard data.starts(with: Data("#EXTM3U".utf8)) else { return (status, data.count, "not an HLS playlist") }
                return (status, data.count, nil)
            } catch {
                return (nil, nil, error.localizedDescription)
            }
        }
        switch await URLSessionMediaProbe().probe(s, proxy: nil) {
        case let .ok(status, bytes, _): return (status, bytes, nil)
        case let .forbidden(status): return (status, nil, "HTTP \(status) on a fresh URL (engine-class)")
        case let .failed(why): return (nil, nil, why)
        }
    }
}
