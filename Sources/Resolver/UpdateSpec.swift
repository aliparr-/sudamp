// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// yt-dlp's `_update_spec` release asset, which stops its self-updater from moving machines that a newer build
/// can't run on (old Pythons, old macOS) past a given release. EngineStore honours it the same way
/// (`yt_dlp/update.py` `_process_update_spec`, 2026.10.21):
///
/// - If any `lockV2` line exists, only `lockV2 <repo> <tag> <regex>` lines for our repo count; otherwise
///   `lock <tag> <regex>` lines.
/// - Lines are tried in file order; the first whose regex matches the *start* of the machine identifier
///   (Python's `re.match`) wins, and its tag caps the install: nothing newer than it may be chosen.
/// - The identifier is `<variant> <system_identifier()>`; 2026.10.21 on the dev machine reports `darwin_dir Python
///   3.14.7 (CPython arm64 64bit) - macOS-27.0.1-arm64-arm-64bit-Mach-O (OpenSSL 3.5.7 9 Jun 2026)` (R1).
///   Before any engine is installed we synthesise it from the
///   variant (`darwin_dir`, the onedir zip), macOS version and architecture, leaving the Python version out,
///   so only variant- and OS-based locks can match a first install (Python locks concern pip/zip installs).
///   Updates (M6) can pass the running engine's real identifier from its `-v` header instead.
public struct UpdateSpec: Sendable, Equatable {
    public struct Lock: Sendable, Equatable {
        public var repo: String?
        public var tag: String
        public var pattern: String
    }

    public let locks: [Lock]
    public let isVersion2: Bool

    public init(parsing text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        isVersion2 = lines.contains { $0.hasPrefix("lockV2 ") }
        var locks: [Lock] = []
        for line in lines {
            let f = line.split(separator: " ", maxSplits: isVersion2 ? 3 : 2, omittingEmptySubsequences: false)
                .map(String.init)
            if isVersion2, f.count == 4, f[0] == "lockV2" {
                locks.append(Lock(repo: f[1], tag: f[2], pattern: f[3]))
            } else if !isVersion2, f.count == 3, f[0] == "lock" {
                locks.append(Lock(repo: nil, tag: f[1], pattern: f[2]))
            }
        }
        self.locks = locks
    }

    /// The release this machine is capped at, or nil when no lock line matches (no cap).
    public func lockedTag(identifier: String, repo: String = "yt-dlp/yt-dlp") -> String? {
        for lock in locks where !isVersion2 || lock.repo == repo {
            guard let regex = try? NSRegularExpression(pattern: lock.pattern) else { continue }
            let range = NSRange(identifier.startIndex..., in: identifier)
            guard regex.firstMatch(in: identifier, options: .anchored, range: range) != nil else { continue }
            // Non-version tags only lock an exact requested tag in yt-dlp; they never cap "latest".
            if EngineVersion(lock.tag) != nil { return lock.tag }
        }
        return nil
    }

    /// The identifier of the onedir macOS build on this machine, without a Python version (see type docs).
    public static func synthesizedIdentifier(osVersion: OperatingSystemVersion = ProcessInfo.processInfo
        .operatingSystemVersion, machine: String = UpdateSpec.machine) -> String {
        let os = osVersion.patchVersion == 0
            ? "\(osVersion.majorVersion).\(osVersion.minorVersion)"
            : "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let arch = machine == "arm64" ? "arm64-arm-64bit" : "\(machine)-i386-64bit"
        return "darwin_dir Python (CPython \(machine) 64bit) - macOS-\(os)-\(arch)"
    }

    /// The identifier from a `yt-dlp -v` debug header: the variant from `[debug] yt-dlp version … (<variant>)` plus
    /// the `[debug] Python …` line, i.e. `darwin_dir Python 3.14.7 (CPython arm64 64bit) - macOS-…` (R1).
    public static func identifier(fromVerbose stderr: String) -> String? {
        var variant: String?
        var python: String?
        for raw in stderr.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[debug] yt-dlp version "), line.hasSuffix(")"), let open = line.lastIndex(of: "(") {
                let v = line[line.index(after: open)..<line.index(before: line.endIndex)]
                if !v.isEmpty, v.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { variant = String(v) }
            } else if line.hasPrefix("[debug] Python ") {
                python = String(line.dropFirst("[debug] ".count))
            }
        }
        guard let variant, let python else { return nil }
        return "\(variant) \(python)"
    }

    public static var machine: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}
