// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation
import Synchronization

/// `sudamp-dev soak (--minutes N | --hours N) --genre <id> [--skip-every <dur>] [--source k[,k…]] [--profile P]
///  [--feed <path>] [--sample-every <dur>] [--warmup <dur>] [--child <sudamp-dev>] [--json]` (PLAN M3, M6).
///
/// Long-running playback with skips, supervised from outside: the soak runs `sudamp-dev play --genre <id> --seconds
/// <left> --next-every <skip> --json` as a child process in the same profile (muted, like every `play`), samples
/// the child's resident size and physical footprint every `--sample-every` (default 30 s), restarts it if it dies
/// before the time is up, and reports:
/// - **crashes**: children ended by a signal (or a non-zero exit without a report);
/// - **RSS drift**: the last sample minus the first sample after `--warmup` (default 10% of the run, at most 5 min);
/// - **start success rate**: from the profile's `metrics.jsonl` lines written during the soak, stream starts
///   (`ttfa` events that aren't reloads) over starts plus attempt failures (`failure` events at the resolve, dns,
///   load, firstAudio or stream stage).
/// Durations are `90`, `90s`, `10m` or `1h`. Exit 0 when crashes = 0, |drift| < 20 MB and success ≥ 97% (PLAN M6).
enum SoakCommand {
    static let usage = """
    usage: sudamp-dev soak (--minutes N | --hours N) --genre <id> [--skip-every <dur>] [--source k[,k…]]
                           [--profile P] [--feed <path>] [--sample-every <dur>] [--warmup <dur>] [--json]
    """

    struct Sample: Encodable {
        var sec: Double
        var residentMB: Double
        var footprintMB: Double
        var child: Int
    }

    struct Child: Encodable {
        var pid: Int32
        var startedSec: Double
        var endedSec: Double
        var exit: String
        var crashed: Bool
        var streamsStarted: Int?
        var failures: Int?
        var report: Bool
    }

    struct Memory: Encodable {
        var baselineMB: Double?
        var endMB: Double?
        var driftMB: Double?
        var maxMB: Double?
    }

    struct Report: Encodable {
        var ok: Bool
        var genre: String
        var sources: String?
        var secondsRequested: Double
        var secondsRun: Double
        var skipEverySec: Double?
        var crashes: Int
        var children: [Child]
        var resident: Memory
        var footprint: Memory
        var warmupSec: Double
        var starts: Int
        var attemptFailures: Int
        var startSuccessRate: Double?
        var failureKinds: [String: Int]
        var ttfaP50Ms: Double?
        var ttfaP90Ms: Double?
        var recoveries: Int
        var deferrals: Int
        var samples: [Sample]
        var profile: String
        var metricsFile: String
        var interrupted: Bool
        var thresholds: [String: Double]
    }

    static func duration(_ s: String?) -> Double? {
        guard var t = s?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        var scale = 1.0
        if t.hasSuffix("h") { scale = 3600; t.removeLast() } else if t.hasSuffix("m") { scale = 60; t.removeLast() }
        else if t.hasSuffix("s") { t.removeLast() }
        guard let v = Double(t), v.isFinite, v > 0 else { return nil }
        return v * scale
    }

