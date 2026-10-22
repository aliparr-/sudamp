// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import os

/// What runs yt-dlp for the StreamResolver: `ResolverService` in the app, a fake in tests.
public protocol ResolveBackend: Sendable {
    func resolve(_ request: ResolveRequest, tier: ResolveTier, priority: ResolvePriority) async throws -> ResolveOutcome
    func setEngine(_ url: URL?) async
    func setProxy(_ url: URL?) async
    func hasQuickJS() async -> Bool
    /// The feed's engine strings changed (M7 remote feed); returns the rejected values.
    func setSettings(_ settings: ResolverSettings) async -> [String]
    /// The launch `--version` warm-up through the serial gate (M6).
    func warmUp(version: String?) async -> EngineWarmUp?
}

extension ResolveBackend {
    public func setSettings(_ settings: ResolverSettings) async -> [String] { [] }
    public func warmUp(version: String?) async -> EngineWarmUp? { nil }
}

extension ResolverService: ResolveBackend {
    public func hasQuickJS() -> Bool { qjs != nil }
}

/// A resolution ready for playback decisions.
public struct StreamResolution: Sendable, Equatable {
    public var stream: ResolvedStream
    public var fromCache: Bool
    /// The tier that produced it.
    public var tier: ResolveTier
    /// yt-dlp time for this request (0 from the cache).
    public var elapsedMs: Double
    /// When it may be loaded (`available_at`).
    public var availability: Availability
    /// Tier 1 failed and tier 2 produced this.
    public var steppedUp: Bool

    public init(stream: ResolvedStream, fromCache: Bool, tier: ResolveTier, elapsedMs: Double,
                availability: Availability, steppedUp: Bool = false) {
        self.stream = stream
        self.fromCache = fromCache
        self.tier = tier
        self.elapsedMs = elapsedMs
        self.availability = availability
        self.steppedUp = steppedUp
    }
}

/// Resolves refused before yt-dlp runs (resolve *failures* are `ResolveFailure`).
public enum StreamResolveError: Error, Sendable, Equatable, CustomStringConvertible {
    case notResolvable(SourceKind)
    /// The YouTube bucket is empty (or below the hover minimum): the item is deferred, not failed.
    case noToken(ResolvePurpose)
    /// A bot check or 429 paused the platform until `until`.
    case sourceBlocked(SourceKind, until: Date)
    case engineMissing

    public var description: String {
        switch self {
        case .notResolvable(let s): "\(s.rawValue) is not resolved"
        case .noToken(let p): "no YouTube token for \(p.rawValue)"
        case .sourceBlocked(let s, let until): "\(s.rawValue) paused until \(until)"
        case .engineMissing: "yt-dlp is not installed"
        }
    }
}

/// What the picker and UI need from the resolver right now.
public struct ResolverStatus: Sendable, Equatable, Codable {
    public var youtubeTokens: Int
    /// Valid cached resolutions loadable within 3 s (fast-start's "ready").
    public var readyIDs: Set<StreamID>
    /// Every valid cached resolution.
    public var cachedIDs: Set<StreamID>
    /// Platforms paused by a bot check (the picker treats them as an open breaker).
    public var openSources: Set<SourceKind>
    public var preferTier2Until: Date?
    public var engineReady: Bool
    public var quickJS: Bool

    public init(youtubeTokens: Int = TokenBucket.burst, readyIDs: Set<StreamID> = [], cachedIDs: Set<StreamID> = [],
                openSources: Set<SourceKind> = [], preferTier2Until: Date? = nil, engineReady: Bool = false,
                quickJS: Bool = false) {
        self.youtubeTokens = youtubeTokens
        self.readyIDs = readyIDs
        self.cachedIDs = cachedIDs
        self.openSources = openSources
        self.preferTier2Until = preferTier2Until
        self.engineReady = engineReady
        self.quickJS = quickJS
    }
}

