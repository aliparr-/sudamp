// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Catalog
import Core
import Foundation
import Playback
import os

/// Runs an `--automation <script.json>` script against the front end's own controls (PLAN M2 agent hooks; M5 adds
/// the skinned windows' menus, controls and skins) and produces one JSON document: the final `state.json` content
/// plus an `automation` report (each step's result, the starts with their TTFA, p50/p90, `dumpState` copies, and the
/// front end's extras such as `menuAutoOpened`, menu selections and menu dumps). The caller prints it and quits.
final class AutomationRunner {
    struct StepResult: Encodable {
        var index: Int
        var step: String
        var ok: Bool
        var ms: Double
        var state: String
        var note: String?
    }

    struct Start: Encodable {
        var ms: Double
        var source: String
        var streamId: String
        var trigger: String
        var prefetched: Bool
    }

    struct Report: Encodable {
        var name: String?
        var ok: Bool
        var failedStep: Int?
        var steps: [StepResult]
        var starts: [Start]
        var nonRadioStarts: Int
        var ttfaP50Ms: Double?
        var ttfaP90Ms: Double?
        var elapsedMs: Double
        var muted: Bool
    }

    private let script: ShellAutomationScript
    private let context: AppContext
    private let frontEnd: any PlayerFrontEnd
    private var dumps: [Any] = []
    private let log = Log.logger("automation")

    init(script: ShellAutomationScript, context: AppContext, frontEnd: any PlayerFrontEnd) {
        self.script = script
        self.context = context
        self.frontEnd = frontEnd
    }

    /// The script waits for the first-launch auto-open (only then does automation reproduce it).
    var wantsAutoOpen: Bool {
        script.steps.contains { if case .skin(.waitForMenu(.auto, _)) = $0 { true } else { false } }
    }

    /// Runs every step (stopping at the first failure) and returns the output document and whether all passed.
    func run() async -> (output: Data, ok: Bool) {
        let controller = context.controller
        let started = Date()
        await controller.prepare()
        frontEnd.automationWillStart(firstLaunch: context.isFirstLaunch && wantsAutoOpen)
        var results: [StepResult] = []
        var failed: Int?
        for (i, step) in script.steps.enumerated() {
            let t0 = Date()
            let (ok, note) = await perform(step)
            let result = StepResult(index: i + 1, step: step.description, ok: ok,
                                    ms: (Date().timeIntervalSince(t0) * 1000).rounded(), state: controller.snapshot.stateName,
                                    note: note)
            results.append(result)
            FileHandle.standardError.write(Data("automation: \(ok ? "ok  " : "FAIL") \(i + 1) \(step) → \(result.state)\(note.map { " (\($0))" } ?? "") [\(Int(result.ms)) ms]\n".utf8))
            if !ok {
                failed = i + 1
                break
            }
        }
        let starts = controller.ttfaHistory.filter { $0.trigger != "liveReload" }
        let ms = starts.map(\.ms)
        let report = Report(
            name: script.name, ok: failed == nil, failedStep: failed, steps: results,
            starts: starts.map { Start(ms: $0.ms, source: $0.source.rawValue, streamId: $0.streamId.rawValue,
                                       trigger: $0.trigger, prefetched: $0.prefetched) },
            nonRadioStarts: starts.filter { $0.source != .radio }.count,
            ttfaP50Ms: Self.percentile(ms, 50), ttfaP90Ms: Self.percentile(ms, 90),
            elapsedMs: (Date().timeIntervalSince(started) * 1000).rounded(), muted: context.muted)
        let extras = frontEnd.automationReport
        frontEnd.automationDidFinish()
        frontEnd.publishDebugState()
        await controller.writeDebugStateNow()
        let state = await controller.debugState()
        return (Self.document(state: state, report: report, dumps: dumps, extras: extras, pretty: !context.launch.json),
                failed == nil)
    }

    private func perform(_ step: ShellAutomationScript.Step) async -> (Bool, String?) {
        switch step {
        case .core(let core): return await perform(core)
        case .skin(let skin):
            // Menus show the genres' availability: let the first computation land so every anchor shows the same.
            await waitForAvailability()
            return await frontEnd.perform(skin)
        }
    }