    static func run(_ args: Args) async throws -> Int32 {
        let total: Double
        if let h = args.double("hours") { total = h * 3600 } else if let m = args.double("minutes") { total = m * 60 } else {
            stderr(usage)
            return 64
        }
        guard let genre = args.string("genre"), total > 0 else {
            stderr(usage)
            return 64
        }
        let skip = duration(args.string("skip-every"))
        let sampleEvery = duration(args.string("sample-every")) ?? 30
        let warmup = duration(args.string("warmup")) ?? min(300, total * 0.1)
        let json = args.flag("json")
        let paths = Paths.resolve()
        try paths.createDirectories()
        let profile = paths.appSupport.path
        let metricsStart = (try? FileManager.default.attributesOfItem(atPath: paths.metricsFile.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        // `--child <path>`: supervise another sudamp-dev build's `play` (A/B memory comparisons).
        guard let exe = args.string("child").map({ URL(filePath: $0) })
            ?? Bundle.main.executableURL ?? URL(string: "file://" + CommandLine.arguments[0]) else { return 1 }
        // The children get the feed's absolute path, wherever this binary runs from.
        let feedPath = try DevFeed.load(args).url.path

        let interrupted = Atomic<Bool>(false)
        let current = Mutex<Process?>(nil)
        let signals = SignalWatcher { _ in
            interrupted.store(true, ordering: .relaxed)
            current.withLock { $0?.terminate() }
        }
        defer { signals.cancel() }

        let t0 = Date()
        func elapsed() -> Double { Date().timeIntervalSince(t0) }
        var samples: [Sample] = []
        var children: [Child] = []
        var crashes = 0
        var index = 0
        var quickExits = 0
        while !interrupted.load(ordering: .relaxed) {
            let left = total - elapsed()
            guard left > 20 else { break }
            index += 1
            var argv = ["play", "--genre", genre, "--seconds", String(Int(left.rounded())), "--json", "--profile", profile]
            if let skip { argv += ["--next-every", String(skip)] }
            if let s = args.string("source") { argv += ["--source", s] }
            argv += ["--feed", feedPath]
            let p = Process()
            p.executableURL = exe
            p.arguments = argv
            let out = Pipe()
            p.standardOutput = out
            let logURL = paths.logs.appending(path: "soak-child-\(index).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            p.standardError = log
            let started = elapsed()
            // Drain stdout as it comes, so a large report can never block the child on a full pipe.
            let collected = Mutex(Data())
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                collected.withLock { $0.append(d) }
            }
            try p.run()
            current.withLock { $0 = p }
            if !json { stderr(String(format: "%7.1fs  child %d (pid %d) for %d s", started, index, p.processIdentifier, Int(left))) }
            var nextSample = elapsed()
            while p.isRunning {
                if elapsed() >= nextSample {
                    if let m = ProcessSampler.memory(of: p.processIdentifier) {
                        let s = Sample(sec: (elapsed() * 10).rounded() / 10, residentMB: mb(m.resident),
                                       footprintMB: mb(m.footprint), child: index)
                        samples.append(s)
                        if !json {
                            stderr(String(format: "%7.1fs  rss %.1f MB, footprint %.1f MB", s.sec, s.residentMB, s.footprintMB))
                        }
                    }
                    nextSample += sampleEvery
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            current.withLock { $0 = nil }
            out.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            try? out.fileHandleForReading.close()
            let data = collected.withLock { $0 } + rest
            let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let crashed = p.terminationReason == .uncaughtSignal && !interrupted.load(ordering: .relaxed)
                || (p.terminationReason == .exit && report == nil && !interrupted.load(ordering: .relaxed))
            if crashed { crashes += 1 }
            let exit = p.terminationReason == .uncaughtSignal ? "signal \(p.terminationStatus)" : "exit \(p.terminationStatus)"
            children.append(Child(pid: p.processIdentifier, startedSec: (started * 10).rounded() / 10,
                                  endedSec: (elapsed() * 10).rounded() / 10, exit: exit, crashed: crashed,
                                  streamsStarted: report?["streamsStarted"] as? Int, failures: report?["failures"] as? Int,
                                  report: report != nil))
            if !json { stderr(String(format: "%7.1fs  child %d ended: %@%@", elapsed(), index, exit, crashed ? " (CRASH)" : "")) }
            // A child that can't even start (bad arguments, no feed, a locked profile) would spin: stop after three.
            if elapsed() - started < 15 {
                quickExits += 1
                if quickExits >= 3 {
                    stderr("soak: three children exited within 15 s of starting; see \(logURL.path)")
                    break
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }

        // Starts and attempt failures from the metrics written during the soak.
        var starts = 0, failures = 0, recoveries = 0, deferrals = 0
        var kinds: [String: Int] = [:]
        var ttfa: [Double] = []
        if let handle = try? FileHandle(forReadingFrom: paths.metricsFile) {
            try? handle.seek(toOffset: UInt64(max(0, metricsStart)))
            let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            for line in text.split(separator: "\n") {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let event = o["event"] as? String else { continue }
                switch event {
                case "ttfa" where (o["reload"] as? Bool) != true:
                    starts += 1
                    if let ms = o["ms"] as? Double { ttfa.append(ms) }
                case "failure":
                    let stage = o["stage"] as? String ?? ""
                    guard ["resolve", "dns", "load", "firstAudio", "stream"].contains(stage) else { continue }
                    failures += 1
                    kinds["\(o["kind"] as? String ?? "?")/\(o["reason"] as? String ?? stage)", default: 0] += 1
                case "recover" where o["ok"] as? Bool != false:
                    recoveries += 1
                case "deferred":
                    deferrals += 1
                default:
                    break
                }
            }
        }
        let rate = starts + failures > 0 ? Double(starts) / Double(starts + failures) : nil
        func memory(_ value: (Sample) -> Double) -> Memory {
            let after = samples.filter { $0.sec >= warmup }
            guard let first = after.first, let last = samples.last else { return Memory() }
            return Memory(baselineMB: value(first), endMB: value(last), driftMB: ((value(last) - value(first)) * 10).rounded() / 10,
                          maxMB: samples.map(value).max())
        }
        let resident = memory(\.residentMB), footprint = memory(\.footprintMB)
        let driftOK = abs(resident.driftMB ?? 0) < 20 && abs(footprint.driftMB ?? 0) < 20
        let report = Report(
            ok: crashes == 0 && driftOK && (rate ?? 0) >= 0.97 && !children.isEmpty,
            genre: genre, sources: args.string("source"), secondsRequested: total,
            secondsRun: (elapsed() * 10).rounded() / 10, skipEverySec: skip, crashes: crashes, children: children,
            resident: resident, footprint: footprint, warmupSec: warmup, starts: starts, attemptFailures: failures,
            startSuccessRate: rate.map { ($0 * 1000).rounded() / 1000 }, failureKinds: kinds,
            ttfaP50Ms: Stats.p50(ttfa), ttfaP90Ms: Stats.percentile(ttfa, 90), recoveries: recoveries, deferrals: deferrals,
            samples: samples, profile: profile, metricsFile: paths.metricsFile.path,
            interrupted: interrupted.load(ordering: .relaxed),
            thresholds: ["maxDriftMB": 20, "minStartSuccessRate": 0.97, "maxCrashes": 0])
        if json {
            printReport(report, pretty: true)
        } else {
            print("""
            soak \(genre): \(report.secondsRun) s, \(children.count) child run(s), \(crashes) crash(es)
              starts \(starts), attempt failures \(failures), success \(rate.map { String(format: "%.1f%%", $0 * 100) } ?? "–")
              rss \(resident.baselineMB.map { String(format: "%.1f", $0) } ?? "–") → \(resident.endMB.map { String(format: "%.1f", $0) } ?? "–") MB (drift \(resident.driftMB.map { String(format: "%+.1f", $0) } ?? "–")), \
            footprint drift \(footprint.driftMB.map { String(format: "%+.1f", $0) } ?? "–") MB
              TTFA p50 \(Stats.text(report.ttfaP50Ms)); recoveries \(recoveries); deferrals \(deferrals)
              \(report.ok ? "PASS" : "FAIL")
            """)
        }
        return report.ok ? 0 : 1
    }

    private static func mb(_ bytes: UInt64) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }
}
