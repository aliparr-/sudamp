// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// An `--automation <script.json>` script (DESIGN §9 agent hooks, PLAN M2): the steps an agent drives the plain
/// window through, with no Apple Events. The app runs them, then prints its debug state (plus a step report) as
/// one JSON document on stdout and exits.
///
/// The document is an object `{"name": …, "timeout": <default wait seconds>, "steps": [...]}` or just the array of
/// steps. A step is a bare string for steps without arguments (`"pressNext"`) or an object with one step key and
/// options (`{"waitFor": "playing", "timeout": 10}`):
///
/// | Step | Meaning |
/// |---|---|
/// | `{"selectGenre": "<id>"}` | choose the genre in the dropdown (`"surprise"` = Surprise Me) |
/// | `"surpriseMe"` | choose Surprise Me |
/// | `"pressPlay"`, `"pressPause"`, `"pressPlayPause"`, `"pressNext"`, `"pressPrevious"`, `"pressStop"`, `"pressRetry"` | press a control |
/// | `{"waitFor": "<state>" or ["<state>", …], "timeout": <s>}` | wait until `.state` is one of them; a timeout fails the script |
/// | `{"sleep": <s>}` | wait |
/// | `"dumpState"` or `{"dumpState": "<label>"}` | write `debug/state.json` now and keep a copy in the report |
/// | `{"openURL": "sudamp://…"}` | act on a URL as if the URL scheme delivered it |
/// | `{"setVolume": <0…100>}` | move the volume slider |
/// | `{"waitForEngine": "<state or download>", "timeout": <s>}` | wait until `.engine.state` or `.engine.download` is it (`ready`, `failed`, `unreachable`, `noSpace`, `downloading`, …) |
/// | `{"snapshot": "<file.png>"}` | render the window's content to a PNG (works off screen and on a locked screen) |
public struct AutomationScript: Equatable, Sendable {
    public enum Control: String, Sendable, CaseIterable {
        case play, pause, playPause, next, previous, stop, retry
    }

    public enum Step: Equatable, Sendable, CustomStringConvertible {
        case selectGenre(String)
        case surpriseMe
        case press(Control)
        case waitFor(states: [String], timeout: Double)
        case sleep(Double)
        case dumpState(label: String?)
        case openURL(String)
        case setVolume(Double)
        case waitForEngine(String, timeout: Double)
        case snapshot(String)

        public var description: String {
            switch self {
            case .selectGenre(let g): "selectGenre \(g)"
            case .surpriseMe: "surpriseMe"
            case .press(let c): "press \(c.rawValue)"
            case let .waitFor(states, timeout): "waitFor \(states.joined(separator: "|")) (\(timeout) s)"
            case .sleep(let s): "sleep \(s) s"
            case .dumpState(let label): "dumpState\(label.map { " \($0)" } ?? "")"
            case .openURL(let u): "openURL \(u)"
            case .setVolume(let v): "setVolume \(v)"
            case let .waitForEngine(e, timeout): "waitForEngine \(e) (\(timeout) s)"
            case .snapshot(let path): "snapshot \(path)"
            }
        }
    }

    /// `.state` values a `waitFor` may name: the playback phases plus `audioEngineError` (PlaybackPhase lives in
    /// Picker, above Core; a Playback test keeps the two lists in step).
    public static let knownStates: Set<String> = [
        "idle", "tuning", "buffering", "playing", "paused", "offline", "failed", "audioEngineError",
    ]
    public static let defaultTimeout: Double = 15
    /// `--skips N`: how long each stream plays before Next (long enough for the ~10 s prefetch to finish).
    public static let defaultSkipDwell: Double = 14

    public var name: String?
    public var steps: [Step]

    public init(name: String? = nil, steps: [Step]) {
        self.name = name
        self.steps = steps
    }

    /// `--skips N`: after the script, N times: play for `dwell` seconds, press Next, wait for playing.
    public mutating func appendSkips(_ count: Int, dwell: Double = AutomationScript.defaultSkipDwell,
                                     timeout: Double = 30) {
        guard count > 0 else { return }
        for _ in 0..<count {
            steps += [.sleep(dwell), .press(.next), .waitFor(states: ["playing"], timeout: timeout)]
        }
    }

