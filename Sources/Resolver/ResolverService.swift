// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import os

/// A successful resolve.
public struct ResolveOutcome: Sendable {
    public var stream: ResolvedStream
    public var elapsedMs: Double
    public var warnings: [String]
}

/// Runs yt-dlp, one resolve at a time (DESIGN §6.2, §6.3). A `.user` request kills an in-flight `.background`
/// one (prefetch, hover), which then throws `ResolverError.preempted`; waiting requests are served by priority,
/// then arrival. Cancelling the calling task kills the yt-dlp process group. The canary uses a second instance
/// with `layout.canaryCacheDir`, so no two processes ever share a `--cache-dir`.
public actor ResolverService {
    public typealias Runner = @Sendable (SubprocessSpec) async throws -> SubprocessResult

    private struct Waiter {
        let id: UInt64
        let priority: ResolvePriority
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct InFlight {
        let id: UInt64
        let priority: ResolvePriority
        let task: Task<SubprocessResult, any Error>
    }

    public let layout: EngineLayout
    public private(set) var engine: URL?
    public private(set) var qjs: URL?
    public private(set) var settings: ResolverSettings
    public private(set) var proxy: URL?
    private let cacheDirectory: URL
    private let time: any TimeSource
    private let metrics: MetricsLog?
    private let runner: Runner
    private let log = Log.logger("resolver")

    private var busy = false
    private var waiters: [Waiter] = []
    private var inFlight: InFlight?
    private var preempted: Set<UInt64> = []
    private var nextID: UInt64 = 0

    public init(layout: EngineLayout, engine: URL?, qjs: URL? = nil, settings: ResolverSettings = .standard,
                cacheDirectory: URL? = nil, proxy: URL? = nil, time: any TimeSource = SystemTimeSource(),
                metrics: MetricsLog? = nil, runner: @escaping Runner = { try await Subprocess.run($0) }) {
        self.layout = layout
        self.engine = engine
        self.qjs = qjs
        let (valid, rejected) = settings.validated()
        self.settings = valid
        self.cacheDirectory = cacheDirectory ?? layout.cacheDir
        self.proxy = proxy
        self.time = time
        self.metrics = metrics
        self.runner = runner
        if !rejected.isEmpty { Log.logger("resolver").warning("rejected settings: \(rejected, privacy: .public)") }
    }

    public func setEngine(_ url: URL?) { engine = url }
    public func setQuickJS(_ url: URL?) { qjs = url }
    public func setProxy(_ url: URL?) { proxy = url }

    /// Replaces the feed-driven strings; invalid values fall back to defaults (DESIGN §7.2).
    @discardableResult
    public func setSettings(_ s: ResolverSettings) -> [String] {
        let (valid, rejected) = s.validated()
        settings = valid
        return rejected
    }

    /// The exact command a resolve would run (for tools and goldens).
    public func invocation(for request: ResolveRequest, tier: ResolveTier) throws -> EngineInvocation {
        guard let engine else { throw ResolverError.engineMissing }
        return try EngineInvocation.make(request: request, tier: tier, settings: settings, layout: layout,
                                         engine: engine, qjs: qjs, proxy: proxy, cacheDirectory: cacheDirectory)
    }

    /// Resolves one stream at one tier. Throws `ResolveFailure` (classified), `ResolverError`, or
    /// `CancellationError`.
    public func resolve(_ request: ResolveRequest, tier: ResolveTier = .jsless,
                        priority: ResolvePriority = .user) async throws -> ResolveOutcome {
        let id = nextID
        nextID += 1
        let invocation = try invocation(for: request, tier: tier)
        try await acquire(id: id, priority: priority)
        defer { release() }
        try Task.checkCancellation()
        try layout.createDirectories()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let runner = self.runner
        let spec = invocation.spec
        let task = Task.detached { try await runner(spec) }
        inFlight = InFlight(id: id, priority: priority, task: task)
        defer { inFlight = nil }

        let result: SubprocessResult
        do {
            result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch is CancellationError {
            if preempted.remove(id) != nil {
                record(request, tier: tier, ms: nil, failure: "preempted")
                throw ResolverError.preempted
            }
            throw CancellationError()
        }
        preempted.remove(id)  // a pre-emption that arrived after the run finished
        return try finish(request, tier: tier, result: result)
    }

    /// The launch warm-up (DESIGN §3: "yt-dlp is warmed with `--version`"; PLAN M6), through the same serial gate as
    /// resolves at background priority: it never runs beside a resolve, and a user pick kills it. A second, `-v` run
    /// without a URL (no network) prints the build's `_update_spec` identifier. Nil when pre-empted or no engine.
    public func warmUp(version: String?) async -> EngineWarmUp? {
        guard let engine else { return nil }
        let id = nextID
        nextID += 1
        do { try await acquire(id: id, priority: .background) } catch { return nil }
        defer { release() }
        try? layout.createDirectories()
        let runner = self.runner
        func run(_ args: [String]) async -> SubprocessResult? {
            guard !Task.isCancelled else { return nil }
            let spec = SubprocessSpec(executable: engine, arguments: args, environment: layout.environment,
                                      workingDirectory: layout.home, timeout: .seconds(30))
            let task = Task.detached { try await runner(spec) }
            inFlight = InFlight(id: id, priority: .background, task: task)
            defer { inFlight = nil }
            let result = try? await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if preempted.remove(id) != nil { return nil }
            return result
        }
        guard let v = await run(["--version"]) else {
            metrics?.record("engine.warmup", ["ok": false, "preempted": true])
            return nil
        }
        let printed = v.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        var warm = EngineWarmUp(version: version ?? printed, versionMs: v.elapsed.milliseconds.rounded(),
                                ok: v.succeeded && (version == nil || printed == version))
        if let verbose = await run(["--ignore-config", "--no-plugin-dirs", "--no-update", "--no-js-runtimes", "-v"]) {
            warm.identifierMs = verbose.elapsed.milliseconds.rounded()
            warm.identifier = UpdateSpec.identifier(fromVerbose: verbose.stderrString)
        }
        metrics?.record("engine.warmup", ["version": warm.version, "ms": warm.versionMs, "ok": warm.ok,
                                          "identifierMs": warm.identifierMs ?? 0, "identifier": warm.identifier ?? ""])
        log.info("engine warm-up: --version \(warm.versionMs, format: .fixed(precision: 0)) ms")
        return warm
    }

    /// Tier 1, then tier 2 on an engine-class failure when QuickJS-NG is available (YouTube only). M3 adds the
    /// "two tier-1 failures while tier 2 works start at tier 2 for 24 h" adaptation on top.
    public func resolveWithLadder(_ request: ResolveRequest, priority: ResolvePriority = .user) async throws
        -> ResolveOutcome {
        do {
            return try await resolve(request, tier: .jsless, priority: priority)
        } catch let failure as ResolveFailure
            where failure.failureClass == .engine && qjs != nil
            && (request.source == .youtube || request.source == .youtubeLive) {
            log.info("tier 1 failed (\(failure.reason, privacy: .public)); stepping up to QuickJS")
            return try await resolve(request, tier: .quickjs, priority: priority)
        }
    }

    // MARK: Result handling

    private func finish(_ request: ResolveRequest, tier: ResolveTier, result: SubprocessResult) throws
        -> ResolveOutcome {
        let ms = result.elapsed.milliseconds
        let stderr = result.stderrString
        let warnings = ResolveErrorClassifier.warnings(stderr)
        for w in warnings { log.notice("yt-dlp \(request.source.rawValue, privacy: .public): \(w, privacy: .public)") }

        func fail(_ f: ResolveFailure) -> ResolveFailure {
            record(request, tier: tier, ms: ms, failure: "\(f.failureClass.rawValue)/\(f.reason)")
            log.error("resolve failed \(f.description, privacy: .public)")
            return f
        }
        guard result.succeeded else {
            throw fail(ResolveErrorClassifier.classify(stderr: stderr, termination: result.termination,
                                                       timedOut: result.timedOut, tier: tier.rawValue, elapsedMs: ms))
        }
        let stream: ResolvedStream
        do {
            stream = try ResolvedStream.parse(json: result.stdout, source: request.source, tier: tier.rawValue,
                                              now: time.now)
        } catch {
            throw fail(ResolveFailure(.engine, (error as? ResolvedStreamError) == .notJSON ? "badJSON" : "noMediaURL",
                                      message: ResolveErrorClassifier.errorLine(stderr), tier: tier.rawValue,
                                      elapsedMs: ms))
        }
        if (stream.formatID ?? "").contains("preview") {
            throw fail(ResolveFailure(.unavailable, "preview", message: "only a preview format (\(stream.formatID ?? ""))",
                                      tier: tier.rawValue, elapsedMs: ms))
        }
        let hosts = settings.mediaHosts[request.source] ?? []
        guard ResolvedStream.isAllowedMediaHost(stream.url, suffixes: hosts) else {
            throw fail(ResolveFailure(.engine, "mediaHost",
                                      message: "\(stream.url.scheme ?? "")://\(stream.url.host ?? "") not in \(hosts)",
                                      tier: tier.rawValue, elapsedMs: ms))
        }
        record(request, tier: tier, ms: ms, failure: nil)
        return ResolveOutcome(stream: stream, elapsedMs: ms, warnings: warnings)
    }

    private func record(_ request: ResolveRequest, tier: ResolveTier, ms: Double?, failure: String?) {
        var fields: [String: any Sendable] = ["source": request.source.rawValue, "tier": tier.rawValue,
                                              "ok": failure == nil]
        if let ms { fields["ms"] = ms.rounded() }
        if let failure { fields["class"] = failure }
        metrics?.record("resolve", fields)
    }

    // MARK: Serial gate

    private func acquire(id: UInt64, priority: ResolvePriority) async throws {
        if priority == .user, let running = inFlight, running.priority < .user {
            preempted.insert(running.id)
            running.task.cancel()
        }
        guard busy else {
            busy = true
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                waiters.append(Waiter(id: id, priority: priority, continuation: c))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }

    /// Hands the slot to the highest-priority, earliest waiter, or frees it.
    private func release() {
        guard let best = waiters.indices.max(by: { a, b in
            waiters[a].priority != waiters[b].priority ? waiters[a].priority < waiters[b].priority : a > b
        }) else {
            busy = false
            return
        }
        waiters.remove(at: best).continuation.resume()
    }
}
