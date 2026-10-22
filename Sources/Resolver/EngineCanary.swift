// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import os

/// One canary step.
public struct CanaryCheck: Sendable, Codable, Equatable {
    public var streamId: String
    public var source: String
    /// `resolve` or `probe` (the YouTube range GET).
    public var step: String
    public var ok: Bool
    /// The failure class, when it failed (`noToken` counts as transient).
    public var failureClass: String?
    public var reason: String?
    public var ms: Double
    public var tier: Int?

    public init(streamId: String, source: String, step: String, ok: Bool, failureClass: String? = nil,
                reason: String? = nil, ms: Double = 0, tier: Int? = nil) {
        self.streamId = streamId
        self.source = source
        self.step = step
        self.ok = ok
        self.failureClass = failureClass
        self.reason = reason
        self.ms = ms
        self.tier = tier
    }
}

/// What a canary run decided about one build (DESIGN §6.1 step 5).
public struct CanaryResult: Sendable, Codable, Equatable {
    public var version: String
    public var checks: [CanaryCheck]
    /// Every resolve and probe succeeded.
    public var passed: Bool
    /// At least one engine-class failure: the build can't extract (it is rejected, and stable may escalate to
    /// nightly). Transient failures and missing tokens are only inconclusive.
    public var engineFailure: Bool
    /// YouTube answered with a bot check: the canary stops and YouTube pauses like any other bot check.
    public var botCheck: Bool
    public var ms: Double

    public init(version: String, checks: [CanaryCheck], ms: Double = 0) {
        self.version = version
        self.checks = checks
        passed = !checks.isEmpty && checks.allSatisfy(\.ok)
        engineFailure = checks.contains { $0.failureClass == ResolveFailureClass.engine.rawValue }
        botCheck = checks.contains { $0.failureClass == ResolveFailureClass.botCheck.rawValue }
        self.ms = ms
    }
}

/// Runs the update canary on a candidate build.
public protocol EngineCanaryRunning: Sendable {
    func run(engine: URL, version: String, items: [StreamRef], settings: ResolverSettings) async -> CanaryResult
}

/// The real canary (DESIGN §6.1 step 5): resolve the feed's canary YouTube and SoundCloud items with the candidate,
/// plus a 64 KB range GET of the YouTube URL, through its own `ResolverService` with `--cache-dir
/// <Caches>/yt-dlp-canary`, so it never shares a cache directory with the app's resolves (§6.3 "Concurrency").
/// YouTube requests take tokens from the app's shared bucket (`tokens`), waiting up to `tokenWait` for one; the JS
/// ladder steps up to QuickJS-NG on an engine-class failure, as playback would.
public struct EngineCanary: EngineCanaryRunning {
    public typealias TokenGate = @Sendable (ResolvePurpose) async -> Bool

    public let layout: EngineLayout
    public let qjs: URL?
    public let probe: (any MediaProbing)?
    public let tokens: TokenGate
    public let proxy: @Sendable () -> URL?
    public let faults: ResolverFaults
    /// `SUDAMP_FAULT=engine:bad-update`: every check fails as an engine error without running anything.
    public let badUpdate: Bool
    public let metrics: MetricsLog?
    public let tokenWait: Duration
    public let runner: ResolverService.Runner
    private let log = Log.logger("engine")

    public init(layout: EngineLayout, qjs: URL?, probe: (any MediaProbing)? = URLSessionMediaProbe(),
                tokens: @escaping TokenGate, proxy: @escaping @Sendable () -> URL? = { SystemProxy.current().url },
                faults: ResolverFaults = .none, badUpdate: Bool = false, metrics: MetricsLog? = nil,
                tokenWait: Duration = .seconds(90),
                runner: @escaping ResolverService.Runner = { try await Subprocess.run($0) }) {
        self.layout = layout
        self.qjs = qjs
        self.probe = probe
        self.tokens = tokens
        self.proxy = proxy
        self.faults = faults
        self.badUpdate = badUpdate
        self.metrics = metrics
        self.tokenWait = tokenWait
        self.runner = runner
    }

