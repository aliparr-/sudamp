// SPDX-License-Identifier: GPL-3.0-or-later
import Audio
import Core
import Foundation
import MPV

/// `sudamp --selftest [--json] [--fixture <wav>]` and `sudamp --selftest --play <url> [--seconds N] [--json]`:
/// checks that can be asserted from a terminal with `jq` (PLAN M0 T1, E1, L1). The engine checks play silently
/// (mixer volume 0 and the render bridge's output muted) through the real pull-AO path inside the .app.
struct SelfTestReport: Encodable {
    struct Resources: Encodable {
        var ok: Bool
        var detail: String
    }

    struct Engine: Encodable {
        var mode: String
        var source: String
        var secondsPlayed: Double
        var ttfaMs: Double?
        var audioRendered: Bool
        var callbacks: UInt64
        var nonSilentCallbacks: UInt64
        var shortReads: UInt64
        var mediaTitle: String?
        var icyTitle: String?
        var optionsRejected: [String]
        var guardFailures: [String]
        var errors: [String]
    }

    var version: String
    var resources: Resources
    var mpvClientAPI: UInt
    var mpvVersion: String?
    var aoDescription: String
    var aoInitCount: Int64
    var aoErrorCount: Int64
    var audioOutParams: AudioParams?
    var engine: Engine
    var ok: Bool

    func json(pretty: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf",
                                                                      nan: "nan")
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

enum SelfTest {
    static func run(arguments: [String]) -> SelfTestReport {
        let resources = checkResources()
        let play = value(after: "--play", in: arguments)
        let seconds = value(after: "--seconds", in: arguments).flatMap(Double.init) ?? (play == nil ? 1 : 10)
        let outcome: EngineOutcome
        if let play {
            outcome = runEngine(source: play, options: .radio(), seconds: seconds, mode: "play")
        } else {
            do {
                let fixture = try fixtureURL(arguments)
                outcome = runEngine(source: fixture.path, options: LoadFileOptions(), seconds: seconds, mode: "fixture")
            } catch {
                outcome = EngineOutcome(failure: "fixture: \(error)", mode: "fixture")
            }
        }
        let g = outcome.guards
        let ok: Bool
        if play != nil {
            // L1: audio rendered through the pull AO, no format refusals.
            ok = outcome.engine.audioRendered && g.aoInitCount >= 1 && g.aoErrorCount == 0
        } else {
            // T1 + E1: resources load, and every runtime engine guard holds for the 44.1 kHz ramp fixture.
            ok = resources.ok && outcome.engine.audioRendered && g.ok
        }
        return SelfTestReport(version: BuildInfo.version, resources: resources, mpvClientAPI: MPVInfo.clientAPIVersion,
                              mpvVersion: g.mpvVersion, aoDescription: PullAO.driverDescription,
                              aoInitCount: g.aoInitCount, aoErrorCount: g.aoErrorCount,
                              audioOutParams: g.audioOutParams, engine: outcome.engine, ok: ok)
    }

    /// Proves `Bundle.module` resolves inside the assembled .app (resource bundles copied to Contents/Resources).
    private static func checkResources() -> SelfTestReport.Resources {
        guard let url = Bundle.module.url(forResource: "selftest", withExtension: "txt") else {
            return .init(ok: false, detail: "selftest.txt not found in Bundle.module")
        }
        let text = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(ok: text == "sudamp resources ok", detail: url.path)
    }

    /// `--fixture <path>`, else `.build/fixtures/ramp60.wav` (cwd), else a freshly generated temporary copy.
    private static func fixtureURL(_ arguments: [String]) throws -> URL {
        if let path = value(after: "--fixture", in: arguments) { return URL(filePath: path) }
        let local = URL(filePath: RampFixture.defaultRelativePath)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        return try RampFixture.ensure(at: FileManager.default.temporaryDirectory.appending(path: "sudamp-selftest/ramp60.wav"))
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    private struct EngineOutcome {
        var engine: SelfTestReport.Engine
        var guards: EngineGuards

        init(engine: SelfTestReport.Engine, guards: EngineGuards) {
            self.engine = engine
            self.guards = guards
        }

        init(failure: String, mode: String) {
            engine = .init(mode: mode, source: "", secondsPlayed: 0, ttfaMs: nil, audioRendered: false, callbacks: 0,
                           nonSilentCallbacks: 0, shortReads: 0, mediaTitle: nil, icyTitle: nil, optionsRejected: [],
                           guardFailures: [], errors: [failure])
            guards = EngineGuards(mpvVersion: nil, aoInitCount: PullAO.initCount, aoErrorCount: PullAO.errorCount,
                                  audioOutParams: nil)
        }
    }

    /// Plays `source` silently for `seconds` (at least until first audio, up to 5 s extra) and collects guards.
    private static func runEngine(source: String, options: LoadFileOptions, seconds: Double, mode: String) -> EngineOutcome {
        let log = Log.logger("selftest")
        let audio: AudioEngine
        let mpv: MPVClient
        do {
            audio = try AudioEngine(volume: 0)
            audio.bridge.setOutputMuted(true)
            mpv = try MPVClient()
            try audio.start()
        } catch {
            return EngineOutcome(failure: "engine start: \(error)", mode: mode)
        }
        audio.bridge.armTTFA()
        let t0 = monotonicNanos()
        var errors: [String] = []
        do {
            try mpv.loadfile(source, options: options)
        } catch {
            errors.append("loadfile: \(error)")
        }
        let minimum = t0 + UInt64(seconds * 1e9)
        let maximum = minimum + 5_000_000_000
        var guards = mpv.guards()
        while true {
            usleep(20_000)
            let now = monotonicNanos()
            if audio.bridge.ttfaNanos != nil, guards.audioOutParams == nil { guards = mpv.guards() }
            if let end = mpv.snapshot.lastEndFile, end.reason == .error { break }
            if now >= minimum && (audio.bridge.ttfaNanos != nil || now >= maximum) { break }
        }
        let latest = mpv.guards()
        guards = EngineGuards(mpvVersion: latest.mpvVersion, aoInitCount: latest.aoInitCount,
                              aoErrorCount: latest.aoErrorCount, audioOutParams: latest.audioOutParams ?? guards.audioOutParams)
        let played = Double(monotonicNanos() - t0) / 1e9
        let counters = audio.bridge.counters
        let snapshot = mpv.snapshot
        let rejected = mpv.optionResults.filter { !$0.ok }.map { "\($0.name)=\($0.value)" }
        errors += mpv.recentErrors
        // DESIGN §5.2 shutdown order: engine first, then mpv (stopping flag → wakeup → join → destroy).
        audio.stop()
        mpv.shutdown()
        let rendered = counters.callbacks > counters.silentCallbacks
        if !guards.ok { log.error("engine guard failed: \(guards.failures.joined(separator: "; "), privacy: .public)") }
        let engine = SelfTestReport.Engine(
            mode: mode, source: source, secondsPlayed: (played * 100).rounded() / 100,
            ttfaMs: audio.bridge.ttfaMilliseconds.map { ($0 * 10).rounded() / 10 }, audioRendered: rendered,
            callbacks: counters.callbacks, nonSilentCallbacks: counters.callbacks - counters.silentCallbacks,
            shortReads: counters.shortReads, mediaTitle: snapshot.mediaTitle, icyTitle: snapshot.icyTitle,
            optionsRejected: rejected, guardFailures: guards.failures, errors: errors)
        return EngineOutcome(engine: engine, guards: guards)
    }
}
