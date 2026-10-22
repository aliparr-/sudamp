// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The app's command line (PLAN M2; DESIGN §9 agent hooks). `--selftest`, `--engine-check` and `--skin-preview`
/// are dispatched before this parser runs.
///
/// ```
/// sudamp [--plain] [--mute] [--profile <dir>] [--no-resume] [sudamp://… …]
///        [--automation <script.json> [--skips N] [--skip-dwell S] [--json]]
///        [--feed <feed.json>] [--source k[,k…]]          (debug builds)
/// ```
/// Unknown `-Apple…`-style arguments (LaunchServices and AppKit pass some, e.g. `-NSDocumentRevisionsDebugMode YES`)
/// are skipped together with their value; other unknown `--options` are reported, not fatal.
public struct LaunchArguments: Equatable, Sendable {
    /// M2: the plain window is the only UI (M5 makes the skinned windows the default).
    public var plain = false
    /// Forces mixer volume 0 (AUDIO SAFETY for automation; also `SUDAMP_MUTE=1`).
    public var mute = false
    public var json = false
    public var profile: String?
    public var automation: String?
    /// `--skips N`: after the script, press Next N times (see `AutomationScript.appendSkips`).
    public var skips = 0
    public var skipDwell: Double?
    /// Debug: another feed file.
    public var feed: String?
    /// Debug: restrict picks to these sources (raw `SourceKind` values).
    public var sources: [String]?
    /// Don't auto-resume this launch.
    public var noResume = false
    /// `sudamp:` URLs given on the command line, in order.
    public var urls: [String] = []
    /// Unknown `--options` (warned about).
    public var unknown: [String] = []

    public init() {}

    /// - Parameter arguments: argv without the executable.
    public static func parse(_ arguments: [String]) throws(LaunchArgumentsError) -> LaunchArguments {
        var a = LaunchArguments()
        var i = 0
        func value(_ name: String) throws(LaunchArgumentsError) -> String {
            guard i + 1 < arguments.count else { throw .missingValue(name) }
            i += 1
            return arguments[i]
        }
        while i < arguments.count {
            let arg = arguments[i]
            var name = arg
            var inline: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                name = String(arg[..<eq])
                inline = String(arg[arg.index(after: eq)...])
            }
            func take() throws(LaunchArgumentsError) -> String {
                if let inline { return inline }
                return try value(name)
            }
            switch name {
            case "--plain": a.plain = true
            case "--mute": a.mute = true
            case "--json": a.json = true
            case "--no-resume": a.noResume = true
            case "--profile": a.profile = try take()
            case "--automation": a.automation = try take()
            case "--feed": a.feed = try take()
            case "--skips":
                let v = try take()
                guard let n = Int(v), (0...100).contains(n) else { throw .badValue(name, v) }
                a.skips = n
            case "--skip-dwell":
                let v = try take()
                guard let s = Double(v), s >= 0, s <= 600 else { throw .badValue(name, v) }
                a.skipDwell = s
            case "--source":
                let v = try take()
                let list = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !list.isEmpty else { throw .badValue(name, v) }
                a.sources = list
            default:
                if arg.lowercased().hasPrefix("\(RemoteCommand.scheme):") {
                    a.urls.append(arg)
                } else if arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 1 {
                    // `-NSSomething YES` / `-psn_0_123`: AppKit's, skip with a following value.
                    if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") { i += 1 }
                } else {
                    a.unknown.append(arg)
                }
            }
            i += 1
        }
        if a.skips > 0, a.automation == nil { throw .requiresAutomation("--skips") }
        return a
    }

    /// A file whose existence mutes debug builds whatever the arguments (a guard for agents' terminal checks: a
    /// LaunchServices launch never carries `--mute`).
    public static let debugMuteSentinel = URL(filePath: "/tmp/sudamp-force-mute")

    /// `--mute`, `SUDAMP_MUTE=1|true|yes`, or (debug builds) the sentinel file.
    public func isMuted(environment: [String: String] = ProcessInfo.processInfo.environment,
                        sentinel: URL? = LaunchArguments.debugMuteSentinel) -> Bool {
        if mute { return true }
        if let v = environment["SUDAMP_MUTE"]?.lowercased(), ["1", "true", "yes"].contains(v) { return true }
        #if DEBUG
        if let sentinel, FileManager.default.fileExists(atPath: sentinel.path) { return true }
        #endif
        return false
    }
}

public enum LaunchArgumentsError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingValue(String)
    case badValue(String, String)
    case requiresAutomation(String)

    public var description: String {
        switch self {
        case .missingValue(let n): "\(n) needs a value"
        case let .badValue(n, v): "bad value for \(n): \(v)"
        case .requiresAutomation(let n): "\(n) needs --automation <script.json>"
        }
    }

    public static let usage = """
    usage: sudamp [--plain] [--mute] [--profile <dir>] [--no-resume] [sudamp://…]
           sudamp --automation <script.json> [--skips N] [--skip-dwell S] [--json] [--mute] [--profile <dir>]
           sudamp --selftest [--json] | --selftest --engine-check | --skin-preview [options]
      debug builds: --feed <feed.json>, --source youtube|youtube-live|soundcloud|mixcloud|radio[,…]
    """
}
