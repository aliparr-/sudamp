// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import Synchronization
import Testing
@testable import Resolver

/// A canary that passes or fails per version (engine-class failures by default) and records what it ran.
final class FakeCanary: EngineCanaryRunning {
    let failing: Mutex<[String: String]>
    let runs = Mutex<[String]>([])

    /// `failing`: version → failure class (`engine`, `transient`, `botCheck`).
    init(failing: [String: String] = [:]) { self.failing = Mutex(failing) }

    func run(engine: URL, version: String, items: [StreamRef], settings: ResolverSettings) async -> CanaryResult {
        runs.withLock { $0.append(version) }
        // The candidate really is runnable: its --version answers.
        let ok = FileManager.default.isExecutableFile(atPath: engine.path)
        if let cls = failing.withLock({ $0[version] }) {
            return CanaryResult(version: version, checks: [
                CanaryCheck(streamId: "yt:x", source: "youtube", step: "resolve", ok: false, failureClass: cls, reason: "fake"),
            ])
        }
        return CanaryResult(version: version, checks: [CanaryCheck(streamId: "yt:x", source: "youtube", step: "resolve", ok: ok)])
    }
}

@Suite struct EngineUpdaterTests {
    let profile = FileManager.default.temporaryDirectory.appending(path: "engine-updater-\(UUID().uuidString)")
    var layout: EngineLayout { EngineLayout(paths: .profile(profile)) }
    let clock = FakeTimeSource(Date(timeIntervalSince1970: 1_800_000_000))

    func request(_ trigger: EngineUpdateTrigger, block: [String] = [], nightly: Bool = true) -> EngineUpdateRequest {
        EngineUpdateRequest(trigger: trigger, policy: EngineInstallPolicy(block: block), nightlyEscalation: nightly,
                            canary: [ref(.youtube, 1), ref(.soundcloud, 1)])
    }

    /// A store with `installed` current (installed from its own fake release).
    func store(installed: String) async throws -> EngineStore {
        let first = try FakeReleases(latest: installed, versions: [installed])
        let s = EngineStore(layout: layout, releases: first, time: clock)
        _ = try await s.install(config: EngineInstallPolicy())
        return s
    }

    func currentJSON() throws -> Data { try Data(contentsOf: layout.currentFile) }

    @Test func dueRulesFollowDesign() {
        var state = EngineUpdateState()
        let now = clock.now
        #expect(EngineUpdater.isDue(.launch, state: state, now: now), "never checked")
        state.lastCheckAt = now.addingTimeInterval(-23 * 3600)
        #expect(!EngineUpdater.isDue(.launch, state: state, now: now))
        #expect(!EngineUpdater.isDue(.daily, state: state, now: now))
        #expect(EngineUpdater.isDue(.launch, state: state, now: now, forced: true), "engine:bad-update")
        state.lastCheckAt = now.addingTimeInterval(-24 * 3600)
        #expect(EngineUpdater.isDue(.launch, state: state, now: now))
        #expect(EngineUpdater.isDue(.afterPinInstall, state: state, now: now))
        state.lastFailureCheckAt = now.addingTimeInterval(-7199)
        #expect(!EngineUpdater.isDue(.engineFailures, state: state, now: now))
        state.lastFailureCheckAt = now.addingTimeInterval(-7200)
        #expect(EngineUpdater.isDue(.engineFailures, state: state, now: now))
    }

