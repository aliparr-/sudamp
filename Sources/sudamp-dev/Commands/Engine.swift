// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation
import Resolver
import Synchronization

/// `sudamp-dev engine install|status [--profile P] [--json]` (PLAN M0 R1, DESIGN §6.1).
///
/// install: honours the bundled feed's `engine.pin` and `engine.block` (or `--feed <path>`'s); `[--pin <ver>
/// --pin-sha256 <hex>] [--block <ver>[,<ver>…]]` override them; `--channel nightly` installs from
/// yt-dlp-nightly-builds (the M6 nightly-escalation source). status: re-hashes `tree.json`, scans for quarantine attributes
/// and times three warm `--version` runs.
enum EngineCommand {
    static let usage = """
    usage: sudamp-dev engine install [--profile P] [--json] [--feed <path>] [--pin <ver> --pin-sha256 <hex>]
                                     [--block v1,v2] [--channel stable|nightly]
           sudamp-dev engine status  [--profile P] [--json]
    """

    static func run(_ args: Args) async throws -> Int32 {
        let paths = Paths.resolve()
        let layout = EngineLayout(paths: paths)
        let repo = args.string("channel") == "nightly" ? GitHubReleases.nightlyRepo : GitHubReleases.stableRepo
        let store = EngineStore(layout: layout, releases: GitHubReleases(repo: repo),
                                metrics: MetricsLog(url: paths.metricsFile))
        switch args.positionals.first {
        case "install": return try await install(args, store: store)
        case "status": return try await status(args, store: store, layout: layout)
        default:
            stderr(usage)
            return 64
        }
    }

    /// `--pin`/`--block` when given; otherwise the bundled feed's `engine.pin` and `engine.block` (DESIGN §7.2: "Its
    /// `pin` and `block` apply from M1, even to the first engine install"), `--feed <path>` choosing another feed.
    private static func config(_ args: Args) -> EngineInstallPolicy {
        if args.string("pin") == nil, args.string("block") == nil {
            do {
                let feed = try DevFeed.load(args)
                let policy = EngineInstallPolicy(feed: feed.document.engine)
                stderr("engine: policy from \(feed.url.path): pin \(policy.pin?.version ?? "none"), block \(policy.block)")
                return policy
            } catch {
                stderr("engine: no feed (\(error)); installing upstream's latest")
                return EngineInstallPolicy()
            }
        }
        var pin: EngineInstallPolicy.Pin?
        if let v = args.string("pin") { pin = .init(version: v, sha256: args.string("pin-sha256") ?? "") }
        let block = (args.string("block") ?? "").split(separator: ",").map(String.init)
        return EngineInstallPolicy(pin: pin, block: block)
    }

    private static func install(_ args: Args, store: EngineStore) async throws -> Int32 {
        let json = args.flag("json")
        let lastDecile = Mutex(-1)
        do {
            let report = try await store.install(config: config(args)) { phase in
                switch phase {
                case let .downloading(onDisk, expected):
                    guard let expected, expected > 0 else { return }
                    let decile = Int(onDisk * 10 / expected)
                    if lastDecile.withLock({ d in defer { d = decile }; return d != decile }) {
                        stderr("engine: downloading \(decile * 10)% (\(onDisk / 1_000_000) of \(expected / 1_000_000) MB)")
                    }
                default:
                    stderr("engine: \(phase)")
                }
            }
            if json {
                printJSON(report, pretty: true)
            } else {
                print("""
                installed yt-dlp \(report.version) (\(report.reason.rawValue))\(report.alreadyInstalled ? " — already current" : "")
                  path      \(report.path)
                  sha256    \(report.zipSHA256) (verified against \(report.verifiedAgainst); upstream match: \(report.upstreamMatch))
                  files     \(report.files), \(report.treeBytes / 1_000_000) MB; quarantined: \(report.quarantined.count)
                  --version cold \(Int(report.smoke?.coldMs ?? 0)) ms, warm median \(Int(report.smoke?.warmMedianMs ?? 0)) ms
                  previous  \(report.previous ?? "none")
                """)
            }
            return 0
        } catch {
            if json { printJSON(["error": "\(error)"]) }
            stderr("engine install failed: \(error)")
            return 1
        }
    }

    struct Status: Encodable {
        var installed: Bool
        var version: String?
        var path: String?
        var previous: String?
        var installedAt: Double?
        var zipSHA256: String?
        var tree: TreeVerification?
        var treeError: String?
        var quarantined: [String]?
        var versionWarmMs: [Double]?
        var versionMedianMs: Double?
        var versionOutput: String?
        /// `updates.json` (M6): last checks, the last switch, rejected builds, the `_update_spec` identifier.
        var updates: EngineUpdateState?
    }

    private static func status(_ args: Args, store: EngineStore, layout: EngineLayout) async throws -> Int32 {
        guard let current = await store.current() else {
            if args.flag("json") { printJSON(Status(installed: false), pretty: true) } else { print("no engine installed") }
            return 1
        }
        var s = Status(installed: true, version: current.version, path: current.directoryURL(in: layout).path,
                       previous: current.previous, installedAt: current.installedAt, zipSHA256: current.zipSHA256)
        do { s.tree = try await store.verifyTree() } catch { s.treeError = "\(error)" }
        s.updates = await store.updateState()
        s.quarantined = Quarantine.scan(root: current.directoryURL(in: layout))
        // The first of these may be cold after a reboot; the smoke test's "warm" is runs 2–4.
        if let smoke = try? await store.smokeTest(executable: current.executableURL(in: layout),
                                                  expectedVersion: current.version, warmRuns: 3) {
            s.versionWarmMs = smoke.warmMs
            s.versionMedianMs = smoke.warmMedianMs
            s.versionOutput = smoke.output
        }
        if args.flag("json") {
            printJSON(s, pretty: true)
        } else {
            print("""
            yt-dlp \(current.version) at \(s.path ?? "")
              tree      \(s.tree.map { $0.ok ? "ok (\($0.checked) files, \(Int($0.elapsedMs)) ms)" : "MISMATCH \($0)" } ?? s.treeError ?? "?")
              quarantine \(s.quarantined?.isEmpty == true ? "none" : "\(s.quarantined ?? [])")
              --version warm \(s.versionWarmMs?.map { String(Int($0)) }.joined(separator: "/") ?? "failed") ms
              previous  \(current.previous ?? "none")
              updates   last check \(s.updates?.lastCheckAt.map { "\($0)" } ?? "never"), rejected \(s.updates?.rejectedVersions(now: Date()) ?? [])
            """)
        }
        return (s.tree?.ok ?? false) && (s.quarantined?.isEmpty ?? false) ? 0 : 1
    }
}