/// The playback-facing resolver: what the PlaybackController calls (and what its tests fake).
public protocol StreamResolving: Sendable {
    /// Resolves `stream` for `purpose`, from the cache when possible. Throws `StreamResolveError` (not attempted),
    /// `ResolveFailure` (classified), `ResolverError` or `CancellationError`.
    func resolve(_ stream: StreamRef, purpose: ResolvePurpose) async throws -> StreamResolution
    /// A valid cached resolution, if any.
    func cached(_ id: StreamID) async -> ResolvedStream?
    func status() async -> ResolverStatus
    /// The network path changed: drops IP-bound (YouTube) resolutions and returns their IDs.
    func networkPathChanged() async -> [StreamID]
    func evict(_ id: StreamID) async
    func clearCache() async
    func setEngine(_ executable: URL?) async
    /// A new active feed (M7): its formats, extractor args, clients and media hosts apply from the next resolve.
    func setEngineConfig(_ engine: EngineConfig) async
    /// A source breaker opened (M6): no resolve for `platform` until `until` (YouTube's bot-check pause). Blocks
    /// only ever extend.
    func blockPlatform(_ platform: SourceKind, until: Date) async
    /// Takes a token from the shared YouTube bucket for work outside `resolve` (the update canary, DESIGN §6.3).
    func spendToken(for purpose: ResolvePurpose) async -> Bool
    /// The launch `--version` warm-up, serialised with resolves (a user pick kills it). Nil when skipped.
    func warmUp(version: String?) async -> EngineWarmUp?
}

extension StreamResolving {
    public func setEngineConfig(_ engine: EngineConfig) async {}
    public func blockPlatform(_ platform: SourceKind, until: Date) async {}
    public func spendToken(for purpose: ResolvePurpose) async -> Bool { true }
    public func warmUp(version: String?) async -> EngineWarmUp? { nil }
}

/// Debug-only faults (`SUDAMP_FAULT`, PLAN conventions). Each fails the matching resolves *without running yt-dlp*,
/// through the real classifier with yt-dlp's own error text, so they cost no requests:
/// - `youtube:jsless-fail` (M3): tier-1 YouTube resolves fail as engine/`faultJSLess`;
/// - `youtube:403`: every YouTube resolve fails as engine/`http403` (`HTTP Error 403: Forbidden`), at every tier;
/// - `youtube:botcheck`: as botCheck/`notABot` ("Sign in to confirm you're not a bot");
/// - `youtube:timeout`: as transient/`timeout` (our 10 s process-group kill), returned at once;
/// - `mixcloud:repeat_play`: Mixcloud resolves fail as unavailable/`mixcloudRepeatPlay` ("reached your play limit");
/// - `resolve:delay=<s>`: real resolves are held until `s` seconds after they started (a slow cold pick).
public struct ResolverFaults: Sendable, Equatable {
    public var jslessFail = false
    public var youtube403 = false
    public var youtubeBotCheck = false
    public var youtubeTimeout = false
    public var mixcloudRepeatPlay = false
    /// Seconds; nil or 0 adds nothing.
    public var resolveDelay: TimeInterval?

    public init(jslessFail: Bool = false, youtube403: Bool = false, youtubeBotCheck: Bool = false,
                youtubeTimeout: Bool = false, mixcloudRepeatPlay: Bool = false, resolveDelay: TimeInterval? = nil) {
        self.jslessFail = jslessFail
        self.youtube403 = youtube403
        self.youtubeBotCheck = youtubeBotCheck
        self.youtubeTimeout = youtubeTimeout
        self.mixcloudRepeatPlay = mixcloudRepeatPlay
        self.resolveDelay = resolveDelay
    }

    public static let none = ResolverFaults()
    public var isActive: Bool { self != .none }

    /// Parses `SUDAMP_FAULT` (comma-separated) in debug builds; always `.none` in release.
    public static func from(environment: [String: String] = ProcessInfo.processInfo.environment) -> ResolverFaults {
        #if DEBUG
        parse(environment["SUDAMP_FAULT"] ?? "")
        #else
        .none
        #endif
    }

