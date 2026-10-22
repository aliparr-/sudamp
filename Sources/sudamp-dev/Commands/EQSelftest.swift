// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Audio
import Core
import Foundation
import MPV
import Synchronization

/// `sudamp-dev eq-selftest [--json] [--mode all|gates|persist|shelf-ab|limiter] [--fixture <wav>]
///  [--cpu-seconds S]`
///
/// PLAN M3. `gates` renders the real graph (render bridge → AVAudioUnitEQ → mixer) in AVAudioEngine's offline
/// manual rendering mode (no device, deterministic; AVAudioSourceNode renders offline) and checks every band at
/// +12 dB, preamp +6, flat and balance, plus the headroom cap and the analytic EQ model. `persist` plays the ramp
/// fixture through mpv on a live engine whose mixer volume is 0 (the mixer's output is tapped and must be all
/// zeros) and checks the EQ gain is unchanged across `loadfile` and seek. `shelf-ab` and `limiter` are the PLAN's
/// evaluations (reported, not gates). `all` (default) runs everything; exit 0 iff every gate passes.
enum EQSelftestCommand {
    struct Report: Encodable {
        /// How the band/preamp/flat/balance gates were rendered.
        var mode: String
        var gates: EQMeasurement.GateReport?
        var persistence: Persistence?
        var shelfAB: EQMeasurement.ShelfABReport?
        var limiter: EQMeasurement.LimiterReport?
        var failures: [String]
        var ok: Bool
    }

    struct Persistence: Encodable {
        /// "liveMuted": a live engine at mixer volume 0 with the bridge unmuted, measured at the EQ's output tap.
        var mode: String
        var bandGains: [Float]
        var gainBeforeDB: Double
        var gainAfterLoadfileDB: Double
        var gainAfterSeekDB: Double
        var bandGainsAfter: [Float]
        /// Largest |sample| at the main mixer's output during the test (must be 0: nothing audible).
        var mixerOutputPeak: Float
        var checks: [EQMeasurement.Check]
        var ok: Bool
    }

    static func run(_ args: Args) async throws -> Int32 {
        let mode = args.string("mode") ?? "all"
        let all = mode == "all"
        var report = Report(mode: "offline", failures: [], ok: true)
        if all || mode == "gates" {
            let gates = try EQMeasurement.offlineGates()
            report.gates = gates
            report.failures += (gates.gates + gates.extra).filter { !$0.pass }.map(\.name)
        }
        if all || mode == "persist" {
            let persistence = try persist(fixture: try EngineHarness.fixture(args.string("fixture")))
            report.persistence = persistence
            report.failures += persistence.checks.filter { !$0.pass }.map { "persist.\($0.name)" }
        }
        if all || mode == "shelf-ab" { report.shelfAB = try EQMeasurement.shelfAB() }
        if all || mode == "limiter" {
            report.limiter = try EQMeasurement.limiterEvaluation(cpuSeconds: args.double("cpu-seconds") ?? 20)
        }
        report.ok = report.failures.isEmpty
        printReport(report, pretty: !args.flag("json"))
        return report.ok ? 0 : 1
    }

    /// Collects channel 0 (and the peak over all channels) of a tap.
    final class Collector: Sendable {
        private let samples = Mutex<[Float]>([])
        private let peak = Mutex<Float>(0)

        func append(_ buffer: AVAudioPCMBuffer) {
            guard let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            var p: Float = 0
            for c in 0..<Int(buffer.format.channelCount) {
                for i in 0..<n { p = max(p, abs(data[c][i])) }
            }
            let chunk = Array(UnsafeBufferPointer(start: data[0], count: n))
            samples.withLock { $0 += chunk }
            peak.withLock { $0 = max($0, p) }
        }

        func take() -> [Float] { samples.withLock { s in defer { s.removeAll() }; return s } }
        var peakValue: Float { peak.withLock { $0 } }
    }

    static func persist(fixture: URL) throws -> Persistence {
        let h = try EngineHarness()
        // AUDIO SAFETY: the mixer volume stays 0 (EngineHarness), so the device gets silence; the bridge is unmuted
        // only so the EQ sees the real signal. The mixer-output tap proves nothing audible left the graph.
        h.bridge.setOutputMuted(false)
        precondition(h.audio.mixerOutputVolume == 0, "eq-selftest persist needs mixer volume 0")
        h.audio.setEQHeadroom(.off)
        var bands = [Float](repeating: 0, count: 10)
        bands[4] = 12
        h.audio.apply(EQSettings(bands: bands))
        let source = Collector(), post = Collector(), mixer = Collector()
        h.audio.installTap(at: .sourceOutput) { buffer, _ in source.append(buffer) }
        h.audio.installTap(at: .eqOutput) { buffer, _ in post.append(buffer) }
        h.audio.installTap(at: .mixerOutput) { buffer, _ in mixer.append(buffer) }
        defer {
            for point in [AudioEngine.TapPoint.sourceOutput, .eqOutput, .mixerOutput] { h.audio.removeTap(at: point) }
            h.shutdown()
        }
        try h.start()
        let loop = [MPVOption("loop-file", "inf")]
        try h.mpv.loadfile(fixture.path, options: LoadFileOptions(start: 5, extra: loop))
        guard Measure.wait(timeout: 3, { h.bridge.counters.silentCallbacks < h.bridge.counters.callbacks }) else {
            throw ToolError("no audio from the fixture within 3 s")
        }
        func gain() -> Double {
            Measure.sleep(seconds: 0.4) // past the transport change and the EQ's settling
            _ = source.take()
            _ = post.take()
            Measure.sleep(seconds: 0.6)
            let input = EQMeasurement.amplitude(source.take(), frequency: 1000)
            let output = EQMeasurement.amplitude(post.take(), frequency: 1000)
            return input > 0 ? 20 * log10(output / input) : -200
        }
        let before = gain()
        try h.mpv.loadfile(fixture.path, options: LoadFileOptions(start: 20, extra: loop))
        let afterLoad = gain()
        try h.mpv.seek(to: 40)
        let afterSeek = gain()
        let after = h.audio.eqBandGains
        let checks: [EQMeasurement.Check] = [
            .within("band4+12.before", before, expected: 12, tolerance: 0.1),
            .within("band4+12.afterLoadfile", afterLoad, expected: 12, tolerance: 0.1),
            .within("band4+12.afterSeek", afterSeek, expected: 12, tolerance: 0.1),
            .within("bandGainsUnchanged", after == bands ? 1 : 0, expected: 1, tolerance: 0),
            .atMost("mixerOutputPeak", Double(mixer.peakValue), limit: 0),
        ]
        let r = { (v: Double) in Measure.round(v, 4) }
        return Persistence(mode: "liveMuted", bandGains: bands, gainBeforeDB: r(before), gainAfterLoadfileDB: r(afterLoad),
                           gainAfterSeekDB: r(afterSeek), bandGainsAfter: after, mixerOutputPeak: mixer.peakValue,
                           checks: checks, ok: checks.allSatisfy(\.pass))
    }
}
