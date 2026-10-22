// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import Resolver

/// `sudamp-dev resolve <url> --source <kind> [--tier 1|2] [-n N] [--json] [--save <file>]` (PLAN M0 R1).
///
/// One run prints the `ResolvedStream`. With `-n N` it first does `--warmup` untimed resolves (default 1), then N
/// timed ones `--interval` seconds apart (default 3 s for YouTube, to stay polite, 1 s otherwise) and reports
/// p50/p90 of the successful runs. `--save` writes the last `ResolvedStream` as JSON (`url`, `httpHeaders`,
/// `userAgent`, …; decodable as `Resolver.ResolvedStream`) for `play-url`.
///
/// Other options: `--profile P`, `--qjs <path>` (tier 2; default `$SUDAMP_QJS` or the fetch-qjs.sh cache),
/// `--ladder` (tier 1 then tier 2 on an engine failure), `--proxy http://host:port` (default: the system proxy, or
/// the debug `SUDAMP_PROXY`), `--feed <path>` (engine strings; default the bundled feed), `--format <f>` and
/// `--extractor-args <a>[,<b>]|none` (override the source's defaults; validated like feed values),
/// `--skip-verify` (don't re-hash `tree.json` first; the plugin canary plants files next to the engine).
enum ResolveCommand {
    static let usage = """
    usage: sudamp-dev resolve <url> --source youtube|youtube-live|soundcloud|mixcloud [--tier 1|2] [-n N]
                              [--json] [--save <file>] [--profile P] [--qjs <path>] [--ladder] [--interval s]
                              [--warmup k] [--proxy url] [--format f] [--extractor-args a|none] [--skip-verify]
    """

    struct Run: Encodable {
        var ms: Double
        var ok: Bool
        var tier: Int
        var failureClass: String?
        var reason: String?
        var message: String?
    }

    struct Summary: Encodable {
        var source: String
        var url: String
        var tier: Int
        var engineVersion: String
        var warmup: Int
        var n: Int
        var ok: Int
        var p50Ms: Double?
        var p90Ms: Double?
        var minMs: Double?
        var maxMs: Double?
        var runs: [Run]
        var mediaHost: String?
        var stream: ResolvedStream?
        var argv: [String]
    }

    struct Single: Encodable {
        var elapsedMs: Double
        var engineVersion: String
        var warnings: [String]
        var stream: ResolvedStream
        var argv: [String]
    }