    /// The grammar (unknown items are ignored: other modules own them).
    public static func parse(_ value: String) -> ResolverFaults {
        var f = ResolverFaults()
        for item in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch item {
            case "youtube:jsless-fail": f.jslessFail = true
            case "youtube:403": f.youtube403 = true
            case "youtube:botcheck": f.youtubeBotCheck = true
            case "youtube:timeout": f.youtubeTimeout = true
            case "mixcloud:repeat_play": f.mixcloudRepeatPlay = true
            default:
                if item.hasPrefix("resolve:delay="), let s = TimeInterval(item.dropFirst("resolve:delay=".count)),
                   s.isFinite, s > 0, s <= 120 {
                    f.resolveDelay = s
                }
            }
        }
        return f
    }

    /// The failure a fault injects for `request` at `tier`, if any (classified from yt-dlp's real messages).
    public func injectedFailure(_ request: ResolveRequest, tier: ResolveTier) -> ResolveFailure? {
        let platform = request.source.platform
        let id = request.url.lastPathComponent
        var stderr: String?
        var timedOut = false
        if platform == .youtube {
            if youtubeBotCheck {
                stderr = "ERROR: [youtube] \(id): Sign in to confirm you\u{2019}re not a bot. Use --cookies-from-browser or "
                    + "--cookies for the authentication."
            } else if youtube403 {
                stderr = "ERROR: [youtube] \(id): Unable to download webpage: HTTP Error 403: Forbidden "
                    + "(caused by <HTTPError 403: Forbidden>)"
            } else if youtubeTimeout {
                timedOut = true
                stderr = ""
            } else if jslessFail, tier == .jsless {
                return ResolveFailure(.engine, "faultJSLess", message: "SUDAMP_FAULT=youtube:jsless-fail", tier: tier.rawValue)
            }
        } else if platform == .mixcloud, mixcloudRepeatPlay {
            stderr = "ERROR: [mixcloud] \(id): You have reached your play limit for this track"
        }
        guard let stderr else { return nil }
        var f = ResolveErrorClassifier.classify(stderr: stderr, termination: .exited(1), timedOut: timedOut,
                                                tier: tier.rawValue,
                                                elapsedMs: timedOut ? Double(ResolverSettings.standard.timeout(for: tier).components.seconds) * 1000 : 0)
        f.message = "SUDAMP_FAULT: " + f.message
        return f
    }
}

/// `<profile>/resolver.json`: the Resolver's persisted local adaptations.
public struct ResolverState: Sendable, Equatable, Codable {
    public static let currentVersion = 1
    public var version = ResolverState.currentVersion
    public var tier = TierAdaptation()
    /// YouTube is paused after a bot check or 429 until this time: at least 6 h at once, extended by the source
    /// breaker's 6 → 12 → 24 h schedule (`blockPlatform`, DESIGN §6.4).
    public var youtubeBlockedUntil: Date?
    /// The shared YouTube token bucket (M6: persisted, so a relaunch doesn't hand out a fresh burst).
    public var bucket: TokenBucket?

    public init() {}
}

