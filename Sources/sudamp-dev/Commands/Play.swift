// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Feeds
import Foundation
import Picker
import Playback
import Resolver
import Synchronization

/// `sudamp-dev play --genre <id> [--profile P] [--feed <path>] [--seconds N] [--next-every S] [--source k[,k…]]
///  [--no-engine] [--install-engine=true] [--prefetch=false] [--pause-at T[,T…] --pause-for D[,D…]]
///  [--sample=true] [--json]` (PLAN M1, M3, M6).
///
/// The north star, headless: feed → picker → resolver → mpv → pull AO → AVAudioEngine through the real
/// `PlaybackController`. AUDIO SAFETY: mixer volume 0 and the render bridge zeroes its output after the TTFA
/// measurement, always. The profile's instance lock is taken first, so a second `play` on the same profile exits 75
/// with "profile in use". `--next-every S` presses Next every S seconds (postponed while a pick is still tuning);
/// `--pause-at`/`--pause-for` pause the playing stream at T seconds for D seconds and report whether the resume
/// rejoined the live edge (`liveReload`) and how fast it was audible. `--sample=true` samples every 50 ms how many
/// yt-dlp processes are this process's children and which status texts were shown (PLAN M6's "no second yt-dlp
/// process" and `TUNING…` checks). The report includes the source breakers, the last engine update check and the
/// recovery counters (M6). Exit 0 when at least one stream started, no unhandled error occurred and the audio engine
/// guards held.
enum PlayCommand {
    static let usage = """
    usage: sudamp-dev play --genre <id> [--profile P] [--feed <path>] [--seconds N] [--next-every S]
                           [--source youtube|youtube-live|soundcloud|mixcloud|radio[,…]] [--no-engine]
                           [--install-engine=true] [--prefetch=false] [--pause-at T[,T…] --pause-for D[,D…]]
                           [--sample=true] [--json]
    """

    /// What `--sample=true` saw.
    struct Samples: Encodable {
        var count = 0
        var maxConcurrentYtdlp = 0
        var ytdlpPids: [Int32] = []
        /// Distinct status texts in the order first seen, with when (seconds since the first pick).
        var statusTexts: [String] = []
        var statusFirstSeenSec: [Double] = []
        /// Phase changes: `<sec> <phase>`.
        var phases: [String] = []
    }

    struct PauseResult: Encodable {
        var atSec: Double
        var pausedSec: Double
        var streamId: String?
        var source: String?
        var liveReload: Bool
        /// Resume → first non-silent callback (the reload's TTFA for a live-edge reload).
        var resumeAudibleMs: Double?
    }

    struct Report: Encodable {
        var ok: Bool
        var genre: String
        var profile: String
        var feed: String
        var secondsRequested: Double
        var secondsPlayed: Double
        var engine: EngineStatus
        var sources: [String]?
        var streamsStarted: Int
        var starts: [TTFAInfo]
        var ttfaP50Ms: Double?
        var prefetchedStarts: Int
        var ttfaPrefetchedP50Ms: Double?
        var coldStarts: Int
        var ttfaColdP50Ms: Double?
        var nextPresses: Int
        var failures: Int
        var deferrals: Int
        var liveReloads: Int
        var prefetches: Int
        var unhandledErrors: Int
        var audioEngineError: String?
        var lastError: PlaybackErrorInfo?
        var finalState: String
        var pauses: [PauseResult]
        var player: PlayerDiagnostics
        var metricsFile: String
        var interrupted: Bool
        // M6
        var recoveries: Int
        var refreshes: Int
        var breakerTrips: Int
        var updateChecks: Int
        var offlineEpisodes: Int
        var breakers: [String: BreakerSummary]
        var engineUpdate: EngineUpdateOutcome?
        var engineWarmUp: EngineWarmUp?
        var faults: String?
        var samples: Samples?
    }