    public static func parse(_ data: Data) throws(AutomationScriptError) -> AutomationScript {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
            throw .invalidJSON("\(error.localizedDescription)")
        }
        var name: String?
        var timeout = defaultTimeout
        let rawSteps: [Any]
        if let array = root as? [Any] {
            rawSteps = array
        } else if let object = root as? [String: Any] {
            let unknown = Set(object.keys).subtracting(["name", "timeout", "steps", "description"])
            if let key = unknown.sorted().first { throw .unknownKey(key) }
            name = object["name"] as? String
            if let t = object["timeout"] {
                guard let n = number(t), n > 0 else { throw .badValue(step: nil, key: "timeout") }
                timeout = n
            }
            guard let s = object["steps"] as? [Any] else { throw .missingSteps }
            rawSteps = s
        } else {
            throw .missingSteps
        }
        guard !rawSteps.isEmpty else { throw .missingSteps }
        var steps: [Step] = []
        for (i, raw) in rawSteps.enumerated() {
            steps.append(try step(raw, index: i, defaultTimeout: timeout))
        }
        return AutomationScript(name: name, steps: steps)
    }

    public static func load(from url: URL) throws(AutomationScriptError) -> AutomationScript {
        guard let data = try? Data(contentsOf: url) else { throw .unreadable(url.path) }
        return try parse(data)
    }

    private static let controls: [String: Control] = [
        "pressPlay": .play, "pressPause": .pause, "pressPlayPause": .playPause, "pressNext": .next,
        "pressPrevious": .previous, "pressStop": .stop, "pressRetry": .retry,
    ]

    private static func step(_ raw: Any, index i: Int, defaultTimeout: Double) throws(AutomationScriptError) -> Step {
        if let bare = raw as? String {
            if let c = controls[bare] { return .press(c) }
            switch bare {
            case "surpriseMe": return .surpriseMe
            case "dumpState": return .dumpState(label: nil)
            default: throw .unknownStep(index: i, bare)
            }
        }
        guard let object = raw as? [String: Any] else { throw .unknownStep(index: i, "\(raw)") }
        let keys = Set(object.keys)
        let stepKeys = keys.subtracting(["timeout", "comment"])
        guard stepKeys.count == 1, let key = stepKeys.first else {
            throw .unknownStep(index: i, stepKeys.sorted().joined(separator: ","))
        }
        if keys.contains("timeout"), key != "waitFor", key != "waitForEngine" { throw .badValue(step: i, key: "timeout") }
        let value = object[key]!
        if let c = controls[key] {
            guard (value as? Bool) != false else { throw .badValue(step: i, key: key) }
            return .press(c)
        }
        switch key {
        case "selectGenre":
            guard let g = value as? String, !g.isEmpty else { throw .badValue(step: i, key: key) }
            if g == "surprise" { return .surpriseMe }
            guard RemoteCommand.isValidGenreID(g) else { throw .badValue(step: i, key: key) }
            return .selectGenre(g)
        case "surpriseMe":
            return .surpriseMe
        case "waitFor":
            let states: [String]
            if let s = value as? String { states = [s] } else if let a = value as? [String], !a.isEmpty { states = a } else {
                throw .badValue(step: i, key: key)
            }
            if let bad = states.first(where: { !knownStates.contains($0) }) { throw .unknownState(index: i, bad) }
            var timeout = defaultTimeout
            if let t = object["timeout"] {
                guard let n = number(t), n > 0 else { throw .badValue(step: i, key: "timeout") }
                timeout = n
            }
            return .waitFor(states: states, timeout: timeout)
        case "sleep":
            guard let s = number(value), s >= 0, s <= 3600 else { throw .badValue(step: i, key: key) }
            return .sleep(s)
        case "dumpState":
            if let label = value as? String { return .dumpState(label: label) }
            guard (value as? Bool) != false else { throw .badValue(step: i, key: key) }
            return .dumpState(label: nil)
        case "openURL":
            guard let s = value as? String, RemoteCommand(string: s) != nil else { throw .badValue(step: i, key: key) }
            return .openURL(s)
        case "setVolume":
            guard let v = number(value), (0...100).contains(v) else { throw .badValue(step: i, key: key) }
            return .setVolume(v)
        case "waitForEngine":
            guard let e = value as? String, e.wholeMatch(of: #/[a-zA-Z]+/#) != nil else { throw .badValue(step: i, key: key) }
            var timeout = defaultTimeout
            if let t = object["timeout"] {
                guard let n = number(t), n > 0 else { throw .badValue(step: i, key: "timeout") }
                timeout = n
            }
            return .waitForEngine(e, timeout: timeout)
        case "snapshot":
            guard let path = value as? String, path.hasSuffix(".png") else { throw .badValue(step: i, key: key) }
            return .snapshot(path)
        default:
            throw .unknownStep(index: i, key)
        }
    }

    /// JSON numbers only (JSONSerialization also bridges booleans to NSNumber).
    private static func number(_ value: Any) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}

public enum AutomationScriptError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreadable(String)
    case invalidJSON(String)
    case missingSteps
    case unknownKey(String)
    case unknownStep(index: Int, String)
    case unknownState(index: Int, String)
    case badValue(step: Int?, key: String)

    public var description: String {
        switch self {
        case .unreadable(let p): "cannot read \(p)"
        case .invalidJSON(let m): "not JSON: \(m)"
        case .missingSteps: "no steps (expected {\"steps\": [...]} or an array of steps)"
        case .unknownKey(let k): "unknown key \(k)"
        case let .unknownStep(i, s): "step \(i + 1): unknown step \(s)"
        case let .unknownState(i, s): "step \(i + 1): unknown state \(s) (known: \(AutomationScript.knownStates.sorted().joined(separator: ", ")))"
        case let .badValue(i, k): "\(i.map { "step \($0 + 1): " } ?? "")bad value for \(k)"
        }
    }
}
