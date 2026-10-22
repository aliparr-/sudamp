// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation
import os

/// `current.json`: the active engine, switched atomically after a successful install (DESIGN §6.1 step 6).
public struct EngineInstallation: Sendable, Codable, Equatable {
    public var version: String
    /// Directory name under `engines/yt-dlp/`.
    public var directory: String
    public var executable: String
    /// SHA-256 of the verified `yt-dlp_macos.zip`.
    public var zipSHA256: String
    public var installedAt: Double
    /// The build kept for rollback.
    public var previous: String?
    /// Its zip's SHA-256 (M6; absent in files written before).
    public var previousZipSHA256: String?

    public func executableURL(in layout: EngineLayout) -> URL {
        layout.enginesRoot.appending(path: directory).appending(path: executable)
    }

    public func directoryURL(in layout: EngineLayout) -> URL {
        layout.enginesRoot.appending(path: directory, directoryHint: .isDirectory)
    }
}

/// `--version` smoke test (DESIGN §6.1 step 5). The cold run pays for first-launch work (dyld, code signature
/// checks, page cache); warm runs are what every resolve pays.
public struct EngineSmokeTest: Sendable, Codable, Equatable {
    public var output: String
    public var coldMs: Double
    public var warmMs: [Double]

    public var warmMedianMs: Double {
        let s = warmMs.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }
}

/// A verified, unpacked and smoke-tested build that `current.json` doesn't point at yet (an update candidate
/// waiting for its canary, or a first install about to switch).
public struct StagedEngine: Sendable {
    public var version: String
    /// `engines/yt-dlp/<ver>.partial/unpacked`.
    public var directory: URL
    public var executable: URL
    public var zipSHA256: String
    public var report: EngineInstallReport
}

/// `engines/yt-dlp/updates.json`: when updates last ran and what they rejected (DESIGN §6.1 "Updates").
public struct EngineUpdateState: Sendable, Codable, Equatable {
    /// The last completed check (any trigger): the launch and daily checks wait 24 h from it.
    public var lastCheckAt: Date?
    /// The last failure-triggered check: they run at most every 2 h.
    public var lastFailureCheckAt: Date?
    /// The last switch to a new build (post-switch engine failures roll back within 24 h of it).
    public var lastSwitchAt: Date?
    public var switchedFrom: String?
    public var switchedTo: String?
    /// Versions this machine won't choose again until the date (a failed canary 24 h, a rollback 7 d).
    public var rejected: [String: Date] = [:]
    /// The running build's `_update_spec` identifier, from the launch warm-up's `-v` header.
    public var identifier: String?

    public init() {}

    public func rejectedVersions(now: Date) -> [String] { rejected.filter { $0.value > now }.map(\.key).sorted() }
}

/// What the launch warm-up measured.
public struct EngineWarmUp: Sendable, Codable, Equatable {
    public var version: String
    public var versionMs: Double
    public var ok: Bool
    public var identifier: String?
    public var identifierMs: Double?
}

/// What `install` did, for `sudamp-dev engine install --json` and the R1 gate.
public struct EngineInstallReport: Sendable, Codable {
    public struct UpdateSpecInfo: Sendable, Codable {
        public var present: Bool
        public var identifier: String
        public var lockedTag: String?
    }

    public struct DownloadInfo: Sendable, Codable {
        public var bytes: Int64
        public var resumedFrom: Int64
        public var sentRange: Bool
        public var httpStatus: Int
        public var ms: Double
    }

    public var version: String
    public var reason: EngineChoice.Reason
    public var origin: String
    public var alreadyInstalled = false
    public var rejectedConfig: [String] = []
    public var updateSpec: UpdateSpecInfo?
    /// The hash the zip had to match, and where it came from (`pin` or `upstream` SHA2-256SUMS).
    public var expectedSHA256 = ""
    public var verifiedAgainst = ""
    public var zipSHA256 = ""
    public var upstreamSHA256: String?
    public var upstreamMatch = false
    public var freeBytes: Int64?
    public var download: DownloadInfo?
    public var unpackMs = 0.0
    public var quarantined: [String] = []
    public var files = 0
    public var treeBytes: Int64 = 0
    public var treeMs = 0.0
    public var smoke: EngineSmokeTest?
    public var path = ""
    public var previous: String?
    public var totalMs = 0.0
}

/// Install progress for status lines (`PREPARING STREAM ENGINE 63%`).
public enum EngineInstallPhase: Sendable, Equatable {
    case choosing
    case downloading(onDisk: Int64, expected: Int64?)
    case verifying
    case unpacking
    case recording
    case testing
    case switching
}

