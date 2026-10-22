// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation
import MPV

/// `sudamp-dev stress-lifecycle [N] [--json] [--fixture <wav>] [--seed S]`
///
/// Creates and destroys the whole engine N times (default 100) in the DESIGN §5.2 shutdown order, cycling
/// through four shutdown moments: mid-load, while playing, while paused, and idle after `stop`. The wrong order
/// crashed the spike (EXC_BAD_ACCESS in mpv_wait_event), so this guards it; a crash ends the process, so
/// finishing with `crashes: 0` means none occurred.
enum StressLifecycleCommand {
    struct Report: Encodable {
        var iterations: Int
        var completed: Int
        var crashes: Int
        var failures: [String]
        var variants: [String: Int]
        var meanIterationMs: Double
        var maxIterationMs: Double
        var aoInitCountDelta: Int64
        var aoErrorCount: Int64
        var residentMBBefore: Double
        var residentMBAfter: Double
        var threadsBefore: Int
        var threadsAfter: Int
        var ok: Bool
    }

    static let variantNames = ["mid-load", "playing", "paused", "idle-after-stop"]

    static func run(_ args: Args) async throws -> Int32 {
        let n = args.positionals.first.flatMap { Int($0) } ?? args.int("iterations") ?? 100
        let file = try EngineHarness.fixture(args.string("fixture"))
        var rng = SeededRandom(seed: UInt64(args.int("seed") ?? 7))
        let before = Measure.processInfo()
        let initsBefore = PullAO.initCount
        var failures: [String] = []
        var durations: [Double] = []
        var variants: [String: Int] = [:]
        for i in 0..<n {
            let variant = i % 4
            variants[variantNames[variant], default: 0] += 1
            let t0 = monotonicNanos()
            do {
                if let problem = try iteration(variant: variant, file: file, start: 5 + 40 * rng.unitInterval(),
                                               jitterMs: Int(rng.next() % 30)) {
                    failures.append("#\(i) \(variantNames[variant]): \(problem)")
                }
            } catch {
                failures.append("#\(i) \(variantNames[variant]): \(error)")
            }
            durations.append(Measure.ms(from: t0, to: monotonicNanos()))
            if !args.flag("json"), (i + 1) % 10 == 0 { stderr("stress-lifecycle: \(i + 1)/\(n)") }
        }
        let after = Measure.processInfo()
        let report = Report(
            iterations: n, completed: durations.count, crashes: 0, failures: failures, variants: variants,
            meanIterationMs: Measure.round(durations.reduce(0, +) / Double(max(durations.count, 1)), 1),
            maxIterationMs: Measure.round(durations.max() ?? 0, 1), aoInitCountDelta: PullAO.initCount - initsBefore,
            aoErrorCount: PullAO.errorCount, residentMBBefore: Measure.round(before.residentMB, 1),
            residentMBAfter: Measure.round(after.residentMB, 1), threadsBefore: before.threads,
            threadsAfter: after.threads, ok: failures.isEmpty && PullAO.errorCount == 0)
        printReport(report, pretty: !args.flag("json"))
        return report.ok ? 0 : 1
    }

    /// One create → play → shutdown cycle. Returns a problem description, or nil.
    static func iteration(variant: Int, file: URL, start: Double, jitterMs: Int) throws -> String? {
        let h = try EngineHarness()
        defer { h.shutdown() }
        try h.start()
        let inits = PullAO.initCount
        try h.mpv.loadfile(file.path, options: LoadFileOptions(start: start))
        if variant == 0 {
            usleep(UInt32(jitterMs * 1000))
            return nil // shut down while mpv is still opening the file
        }
        guard Measure.wait(timeout: 3, { h.bridge.counters.silentCallbacks < h.bridge.counters.callbacks }) else {
            return "no audio within 3 s"
        }
        if PullAO.initCount <= inits { return "AO not initialised" }
        if !(h.mpv.guards().audioOutParams?.isPullAOFormat ?? false) { return "audio-out-params guard failed" }
        switch variant {
        case 2:
            try h.pause()
            usleep(UInt32(10_000 + jitterMs * 1000))
        case 3:
            try h.mpv.seek(to: max(1, start - 3))
            usleep(30_000)
            try h.mpv.stop()
            if !Measure.wait(timeout: 1, { h.mpv.snapshot.idleActive == true }) { return "not idle after stop" }
        default:
            usleep(UInt32(jitterMs * 1000))
        }
        return nil
    }
}