    @MainActor
    static func run(_ args: Args) async throws -> Int32 {
        guard let raw = args.string("genre"), let genre = GenreID(rawValue: raw) else {
            stderr(usage)
            return 64
        }
        let paths = Paths.resolve()
        let lock: InstanceLock
        do {
            lock = try InstanceLock.acquire(paths: paths)
        } catch {
            stderr("sudamp-dev play: \(error)")
            return 75
        }
        defer { lock.release() }

        let feed = try DevFeed.load(args)
        guard feed.document.catalog.genre(genre) != nil else {
            stderr("unknown genre \(raw); the feed has \(feed.document.catalog.genres.map(\.id.rawValue))")
            return 64
        }
        var config = PlaybackConfiguration(paths: paths)
        config.volume = 0
        config.engineMode = args.flag("no-engine") ? .disabled : (args.flag("install-engine") ? .install : .automatic)
        var sources: Set<SourceKind>?
        if let list = args.string("source") {
            let kinds = list.split(separator: ",").map { SourceKind(rawValue: String($0)) }
            guard !kinds.isEmpty, kinds.allSatisfy({ $0 != nil }) else {
                stderr("unknown --source \(list)")
                return 64
            }
            sources = Set(kinds.compactMap { $0 })
            config.allowedSources = sources
        }
        // `--prefetch=false`: every pick cold (tier checks that need each pick to reach yt-dlp).
        if args.string("prefetch") == "false" { config.prefetchEnabled = false }
        let seconds = args.double("seconds") ?? 60
        let nextEvery = args.double("next-every")
        let pauseAt = DevFeed.doubles(args.string("pause-at"))
        let pauseFor = DevFeed.doubles(args.string("pause-for"))
        guard pauseAt.count == pauseFor.count else {
            stderr("--pause-at and --pause-for need the same number of values")
            return 64
        }
        let json = args.flag("json")

        let controller = try PlaybackController.live(
            configuration: config, feed: feed,
            options: LivePlaybackOptions(silent: true, quickJS: PlaybackController.defaultQuickJS()))
        let interrupted = Atomic<Bool>(false)
        let signals = SignalWatcher { _ in interrupted.store(true, ordering: .relaxed) }
        defer { signals.cancel() }

        await controller.prepare()
        if !json { stderr("engine: \(controller.snapshot.engine.state.rawValue)\(controller.snapshot.engine.version.map { " \($0)" } ?? "")") }
        controller.start(genre: genre)

        let t0 = monotonicNanos()
        func elapsed() -> Double { Double(monotonicNanos() - t0) / 1e9 }
        var nextDue = nextEvery
        var nextPresses = 0
        var pauses: [PauseResult] = []
        var pauseIndex = 0
        var reported = 0
        let sampling = args.flag("sample")
        var samples = Samples()
        var lastPhase: PlaybackPhase?
        while elapsed() < seconds, !interrupted.load(ordering: .relaxed) {
            try? await Task.sleep(for: .milliseconds(50))
            if sampling {
                samples.count += 1
                let pids = ProcessSampler.childPIDs(named: "yt-dlp_macos")
                samples.maxConcurrentYtdlp = max(samples.maxConcurrentYtdlp, pids.count)
                for pid in pids where !samples.ytdlpPids.contains(pid) { samples.ytdlpPids.append(pid) }
                let text = controller.snapshot.statusText
                if !samples.statusTexts.contains(text) {
                    samples.statusTexts.append(text)
                    samples.statusFirstSeenSec.append((elapsed() * 100).rounded() / 100)
                }
            }
            if controller.phase != lastPhase {
                lastPhase = controller.phase
                if sampling { samples.phases.append(String(format: "%.2f %@", elapsed(), controller.phase.rawValue)) }
            }
            let history = controller.ttfaHistory
            if !json {
                for t in history.dropFirst(reported) {
                    stderr(String(format: "%6.1fs  start %@ %@ %.0f ms%@ (%@)", elapsed(), t.source.tag, t.streamId.rawValue, t.ms,
                                  t.prefetched ? " prefetched" : "", t.trigger))
                }
            }
            reported = history.count
            if controller.snapshot.audioEngineError != nil { break }
            if pauseIndex < pauseAt.count, elapsed() >= pauseAt[pauseIndex], controller.phase == .playing {
                pauses.append(await pauseAndResume(controller, for: pauseFor[pauseIndex], at: elapsed(), json: json))
                pauseIndex += 1
                continue
            }
            if let every = nextEvery, let due = nextDue, elapsed() >= due, controller.phase == .playing {
                controller.next()
                nextPresses += 1
                nextDue = due + every
                if !json { stderr(String(format: "%6.1fs  next", elapsed())) }
            }
        }
        let played = elapsed()
        let final = controller.snapshot
        let counters = controller.debugCounters
        let diagnostics = controller.playerDiagnostics()
        let breakers = controller.breakerSummary()
        let engineUpdate = controller.lastEngineUpdate
        let warmUp = controller.engineWarmUp
        await controller.shutdown()

        let starts = controller.ttfaHistory.filter { $0.trigger != "liveReload" }
        let prefetched = starts.filter(\.prefetched)
        let cold = starts.filter { !$0.prefetched }
        let report = Report(
            ok: counters.streamsStarted > 0 && counters.unhandledErrors == 0 && final.audioEngineError == nil,
            genre: genre.rawValue, profile: paths.appSupport.path, feed: feed.url.path, secondsRequested: seconds,
            secondsPlayed: (played * 10).rounded() / 10, engine: final.engine,
            sources: sources.map { $0.map(\.rawValue).sorted() }, streamsStarted: counters.streamsStarted, starts: starts,
            ttfaP50Ms: Stats.p50(starts.map(\.ms)), prefetchedStarts: prefetched.count,
            ttfaPrefetchedP50Ms: Stats.p50(prefetched.map(\.ms)), coldStarts: cold.count, ttfaColdP50Ms: Stats.p50(cold.map(\.ms)),
            nextPresses: nextPresses, failures: counters.failures, deferrals: counters.deferrals,
            liveReloads: counters.liveReloads, prefetches: counters.prefetches, unhandledErrors: counters.unhandledErrors,
            audioEngineError: final.audioEngineError, lastError: final.lastError, finalState: final.stateName,
            pauses: pauses, player: diagnostics, metricsFile: paths.metricsFile.path,
            interrupted: interrupted.load(ordering: .relaxed), recoveries: counters.recoveries,
            refreshes: counters.refreshes, breakerTrips: counters.breakerTrips, updateChecks: counters.updateChecks,
            offlineEpisodes: counters.offlineEpisodes, breakers: breakers, engineUpdate: engineUpdate,
            engineWarmUp: warmUp, faults: ProcessInfo.processInfo.environment["SUDAMP_FAULT"],
            samples: sampling ? samples : nil)
        if json {
            printReport(report, pretty: true)
        } else {
            print("""
            play \(genre.rawValue): \(report.streamsStarted) stream(s) started in \(report.secondsPlayed) s, \
            \(report.failures) failure(s), \(report.deferrals) deferral(s), \(report.unhandledErrors) unhandled error(s)
              TTFA p50 \(Stats.text(report.ttfaP50Ms)) (prefetched \(report.prefetchedStarts): \
            \(Stats.text(report.ttfaPrefetchedP50Ms)); cold \(report.coldStarts): \(Stats.text(report.ttfaColdP50Ms)))
              engine \(report.engine.state.rawValue)\(report.engine.version.map { " \($0)" } ?? ""); final state \(report.finalState)
              metrics \(report.metricsFile)
            """)
            for p in pauses {
                print("  pause \(Int(p.pausedSec)) s on \(p.streamId ?? "?"): liveReload \(p.liveReload), audible after \(Stats.text(p.resumeAudibleMs))")
            }
            if let e = report.lastError { print("  last error: \(e.kind) at \(e.stage): \(e.message)") }
            for (platform, b) in report.breakers.sorted(by: { $0.key < $1.key }) {
                print("  breaker \(platform): \(b.state.rawValue) \(b.kind?.rawValue ?? "")\(b.reopenAt.map { " until \($0)" } ?? "")")
            }
            if let u = report.engineUpdate {
                print("  engine update (\(u.trigger.rawValue)): \(u.result.rawValue) \(u.reason ?? "")")
            }
        }
        return report.ok ? 0 : 1
    }