    @Test func aNewerReleasePassingTheCanarySwitchesAndKeepsThePrevious() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let s = try await store(installed: "2026.08.19")
        let stable = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21", "2026.08.19"])
        let nightly = try FakeReleases(latest: "2026.10.21.233146", versions: ["2026.10.21.233146"],
                                       name: GitHubReleases.nightlyRepo)
        let canary = FakeCanary()
        let metrics = MetricsLog(url: profile.appending(path: "Logs/metrics.jsonl"), time: clock)
        let u = EngineUpdater(store: s, stable: stable, nightly: nightly, canary: canary, time: clock, metrics: metrics)
        let outcome = await u.check(request(.launch))
        #expect(outcome.result == .switched && outcome.current == "2026.10.21" && outcome.channel == "stable")
        #expect(canary.runs.withLock { $0 } == ["2026.10.21"])
        let cur = try #require(await s.current())
        #expect(cur.version == "2026.10.21" && cur.previous == "2026.08.19")
        #expect(try await s.verifyTree().ok)
        let state = await s.updateState()
        #expect(state.lastCheckAt == clock.now && state.switchedTo == "2026.10.21")
        // The launch check is rate-limited now.
        #expect(await u.check(request(.launch)).result == .notDue)
        let log = try String(contentsOf: metrics.url, encoding: .utf8)
        #expect(log.contains("\"engine.update.check\"") && log.contains("\"engine.update.switch\""))
    }

    @Test func aFailedCanaryLeavesCurrentJSONUntouchedAndRejectsTheBuild() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let s = try await store(installed: "2026.08.19")
        let before = try currentJSON()
        let stable = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"])
        let canary = FakeCanary(failing: ["2026.10.21": "engine"])
        let u = EngineUpdater(store: s, stable: stable, nightly: stable, canary: canary, time: clock)
        let outcome = await u.check(request(.launch, nightly: false))
        #expect(outcome.result == .canaryFailed)
        #expect(try currentJSON() == before, "current.json is unchanged")
        #expect(await s.current()?.version == "2026.08.19")
        #expect(!FileManager.default.fileExists(atPath: layout.partialDirectory("2026.10.21").path), "the candidate is discarded")
        #expect(await s.updateState().rejectedVersions(now: clock.now) == ["2026.10.21"])
        // Rejected for 24 h: the next daily check is up to date without downloading it again.
        clock.advance(by: 24 * 3600 - 60)
        var state = await s.updateState()
        state.lastCheckAt = nil
        await s.saveUpdateState(state)
        let again = await u.check(request(.daily, nightly: false))
        #expect(again.result == .upToDate)
        #expect(stable.downloads.withLock { $0 } == ["2026.10.21"])
    }

    @Test func stableFailingWithEngineErrorsEscalatesToNightly() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let s = try await store(installed: "2026.08.19")
        let stable = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"])
        let nightly = try FakeReleases(latest: "2026.10.21.233146", versions: ["2026.10.21.233146"],
                                       name: GitHubReleases.nightlyRepo)
        let canary = FakeCanary(failing: ["2026.10.21": "engine"])
        let metrics = MetricsLog(url: profile.appending(path: "Logs/metrics.jsonl"), time: clock)
        let u = EngineUpdater(store: s, stable: stable, nightly: nightly, canary: canary, time: clock, metrics: metrics)
        let outcome = await u.check(request(.launch))
        #expect(outcome.result == .switched && outcome.channel == "nightly" && outcome.current == "2026.10.21.233146")
        #expect(canary.runs.withLock { $0 } == ["2026.10.21", "2026.10.21.233146"])
        #expect(await s.current()?.previous == "2026.08.19")
        #expect(try String(contentsOf: metrics.url, encoding: .utf8).contains("engine.nightly.escalate"))
    }

    @Test func anInconclusiveCanaryNeitherRejectsNorEscalates() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let s = try await store(installed: "2026.08.19")
        let stable = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"])
        let nightly = try FakeReleases(latest: "2026.10.21.233146", versions: ["2026.10.21.233146"],
                                       name: GitHubReleases.nightlyRepo)
        let canary = FakeCanary(failing: ["2026.10.21": "transient"])
        let u = EngineUpdater(store: s, stable: stable, nightly: nightly, canary: canary, time: clock)
        let outcome = await u.check(request(.launch))
        #expect(outcome.result == .canaryFailed)
        #expect(await s.updateState().rejectedVersions(now: clock.now).isEmpty)
        #expect(nightly.downloads.withLock { $0 }.isEmpty)
    }

    @Test func engineFailuresOnTheNewestBuildCanaryItThenTryNightly() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let s = try await store(installed: "2026.10.21")
        let stable = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"])
        let nightly = try FakeReleases(latest: "2026.10.21.233146", versions: ["2026.10.21.233146"],
                                       name: GitHubReleases.nightlyRepo)
        // Passing: up to date, nothing downloaded.
        let passing = FakeCanary()
        let u1 = EngineUpdater(store: s, stable: stable, nightly: nightly, canary: passing, time: clock)
        #expect(await u1.check(request(.engineFailures)).result == .upToDate)
        #expect(passing.runs.withLock { $0 } == ["2026.10.21"])
        // Within 2 h a second failure-triggered check doesn't run …
        #expect(await u1.check(request(.engineFailures)).result == .notDue)
        // … after 2 h, with the current build failing too, nightly takes over.
        clock.advance(by: 2 * 3600)
        let failing = FakeCanary(failing: ["2026.10.21": "engine"])
        let u2 = EngineUpdater(store: s, stable: stable, nightly: nightly, canary: failing, time: clock)
        let outcome = await u2.check(request(.engineFailures))
        #expect(outcome.result == .switched && outcome.current == "2026.10.21.233146")
        #expect(stable.downloads.withLock { $0 }.isEmpty, "the current stable build was never downloaded again")
    }

    @Test func blockAndUpdateSpecChooseTheCandidateAndPinNeverHoldsBack() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let s = try await store(installed: "2026.07.04")
        // Latest is blocked; the lock line for this machine caps at 2026.09.30; the pin (older) is ignored.
        let spec = "lockV2 yt-dlp/yt-dlp 2026.09.30 darwin_dir Python 3\\.14\n"
        let stable = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21", "2026.09.30", "2026.08.19"], spec: spec)
        var state = await s.updateState()
        state.identifier = "darwin_dir Python 3.14.7 (CPython arm64 64bit) - macOS-27.0.1-arm64-arm-64bit-Mach-O"
        await s.saveUpdateState(state)
        let u = EngineUpdater(store: s, stable: stable, nightly: stable, canary: FakeCanary(), time: clock)
        var r = request(.launch, block: ["2026.10.21"])
        r.policy.pin = .init(version: "2026.07.04", sha256: String(repeating: "a", count: 64))
        let outcome = await u.check(r)
        #expect(outcome.result == .switched && outcome.current == "2026.09.30", "\(outcome)")
    }

    @Test func aBlockedCurrentBuildIsLeftEvenForAnOlderOne() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let s = try await store(installed: "2026.10.21")
        let stable = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21", "2026.08.19"])
        let u = EngineUpdater(store: s, stable: stable, nightly: stable, canary: FakeCanary(), time: clock)
        let outcome = await u.check(request(.launch, block: ["2026.10.21"]))
        #expect(outcome.result == .switched && outcome.current == "2026.08.19")
    }

    @Test func postSwitchEngineFailuresRollBackWithin24Hours() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let s = try await store(installed: "2026.08.19")
        let stable = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21", "2026.08.19"])
        let metrics = MetricsLog(url: profile.appending(path: "Logs/metrics.jsonl"), time: clock)
        let u = EngineUpdater(store: s, stable: stable, nightly: stable, canary: FakeCanary(), time: clock, metrics: metrics)
        #expect(await u.check(request(.launch)).result == .switched)
        clock.advance(by: 3600)
        let rolled = try #require(await u.rollbackAfterEngineFailures())
        #expect(rolled.version == "2026.08.19" && rolled.previous == nil)
        #expect(await s.current()?.version == "2026.08.19")
        #expect(try await s.verifyTree().ok)
        #expect(!FileManager.default.fileExists(atPath: layout.versionDirectory("2026.10.21").path), "the bad build is pruned")
        #expect(await s.updateState().rejectedVersions(now: clock.now) == ["2026.10.21"])
        #expect(await u.rollbackAfterEngineFailures() == nil, "nothing left to roll back")
        // The rejected build isn't chosen again by the next check.
        clock.advance(by: 25 * 3600)
        #expect(await u.check(request(.daily)).result == .upToDate)
        #expect(try String(contentsOf: metrics.url, encoding: .utf8).contains("\"engine.rollback.postSwitch\""))
    }

    @Test func noRollbackLongAfterASwitch() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let s = try await store(installed: "2026.08.19")
        let stable = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"])
        let u = EngineUpdater(store: s, stable: stable, nightly: stable, canary: FakeCanary(), time: clock)
        #expect(await u.check(request(.launch)).result == .switched)
        clock.advance(by: 25 * 3600)
        #expect(await u.rollbackAfterEngineFailures() == nil)
        #expect(await s.current()?.version == "2026.10.21")
    }

    @Test func badUpdateFaultUsesNightlyAsCandidateAndKeepsCurrent() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let s = try await store(installed: "2026.10.21")
        var state = await s.updateState()
        state.lastCheckAt = clock.now
        await s.saveUpdateState(state)
        let before = try currentJSON()
        let stable = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"])
        let nightly = try FakeReleases(latest: "2026.10.21.233146", versions: ["2026.10.21.233146"],
                                       name: GitHubReleases.nightlyRepo)
        let canary = EngineCanary(layout: layout, qjs: nil, probe: nil, tokens: { _ in true }, badUpdate: true)
        let u = EngineUpdater(store: s, stable: stable, nightly: nightly, canary: canary, time: clock, badUpdate: true)
        #expect(await u.isDue(.launch), "the fault makes the launch check due")
        let outcome = await u.check(request(.launch))
        #expect(outcome.result == .canaryFailed && outcome.candidate == "2026.10.21.233146", "\(outcome)")
        #expect(outcome.canary.first?.engineFailure == true)
        #expect(try currentJSON() == before)
        #expect(await s.current()?.version == "2026.10.21")
    }

    @Test func rollbackWithoutAPreviousBuildThrows() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let s = try await store(installed: "2026.10.21")
        await #expect(throws: EngineStoreError.noPrevious) { try await s.rollback() }
    }

    // MARK: engine:corrupt and repair

    @Test func corruptionIsCaughtByTheRehashAndRepairedByReinstall() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let releases = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"])
        let s = EngineStore(layout: layout, releases: releases, time: clock)
        _ = try await s.install(config: EngineInstallPolicy())
        let metrics = MetricsLog(url: profile.appending(path: "Logs/metrics.jsonl"), time: clock)
        let service = EngineService(store: s, updater: EngineUpdater(store: s, stable: releases, nightly: releases,
                                                                     canary: FakeCanary(), time: clock),
                                    faults: EngineFaults(corrupt: true), metrics: metrics)
        let readiness = await service.readiness()
        guard case .corrupt(let reason) = readiness else {
            Issue.record("expected corrupt, got \(readiness)")
            return
        }
        #expect(reason.contains("_internal/lib.bin"))
        // The fault fires once: exactly one byte differs from the release's.
        let lib = try Data(contentsOf: layout.versionDirectory("2026.10.21").appending(path: "_internal/lib.bin"))
        _ = await service.readiness()
        let again = try Data(contentsOf: layout.versionDirectory("2026.10.21").appending(path: "_internal/lib.bin"))
        #expect(lib == again)
        #expect(zip(lib, Data("python stand-in".utf8)).filter { $0 != $1 }.count == 1)
        let repaired = await service.repair(policy: EngineInstallPolicy()) { _ in }
        #expect(repaired.isReady)
        #expect(try await s.verifyTree().ok)
        #expect(try String(contentsOf: metrics.url, encoding: .utf8).contains("\"engine.repair\""))
    }

    @Test func repairFallsBackToThePreviousBuildWhenTheReinstallFails() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        for v in ["2026.08.19", "2026.10.21"] {
            _ = try await EngineStore(layout: layout, releases: try FakeReleases(latest: v, versions: [v]), time: clock)
                .install(config: EngineInstallPolicy())
        }
        let unreachable = EngineFaults(unreachable: true).releases(try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"]))
        let s = EngineStore(layout: layout, releases: unreachable, time: clock)
        try Data("tampered".utf8).write(to: layout.versionDirectory("2026.10.21").appending(path: "_internal/lib.bin"))
        let service = EngineService(store: s, updater: EngineUpdater(store: s, stable: unreachable, nightly: unreachable,
                                                                     canary: FakeCanary(), time: clock))
        guard case .corrupt = await service.readiness() else { Issue.record("expected corrupt"); return }
        let repaired = await service.repair(policy: EngineInstallPolicy()) { _ in }
        #expect(repaired.version == "2026.08.19")
    }

    @Test func warmUpRecordsTheIdentifier() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        // A fake build whose -v prints the debug header.
        let releases = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"])
        let s = EngineStore(layout: layout, releases: releases, time: clock)
        _ = try await s.install(config: EngineInstallPolicy())
        let exe = try #require(await s.current()).executableURL(in: layout)
        try """
        #!/bin/sh
        case "$*" in
          *" -v") echo "[debug] yt-dlp version stable@2026.10.21 from yt-dlp/yt-dlp [abc] (darwin_dir)" >&2
                echo "[debug] Python 3.14.7 (CPython arm64 64bit) - macOS-27.0.1-arm64" >&2; exit 2;;
          *) echo 2026.10.21;;
        esac
        """.write(to: exe, atomically: true, encoding: .utf8)
        let warm = try #require(await s.warmUp())
        #expect(warm.ok && warm.version == "2026.10.21")
        #expect(warm.identifier == "darwin_dir Python 3.14.7 (CPython arm64 64bit) - macOS-27.0.1-arm64")
        #expect(await s.updateState().identifier == warm.identifier)
    }

    // MARK: The real canary over a scripted runner

    @Test func canaryResolvesBothItemsWithItsOwnCacheDirAndTokens() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let argv = Mutex<[[String]]>([])
        let tokens = Mutex(0)
        let yt = resolvedStream(.youtube, expires: cacheT0 + 3600)
        let sc = resolvedStream(.soundcloud, expires: cacheT0 + 3600, hls: true)
        @Sendable func json(_ s: ResolvedStream) -> Data {
            let o: [String: Any] = ["url": s.url.absoluteString, "protocol": s.protocol ?? "https", "format_id": "251",
                                    "http_headers": ["User-Agent": "UA"]]
            return try! JSONSerialization.data(withJSONObject: o)
        }
        let canary = EngineCanary(layout: layout, qjs: nil, probe: FakeProbe(.forbidden(status: 403)),
                                  tokens: { _ in tokens.withLock { $0 += 1 }; return true },
                                  runner: { spec in
                                      argv.withLock { $0.append(spec.arguments) }
                                      let isYT = spec.arguments.last?.contains("youtube") == true
                                      return SubprocessResult(termination: .exited(0), stdout: json(isYT ? yt : sc))
                                  })
        let result = await canary.run(engine: URL(filePath: "/nonexistent/yt-dlp_macos"), version: "2026.10.22",
                                      items: [ref(.youtube, 1), ref(.soundcloud, 1), ref(.radio, 1)],
                                      settings: .standard)
        #expect(!result.passed && result.engineFailure, "a 403 on the range GET is an engine failure")
        #expect(result.checks.map(\.step) == ["resolve", "probe", "resolve"])
        #expect(tokens.withLock { $0 } == 1, "one YouTube token")
        let dirs = argv.withLock { $0 }.compactMap { a in a.firstIndex(of: "--cache-dir").map { a[$0 + 1] } }
        #expect(dirs.count == 2 && dirs.allSatisfy { $0 == layout.canaryCacheDir.path })
    }

    @Test func canaryAppliesYouTubeFaultsAndStopsOnABotCheck() async {
        let canary = EngineCanary(layout: layout, qjs: nil, probe: nil, tokens: { _ in true },
                                  faults: ResolverFaults(youtubeBotCheck: true),
                                  runner: { _ in Issue.record("no process may run"); return SubprocessResult(termination: .exited(1)) })
        let result = await canary.run(engine: URL(filePath: "/x"), version: "v", items: [ref(.youtube, 1), ref(.soundcloud, 1)],
                                      settings: .standard)
        #expect(result.botCheck && !result.passed && result.checks.count == 1)
    }

    @Test func canaryWithoutTokensIsInconclusive() async {
        let canary = EngineCanary(layout: layout, qjs: nil, probe: nil, tokens: { _ in false }, tokenWait: .zero,
                                  runner: { _ in SubprocessResult(termination: .exited(1)) })
        let result = await canary.run(engine: URL(filePath: "/x"), version: "v", items: [ref(.youtube, 1)], settings: .standard)
        #expect(!result.passed && !result.engineFailure)
        #expect(result.checks.first?.reason == "noToken")
    }
}