    public func run(engine: URL, version: String, items: [StreamRef], settings: ResolverSettings) async -> CanaryResult {
        let started = ContinuousClock.now
        var checks: [CanaryCheck] = []
        let proxy = self.proxy()
        let service = ResolverService(layout: layout, engine: engine, qjs: qjs, settings: settings,
                                      cacheDirectory: layout.canaryCacheDir, proxy: proxy, runner: runner)
        for item in items where item.source.needsResolver {
            let isYouTube = item.source.platform == .youtube
            let id = item.id.rawValue, src = item.source.rawValue
            if badUpdate {
                checks.append(CanaryCheck(streamId: id, source: src, step: "resolve", ok: false,
                                          failureClass: ResolveFailureClass.engine.rawValue,
                                          reason: "fault:bad-update"))
                continue
            }
            let request = ResolveRequest(source: item.source, url: item.url)
            var tier = ResolveTier.jsless
            var outcome: ResolveOutcome?
            var lastFailure: ResolveFailure?
            var t0 = ContinuousClock.now
            while true {
                if isYouTube, !(await waitForToken()) {
                    lastFailure = ResolveFailure(.transient, "noToken", message: "no YouTube token for the canary")
                    break
                }
                t0 = ContinuousClock.now
                do {
                    if let injected = faults.injectedFailure(request, tier: tier) { throw injected }
                    outcome = try await service.resolve(request, tier: tier, priority: .background)
                    lastFailure = nil
                    break
                } catch let f as ResolveFailure {
                    lastFailure = f
                    if isYouTube, f.failureClass == .engine, tier == .jsless, qjs != nil {
                        tier = .quickjs
                        continue
                    }
                    break
                } catch {
                    lastFailure = ResolveFailure(.transient, "canary", message: "\(error)")
                    break
                }
            }
            let ms = (ContinuousClock.now - t0).milliseconds.rounded()
            guard let outcome else {
                let f = lastFailure ?? ResolveFailure(.transient, "unknown")
                checks.append(CanaryCheck(streamId: id, source: src, step: "resolve", ok: false,
                                          failureClass: f.failureClass.rawValue, reason: f.reason, ms: ms,
                                          tier: tier.rawValue))
                if f.failureClass == .botCheck { break }
                continue
            }
            checks.append(CanaryCheck(streamId: id, source: src, step: "resolve", ok: true, ms: ms, tier: tier.rawValue))
            if isYouTube, !outcome.stream.isHLS, let probe {
                let p0 = ContinuousClock.now
                let result = await probe.probe(outcome.stream, proxy: proxy)
                let pms = (ContinuousClock.now - p0).milliseconds.rounded()
                switch result {
                case .ok:
                    checks.append(CanaryCheck(streamId: id, source: src, step: "probe", ok: true, ms: pms))
                case .forbidden(let status):
                    checks.append(CanaryCheck(streamId: id, source: src, step: "probe", ok: false,
                                              failureClass: ResolveFailureClass.engine.rawValue,
                                              reason: "probe\(status)", ms: pms))
                case .failed(let why):
                    checks.append(CanaryCheck(streamId: id, source: src, step: "probe", ok: false,
                                              failureClass: ResolveFailureClass.transient.rawValue,
                                              reason: String(why.prefix(120)), ms: pms))
                }
            }
        }
        if checks.isEmpty {
            log.warning("canary for \(version, privacy: .public): no canary items; the smoke test stands alone")
            checks.append(CanaryCheck(streamId: "-", source: "-", step: "smoke", ok: true))
        }
        let result = CanaryResult(version: version, checks: checks, ms: (ContinuousClock.now - started).milliseconds.rounded())
        metrics?.record("engine.canary", ["version": version, "passed": result.passed, "engineFailure": result.engineFailure,
                                          "botCheck": result.botCheck, "ms": result.ms,
                                          "checks": checks.map { "\($0.streamId)/\($0.step)=\($0.ok ? "ok" : "\($0.failureClass ?? "")/\($0.reason ?? "")")" }])
        log.notice("canary \(version, privacy: .public): \(result.passed ? "passed" : "failed", privacy: .public)")
        return result
    }

    private func waitForToken() async -> Bool {
        let deadline = ContinuousClock.now + tokenWait
        while true {
            if await tokens(.canary) { return true }
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