    /// Pauses for `seconds`, resumes, and measures how soon audio is back (DESIGN §5.2 live-pause rule).
    @MainActor
    static func pauseAndResume(_ controller: PlaybackController, for seconds: Double, at: Double, json: Bool) async -> PauseResult {
        let stream = controller.currentStream
        let reloadsBefore = controller.debugCounters.liveReloads
        let ttfaBefore = controller.ttfaHistory.count
        controller.pause()
        if !json { stderr(String(format: "%6.1fs  pause %.0f s (%@)", at, seconds, stream?.id.rawValue ?? "?")) }
        let p0 = monotonicNanos()
        try? await Task.sleep(for: .seconds(seconds), tolerance: .milliseconds(10))
        let before = controller.playerDiagnostics()
        let audibleBefore = before.callbacks - before.silentCallbacks
        let r0 = monotonicNanos()
        controller.play()
        let reload = controller.debugCounters.liveReloads > reloadsBefore
        var audibleMs: Double?
        let deadline = r0 + 10_000_000_000
        while monotonicNanos() < deadline {
            if reload {
                if controller.ttfaHistory.count > ttfaBefore, let t = controller.ttfaHistory.last, t.trigger == "liveReload" {
                    audibleMs = t.ms
                    break
                }
            } else {
                let d = controller.playerDiagnostics()
                if d.callbacks - d.silentCallbacks > audibleBefore {
                    audibleMs = Double(monotonicNanos() - r0) / 1e6
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let result = PauseResult(atSec: (at * 10).rounded() / 10, pausedSec: (Double(r0 - p0) / 1e8).rounded() / 10,
                                 streamId: stream?.id.rawValue, source: stream?.source.rawValue, liveReload: reload,
                                 resumeAudibleMs: audibleMs.map { ($0 * 10).rounded() / 10 })
        if !json {
            stderr("        resume: liveReload \(reload), audible after \(Stats.text(result.resumeAudibleMs))")
        }
        return result
    }
}

/// Feed loading and small helpers shared by `play` and `ttfa`.
enum DevFeed {
    /// `--feed <path>`, else the bundled feed (app resources, else `catalog/feed.json` in the checkout).
    static func load(_ args: Args) throws -> LoadedFeed {
        let feed: LoadedFeed
        if let path = args.string("feed") {
            feed = try BundledFeed.load(from: URL(filePath: path))
        } else {
            feed = try BundledFeed.loadDefault()
        }
        for w in feed.warnings { stderr("feed: \(w)") }
        return feed
    }

    static func doubles(_ s: String?) -> [Double] {
        (s ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// This process's children by executable name (libproc), for `--sample=true` and `soak`.
enum ProcessSampler {
    static func childPIDs(of parent: pid_t = getpid(), named name: String) -> [Int32] {
        var pids = [pid_t](repeating: 0, count: 64)
        let n = pids.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return [] }
        return pids.prefix(Int(n)).filter { pid in
            var buf = [CChar](repeating: 0, count: 256)
            let len = proc_name(pid, &buf, UInt32(buf.count))
            guard len > 0 else { return false }
            return String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self) == name
        }
    }

    /// Resident and physical-footprint bytes of `pid` (proc_pid_rusage), nil when it is gone.
    static func memory(of pid: pid_t) -> (resident: UInt64, footprint: UInt64)? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        return (info.ri_resident_size, info.ri_phys_footprint)
    }
}

enum Stats {
    /// Nearest-rank percentile; nil when empty.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let rank = Int((p / 100 * Double(s.count)).rounded(.up))
        return s[min(max(rank, 1), s.count) - 1]
    }

    static func p50(_ values: [Double]) -> Double? { percentile(values, 50) }

    static func text(_ ms: Double?) -> String { ms.map { String(format: "%.0f ms", $0) } ?? "–" }
}
