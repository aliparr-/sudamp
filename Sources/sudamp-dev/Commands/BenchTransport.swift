// SPDX-License-Identifier: GPL-3.0-or-later
import Audio
import Core
import Foundation
import MPV

/// `sudamp-dev bench-transport [<wav>] [--seconds N] [--json] [--seed S] [--mpv-log <file>] [--log-level <lvl>]`
///
/// PLAN M0 E1 transport benchmark, methodology from spikes/engine-pull-ao (spikepull): the ramp fixture plays
/// through mpv → pull AO → AVAudioEngine (muted); every render callback is logged in C; latencies are command →
/// render callback, read off the logged samples (the ramp encodes the source position).
enum BenchTransportCommand {
    /// PLAN M0 E1 (pauseToSilenceMs ≤ 16: one 10.67 ms IO buffer + the 5 ms ramp, as docs/spikes/E1.md proposed).
    static let thresholds: [String: Double] = [
        "shortReads": 0, "pauseToSilenceMs": 16, "seekP95Ms": 25, "staleQuanta": 1, "loadfileMs": 50,
        "getPropertyP99Ms": 1, "cpuPct": 3,
    ]

    struct Report: Encodable {
        var file: String
        var seconds: Double
        var buildConfiguration: String
        // Gate metrics (PLAN M0 E1)
        var shortReads: Int
        var pauseToSilenceMs: Double
        var seekP95Ms: Double
        var staleQuanta: Int
        var loadfileMs: Double
        var getPropertyP99Ms: Double
        var cpuPct: Double
        // Detail
        var steadyWindowSeconds: Double
        var steadyCallbacks: Int
        var steadyAOUnavailable: Int
        var callbackFrames: [String: Int]
        var callbackIntervalMeanMs: Double
        var callbackIntervalMaxMs: Double
        var shortReadsOutsideTransport: Int
        var pauseToSilenceSamplesMs: [Double]
        var pauseToSilenceP50Ms: Double
        /// Command → the first callback that starts silencing (the ramp's first sample).
        var pauseTakesEffectMaxMs: Double
        /// Design bound for pauseToSilenceMs: one IO buffer + the 5 ms ramp.
        var pauseToSilenceBoundMs: Double
        var pauseToSilentCallbackMaxMs: Double
        var mpvPauseToSilenceSamplesMs: [Double]
        var resumeToAudioMaxMs: Double
        var resumeSourceGapMaxMs: Double
        var seekSamplesMs: [Double]
        var seekP50Ms: Double
        var seekMaxMs: Double
        var seekStaleQuanta: [Int]
        var loadfileSamplesMs: [Double]
        var loadfileP50Ms: Double
        var loadfileStaleQuanta: [Int]
        var firstLoadMs: Double
        var getPropertyP50Ms: Double
        var getPropertyMaxMs: Double
        var getPropertySamples: Int
        var presentationLatencyMs: Double
        var outputLatencyMs: Double
        var ioBufferMs: Double
        var mpvVersion: String?
        var aoInitCount: Int64
        var aoErrorCount: Int64
        var audioOutParams: AudioParams?
        var guardsOK: Bool
        var optionsRejected: [String]
        var scriptsLoaded: [String]
        var mpvErrors: [String]
        var renderCounters: RenderCounters
        var pass: [String: Bool]
        var ok: Bool
    }

    static func run(_ args: Args) async throws -> Int32 {
        let file = try EngineHarness.fixture(args.positionals.first)
        let seconds = max(args.double("seconds") ?? 30, 20)
        let mpvLog = args.string("mpv-log").map { URL(filePath: $0) }
        let logLevel = args.string("log-level") ?? (mpvLog == nil ? "warn" : "debug")
        let report = try bench(file: file, seconds: seconds, seed: UInt64(args.int("seed") ?? 1), logLevel: logLevel,
                               mpvLog: mpvLog)
        printReport(report, pretty: !args.flag("json"))
        return report.ok ? 0 : 1
    }