public enum EngineStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case insufficientSpace(available: Int64, required: Int64)
    case noAllowedVersion
    case unreachable(String)
    case checksumMissing(String)
    case checksumMismatch(expected: String, actual: String)
    case unpackFailed(String)
    case badLayout(String)
    case quarantined([String])
    case smokeTestFailed(String)
    case notInstalled
    /// No verified previous build to roll back to.
    case noPrevious

    public var description: String {
        switch self {
        case let .insufficientSpace(a, r): "not enough free space: \(a) bytes available, \(r) needed"
        case .noAllowedVersion: "no release satisfies pin/block/_update_spec"
        case let .unreachable(m): "release host unreachable: \(m)"
        case let .checksumMissing(f): "SHA2-256SUMS has no entry for \(f)"
        case let .checksumMismatch(e, a): "SHA-256 mismatch: expected \(e), got \(a)"
        case let .unpackFailed(m): "unpack failed: \(m)"
        case let .badLayout(m): "unexpected engine layout: \(m)"
        case let .quarantined(p): "quarantine attribute found on \(p.count) paths, e.g. \(p.prefix(3))"
        case let .smokeTestFailed(m): "--version smoke test failed: \(m)"
        case .notInstalled: "no engine installed"
        case .noPrevious: "no verified previous build to roll back to"
        }
    }
}

