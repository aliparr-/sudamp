// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SkinUI

/// The app's own command-line options on top of Core's `LaunchArguments` (which keeps M2's): they are taken out
/// first and the rest goes to `LaunchArguments.parse`.
///
/// ```
/// sudamp [<skin.wsz> …] [--style modern|classic] [--scale 1|1.2|1.5|2|2.5|3] [--no-region] [--ignore-occlusion]
/// sudamp --snapshot <dir> --states <state.json> [<state.json> …]
/// ```
/// - `.wsz`/`.zip` paths load that skin (a second launch forwards them to the running instance, absolute).
/// - `--style` shows the modern or the classic skins for this launch without changing the saved choice (DESIGN §8.4).
/// - `--scale` overrides the saved window scale; `--no-region` turns region.txt shaping off for this launch (S1 kill
///   switch); `--ignore-occlusion` keeps the visualiser animating while the windows are covered (CPU measurements
///   on a locked screen).
/// - `--snapshot` renders app states offscreen to PNG, `.rgba` and `.sha256` and exits (PLAN M5 snapshot goldens).
nonisolated struct ShellArguments: Equatable, Sendable {
    var skinFiles: [String] = []
    /// `modern` or `classic` (`SkinClass`), this launch only.
    var style: String?
    var scale: Double?
    var noRegion = false
    var ignoreOcclusion = false
    var snapshotDirectory: String?
    var states: [String] = []
    /// Everything else, for `LaunchArguments.parse`.
    var remaining: [String] = []

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case badValue(String, String)
        case statesWithoutSnapshot

        var description: String {
            switch self {
            case .missingValue(let n): "\(n) needs a value"
            case let .badValue(n, v): "bad value for \(n): \(v)"
            case .statesWithoutSnapshot: "--states needs --snapshot <dir>"
            }
        }
    }

    static func isSkinPath(_ argument: String) -> Bool {
        guard !argument.hasPrefix("-"), !argument.contains("://") else { return false }
        return ["wsz", "zip"].contains((argument as NSString).pathExtension.lowercased())
    }

    /// - Parameter arguments: argv without the executable.
    static func parse(_ arguments: [String]) throws(ParseError) -> ShellArguments {
        var a = ShellArguments()
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            func value() throws(ParseError) -> String {
                guard i + 1 < arguments.count else { throw .missingValue(arg) }
                i += 1
                return arguments[i]
            }
            switch arg {
            case "--scale":
                let v = try value()
                guard let n = Double(v), SkinScale.allowed.contains(n) else { throw .badValue(arg, v) }
                a.scale = n
            case "--style":
                let v = try value()
                guard ["modern", "classic"].contains(v) else { throw .badValue(arg, v) }
                a.style = v
            case "--no-region": a.noRegion = true
            case "--ignore-occlusion": a.ignoreOcclusion = true
            case "--snapshot": a.snapshotDirectory = try value()
            case "--states":
                // Every following argument up to the next option (a shell glob expands to many).
                while i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
                    i += 1
                    a.states.append(arguments[i])
                }
                if a.states.isEmpty { throw .missingValue(arg) }
            default:
                if isSkinPath(arg) {
                    a.skinFiles.append(arg)
                } else {
                    a.remaining.append(arg)
                }
            }
            i += 1
        }
        if !a.states.isEmpty, a.snapshotDirectory == nil { throw .statesWithoutSnapshot }
        return a
    }

    /// Absolute skin paths, resolved against `directory` (a forwarded launch may run from anywhere).
    static func absolute(_ path: String, relativeTo directory: String = FileManager.default.currentDirectoryPath) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        return ((directory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    /// argv for the forwarded message: the same arguments with skin paths made absolute.
    static func forwardedArguments(_ arguments: [String], relativeTo directory: String = FileManager.default.currentDirectoryPath)
        -> [String] {
        arguments.map { isSkinPath($0) ? absolute($0, relativeTo: directory) : $0 }
    }

    /// The skin files in a forwarded argv.
    static func skinFiles(in arguments: [String]) -> [String] {
        arguments.filter(isSkinPath)
    }
}
