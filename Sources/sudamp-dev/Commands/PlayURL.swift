// SPDX-License-Identifier: GPL-3.0-or-later
import Audio
import Core
import Foundation
import MPV
import Resolver

/// `sudamp-dev play-url <url> [--headers-json <file>] [--seconds N] [--json] [--lavf-o k=v,...] [--start S]
///  [--mpv-log <file>] [--log-level <lvl>]`
///
/// Plays one URL through the real engine, silently (mixer volume 0 and the bridge's output muted), and reports
/// time to first audio at the render callback, the guards, the ICY title and any errors. `--headers-json` takes
/// yt-dlp's shape: `{"http_headers": {...}, "user_agent": "..."}`. `--resolved <file>` instead plays a saved
/// `Resolver.ResolvedStream` (from `sudamp-dev resolve --save`), mapping it to per-file options like the app does.
enum PlayURLCommand {
    struct Report: Encodable {
        var url: String
        var ttfaMs: Double?
        var loadfileReplyMs: Double?
        var secondsPlayed: Double
        var audioRendered: Bool
        var nonSilentCallbacks: UInt64
        var callbacks: UInt64
        var shortReadsAfterStart: UInt64
        var aoUnavailableAfterStart: UInt64
        var audioOutParams: AudioParams?
        var audioParams: AudioParams?
        var mediaTitle: String?
        var icyTitle: String?
        var seekable: Bool?
        var audioBitrate: Double?
        var mpvVersion: String?
        var aoInitCount: Int64
        var aoErrorCount: Int64
        var guardsOK: Bool
        var guardFailures: [String]
        var perFileOptions: [String: String]
        var unsetAVOptions: [String]
        var scriptsLoaded: [String]
        var errors: [String]
        var ok: Bool
    }

    struct HeadersFile: Decodable {
        var http_headers: [String: String]?
        var user_agent: String?
    }

    static func run(_ args: Args) async throws -> Int32 {
        if let path = args.string("resolved") {
            let stream = try JSONDecoder().decode(ResolvedStream.self, from: Data(contentsOf: URL(filePath: path)))
            let report = try play(url: stream.url.absoluteString, options: loadOptions(for: stream),
                                  seconds: args.double("seconds") ?? 10, logLevel: args.string("log-level") ?? "warn",
                                  mpvLog: args.string("mpv-log").map { URL(filePath: $0) })
            printReport(report, pretty: !args.flag("json"))
            return report.ok ? 0 : 1
        }
        guard let url = args.positionals.first else {
            stderr("usage: sudamp-dev play-url <url> [--headers-json <file> | --resolved <file>] [--seconds N] [--json]")
            return 64
        }
        var options = url.hasPrefix("http") ? LoadFileOptions.radio() : LoadFileOptions()
        if let path = args.string("headers-json") {
            let headers = try JSONDecoder().decode(HeadersFile.self, from: Data(contentsOf: URL(filePath: path)))
            options.httpHeaders = headers.http_headers ?? [:]
            options.userAgent = headers.user_agent
        }
        if let lavf = args.string("lavf-o") {
            options.lavf = lavf.split(separator: ",").compactMap { item in
                let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
                return kv.count == 2 ? LavfOption(kv[0], kv[1]) : nil
            }
        }
        options.start = args.double("start")
        let report = try play(url: url, options: options, seconds: args.double("seconds") ?? 10,
                              logLevel: args.string("log-level") ?? (args.string("mpv-log") == nil ? "warn" : "v"),
                              mpvLog: args.string("mpv-log").map { URL(filePath: $0) })
        printReport(report, pretty: !args.flag("json"))
        return report.ok ? 0 : 1
    }

    static func play(url: String, options: LoadFileOptions, seconds: Double, logLevel: String, mpvLog: URL?) throws -> Report {
        let h = try EngineHarness(logLevel: logLevel, mpvLog: mpvLog)
        try h.start()
        let perFile = (try? options.optionMap()) ?? [:]
        h.bridge.armTTFA()
        let t0 = monotonicNanos()
        let requestID = try h.mpv.loadfile(url, options: options)
        let deadline = t0 + UInt64(seconds * 1e9)
        var countersAtStart: RenderCounters?
        // Play for `seconds`, or stop early if the file ends with an error.
        while monotonicNanos() < deadline {
            usleep(20_000)
            if countersAtStart == nil, let ttfa = h.bridge.ttfaNanos, monotonicNanos() > ttfa + 500_000_000 {
                countersAtStart = h.bridge.counters // short reads are counted from 0.5 s after first audio
            }
            if let end = h.mpv.snapshot.lastEndFile, end.reason == .error { break }
        }
        let played = Double(monotonicNanos() - t0) / 1e9
        let reply = h.events.all.first { entry in
            if case .commandReply(let id, _, _) = entry.event { return id == requestID }
            return false
        }
        let snapshot = h.mpv.snapshot
        let guards = h.mpv.guards()
        let counters = h.bridge.counters
        let ttfa = h.bridge.ttfaMilliseconds
        h.shutdown()
        let base = countersAtStart ?? counters
        let rendered = counters.callbacks > counters.silentCallbacks
        return Report(
            url: url, ttfaMs: ttfa.map { Measure.round($0, 1) },
            loadfileReplyMs: reply.map { Measure.round(Measure.ms(from: t0, to: $0.nanos), 2) },
            secondsPlayed: Measure.round(played, 2), audioRendered: rendered,
            nonSilentCallbacks: counters.callbacks - counters.silentCallbacks, callbacks: counters.callbacks,
            shortReadsAfterStart: countersAtStart == nil ? 0 : counters.shortReads - base.shortReads,
            aoUnavailableAfterStart: countersAtStart == nil ? 0 : counters.aoUnavailable - base.aoUnavailable,
            audioOutParams: guards.audioOutParams ?? snapshot.audioOutParams, audioParams: snapshot.audioParams,
            mediaTitle: snapshot.mediaTitle, icyTitle: snapshot.icyTitle, seekable: snapshot.seekable,
            audioBitrate: snapshot.audioBitrate, mpvVersion: guards.mpvVersion, aoInitCount: guards.aoInitCount,
            aoErrorCount: guards.aoErrorCount, guardsOK: guards.ok, guardFailures: guards.failures,
            perFileOptions: perFile, unsetAVOptions: h.events.unsetAVOptions, scriptsLoaded: h.events.scriptsLoaded,
            errors: Array(h.events.errors.prefix(20)), ok: rendered && guards.ok)
    }
}

extension PlayURLCommand {
    /// Per-file mpv options for a resolved stream (DESIGN §5.2 "Per file"): yt-dlp's headers and user agent, and
    /// for progressive HTTP the ranged-request size yt-dlp reports, as mpv's ytdl_hook does.
    static func loadOptions(for stream: ResolvedStream) -> LoadFileOptions {
        var options: LoadFileOptions
        if !stream.isHLS, let chunk = stream.httpChunkSize, chunk > 0 {
            options = .progressive(requestSize: chunk)
        } else {
            options = LoadFileOptions()
        }
        options.httpHeaders = stream.httpHeaders
        options.userAgent = stream.userAgent
        options.mediaTitle = stream.title
        return options
    }
}