    enum Kind { case firstLoad, productPause, productResume, mpvPause, mpvResume, seek, loadfile }

    struct Op {
        var kind: Kind
        var nanos: UInt64
        var target: Double
    }

    static func bench(file: URL, seconds: Double, seed: UInt64, logLevel: String, mpvLog: URL?) throws -> Report {
        let h = try EngineHarness(probeCapacity: Int(seconds * 100) + 4000, logLevel: logLevel, mpvLog: mpvLog)
        try h.start()
        let loop = [MPVOption("loop-file", "inf")]
        let monitor = PropertyMonitor(mpv: h.mpv)
        var ops: [Op] = []
        var rng = SeededRandom(seed: seed)
        let t0 = monotonicNanos()
        func at(_ s: Double) -> UInt64 { t0 + UInt64(s * 1e9) }
        func mark(_ kind: Kind, _ target: Double = 0) { ops.append(Op(kind: kind, nanos: monotonicNanos(), target: target)) }

        // Timeline: load, a steady window (CPU, short reads), then 10 host pauses, 3 mpv-only pauses, 12 seeks and
        // 5 loadfiles. The transport section takes ~19.5 s; the steady window gets the rest of --seconds.
        Measure.sleep(until: at(0.25))
        mark(.firstLoad)
        try h.mpv.loadfile(file.path, options: LoadFileOptions(extra: loop))
        let steadyStart = 2.0
        let steadyEnd = steadyStart + max(4, seconds - 22)
        Measure.sleep(until: at(steadyStart))
        let cpu0 = Measure.cpuSeconds(), wall0 = monotonicNanos()
        Measure.sleep(until: at(steadyEnd))
        let cpu1 = Measure.cpuSeconds(), wall1 = monotonicNanos()

        var t = steadyEnd + 0.5
        for _ in 0..<10 {
            Measure.sleep(until: at(t)); mark(.productPause); try h.pause()
            Measure.sleep(until: at(t + 0.3)); mark(.productResume); try h.resume()
            t += 0.6
        }
        for _ in 0..<3 {
            Measure.sleep(until: at(t)); mark(.mpvPause); try h.mpv.setPause(true)
            Measure.sleep(until: at(t + 0.3)); mark(.mpvResume); try h.mpv.setPause(false)
            t += 0.6
        }
        var position = h.mpv.getDouble("time-pos") ?? 20
        func nextTarget() -> Double {
            var target: Double
            repeat { target = 5 + 45 * rng.unitInterval() } while abs(target - position) < 3
            return target
        }
        for _ in 0..<12 {
            let target = nextTarget()
            Measure.sleep(until: at(t)); mark(.seek, target); try h.mpv.seek(to: target)
            position = target + 0.5
            t += 0.5
        }
        for _ in 0..<5 {
            let target = nextTarget()
            Measure.sleep(until: at(t)); mark(.loadfile, target)
            try h.mpv.loadfile(file.path, options: LoadFileOptions(mediaTitle: "bench", start: target, extra: loop))
            position = target + 1.0
            t += 1.0
        }
        Measure.sleep(until: at(t + 0.3))

        let latencies = monitor.stop()
        let guards = h.mpv.guards()
        let rejected = h.mpv.optionResults.filter { !$0.ok }.map { "\($0.name)=\($0.value)" }
        let presentation = h.audio.presentationLatency, output = h.audio.outputLatency, io = h.audio.ioBufferDuration
        let counters = h.bridge.counters
        h.shutdown()
        let probe = ProbeAnalysis(records: h.bridge.probeRecords())

        // Steady window.
        let steady = probe.records(from: at(steadyStart), to: at(steadyEnd))
        let shortReads = steady.filter { $0.got >= 0 && $0.got < $0.frames }.count
        var frameHistogram: [String: Int] = [:]
        for r in steady { frameHistogram[String(r.frames), default: 0] += 1 }
        let intervals = zip(steady.dropFirst(), steady).map { Measure.ms(from: $1.nanos, to: $0.nanos) }

        // Pauses: host + mpv (the product path), then mpv alone (the spike's measurement).
        func pauseSamples(_ pause: Kind, _ resume: Kind)
            -> (silence: [Double], effect: [Double], silentCallback: [Double], resume: [Double], gap: [Double]) {
            var silence: [Double] = [], effect: [Double] = [], silentCallback: [Double] = [], resumeMs: [Double] = []
            var gap: [Double] = []
            for (i, op) in ops.enumerated() where op.kind == pause {
                if let onset = probe.silenceOnset(after: op.nanos) { silence.append(Measure.ms(from: op.nanos, to: onset)) }
                if let first = probe.first(after: op.nanos, where: { $0.got < $0.frames || $0.peak == 0 }) {
                    effect.append(Measure.ms(from: op.nanos, to: first.nanos))
                }
                if let s = probe.first(after: op.nanos, where: { $0.peak == 0 }) {
                    silentCallback.append(Measure.ms(from: op.nanos, to: s.nanos))
                }
                guard let r = ops[(i + 1)...].first(where: { $0.kind == resume }) else { continue }
                if let back = probe.first(after: r.nanos, where: ProbeAnalysis.audible) {
                    resumeMs.append(Measure.ms(from: r.nanos, to: back.nanos))
                    if let before = probe.last(before: r.nanos, where: { $0.got > 0 }) {
                        gap.append((ProbeAnalysis.position(back.firstR) - ProbeAnalysis.position(before.lastR)) * 1000)
                    }
                }
            }
            return (silence, effect, silentCallback, resumeMs, gap)
        }
        let product = pauseSamples(.productPause, .productResume)
        let mpvOnly = pauseSamples(.mpvPause, .mpvResume)

        func arrivals(_ kind: Kind) -> (ms: [Double], stale: [Int]) {
            var ms: [Double] = [], stale: [Int] = []
            for op in ops where op.kind == kind {
                if let a = probe.arrival(after: op.nanos, nearPosition: op.target) {
                    ms.append(Measure.ms(from: op.nanos, to: a.record.nanos))
                    stale.append(a.staleQuanta)
                } else {
                    ms.append(.infinity)
                    stale.append(99)
                }
            }
            return (ms, stale)
        }
        let seeks = arrivals(.seek)
        let loads = arrivals(.loadfile)
        let firstLoad = ops.first { $0.kind == .firstLoad }.flatMap { op in
            probe.first(after: op.nanos, where: ProbeAnalysis.audible).map { Measure.ms(from: op.nanos, to: $0.nanos) }
        } ?? .infinity

        // Short reads anywhere outside transport windows (each op + 0.6 s, and paused spans).
        var excluded: [(UInt64, UInt64)] = ops.map { ($0.nanos, $0.nanos + 600_000_000) }
        for (i, op) in ops.enumerated() where op.kind == .productPause || op.kind == .mpvPause {
            if let r = ops[(i + 1)...].first(where: { $0.kind == .productResume || $0.kind == .mpvResume }) {
                excluded.append((op.nanos, r.nanos + 600_000_000))
            }
        }
        let firstAudio = probe.first(after: t0, where: ProbeAnalysis.audible)?.nanos ?? t0
        let outside = probe.records.filter { r in
            r.nanos > firstAudio + 500_000_000 && r.nanos < at(t) && !excluded.contains { r.nanos >= $0.0 && r.nanos <= $0.1 }
        }
        let shortOutside = outside.filter { $0.got >= 0 && $0.got < $0.frames }.count

        let cpuPct = (cpu1 - cpu0) / (Double(wall1 - wall0) / 1e9) * 100
        let pauseMax = product.silence.max() ?? .infinity
        let staleMax = (seeks.stale + loads.stale).max() ?? 99
        let values: [String: Double] = [
            "shortReads": Double(shortReads), "pauseToSilenceMs": pauseMax,
            "seekP95Ms": Measure.percentile(seeks.ms, 95), "staleQuanta": Double(staleMax),
            "loadfileMs": loads.ms.max() ?? .infinity, "getPropertyP99Ms": Measure.percentile(latencies, 99),
            "cpuPct": cpuPct,
        ]
        var pass: [String: Bool] = [:]
        for (k, limit) in thresholds { pass[k] = (values[k] ?? .infinity) <= limit }
        pass["guards"] = guards.ok
        pass["options"] = rejected.isEmpty
        let r = Measure.round
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        return Report(
            file: file.path, seconds: Measure.round(Double(monotonicNanos() - t0) / 1e9, 1),
            buildConfiguration: configuration,
            shortReads: shortReads, pauseToSilenceMs: r(pauseMax, 2), seekP95Ms: r(values["seekP95Ms"]!, 2),
            staleQuanta: staleMax, loadfileMs: r(values["loadfileMs"]!, 2),
            getPropertyP99Ms: r(values["getPropertyP99Ms"]!, 4), cpuPct: r(cpuPct, 2),
            steadyWindowSeconds: steadyEnd - steadyStart, steadyCallbacks: steady.count,
            steadyAOUnavailable: steady.filter { $0.got == -1 }.count, callbackFrames: frameHistogram,
            callbackIntervalMeanMs: r(intervals.isEmpty ? .nan : intervals.reduce(0, +) / Double(intervals.count), 3),
            callbackIntervalMaxMs: r(intervals.max() ?? .nan, 3), shortReadsOutsideTransport: shortOutside,
            pauseToSilenceSamplesMs: product.silence.map { r($0, 2) },
            pauseToSilenceP50Ms: r(Measure.percentile(product.silence, 50), 2),
            pauseTakesEffectMaxMs: r(product.effect.max() ?? .nan, 2),
            pauseToSilenceBoundMs: r((io + Double(RenderBridge.pauseRampFrames) / 48_000) * 1000, 2),
            pauseToSilentCallbackMaxMs: r(product.silentCallback.max() ?? .nan, 2),
            mpvPauseToSilenceSamplesMs: mpvOnly.silence.map { r($0, 2) },
            resumeToAudioMaxMs: r((product.resume + mpvOnly.resume).max() ?? .nan, 2),
            resumeSourceGapMaxMs: r((product.gap + mpvOnly.gap).map(abs).max() ?? .nan, 3),
            seekSamplesMs: seeks.ms.map { r($0, 2) }, seekP50Ms: r(Measure.percentile(seeks.ms, 50), 2),
            seekMaxMs: r(seeks.ms.max() ?? .nan, 2), seekStaleQuanta: seeks.stale,
            loadfileSamplesMs: loads.ms.map { r($0, 2) }, loadfileP50Ms: r(Measure.percentile(loads.ms, 50), 2),
            loadfileStaleQuanta: loads.stale, firstLoadMs: r(firstLoad, 2),
            getPropertyP50Ms: r(Measure.percentile(latencies, 50), 4), getPropertyMaxMs: r(latencies.max() ?? .nan, 4),
            getPropertySamples: latencies.count, presentationLatencyMs: r(presentation * 1000, 3),
            outputLatencyMs: r(output * 1000, 3), ioBufferMs: r(io * 1000, 3), mpvVersion: guards.mpvVersion,
            aoInitCount: guards.aoInitCount, aoErrorCount: guards.aoErrorCount, audioOutParams: guards.audioOutParams,
            guardsOK: guards.ok, optionsRejected: rejected, scriptsLoaded: h.events.scriptsLoaded,
            mpvErrors: Array(h.events.errors.prefix(20)), renderCounters: counters, pass: pass,
            ok: pass.values.allSatisfy { $0 })
    }
}