    private func perform(_ step: AutomationScript.Step) async -> (Bool, String?) {
        let controller = context.controller
        switch step {
        case .selectGenre(let raw):
            guard let g = GenreID(rawValue: raw), controller.catalog.genre(g) != nil else { return (false, "unknown genre") }
            await waitForAvailability()
            return await frontEnd.automationSelect(.genre(g))
        case .surpriseMe:
            await waitForAvailability()
            let before = controller.snapshot
            let (selected, note) = await frontEnd.automationSelect(.surpriseMe)
            guard selected else { return (false, note ?? "Surprise Me disabled") }
            // Surprise Me chooses its genre asynchronously: wait until its pick is under way, so a following
            // `waitFor playing` can't pass on the stream that was already playing.
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let s = controller.snapshot
                if [.tuning, .buffering].contains(s.phase) || s.genre != before.genre { return (true, s.genreName) }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return (false, "Surprise Me picked nothing")
        case .press(let control):
            frontEnd.automationPress(control)
            return (true, nil)
        case let .waitFor(states, timeout):
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if states.contains(controller.snapshot.stateName) { return (true, nil) }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let last = controller.snapshot.lastError.map { "; last error \($0.kind) at \($0.stage): \($0.message.prefix(160))" } ?? ""
            return (states.contains(controller.snapshot.stateName), "timed out after \(timeout) s\(last)")
        case .sleep(let seconds):
            try? await Task.sleep(for: .seconds(seconds))
            return (true, nil)
        case .dumpState(let label):
            await controller.writeDebugStateNow()
            let state = await controller.debugState()
            if let data = try? Self.encoder(pretty: false).encode(state),
               var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let label { object["label"] = label }
                dumps.append(object)
            }
            return (true, nil)
        case .openURL(let url):
            return context.handle(url: url, origin: "automation") ? (true, nil) : (false, "not a sudamp URL")
        case .setVolume(let v):
            frontEnd.automationSetVolume(v)
            return (true, nil)
        case let .waitForEngine(target, timeout):
            let deadline = Date().addingTimeInterval(timeout)
            func matches() -> Bool {
                let e = controller.snapshot.engine
                return e.state.rawValue == target || e.download == target
            }
            while Date() < deadline {
                if matches() { return (true, nil) }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let e = controller.snapshot.engine
            return (matches(), "timed out after \(timeout) s; engine \(e.state.rawValue)/\(e.download ?? "-")")
        case .snapshot(let path):
            do {
                try frontEnd.snapshot(to: URL(filePath: (path as NSString).expandingTildeInPath))
                return (true, nil)
            } catch {
                return (false, "\(error)")
            }
        }
    }

    /// The dropdown's enabled state comes from an async eligibility pass; give the first one a moment.
    private func waitForAvailability() async {
        let deadline = Date().addingTimeInterval(2)
        while context.availability.isEmpty, Date() < deadline {
            context.refreshAvailability()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Output

    static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    /// `state.json`'s keys at the top level (so `jq '.state'` reads the same as on the file), plus `automation`, with
    /// the front end's extras both inside it and (for `menuAutoOpened`) at the top level.
    static func document(state: PlaybackDebugState, report: Report, dumps: [Any], extras: [String: Any] = [:],
                         pretty: Bool) -> Data {
        let encoder = encoder(pretty: false)
        guard let stateData = try? encoder.encode(state), let reportData = try? encoder.encode(report),
              var object = (try? JSONSerialization.jsonObject(with: stateData)) as? [String: Any],
              var automation = (try? JSONSerialization.jsonObject(with: reportData)) as? [String: Any] else {
            return Data("{\"error\":\"cannot encode the automation report\"}\n".utf8)
        }
        if !dumps.isEmpty { automation["dumps"] = dumps }
        for (key, value) in extras { automation[key] = value }
        if let opened = extras["menuAutoOpened"] { object["menuAutoOpened"] = opened }
        object["automation"] = automation
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: options)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// Nearest-rank percentile (as `sudamp-dev play` reports them).
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let rank = Int((p / 100 * Double(s.count)).rounded(.up))
        return s[min(max(rank, 1), s.count) - 1]
    }
}
