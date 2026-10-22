// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Darwin
import Foundation
import Synchronization

/// Debug-only faults in the engine path (`SUDAMP_FAULT`, PLAN M2 and M6):
/// - `engine:unreachable`: every release request fails as if github.com were unreachable;
/// - `engine:abort-at=<pct>`: the zip download is cut once `pct`% of it is on disk (once per process, so a relaunch
///   without the fault resumes the `.partial` with an HTTP Range request);
/// - `disk:full`: the free-space check sees 0 bytes, so no download starts;
/// - `engine:corrupt` (M6): one byte of a file in the current build's `_internal/` is flipped before the launch
///   re-hash, which must catch it;
/// - `engine:bad-update` (M6): the launch update check is due regardless of the 24 h floor, the newest nightly stands
///   in as the candidate when no newer stable exists, and every canary check fails as an engine error.
public struct EngineFaults: Sendable, Equatable {
    public var unreachable = false
    /// 1...99.
    public var abortAtPercent: Int?
    public var diskFull = false
    public var corrupt = false
    public var badUpdate = false

    public init(unreachable: Bool = false, abortAtPercent: Int? = nil, diskFull: Bool = false, corrupt: Bool = false,
                badUpdate: Bool = false) {
        self.unreachable = unreachable
        self.abortAtPercent = abortAtPercent
        self.diskFull = diskFull
        self.corrupt = corrupt
        self.badUpdate = badUpdate
    }

    public static let none = EngineFaults()
    public var isActive: Bool { self != .none }

    /// Parses `SUDAMP_FAULT` (comma-separated) in debug builds; always `.none` in release.
    public static func from(environment: [String: String] = ProcessInfo.processInfo.environment) -> EngineFaults {
        #if DEBUG
        parse(environment["SUDAMP_FAULT"] ?? "")
        #else
        .none
        #endif
    }

    /// The `SUDAMP_FAULT` grammar (unknown items are ignored: other modules own them).
    public static func parse(_ value: String) -> EngineFaults {
        var f = EngineFaults()
        for item in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch item {
            case "engine:unreachable": f.unreachable = true
            case "disk:full": f.diskFull = true
            case "engine:corrupt": f.corrupt = true
            case "engine:bad-update": f.badUpdate = true
            default:
                if item.hasPrefix("engine:abort-at="), let pct = Int(item.dropFirst("engine:abort-at=".count)),
                   (1...99).contains(pct) {
                    f.abortAtPercent = pct
                }
            }
        }
        return f
    }

    /// The release source to install from, with these faults applied.
    public func releases(_ base: any EngineReleaseSource) -> any EngineReleaseSource {
        guard unreachable || abortAtPercent != nil else { return base }
        return FaultInjectingReleases(base: base, faults: self)
    }

    /// `engine:corrupt`: flips one byte in the middle of the first regular file (by path) under the current build's
    /// `_internal/`, as a user-writable tree could be tampered with. Returns the file's path relative to the build.
    public func applyCorruption(layout: EngineLayout, current: EngineInstallation?) -> String? {
        guard corrupt, let current else { return nil }
        let root = current.directoryURL(in: layout)
        guard let paths = try? EngineTree.relativePaths(under: root) else { return nil }
        for rel in paths.sorted() where rel.hasPrefix("_internal/") {
            let url = root.appending(path: rel)
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 0,
                  let handle = try? FileHandle(forUpdating: url) else { continue }
            defer { try? handle.close() }
            let offset = UInt64(st.st_size / 2)
            do {
                try handle.seek(toOffset: offset)
                guard let byte = try handle.read(upToCount: 1)?.first else { continue }
                try handle.seek(toOffset: offset)
                try handle.write(contentsOf: Data([byte ^ 0xFF]))
                return rel
            } catch {
                continue
            }
        }
        return nil
    }

    /// The free-space probe, with `disk:full` applied.
    public func freeSpace(_ base: @escaping @Sendable (URL) -> Int64?) -> @Sendable (URL) -> Int64? {
        guard diskFull else { return base }
        return { @Sendable _ in 0 }
    }
}

/// Wraps a release source with `EngineFaults`. Failures are `URLError`s, which EngineStore reports as
/// `EngineStoreError.unreachable`, like a real outage.
struct FaultInjectingReleases: EngineReleaseSource {
    let base: any EngineReleaseSource
    let faults: EngineFaults
    /// `abort-at` fires once per process.
    private static let aborted = Atomic<Bool>(false)

    var name: String { base.name }

    private func gate() throws {
        if faults.unreachable { throw URLError(.cannotConnectToHost) }
    }

    func latestVersion() async throws -> String {
        try gate()
        return try await base.latestVersion()
    }

    func recentVersions() async throws -> [String] {
        try gate()
        return try await base.recentVersions()
    }

    func updateSpec() async throws -> String? {
        try gate()
        return try await base.updateSpec()
    }

    func checksums(version: String) async throws -> String {
        try gate()
        return try await base.checksums(version: version)
    }

    func download(asset: String, version: String, to file: URL,
                  progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> DownloadOutcome {
        try gate()
        guard let pct = faults.abortAtPercent, !Self.aborted.load(ordering: .relaxed) else {
            return try await base.download(asset: asset, version: version, to: file, progress: progress)
        }
        // Cut the transfer from its own progress callback: cancelling the task stops URLSession and keeps the bytes
        // written so far, exactly what an interrupted download leaves behind.
        let tripped = Atomic<Bool>(false)
        let handle = Mutex<Task<DownloadOutcome, any Error>?>(nil)
        let task = Task { [base] in
            try await base.download(asset: asset, version: version, to: file) { onDisk, expected in
                progress?(onDisk, expected)
                guard let expected, expected > 0, onDisk * 100 >= expected * Int64(pct) else { return }
                if !tripped.exchange(true, ordering: .relaxed) { handle.withLock { $0?.cancel() } }
            }
        }
        handle.withLock { $0 = task }
        if tripped.load(ordering: .relaxed) { task.cancel() }
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        if tripped.load(ordering: .relaxed) {
            Self.aborted.store(true, ordering: .relaxed)
            throw URLError(.networkConnectionLost)
        }
        return try result.get()
    }

    /// Tests reset the once-per-process latch.
    static func resetForTesting() { aborted.store(false, ordering: .relaxed) }
}