    static func run(_ args: Args) async throws -> Int32 {
        let n = args.int("n")
        let positionals = args.positionals
        guard let urlString = positionals.first, let url = URL(string: urlString),
              let source = args.string("source").flatMap(SourceKind.init(rawValue:)) else {
            stderr(usage)
            return 64
        }
        let tier = ResolveTier(rawValue: args.int("tier") ?? 1) ?? .jsless
        let paths = Paths.resolve()
        let layout = EngineLayout(paths: paths)
        let store = EngineStore(layout: layout)
        guard let current = await store.current() else {
            stderr("no engine installed; run `sudamp-dev engine install` first")
            return 1
        }
        if !args.flag("skip-verify") {
            let check = try await store.verifyTree()
            guard check.ok else {
                stderr("engine tree mismatch, refusing to run it: \(check)")
                return 1
            }
        }

        // The feed's engine strings (DESIGN §7.1), as the app uses them; the R1 defaults without a feed.
        var settings = (try? DevFeed.load(args)).map { ResolverSettings(engine: $0.document.engine) } ?? .standard
        if let f = args.string("format") { settings.formats[source] = f }
        if let a = args.string("extractor-args") {
            settings.extractorArgs[source] = a == "none" ? [] : a.split(separator: " ").map(String.init)
        }
        let defaultQJS = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/sudamp-dev/qjs-v0.17.0/qjs-darwin-arm64")
        let qjsPath = args.string("qjs") ?? ProcessInfo.processInfo.environment["SUDAMP_QJS"]
            ?? (FileManager.default.isExecutableFile(atPath: defaultQJS.path) ? defaultQJS.path : nil)
        let service = ResolverService(layout: layout, engine: current.executableURL(in: layout),
                                      qjs: qjsPath.map { URL(filePath: $0) }, settings: settings,
                                      proxy: args.string("proxy").flatMap(URL.init(string:)) ?? SystemProxy.current().url,
                                      metrics: MetricsLog(url: paths.metricsFile))
        let rejected = await service.setSettings(settings)
        if !rejected.isEmpty { stderr("rejected overrides (defaults kept): \(rejected)") }
        let request = ResolveRequest(source: source, url: url)
        let argv = try await service.invocation(for: request, tier: tier).arguments
        let ladder = args.flag("ladder")

        func once() async throws -> ResolveOutcome {
            ladder ? try await service.resolveWithLadder(request) : try await service.resolve(request, tier: tier)
        }

        guard let n, n > 0 else {
            do {
                let outcome = try await once()
                try save(outcome.stream, args)
                if args.flag("json") {
                    printJSON(Single(elapsedMs: outcome.elapsedMs.rounded(), engineVersion: current.version,
                                     warnings: outcome.warnings, stream: outcome.stream, argv: argv), pretty: true)
                } else {
                    let s = outcome.stream
                    print("""
                    \(Int(outcome.elapsedMs)) ms  tier \(s.tier)  \(s.formatID ?? "?") \(s.protocol ?? "?") \(s.acodec ?? "") \(s.abr.map { "\(Int($0))k" } ?? "")
                      \(s.uploader ?? "?") — \(s.title ?? "?")  (\(s.liveStatus ?? "?"), \(s.duration.map { "\(Int($0)) s" } ?? "no duration"))
                      host \(s.url.host ?? "?")  expires \(s.expiresAt.map { "\(Int($0 - s.resolvedAt)) s" } ?? "never")  wait \(Int(s.wait(now: Date())) ) s
                    """)
                    for w in outcome.warnings { print("  \(w)") }
                }
                return 0
            } catch {
                report(error, args)
                return 1
            }
        }

        let isYouTube = source == .youtube || source == .youtubeLive
        let interval = args.double("interval") ?? (isYouTube ? 3 : 1)
        let warmup = args.int("warmup") ?? 1
        var runs: [Run] = []
        var last: ResolvedStream?
        for i in 0..<(warmup + n) {
            if i > 0 { try await Task.sleep(for: .seconds(interval)) }
            let started = ContinuousClock.now
            var run = Run(ms: 0, ok: false, tier: tier.rawValue)
            do {
                let outcome = try await once()
                run.ms = outcome.elapsedMs
                run.ok = true
                run.tier = outcome.stream.tier
                last = outcome.stream
            } catch let f as ResolveFailure {
                run.ms = f.elapsedMs
                run.tier = f.tier
                run.failureClass = f.failureClass.rawValue
                run.reason = f.reason
                run.message = String(f.message.prefix(300))
            } catch {
                let d = ContinuousClock.now - started
                run.ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
                run.failureClass = "error"
                run.message = "\(error)"
            }
            let label = i < warmup ? "warmup" : "run \(i - warmup + 1)/\(n)"
            stderr("\(label): \(Int(run.ms)) ms \(run.ok ? "ok" : "\(run.failureClass ?? "")/\(run.reason ?? "") \(run.message ?? "")")")
            if i >= warmup { runs.append(run) }
        }
        if let last { try save(last, args) }
        let times = runs.filter(\.ok).map(\.ms).sorted()
        let summary = Summary(source: source.rawValue, url: url.absoluteString, tier: tier.rawValue,
                              engineVersion: current.version, warmup: warmup, n: n, ok: times.count,
                              p50Ms: percentile(times, 0.5), p90Ms: percentile(times, 0.9),
                              minMs: times.first, maxMs: times.last, runs: runs, mediaHost: last?.url.host,
                              stream: last, argv: argv)
        if args.flag("json") {
            printJSON(summary, pretty: true)
        } else {
            print("\(source.rawValue) tier \(tier.rawValue): \(times.count)/\(n) ok, p50 \(Int(summary.p50Ms ?? 0)) ms, "
                  + "p90 \(Int(summary.p90Ms ?? 0)) ms, host \(summary.mediaHost ?? "?")")
        }
        return times.count == n ? 0 : 1
    }

    /// Nearest-rank percentile of sorted values.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1].rounded()
    }

    private static func save(_ stream: ResolvedStream, _ args: Args) throws {
        guard let path = args.string("save") else { return }
        let url = URL(filePath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(stream).write(to: url, options: .atomic)
    }

    private static func report(_ error: any Error, _ args: Args) {
        if args.flag("json") {
            if let f = error as? ResolveFailure { printJSON(["failure": f], pretty: true) } else { printJSON(["error": "\(error)"]) }
        }
        stderr("resolve failed: \(error)")
    }
}
