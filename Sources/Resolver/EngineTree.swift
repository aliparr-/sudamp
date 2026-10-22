// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Darwin
import Foundation

/// `tree.json`: path, mode and SHA-256 of every file in an installed engine (DESIGN §6.1 step 4). `_internal/`
/// is user-writable, so every launch re-hashes the tree before the first resolve and reinstalls on a mismatch.
public struct EngineTree: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable {
        /// Relative to the engine directory, `/`-separated.
        public var path: String
        /// Permission bits in octal, e.g. `"0755"`.
        public var mode: String
        public var size: Int64?
        /// Regular files only.
        public var sha256: String?
        /// Symbolic links only: the link's target, which is recorded rather than followed.
        public var link: String?
    }

    public static let fileName = "tree.json"

    public var version: String
    public var createdAt: Double
    public var entries: [Entry]

    public var fileCount: Int { entries.count }
    public var totalBytes: Int64 { entries.reduce(0) { $0 + ($1.size ?? 0) } }

    /// Hashes every regular file and records every symlink under `root` (directories are implied by paths).
    public static func scan(root: URL, version: String, now: Date = Date()) throws -> EngineTree {
        var entries: [Entry] = []
        for path in try relativePaths(under: root) where path != fileName {
            entries.append(try entry(root: root, path: path))
        }
        return EngineTree(version: version, createdAt: now.timeIntervalSince1970,
                          entries: entries.sorted { $0.path < $1.path })
    }

    /// Re-hashes the tree. Extra files count as a mismatch too: a planted `yt-dlp-plugins/` next to the
    /// executable or `_internal/yt_dlp_plugins/` would otherwise go unnoticed (plugin isolation, DESIGN §6.2).
    public func verify(root: URL) throws -> TreeVerification {
        let started = ContinuousClock.now
        var result = TreeVerification()
        let expected = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let actual = Set(try Self.relativePaths(under: root)).subtracting([Self.fileName])
        for (path, want) in expected.sorted(by: { $0.key < $1.key }) {
            guard actual.contains(path) else { result.missing.append(path); continue }
            let have = try Self.entry(root: root, path: path)
            if have.sha256 != want.sha256 || have.link != want.link || have.size != want.size {
                result.modified.append(path)
            } else if have.mode != want.mode {
                result.modeChanged.append(path)
            }
        }
        result.unexpected = actual.subtracting(expected.keys).sorted()
        result.checked = expected.count
        result.elapsedMs = (ContinuousClock.now - started).milliseconds
        return result
    }

    /// Every non-directory path below `root`, relative, without following symlinks.
    static func relativePaths(under root: URL) throws -> [String] {
        guard let e = FileManager.default.enumerator(atPath: root.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        var paths: [String] = []
        while let rel = e.nextObject() as? String {
            var st = stat()
            guard lstat(root.appending(path: rel).path, &st) == 0 else { continue }
            if st.st_mode & S_IFMT != S_IFDIR { paths.append(rel) }
        }
        return paths
    }

    static func entry(root: URL, path: String) throws -> Entry {
        let url = root.appending(path: path)
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let mode = String(format: "%04o", Int(st.st_mode & 0o7777))
        if st.st_mode & S_IFMT == S_IFLNK {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            return Entry(path: path, mode: mode, size: nil, sha256: nil, link: target)
        }
        return Entry(path: path, mode: mode, size: Int64(st.st_size), sha256: try FileDigest.sha256(of: url), link: nil)
    }
}

/// Outcome of `EngineTree.verify`.
public struct TreeVerification: Sendable, Codable, Equatable {
    public var checked = 0
    public var missing: [String] = []
    public var modified: [String] = []
    public var modeChanged: [String] = []
    public var unexpected: [String] = []
    public var elapsedMs = 0.0

    public init() {}

    public var ok: Bool { missing.isEmpty && modified.isEmpty && modeChanged.isEmpty && unexpected.isEmpty }
}

/// Gatekeeper's quarantine attribute (DESIGN §6.1 step 3): a non-sandboxed app's own writes aren't quarantined
/// unless `LSFileQuarantineEnabled` is set, and `ditto --noqtn` doesn't propagate it; this proves both.
public enum Quarantine {
    public static let attribute = "com.apple.quarantine"

    /// Paths (relative to `root`, `.` for root itself) carrying the attribute, checked without following links.
    public static func scan(root: URL) -> [String] {
        var hits: [String] = []
        if has(root.path) { hits.append(".") }
        let e = FileManager.default.enumerator(atPath: root.path)
        while let rel = e?.nextObject() as? String {
            if has(root.appending(path: rel).path) { hits.append(rel) }
        }
        return hits
    }

    public static func has(_ path: String) -> Bool {
        getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}
