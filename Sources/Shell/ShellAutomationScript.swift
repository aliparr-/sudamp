// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation

/// An `--automation` script for the app: Core's `AutomationScript` steps (PLAN M2) plus the skinned UI's (PLAN M5).
/// The file format is Core's; a step whose key is one of these is parsed here, every other step by Core:
///
/// | Step | Meaning |
/// |---|---|
/// | `{"openGenreMenu": "marquee"\|"options"\|"contextMenu"}` | open the genre menu at that anchor (on screen, as a click would) |
/// | `{"waitForMenu": "genre"\|"presets"\|"context"\|"any"\|"auto", "timeout": s}` | wait until such a menu is open; `auto` first asks for the first-launch auto-open |
/// | `{"selectMenuItem": "Deep House"}` or `"Recently Played/…"` | choose an item of the open menu through the menu |
/// | `{"selectMenuBarItem": "View/Scale 2x"}` | choose a menu-bar item by its title path |
/// | `"cancelMenu"` | close the open menu |
/// | `{"pressControl": "<SkinKit control>", "window": "main"\|"equalizer"\|"playlist"}` | click a hotspot (`play`, `shuffle`, `eqOn`, `marquee`, `options`, …) |
/// | `{"dragSlider": "<control>", "value": v, "window": …}` | drag a slider: volume 0…1, balance -1…1, position 0…1, preamp/band0…band9 in dB |
/// | `{"loadSkin": "<path or skin id>", "expect": "loaded"\|"rejected"}` | load a skin as Open Skin… would; the step passes when the outcome is the expected one (default `loaded`) |
/// | `"dumpMenus"` or `{"dumpMenus": "<label>"}` | the menu tree of every entry point into the report |
/// | `{"showWindows": true}` | order the skinned windows in, without activating the app |
/// | `{"saveEQF": "<path>"}`, `{"loadEQF": "<path>"}` | the presets menu's Save/Load .eqf…, with the file chosen |
/// | `{"openStreamURL": "<url>"}` | Eject / ⌘L with the URL typed in |
/// | `{"playRow": n}` | double-click the Playlist's row n |
nonisolated struct ShellAutomationScript: Equatable, Sendable {
    enum MenuKind: String, Sendable, CaseIterable {
        case genre, presets, context, any, auto
    }

    enum SkinStep: Equatable, CustomStringConvertible {
        case openGenreMenu(GenreMenuAnchor)
        case waitForMenu(MenuKind, timeout: Double)
        case selectMenuItem(String)
        case selectMenuBarItem(String)
        case cancelMenu
        case pressControl(String, window: String)
        case dragSlider(String, value: Double, window: String)
        case loadSkin(String, expectRejection: Bool)
        case dumpMenus(label: String?)
        case showWindows
        case saveEQF(String)
        case loadEQF(String)
        case openStreamURL(String)
        case playRow(Int)

        var description: String {
            switch self {
            case .openGenreMenu(let a): "openGenreMenu \(a.rawValue)"
            case let .waitForMenu(k, t): "waitForMenu \(k.rawValue) (\(t) s)"
            case .selectMenuItem(let p): "selectMenuItem \(p)"
            case .selectMenuBarItem(let p): "selectMenuBarItem \(p)"
            case .cancelMenu: "cancelMenu"
            case let .pressControl(c, w): "pressControl \(c) [\(w)]"
            case let .dragSlider(c, v, w): "dragSlider \(c) → \(v) [\(w)]"
            case let .loadSkin(s, rejection): "loadSkin \(s)\(rejection ? " (expect rejected)" : "")"
            case .dumpMenus(let l): "dumpMenus\(l.map { " \($0)" } ?? "")"
            case .showWindows: "showWindows"
            case .saveEQF(let p): "saveEQF \(p)"
            case .loadEQF(let p): "loadEQF \(p)"
            case .openStreamURL(let u): "openStreamURL \(u)"
            case .playRow(let n): "playRow \(n)"
            }
        }
    }

    enum Step: Equatable, CustomStringConvertible {
        case core(AutomationScript.Step)
        case skin(SkinStep)

        var description: String {
            switch self {
            case .core(let s): s.description
            case .skin(let s): s.description
            }
        }

        /// Steps that drive the skinned windows (a `--plain` run refuses them).
        var needsSkinnedUI: Bool { if case .skin = self { true } else { false } }
    }

    var name: String?
    var steps: [Step]

    static let skinKeys: Set<String> = [
        "openGenreMenu", "waitForMenu", "selectMenuItem", "selectMenuBarItem", "cancelMenu", "pressControl",
        "dragSlider", "loadSkin", "dumpMenus", "showWindows", "saveEQF", "loadEQF", "openStreamURL", "playRow",
    ]
    static let windows: Set<String> = ["main", "equalizer", "playlist"]

    static func load(from url: URL) throws(AutomationScriptError) -> ShellAutomationScript {
        guard let data = try? Data(contentsOf: url) else { throw .unreadable(url.path) }
        return try parse(data)
    }

    static func parse(_ data: Data) throws(AutomationScriptError) -> ShellAutomationScript {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
            throw .invalidJSON("\(error.localizedDescription)")
        }
        var name: String?
        var timeout = AutomationScript.defaultTimeout
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
            if let skin = try skinStep(raw, index: i, defaultTimeout: timeout) {
                steps.append(.skin(skin))
            } else {
                steps.append(.core(try coreStep(raw, index: i, defaultTimeout: timeout)))
            }
        }
        return ShellAutomationScript(name: name, steps: steps)
    }

    /// `--skips N` (Core's rule: play, Next, wait for playing).
    mutating func appendSkips(_ count: Int, dwell: Double) {
        var core = AutomationScript(steps: [])
        core.appendSkips(count, dwell: dwell)
        steps += core.steps.map { .core($0) }
    }

    /// One step through Core's parser, so its rules and errors stay the only ones for Core's steps.
    private static func coreStep(_ raw: Any, index i: Int, defaultTimeout: Double) throws(AutomationScriptError)
        -> AutomationScript.Step {
        guard let data = try? JSONSerialization.data(withJSONObject: ["timeout": defaultTimeout, "steps": [raw]],
                                                     options: [.fragmentsAllowed]) else {
            throw .unknownStep(index: i, "\(raw)")
        }
        do {
            return try AutomationScript.parse(data).steps[0]
        } catch {
            // Report the step's position in this script, not in the one-step document.
            switch error {
            case .unknownStep(_, let s): throw .unknownStep(index: i, s)
            case .unknownState(_, let s): throw .unknownState(index: i, s)
            case .badValue(_, let key): throw .badValue(step: i, key: key)
            default: throw error
            }
        }
    }

    private static func skinStep(_ raw: Any, index i: Int, defaultTimeout: Double) throws(AutomationScriptError)
        -> SkinStep? {
        if let bare = raw as? String {
            switch bare {
            case "cancelMenu": return .cancelMenu
            case "dumpMenus": return .dumpMenus(label: nil)
            case "showWindows": return .showWindows
            default: return nil
            }
        }
        guard let object = raw as? [String: Any] else { return nil }
        let stepKeys = Set(object.keys).subtracting(["timeout", "comment", "window", "value", "expect"])
        guard stepKeys.count == 1, let key = stepKeys.first, skinKeys.contains(key) else { return nil }
        let value = object[key]!
        let window = object["window"] as? String ?? "main"
        if object["window"] != nil, !["pressControl", "dragSlider"].contains(key) { throw .badValue(step: i, key: "window") }
        if object["value"] != nil, key != "dragSlider" { throw .badValue(step: i, key: "value") }
        if object["timeout"] != nil, key != "waitForMenu" { throw .badValue(step: i, key: "timeout") }
        if object["expect"] != nil, key != "loadSkin" { throw .badValue(step: i, key: "expect") }
        guard windows.contains(window) else { throw .badValue(step: i, key: "window") }
        func text() throws(AutomationScriptError) -> String {
            guard let s = value as? String, !s.isEmpty else { throw .badValue(step: i, key: key) }
            return s
        }
        switch key {
        case "openGenreMenu":
            guard let a = GenreMenuAnchor(rawValue: try text()), [.marquee, .options, .contextMenu].contains(a) else {
                throw .badValue(step: i, key: key)
            }
            return .openGenreMenu(a)
        case "waitForMenu":
            guard let k = MenuKind(rawValue: try text()) else { throw .badValue(step: i, key: key) }
            var timeout = defaultTimeout
            if let t = object["timeout"] {
                guard let n = number(t), n > 0 else { throw .badValue(step: i, key: "timeout") }
                timeout = n
            }
            return .waitForMenu(k, timeout: timeout)
        case "selectMenuItem": return .selectMenuItem(try text())
        case "selectMenuBarItem": return .selectMenuBarItem(try text())
        case "cancelMenu": return .cancelMenu
        case "pressControl": return .pressControl(try text(), window: window)
        case "dragSlider":
            guard let v = object["value"].flatMap(number), v.isFinite else { throw .badValue(step: i, key: "value") }
            return .dragSlider(try text(), value: v, window: window)
        case "loadSkin":
            let expect = object["expect"] as? String ?? "loaded"
            guard ["loaded", "rejected"].contains(expect) else { throw .badValue(step: i, key: "expect") }
            return .loadSkin(try text(), expectRejection: expect == "rejected")
        case "dumpMenus":
            if let label = value as? String { return .dumpMenus(label: label) }
            guard (value as? Bool) != false else { throw .badValue(step: i, key: key) }
            return .dumpMenus(label: nil)
        case "showWindows":
            guard (value as? Bool) != false else { throw .badValue(step: i, key: key) }
            return .showWindows
        case "saveEQF": return .saveEQF(try text())
        case "loadEQF": return .loadEQF(try text())
        case "openStreamURL": return .openStreamURL(try text())
        case "playRow":
            guard let n = number(value), n >= 0, n == n.rounded() else { throw .badValue(step: i, key: key) }
            return .playRow(Int(n))
        default:
            return nil
        }
    }

    private static func number(_ value: Any) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}