/// Downloads, verifies, records and switches yt-dlp onedir builds (DESIGN §6.1). One instance per profile;
/// the profile's instance lock keeps two processes from installing at once.
public actor EngineStore {
    public static let asset = "yt-dlp_macos.zip"
    public static let checksumsAsset = "SHA2-256SUMS"
    public static let executableName = "yt-dlp_macos"
    /// 54 MB zip + 123 MB unpacked, rounded up [measured].
    public static let requiredFreeBytes: Int64 = 180_000_000

    public let layout: EngineLayout
    private let releases: any EngineReleaseSource
    private let freeSpace: @Sendable (URL) -> Int64?
    private let time: any TimeSource
    private let metrics: MetricsLog?
    private let identifier: String
    private let log = Log.logger("engine")

    public init(layout: EngineLayout, releases: any EngineReleaseSource = GitHubReleases(),
                freeSpace: @escaping @Sendable (URL) -> Int64? = { DiskSpace.available(at: $0) },
                time: any TimeSource = SystemTimeSource(), metrics: MetricsLog? = nil,
                identifier: String = UpdateSpec.synthesizedIdentifier()) {
        self.layout = layout
        self.releases = releases
        self.freeSpace = freeSpace
        self.time = time
        self.metrics = metrics
        self.identifier = identifier
    }

    // MARK: Reading state

    /// The active engine from `current.json`, if any.
    public func current() -> EngineInstallation? {
        guard let data = try? Data(contentsOf: layout.currentFile) else { return nil }
        return try? JSONDecoder().decode(EngineInstallation.self, from: data)
    }

    /// Re-hashes an installed tree against its `tree.json` (the current engine by default).
    public func verifyTree(version: String? = nil) throws -> TreeVerification {
        guard let version = version ?? current()?.version else { throw EngineStoreError.notInstalled }
        let dir = layout.versionDirectory(version)
        let data = try Data(contentsOf: dir.appending(path: EngineTree.fileName))
        return try JSONDecoder().decode(EngineTree.self, from: data).verify(root: dir)
    }

    // MARK: Choosing

    /// Applies pin, block and `_update_spec` (see `EngineChooser`, `UpdateSpec`), fetching only what it needs.
    public func choose(config: EngineInstallPolicy) async throws -> (EngineChoice, EngineInstallReport.UpdateSpecInfo) {
        let config = config.validated().config
        do {
            let specText = try await releases.updateSpec()
            let locked = specText.flatMap { UpdateSpec(parsing: $0).lockedTag(identifier: identifier, repo: releases.name) }
            let info = EngineInstallReport.UpdateSpecInfo(present: specText != nil, identifier: identifier,
                                                          lockedTag: locked)
            if let choice = EngineChooser.choose(config: config, latest: nil, lockedTag: locked), choice.reason == .pin {
                return (choice, info)
            }
            let latest = try await releases.latestVersion()
            if let choice = EngineChooser.choose(config: config, latest: latest, lockedTag: locked),
               choice.version == latest {
                return (choice, info)
            }
            let recent = try await releases.recentVersions()
            guard let choice = EngineChooser.choose(config: config, latest: latest, recent: recent, lockedTag: locked)
            else { throw EngineStoreError.noAllowedVersion }
            return (choice, info)
        } catch let error as URLError {
            throw EngineStoreError.unreachable(error.localizedDescription)
        }
    }

    // MARK: Installing

    /// Chooses, downloads (resuming a `.partial`), verifies, unpacks, records `tree.json`, smoke-tests and
    /// switches `current.json`, keeping the previous build. Returns early when the chosen version is already
    /// current and its tree verifies.
    public func install(config: EngineInstallPolicy,
                        progress: (@Sendable (EngineInstallPhase) -> Void)? = nil) async throws -> EngineInstallReport {
        let started = ContinuousClock.now
        try layout.createDirectories()
        progress?(.choosing)
        let (choice, specInfo) = try await choose(config: config)
        metrics?.record("engine.choose", ["version": choice.version, "reason": choice.reason.rawValue])
        log.info("engine choose \(choice.version, privacy: .public) (\(choice.reason.rawValue, privacy: .public))")

        if let cur = current(), cur.version == choice.version,
           let check = try? verifyTree(version: cur.version), check.ok {
            var report = EngineInstallReport(version: choice.version, reason: choice.reason, origin: releases.name)
            report.rejectedConfig = config.validated().rejected
            report.updateSpec = specInfo
            report.alreadyInstalled = true
            report.zipSHA256 = cur.zipSHA256
            report.path = cur.directoryURL(in: layout).path
            report.previous = cur.previous
            report.files = check.checked
            report.totalMs = (ContinuousClock.now - started).milliseconds
            return report
        }

        let staged = try await stage(choice: choice, from: releases, progress: progress)
        var report = staged.report
        report.rejectedConfig = config.validated().rejected
        report.updateSpec = specInfo
        progress?(.switching)
        let installation = try activate(staged)
        report.path = installation.directoryURL(in: layout).path
        report.previous = installation.previous
        report.totalMs = (ContinuousClock.now - started).milliseconds
        metrics?.record("engine.install", ["version": choice.version, "ms": report.totalMs.rounded()])
        log.info("engine installed \(choice.version, privacy: .public) in \(report.totalMs, format: .fixed(precision: 0)) ms")
        return report
    }

    /// Downloads (resuming a `.partial`), verifies, unpacks, records `tree.json` and smoke-tests `choice` from
    /// `source`, without switching to it (DESIGN §6.1 steps 2–5; an update's canary runs on the staged build).
    public func stage(choice: EngineChoice, from source: (any EngineReleaseSource)? = nil,
                      progress: (@Sendable (EngineInstallPhase) -> Void)? = nil) async throws -> StagedEngine {
        let source = source ?? releases
        let started = ContinuousClock.now
        try layout.createDirectories()
        var report = EngineInstallReport(version: choice.version, reason: choice.reason, origin: source.name)
        let partial = layout.partialDirectory(choice.version)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let zip = partial.appending(path: Self.asset)
        let have = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value ?? 0
        let required = max(0, Self.requiredFreeBytes - have)
        let free = freeSpace(layout.enginesRoot)
        report.freeBytes = free
        if let free, free < required { throw EngineStoreError.insufficientSpace(available: free, required: required) }

        // Checksums first: tiny, and they tell us what the 54 MB must hash to.
        let sums: SHA256Sums
        do {
            sums = SHA256Sums(parsing: try await source.checksums(version: choice.version))
        } catch let error as URLError {
            throw EngineStoreError.unreachable(error.localizedDescription)
        }
        try Data(sums.entries.map { "\($0.value)  \($0.key)\n" }.sorted().joined().utf8)
            .write(to: partial.appending(path: Self.checksumsAsset))
        report.upstreamSHA256 = sums[Self.asset]
        if let pinned = choice.expectedSHA256 {
            report.expectedSHA256 = pinned
            report.verifiedAgainst = "pin"
        } else {
            guard let upstream = sums[Self.asset] else { throw EngineStoreError.checksumMissing(Self.asset) }
            report.expectedSHA256 = upstream
            report.verifiedAgainst = "upstream"
        }

        let dlStart = ContinuousClock.now
        let outcome: DownloadOutcome
        do {
            outcome = try await source.download(asset: Self.asset, version: choice.version, to: zip) { onDisk, expected in
                progress?(.downloading(onDisk: onDisk, expected: expected))
            }
        } catch let error as URLError {
            throw EngineStoreError.unreachable(error.localizedDescription)
        }
        report.download = .init(bytes: outcome.bytesOnDisk, resumedFrom: outcome.resumedFrom,
                                sentRange: outcome.sentRange, httpStatus: outcome.httpStatus,
                                ms: (ContinuousClock.now - dlStart).milliseconds)
        if outcome.sentRange {
            log.info("engine download resumed with Range at \(outcome.resumedFrom) (HTTP \(outcome.httpStatus))")
            metrics?.record("engine.download.resume", ["from": outcome.resumedFrom, "status": outcome.httpStatus])
        }

        progress?(.verifying)
        let actual = try FileDigest.sha256(of: zip)
        report.zipSHA256 = actual
        report.upstreamMatch = actual == sums[Self.asset]
        guard actual == report.expectedSHA256 else {
            try? FileManager.default.removeItem(at: zip)  // never resume onto bad bytes
            throw EngineStoreError.checksumMismatch(expected: report.expectedSHA256, actual: actual)
        }

        progress?(.unpacking)
        let staging = partial.appending(path: "unpacked", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: staging)
        let unpackStart = ContinuousClock.now
        let ditto = try await Subprocess.run(SubprocessSpec(
            executable: URL(filePath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", "--noqtn", zip.path, staging.path],
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], timeout: .seconds(300)))
        guard ditto.succeeded else {
            throw EngineStoreError.unpackFailed("\(ditto.termination): \(ditto.stderrString.prefix(500))")
        }
        report.unpackMs = (ContinuousClock.now - unpackStart).milliseconds
        let exe = staging.appending(path: Self.executableName)
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw EngineStoreError.badLayout("no executable \(Self.executableName) at the zip root")
        }
        report.quarantined = Quarantine.scan(root: staging)
        guard report.quarantined.isEmpty else { throw EngineStoreError.quarantined(report.quarantined) }

        progress?(.recording)
        let treeStart = ContinuousClock.now
        let tree = try EngineTree.scan(root: staging, version: choice.version, now: time.now)
        try Self.encoder.encode(tree).write(to: staging.appending(path: EngineTree.fileName), options: .atomic)
        report.files = tree.fileCount
        report.treeBytes = tree.totalBytes
        report.treeMs = (ContinuousClock.now - treeStart).milliseconds

        progress?(.testing)
        report.smoke = try await smokeTest(executable: exe, expectedVersion: choice.version)
        report.totalMs = (ContinuousClock.now - started).milliseconds
        return StagedEngine(version: choice.version, directory: staging, executable: exe, zipSHA256: actual,
                            report: report)
    }

    /// Moves a staged build into `engines/yt-dlp/<ver>/` and switches `current.json` atomically, keeping the
    /// build it replaces as `previous` (DESIGN §6.1 step 6); everything else is pruned.
    @discardableResult
    public func activate(_ staged: StagedEngine) throws -> EngineInstallation {
        let final = layout.versionDirectory(staged.version)
        if FileManager.default.fileExists(atPath: final.path) {
            let aside = layout.enginesRoot.appending(path: ".\(staged.version).replaced-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: final, to: aside)
            try? FileManager.default.removeItem(at: aside)
        }
        try FileManager.default.moveItem(at: staged.directory, to: final)
        let old = current()
        let previous = old.map { $0.version == staged.version ? $0.previous : $0.version } ?? nil
        let previousZip = old.map { $0.version == staged.version ? $0.previousZipSHA256 : $0.zipSHA256 } ?? nil
        var installation = EngineInstallation(version: staged.version, directory: staged.version,
                                              executable: Self.executableName, zipSHA256: staged.zipSHA256,
                                              installedAt: time.now.timeIntervalSince1970, previous: previous)
        installation.previousZipSHA256 = previousZip
        try writeCurrent(installation)
        try? FileManager.default.removeItem(at: layout.partialDirectory(staged.version))
        prune(keeping: [staged.version, previous].compactMap { $0 })
        return installation
    }

    /// Drops a staged build that failed its canary (current.json is untouched).
    public func discard(_ staged: StagedEngine) {
        try? FileManager.default.removeItem(at: layout.partialDirectory(staged.version))
    }

    /// Switches back to the kept previous build (DESIGN §6.1 "keeping the previous build"; M6 rollback) when its
    /// tree verifies. The build rolled away from is pruned, so a rollback never ping-pongs.
    @discardableResult
    public func rollback() throws -> EngineInstallation {
        guard let cur = current(), let previous = cur.previous else { throw EngineStoreError.noPrevious }
        guard let check = try? verifyTree(version: previous), check.ok else { throw EngineStoreError.noPrevious }
        let installation = EngineInstallation(version: previous, directory: previous, executable: Self.executableName,
                                              zipSHA256: cur.previousZipSHA256 ?? "",
                                              installedAt: time.now.timeIntervalSince1970, previous: nil)
        try writeCurrent(installation)
        prune(keeping: [previous])
        metrics?.record("engine.rollback", ["from": cur.version, "to": previous])
        log.notice("engine rolled back \(cur.version, privacy: .public) → \(previous, privacy: .public)")
        return installation
    }

    private func writeCurrent(_ installation: EngineInstallation) throws {
        try Self.encoder.encode(installation).write(to: layout.currentFile, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    // MARK: Update bookkeeping (M6)

    /// `engines/yt-dlp/updates.json`.
    public func updateState() -> EngineUpdateState {
        guard let data = try? Data(contentsOf: layout.updatesFile) else { return EngineUpdateState() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode(EngineUpdateState.self, from: data)) ?? EngineUpdateState()
    }

    public func saveUpdateState(_ state: EngineUpdateState) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: layout.enginesRoot, withIntermediateDirectories: true)
            try e.encode(state).write(to: layout.updatesFile, options: .atomic)
        } catch {
            log.error("cannot save updates.json: \(error, privacy: .public)")
        }
    }

    /// The launch warm-up (DESIGN §3 "yt-dlp is warmed with `--version`", 1.6 s cold, 0.15 s warm), plus one `-v`
    /// run without a URL (no network) that prints the build's real `_update_spec` identifier.
    public func warmUp() async -> EngineWarmUp? {
        guard let cur = current() else { return nil }
        let exe = cur.executableURL(in: layout)
        try? layout.createDirectories()
        func run(_ args: [String]) async -> SubprocessResult? {
            try? await Subprocess.run(SubprocessSpec(executable: exe, arguments: args, environment: layout.environment,
                                                     workingDirectory: layout.home, timeout: .seconds(30)))
        }
        guard let version = await run(["--version"]) else { return nil }
        var warm = EngineWarmUp(version: cur.version, versionMs: version.elapsed.milliseconds.rounded(),
                                ok: version.succeeded
                                    && version.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == cur.version)
        if let verbose = await run(["--ignore-config", "--no-plugin-dirs", "--no-update", "--no-js-runtimes", "-v"]) {
            warm.identifierMs = verbose.elapsed.milliseconds.rounded()
            warm.identifier = UpdateSpec.identifier(fromVerbose: verbose.stderrString)
        }
        if let id = warm.identifier {
            var state = updateState()
            if state.identifier != id {
                state.identifier = id
                saveUpdateState(state)
            }
        }
        metrics?.record("engine.warmup", ["version": cur.version, "ms": warm.versionMs, "ok": warm.ok,
                                          "identifier": warm.identifier ?? ""])
        return warm
    }

    /// Runs `--version` once cold and `warmRuns` times warm in the engine's scrubbed environment.
    public func smokeTest(executable: URL, expectedVersion: String, warmRuns: Int = 3) async throws -> EngineSmokeTest {
        try layout.createDirectories()
        func run(timeout: Duration) async throws -> (String, Double) {
            let r = try await Subprocess.run(SubprocessSpec(executable: executable, arguments: ["--version"],
                                                            environment: layout.environment,
                                                            workingDirectory: layout.home, timeout: timeout))
            guard r.succeeded else {
                throw EngineStoreError.smokeTestFailed("\(r.termination)\(r.timedOut ? " (timeout)" : ""): "
                    + r.stderrString.prefix(300))
            }
            return (r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), r.elapsed.milliseconds)
        }
        let (output, cold) = try await run(timeout: .seconds(60))
        guard output == expectedVersion else {
            throw EngineStoreError.smokeTestFailed("printed \(output.debugDescription), expected \(expectedVersion)")
        }
        var warm: [Double] = []
        for _ in 0..<warmRuns { warm.append(try await run(timeout: .seconds(10)).1) }
        return EngineSmokeTest(output: output, coldMs: cold, warmMs: warm)
    }

    /// Removes version directories and stale downloads other than `keeping`.
    private func prune(keeping: [String]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: layout.enginesRoot.path) else { return }
        for name in names {
            let base = name.hasSuffix(".partial") ? String(name.dropLast(".partial".count)) : name
            guard EngineVersion(base) != nil, !(keeping.contains(name)) else { continue }
            try? fm.removeItem(at: layout.enginesRoot.appending(path: name))
        }
    }
}
