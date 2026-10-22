// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation
import os

/// Whether yt-dlp can run right now (DESIGN §6.1). Without it only radio is eligible.
public enum EngineReadiness: Sendable, Equatable {
    case ready(version: String, executable: URL)
    case missing
    /// Installed, but the launch re-hash of `tree.json` failed (or it can't be read).
    case corrupt(String)

    public var isReady: Bool { if case .ready = self { return true } else { return false } }
    public var executable: URL? { if case .ready(_, let url) = self { return url } else { return nil } }
    public var version: String? { if case .ready(let v, _) = self { return v } else { return nil } }
}

/// The seam between playback and EngineStore, so the controller is tested without downloads.
public protocol EngineProviding: Sendable {
    /// `current.json` plus the launch re-hash of the installed tree (DESIGN §6.1 step 4).
    func readiness() async -> EngineReadiness
    /// First install (or reinstall) honouring the feed's `pin` and `block`.
    func install(policy: EngineInstallPolicy, progress: @escaping @Sendable (EngineInstallPhase) -> Void) async throws
        -> EngineReadiness
    /// Why the last `install` chose its version (`.pin` asks for an update check right away, DESIGN §6.1).
    func lastInstallReason() async -> EngineChoice.Reason?
    /// A corrupt tree (the launch re-hash failed): reinstall the build, else fall back to the kept previous one.
    func repair(policy: EngineInstallPolicy, progress: @escaping @Sendable (EngineInstallPhase) -> Void) async
        -> EngineReadiness
    /// The launch `--version` warm-up (and the `_update_spec` identifier).
    func warmUp() async -> EngineWarmUp?
    /// A warm-up ran elsewhere (the resolver's serial gate): keep its `_update_spec` identifier for updates.
    func noteWarmUp(_ warm: EngineWarmUp) async
    /// Whether an update check for `trigger` may run now (24 h / 2 h floors).
    func updateDue(_ trigger: EngineUpdateTrigger) async -> Bool
    /// One canary-gated update check (DESIGN §6.1 "Updates").
    func checkForUpdate(_ request: EngineUpdateRequest) async -> EngineUpdateOutcome
    /// Post-switch engine failures: back to the previous build, if a switch happened recently. Nil: nothing done.
    func rollbackAfterEngineFailures() async -> EngineReadiness?
}

extension EngineProviding {
    public func lastInstallReason() async -> EngineChoice.Reason? { nil }
    public func repair(policy: EngineInstallPolicy, progress: @escaping @Sendable (EngineInstallPhase) -> Void) async
        -> EngineReadiness {
        (try? await install(policy: policy, progress: progress)) ?? .missing
    }
    public func warmUp() async -> EngineWarmUp? { nil }
    public func noteWarmUp(_ warm: EngineWarmUp) async {}
    public func updateDue(_ trigger: EngineUpdateTrigger) async -> Bool { false }
    public func checkForUpdate(_ request: EngineUpdateRequest) async -> EngineUpdateOutcome {
        EngineUpdateOutcome(trigger: request.trigger, result: .notDue, reason: "updates unsupported")
    }
    public func rollbackAfterEngineFailures() async -> EngineReadiness? { nil }
}

extension EngineStore: EngineProviding {
    public func readiness() async -> EngineReadiness {
        guard let current = current() else { return .missing }
        do {
            let check = try verifyTree(version: current.version)
            guard check.ok else { return .corrupt("tree.json mismatch: \(check)") }
        } catch {
            return .corrupt("\(error)")
        }
        return .ready(version: current.version, executable: current.executableURL(in: layout))
    }

    public func install(policy: EngineInstallPolicy, progress: @escaping @Sendable (EngineInstallPhase) -> Void) async throws
        -> EngineReadiness {
        _ = try await install(config: policy, progress: progress)
        return await readiness()
    }
}

/// The app's engine stack (PLAN M6): EngineStore for installs and the launch re-hash, EngineUpdater for canary-gated
/// updates and rollback, plus the debug `engine:corrupt` fault (a byte flipped in `_internal/` before the first
/// re-hash).
public actor EngineService: EngineProviding {
    public let store: EngineStore
    public let updater: EngineUpdater
    private let faults: EngineFaults
    private let metrics: MetricsLog?
    private var corrupted = false
    private var lastReason: EngineChoice.Reason?
    private let log = Log.logger("engine")

    public init(store: EngineStore, updater: EngineUpdater, faults: EngineFaults = .none, metrics: MetricsLog? = nil) {
        self.store = store
        self.updater = updater
        self.faults = faults
        self.metrics = metrics
    }

    public func readiness() async -> EngineReadiness {
        if faults.corrupt, !corrupted {
            corrupted = true
            if let path = await faults.applyCorruption(layout: store.layout, current: store.current()) {
                metrics?.record("fault.engineCorrupt", ["path": path])
                log.notice("SUDAMP_FAULT=engine:corrupt flipped a byte in \(path, privacy: .public)")
            }
        }
        return await store.readiness()
    }

    public func install(policy: EngineInstallPolicy, progress: @escaping @Sendable (EngineInstallPhase) -> Void) async throws
        -> EngineReadiness {
        let report = try await store.install(config: policy, progress: progress)
        lastReason = report.alreadyInstalled ? nil : report.reason
        return await store.readiness()
    }

    public func lastInstallReason() async -> EngineChoice.Reason? { lastReason }

    public func repair(policy: EngineInstallPolicy, progress: @escaping @Sendable (EngineInstallPhase) -> Void) async
        -> EngineReadiness {
        let before = await store.current()
        do {
            let readiness = try await install(policy: policy, progress: progress)
            metrics?.record("engine.repair", ["how": "reinstall", "from": before?.version ?? "", "to": readiness.version ?? "",
                                              "ok": readiness.isReady])
            if readiness.isReady { return readiness }
        } catch {
            log.error("engine reinstall failed: \(error, privacy: .public); trying the previous build")
            metrics?.record("engine.repair", ["how": "reinstall", "ok": false, "error": "\(error)"])
        }
        if (try? await store.rollback()) != nil {
            let readiness = await store.readiness()
            metrics?.record("engine.repair", ["how": "rollback", "to": readiness.version ?? "", "ok": readiness.isReady])
            return readiness
        }
        return await store.readiness()
    }

    public func warmUp() async -> EngineWarmUp? { await store.warmUp() }

    public func noteWarmUp(_ warm: EngineWarmUp) async {
        guard let id = warm.identifier else { return }
        var state = await store.updateState()
        guard state.identifier != id else { return }
        state.identifier = id
        await store.saveUpdateState(state)
    }

    public func updateDue(_ trigger: EngineUpdateTrigger) async -> Bool { await updater.isDue(trigger) }

    public func checkForUpdate(_ request: EngineUpdateRequest) async -> EngineUpdateOutcome {
        await updater.check(request)
    }

    public func rollbackAfterEngineFailures() async -> EngineReadiness? {
        guard await updater.rollbackAfterEngineFailures() != nil else { return nil }
        return await store.readiness()
    }
}