/// Composes the YouTube token bucket, the resolution cache, `available_at`, the JS ladder with its 24 h local
/// adaptation, the bot-check pause, the system proxy and the range-GET probe over one `ResolveBackend`
/// (DESIGN §6.2, §6.3). Concurrent requests for the same stream share one yt-dlp run.
public actor StreamResolver: StreamResolving {
    /// DESIGN §6.4: "YouTube degraded 6 h" after a bot check (M6 escalates to 12 h and 24 h).
    public static let botCheckPause: TimeInterval = 6 * 3600

    private let backend: any ResolveBackend
    private let time: any TimeSource
    private let stateFile: URL?
    private let probe: (any MediaProbing)?
    private let metrics: MetricsLog?
    private let faults: ResolverFaults
    private let proxyProvider: @Sendable () -> URL?
    private let log = Log.logger("resolver")

    private var bucket: TokenBucket
    private var cache = ResolutionCache()
    private var state: ResolverState
    private var engineReady = false
    private var lastProxy: URL??

    private struct Flight {
        let task: Task<StreamResolution, any Error>
        var waiters: Int
    }

    private var flights: [StreamID: Flight] = [:]

    /// - Parameters:
    ///   - stateFile: `resolver.json` (tier preference, bot-check pause); nil keeps state in memory.
    ///   - proxyProvider: read before every resolve (DESIGN §6.2); defaults to `SystemProxy.current()`.
    public init(backend: any ResolveBackend, time: any TimeSource = SystemTimeSource(), stateFile: URL? = nil,
                probe: (any MediaProbing)? = nil, metrics: MetricsLog? = nil, faults: ResolverFaults = .none,
                proxyProvider: @escaping @Sendable () -> URL? = { SystemProxy.current().url }) {
        self.backend = backend
        self.time = time
        self.stateFile = stateFile
        self.probe = probe
        self.metrics = metrics
        self.faults = faults
        self.proxyProvider = proxyProvider
        let loaded = stateFile.flatMap(Self.loadState) ?? ResolverState()
        state = loaded
        bucket = Self.restoredBucket(loaded.bucket, now: time.now)
    }

    /// The saved bucket, unless the clock went backwards past its anchor (then it counts from now, keeping only the
    /// tokens it had, so a clock change never mints a burst).
    static func restoredBucket(_ saved: TokenBucket?, now: Date) -> TokenBucket {
        guard let saved else { return TokenBucket(now: now) }
        if saved.anchor > now { return TokenBucket(now: now, tokens: saved.tokens) }
        return saved
    }

    // MARK: StreamResolving

    public func setEngineConfig(_ engine: EngineConfig) async {
        let rejected = await backend.setSettings(ResolverSettings(engine: engine))
        if !rejected.isEmpty { Log.logger("resolver").warning("feed engine values rejected: \(rejected, privacy: .public)") }
    }

    public func setEngine(_ executable: URL?) async {
        engineReady = executable != nil
        await backend.setEngine(executable)
    }

    public func cached(_ id: StreamID) -> ResolvedStream? { cache.lookup(id, now: time.now) }

    public func status() async -> ResolverStatus {
        let now = time.now
        return ResolverStatus(youtubeTokens: bucket.available(now: now), readyIDs: cache.readyIDs(now: now),
                              cachedIDs: cache.validIDs(now: now), openSources: openSources(now: now),
                              preferTier2Until: state.tier.prefersTier2(now: now) ? state.tier.preferTier2Until : nil,
                              engineReady: engineReady, quickJS: await backend.hasQuickJS())
    }

    public func networkPathChanged() -> [StreamID] {
        let dropped = cache.networkPathChanged()
        if !dropped.isEmpty {
            log.info("network path changed: dropped \(dropped.count) YouTube resolution(s)")
            metrics?.record("cache.drop", ["reason": "networkPath", "count": dropped.count])
        }
        return dropped
    }

    public func evict(_ id: StreamID) { cache.remove(id) }

    public func blockPlatform(_ platform: SourceKind, until: Date) async {
        guard platform.platform == .youtube, until > time.now else { return }
        guard until > (state.youtubeBlockedUntil ?? .distantPast) else { return }
        state.youtubeBlockedUntil = until
        log.notice("YouTube paused until \(until, privacy: .public) (source breaker)")
        saveState()
    }

    public func warmUp(version: String?) async -> EngineWarmUp? {
        guard engineReady else { return nil }
        return await backend.warmUp(version: version)
    }

    public func spendToken(for purpose: ResolvePurpose) async -> Bool {
        if let until = state.youtubeBlockedUntil, time.now < until { return false }
        guard bucket.spend(for: purpose, now: time.now) else { return false }
        state.bucket = bucket
        saveState()
        return true
    }

    public func clearCache() { cache.removeAll() }

    /// The persisted adaptation state (for debug output and tests).
    public var persistedState: ResolverState { state }

    public func resolve(_ stream: StreamRef, purpose: ResolvePurpose) async throws -> StreamResolution {
        guard stream.source.needsResolver else { throw StreamResolveError.notResolvable(stream.source) }
        let now = time.now
        cache.prune(now: now)
        if let hit = cache.lookup(stream.id, now: now) {
            return StreamResolution(stream: hit, fromCache: true, tier: ResolveTier(rawValue: hit.tier) ?? .jsless,
                                    elapsedMs: 0, availability: .of(hit, now: now))
        }
        if var flight = flights[stream.id] {
            flight.waiters += 1
            flights[stream.id] = flight
            return try await join(stream.id, flight.task)
        }
        // Refusals happen here, synchronously, so a refused request never starts a flight.
        guard engineReady else { throw StreamResolveError.engineMissing }
        let isYouTube = stream.source.platform == .youtube
        if isYouTube {
            if let until = state.youtubeBlockedUntil, now < until { throw StreamResolveError.sourceBlocked(.youtube, until: until) }
            guard bucket.spend(for: purpose, now: now) else { throw StreamResolveError.noToken(purpose) }
            persistBucket()
        }
        let task = Task { try await self.perform(stream, purpose: purpose) }
        flights[stream.id] = Flight(task: task, waiters: 1)
        return try await join(stream.id, task)
    }

    // MARK: Flights

    /// Waits for a shared resolve. A cancelled waiter leaves; the last one to leave kills yt-dlp.
    private func join(_ id: StreamID, _ task: Task<StreamResolution, any Error>) async throws -> StreamResolution {
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            Task { await self.abandon(id, task) }
        }
        finish(id, task)
        return try result.get()
    }

    private func abandon(_ id: StreamID, _ task: Task<StreamResolution, any Error>) {
        guard var flight = flights[id], flight.task == task else { return }
        flight.waiters -= 1
        if flight.waiters <= 0 {
            flights[id] = nil
            task.cancel()
        } else {
            flights[id] = flight
        }
    }

    private func finish(_ id: StreamID, _ task: Task<StreamResolution, any Error>) {
        if let flight = flights[id], flight.task == task { flights[id] = nil }
    }

    // MARK: The resolve itself

    private func perform(_ stream: StreamRef, purpose: ResolvePurpose) async throws -> StreamResolution {
        let isYouTube = stream.source.platform == .youtube
        await refreshProxy()
        let request = ResolveRequest(source: stream.source, url: stream.url)
        let priority = purpose.priority
        let quickJS = await backend.hasQuickJS()
        let before = state.tier
        state.tier.expire(now: time.now)
        if state.tier != before { saveState() }
        let startTier: ResolveTier = isYouTube && quickJS ? state.tier.startTier(now: time.now) : .jsless
        var tier = startTier
        var steppedUp = false
        let outcome: ResolveOutcome
        do {
            outcome = try await run(request, tier: startTier, priority: priority)
            if isYouTube && startTier == .jsless && state.tier.rescuedFailures > 0 {
                state.tier.recordTier1Success()
                saveState()
            }
        } catch let failure as ResolveFailure
            where isYouTube && startTier == .jsless && failure.failureClass == .engine && quickJS {
            // JS ladder step-up: a second YouTube request, so it needs its own token.
            guard bucket.spend(for: .retry, now: time.now) else {
                note(failure, stream)
                throw failure
            }
            persistBucket()
            log.info("tier 1 failed (\(failure.reason, privacy: .public)); stepping up to QuickJS")
            steppedUp = true
            tier = .quickjs
            do {
                outcome = try await run(request, tier: .quickjs, priority: priority)
            } catch let second as ResolveFailure {
                note(second, stream)
                throw second
            }
            let adapted = state.tier.recordStepUp(tier2Succeeded: true, now: time.now)
            metrics?.record("tier.stepUp", ["streamId": stream.id.rawValue, "source": stream.source.rawValue,
                                            "adapted": adapted, "rescued": state.tier.rescuedFailures])
            if adapted {
                log.notice("two tier-1 failures rescued by tier 2: YouTube picks start at tier 2 for 24 h")
                metrics?.record("tier.adapt", ["until": state.tier.preferTier2Until?.timeIntervalSince1970 ?? 0])
            }
            saveState()
        } catch let failure as ResolveFailure where failure.failureClass == .transient && failure.reason != "timeout"
            && failure.elapsedMs < Self.quickTransientMs {
            // DESIGN §6.4 transient: "retry once". Only quick failures (5xx, a reset, DNS): a timeout already cost
            // the user 10 s, and a second one would leave them in silence for another 10.
            if isYouTube {
                guard bucket.spend(for: .retry, now: time.now) else {
                    note(failure, stream)
                    throw failure
                }
                persistBucket()
            }
            log.info("transient failure (\(failure.reason, privacy: .public)); retrying once")
            metrics?.record("resolve.retry", ["streamId": stream.id.rawValue, "source": stream.source.rawValue,
                                              "reason": failure.reason])
            do {
                outcome = try await run(request, tier: startTier, priority: priority)
            } catch let second as ResolveFailure {
                note(second, stream)
                throw second
            }
        } catch let failure as ResolveFailure {
            note(failure, stream)
            throw failure
        }

        let resolved = outcome.stream
        let now = time.now
        let availability = Availability.of(resolved, now: now)
        cache.insert(resolved, for: stream.id, now: now)
        if purpose == .prefetch, isYouTube, !resolved.isHLS, availability == .now, let probe {
            let result = await probe.probe(resolved, proxy: lastProxy ?? nil)
            switch result {
            case let .ok(status, bytes, ms):
                metrics?.record("probe", ["streamId": stream.id.rawValue, "status": status, "bytes": bytes,
                                          "ms": ms.rounded(), "ok": true])
            case let .forbidden(status):
                metrics?.record("probe", ["streamId": stream.id.rawValue, "status": status, "ok": false])
                cache.remove(stream.id)
                throw ResolveFailure(.engine, "probe403", message: "range GET answered \(status)", tier: tier.rawValue)
            case let .failed(reason):
                // Not proof of a bad URL (the probe has its own timeout); mpv will tell.
                metrics?.record("probe", ["streamId": stream.id.rawValue, "ok": false, "error": reason])
            }
        }
        return StreamResolution(stream: resolved, fromCache: false, tier: tier, elapsedMs: outcome.elapsedMs,
                                availability: availability, steppedUp: steppedUp)
    }

    /// A transient failure faster than this is retried once.
    static let quickTransientMs: Double = 3000

    private func run(_ request: ResolveRequest, tier: ResolveTier, priority: ResolvePriority) async throws -> ResolveOutcome {
        if let injected = faults.injectedFailure(request, tier: tier) {
            try Task.checkCancellation()
            metrics?.record("resolve", ["source": request.source.rawValue, "tier": tier.rawValue, "ok": false,
                                        "class": "\(injected.failureClass.rawValue)/\(injected.reason)", "ms": 0,
                                        "fault": true])
            throw injected
        }
        let started = ContinuousClock.now
        let outcome = try await backend.resolve(request, tier: tier, priority: priority)
        if let delay = faults.resolveDelay {
            // `resolve:delay=<s>`: the result is held until `s` after the start, like a slow yt-dlp.
            let remaining = Duration.milliseconds(Int64(delay * 1000)) - (ContinuousClock.now - started)
            if remaining > .zero {
                metrics?.record("fault.resolveDelay", ["source": request.source.rawValue, "heldMs": remaining.milliseconds.rounded()])
                try await Task.sleep(for: remaining)
            }
        }
        return outcome
    }

    private func persistBucket() {
        state.bucket = bucket
        saveState()
    }

    /// Bot checks and 429s pause YouTube at once (never another request until the pause ends, DESIGN §6.4); the
    /// source breaker then extends the pause along its 6 → 12 → 24 h schedule (`blockPlatform`).
    private func note(_ failure: ResolveFailure, _ stream: StreamRef) {
        guard failure.failureClass == .botCheck, stream.source.platform == .youtube else { return }
        let until = time.now.addingTimeInterval(Self.botCheckPause)
        state.youtubeBlockedUntil = max(state.youtubeBlockedUntil ?? until, until)
        log.error("YouTube bot check (\(failure.reason, privacy: .public)): pausing YouTube until \(until, privacy: .public)")
        metrics?.record("youtube.blocked", ["reason": failure.reason, "until": until.timeIntervalSince1970])
        saveState()
    }

    private func openSources(now: Date) -> Set<SourceKind> {
        if let until = state.youtubeBlockedUntil, now < until { return [.youtube] }
        return []
    }

    private func refreshProxy() async {
        let proxy = proxyProvider()
        guard lastProxy != .some(proxy) else { return }
        lastProxy = .some(proxy)
        await backend.setProxy(proxy)
        if let proxy { log.info("resolver proxy \(proxy.absoluteString, privacy: .public)") }
    }

    // MARK: Persistence

    static func loadState(_ url: URL) -> ResolverState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let s = try? decoder.decode(ResolverState.self, from: data), s.version <= ResolverState.currentVersion else {
            return nil
        }
        return s
    }

    private func saveState() {
        guard let stateFile else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: stateFile, options: .atomic)
        } catch {
            log.error("cannot save \(stateFile.path, privacy: .public): \(error, privacy: .public)")
        }
    }
}
