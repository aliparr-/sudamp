// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import os

/// Why an update check runs (DESIGN §6.1 "Updates").
public enum EngineUpdateTrigger: String, Sendable, Codable, CaseIterable {
    /// Right after a first install chose the feed's `pin`: the pin only picks the first build.
    case afterPinInstall
    /// At launch, when the last check is over 24 h old.
    case launch
    /// Every 24 h while running.
    case daily
    /// After two engine-class failures in a row, at most every 2 h.
    case engineFailures
    /// A tool asked.
    case manual
}

/// What a check needs from the active feed.
public struct EngineUpdateRequest: Sendable {
    public var trigger: EngineUpdateTrigger
    /// The feed's `block` list (its `pin` never holds an update back).
    public var policy: EngineInstallPolicy
    public var nightlyEscalation: Bool
    /// The feed's canary items (`engine.canary`), as catalog streams.
    public var canary: [StreamRef]
    /// The feed's engine strings, so the canary resolves exactly like playback.
    public var settings: ResolverSettings

    public init(trigger: EngineUpdateTrigger, policy: EngineInstallPolicy, nightlyEscalation: Bool, canary: [StreamRef],
                settings: ResolverSettings = .standard) {
        self.trigger = trigger
        self.policy = policy
        self.nightlyEscalation = nightlyEscalation
        self.canary = canary
        self.settings = settings
    }
}

/// What a check did.
public struct EngineUpdateOutcome: Sendable, Codable, Equatable {
    public enum Result: String, Sendable, Codable {
        /// Rate-limited (24 h / 2 h) or another check is running.
        case notDue
        /// The newest allowed build is the current one (and, after engine failures, it passes the canary).
        case upToDate
        /// A candidate passed the canary and `current.json` now points at it.
        case switched
        /// Every candidate failed the canary: `current.json` is unchanged.
        case canaryFailed
        /// The release host was unreachable, a download failed, …
        case failed
    }

    public var trigger: EngineUpdateTrigger
    public var result: Result
    /// The active build before the check.
    public var from: String?
    /// The active build after it.
    public var current: String?
    public var candidate: String?
    /// `stable` or `nightly` (for `switched`).
    public var channel: String?
    public var reason: String?
    public var canary: [CanaryResult] = []
    public var ms: Double = 0

    public init(trigger: EngineUpdateTrigger, result: Result, from: String? = nil, current: String? = nil,
                candidate: String? = nil, channel: String? = nil, reason: String? = nil) {
        self.trigger = trigger
        self.result = result
        self.from = from
        self.current = current
        self.candidate = candidate
        self.channel = channel
        self.reason = reason
    }
}

/// Engine freshness without app releases (DESIGN §6.1, PLAN M6): canary-gated switching to the newest non-blocked
/// upstream release, `_update_spec` honoured with the running build's identifier, nightly escalation when stable
/// fails the canary with engine errors, local rejection of builds that failed, and rollback after post-switch
/// engine failures. Never runs yt-dlp's own `-U`. One check at a time.
public actor EngineUpdater {
    public static let launchInterval: TimeInterval = 24 * 3600
    public static let failureInterval: TimeInterval = 2 * 3600
    /// A build that failed the canary with engine errors isn't tried again for this long.
    public static let canaryRejection: TimeInterval = 24 * 3600
    /// A build rolled back after post-switch engine failures isn't chosen again for this long.
    public static let rollbackRejection: TimeInterval = 7 * 24 * 3600
    /// Engine failures this soon after a switch roll it back.
    public static let postSwitchWindow: TimeInterval = 24 * 3600

    public let store: EngineStore
    private let stable: any EngineReleaseSource
    private let nightly: any EngineReleaseSource
    private let canary: any EngineCanaryRunning
    private let time: any TimeSource
    private let metrics: MetricsLog?
    /// `SUDAMP_FAULT=engine:bad-update`: the launch check is always due, and with no newer stable release the
    /// newest nightly stands in as the candidate (so there is an update for the canary to fail).
    private let badUpdate: Bool
    private let log = Log.logger("engine")
    private var running = false

    public init(store: EngineStore, stable: any EngineReleaseSource = GitHubReleases(),
                nightly: any EngineReleaseSource = GitHubReleases(repo: GitHubReleases.nightlyRepo),
                canary: any EngineCanaryRunning, time: any TimeSource = SystemTimeSource(), metrics: MetricsLog? = nil,
                badUpdate: Bool = false) {
        self.store = store
        self.stable = stable
        self.nightly = nightly
        self.canary = canary
        self.time = time
        self.metrics = metrics
        self.badUpdate = badUpdate
    }

    /// Whether `trigger` may run now (the 24 h and 2 h floors survive relaunch: they live in `updates.json`).
    public func isDue(_ trigger: EngineUpdateTrigger) async -> Bool {
        Self.isDue(trigger, state: await store.updateState(), now: time.now, forced: badUpdate)
    }

    public static func isDue(_ trigger: EngineUpdateTrigger, state: EngineUpdateState, now: Date, forced: Bool = false)
        -> Bool {
        switch trigger {
        case .afterPinInstall, .manual:
            return true
        case .launch, .daily:
            if forced { return true }
            guard let last = state.lastCheckAt else { return true }
            return now.timeIntervalSince(last) >= launchInterval || now < last
        case .engineFailures:
            guard let last = state.lastFailureCheckAt else { return true }
            return now.timeIntervalSince(last) >= failureInterval || now < last
        }
    }

    /// Runs one check. Never throws: every outcome is recorded in `metrics.jsonl` (`engine.update.check`, then
    /// `engine.update` with the result).
    public func check(_ request: EngineUpdateRequest) async -> EngineUpdateOutcome {
        let started = ContinuousClock.now
        let current = await store.current()
        guard !running else {
            return EngineUpdateOutcome(trigger: request.trigger, result: .notDue, from: current?.version,
                                       current: current?.version, reason: "a check is running")
        }
        var state = await store.updateState()
        let now = time.now
        guard Self.isDue(request.trigger, state: state, now: now, forced: badUpdate) else {
            return EngineUpdateOutcome(trigger: request.trigger, result: .notDue, from: current?.version,
                                       current: current?.version, reason: "rate-limited")
        }
        running = true
        defer { running = false }
        if request.trigger == .engineFailures {
            state.lastFailureCheckAt = now
            await store.saveUpdateState(state)
        }
        metrics?.record("engine.update.check", ["trigger": request.trigger.rawValue, "current": current?.version ?? ""])
        log.info("engine update check (\(request.trigger.rawValue, privacy: .public)), current \(current?.version ?? "none", privacy: .public)")

        var outcome = await perform(request, current: current, state: &state)
        if Task.isCancelled {
            // Quit mid-check: nothing was decided (a partial canary must neither count nor set the 24 h clock).
            outcome.result = .failed
            outcome.reason = "cancelled (\(outcome.reason ?? "no result"))"
        }
        outcome.ms = (ContinuousClock.now - started).milliseconds.rounded()
        if outcome.result != .failed { state.lastCheckAt = now }
        await store.saveUpdateState(state)
        var fields: [String: any Sendable] = ["trigger": request.trigger.rawValue, "result": outcome.result.rawValue,
                                              "from": outcome.from ?? "", "current": outcome.current ?? "",
                                              "ms": outcome.ms]
        if let c = outcome.candidate { fields["candidate"] = c }
        if let c = outcome.channel { fields["channel"] = c }
        if let r = outcome.reason { fields["reason"] = String(r.prefix(300)) }
        metrics?.record("engine.update", fields)
        log.notice("engine update \(outcome.result.rawValue, privacy: .public): \(outcome.reason ?? outcome.current ?? "", privacy: .public)")
        return outcome
    }

    private func perform(_ request: EngineUpdateRequest, current: EngineInstallation?, state: inout EngineUpdateState) async
        -> EngineUpdateOutcome {
        let now = time.now
        var outcome = EngineUpdateOutcome(trigger: request.trigger, result: .upToDate, from: current?.version,
                                          current: current?.version)
        let block = Set(request.policy.validated().config.block + state.rejectedVersions(now: now))
        let identifier = state.identifier ?? UpdateSpec.synthesizedIdentifier()
        let currentVersion = current.flatMap { EngineVersion($0.version) }
        let currentBlocked = current.map { block.contains($0.version) } ?? false
        do {
            var stableFailedWithEngineErrors = false
            var source: any EngineReleaseSource = stable
            var candidate = try await Self.candidate(from: stable, block: block, identifier: identifier)
            if badUpdate, candidate == current?.version || candidate == nil {
                source = nightly
                candidate = try await Self.candidate(from: nightly, block: block, identifier: identifier)
            }
            outcome.candidate = candidate
            let candidateVersion = candidate.flatMap(EngineVersion.init)
            if let candidate, let candidateVersion,
               currentVersion == nil || currentBlocked || candidateVersion > currentVersion! {
                switch await tryCandidate(candidate, from: source, request: request, state: &state, outcome: &outcome) {
                case .switched: return outcome
                case .rejected(let engineErrors): stableFailedWithEngineErrors = engineErrors
                }
                outcome.result = .canaryFailed
            } else if let current, request.trigger == .engineFailures {
                // Production is failing on the newest allowed build: check it with the canary before escalating.
                let result = await canary.run(engine: current.executableURL(in: store.layout), version: current.version,
                                              items: request.canary, settings: request.settings)
                outcome.canary.append(result)
                if result.passed {
                    outcome.reason = "\(current.version) is the newest allowed build and passes the canary"
                    return outcome
                }
                stableFailedWithEngineErrors = result.engineFailure
                outcome.result = .canaryFailed
                outcome.reason = "\(current.version) fails the canary"
            } else {
                outcome.reason = "\(current?.version ?? "none") is the newest allowed build"
                return outcome
            }
            // Nightly escalation (DESIGN §6.1): stable failed the canary with engine errors.
            guard stableFailedWithEngineErrors, request.nightlyEscalation else { return outcome }
            guard let nightlyTag = try await Self.candidate(from: nightly, block: block, identifier: identifier),
                  let nv = EngineVersion(nightlyTag), currentVersion.map({ nv > $0 }) ?? true,
                  outcome.candidate != nightlyTag || source.name != nightly.name else {
                outcome.reason = (outcome.reason.map { $0 + "; " } ?? "") + "no newer nightly to escalate to"
                return outcome
            }
            metrics?.record("engine.nightly.escalate", ["from": current?.version ?? "", "candidate": nightlyTag])
            outcome.candidate = nightlyTag
            if case .switched = await tryCandidate(nightlyTag, from: nightly, request: request, state: &state,
                                                   outcome: &outcome) {
                return outcome
            }
            outcome.result = .canaryFailed
            return outcome
        } catch {
            outcome.result = .failed
            outcome.reason = "\(error)"
            return outcome
        }
    }

    private enum Trial { case switched, rejected(engineErrors: Bool) }

    /// Stages `version` from `source`, runs the canary on it and switches only if it passes.
    private func tryCandidate(_ version: String, from source: any EngineReleaseSource, request: EngineUpdateRequest,
                              state: inout EngineUpdateState, outcome: inout EngineUpdateOutcome) async -> Trial {
        let channel = source.name == nightly.name ? "nightly" : "stable"
        let staged: StagedEngine
        do {
            staged = try await store.stage(choice: EngineChoice(version: version, reason: .latest), from: source)
        } catch {
            outcome.reason = "staging \(version) failed: \(error)"
            return .rejected(engineErrors: false)
        }
        let result = await canary.run(engine: staged.executable, version: version, items: request.canary,
                                      settings: request.settings)
        outcome.canary.append(result)
        guard result.passed else {
            await store.discard(staged)
            if result.engineFailure { state.rejected[version] = time.now.addingTimeInterval(Self.canaryRejection) }
            outcome.reason = "\(channel) \(version) failed the canary"
                + (result.engineFailure ? " with engine errors" : " (inconclusive)")
            log.error("canary rejected \(channel, privacy: .public) \(version, privacy: .public); current.json unchanged")
            return .rejected(engineErrors: result.engineFailure)
        }
        do {
            let installation = try await store.activate(staged)
            state.lastSwitchAt = time.now
            state.switchedFrom = outcome.from
            state.switchedTo = installation.version
            outcome.result = .switched
            outcome.current = installation.version
            outcome.channel = channel
            outcome.reason = "\(channel) \(version) passed the canary"
            metrics?.record("engine.update.switch", ["from": outcome.from ?? "", "to": installation.version,
                                                     "channel": channel])
            return .switched
        } catch {
            await store.discard(staged)
            outcome.reason = "switching to \(version) failed: \(error)"
            return .rejected(engineErrors: false)
        }
    }

    /// The newest release from `source` that isn't blocked and isn't above an `_update_spec` lock for `identifier`.
    static func candidate(from source: any EngineReleaseSource, block: Set<String>, identifier: String) async throws
        -> String? {
        do {
            let spec = try await source.updateSpec()
            let locked = spec.flatMap { UpdateSpec(parsing: $0).lockedTag(identifier: identifier, repo: source.name) }
            let policy = EngineInstallPolicy(pin: nil, block: block.sorted())
            let latest = try await source.latestVersion()
            if let c = EngineChooser.choose(config: policy, latest: latest, lockedTag: locked), c.version == latest {
                return latest
            }
            let recent = try await source.recentVersions()
            return EngineChooser.choose(config: policy, latest: latest, recent: recent, lockedTag: locked)?.version
        } catch let error as URLError {
            throw EngineStoreError.unreachable(error.localizedDescription)
        }
    }

    /// Post-switch engine failures (DESIGN §6.1 / PLAN M6 rollback): within 24 h of a switch, go back to the kept
    /// previous build and reject the new one for 7 days. Nil when there was no recent switch or nothing to go back to.
    public func rollbackAfterEngineFailures() async -> EngineInstallation? {
        var state = await store.updateState()
        let now = time.now
        guard let at = state.lastSwitchAt, now.timeIntervalSince(at) < Self.postSwitchWindow, now >= at,
              let to = state.switchedTo, let cur = await store.current(), cur.version == to, cur.previous != nil else {
            return nil
        }
        do {
            let installation = try await store.rollback()
            state.rejected[to] = now.addingTimeInterval(Self.rollbackRejection)
            state.lastSwitchAt = nil
            state.switchedTo = nil
            await store.saveUpdateState(state)
            metrics?.record("engine.rollback.postSwitch", ["from": to, "to": installation.version])
            log.error("post-switch engine failures: rolled back \(to, privacy: .public) → \(installation.version, privacy: .public)")
            return installation
        } catch {
            return nil
        }
    }
}
