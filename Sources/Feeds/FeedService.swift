// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import Synchronization

/// What one refresh did. Every case leaves a valid active document.
public enum FeedRefreshOutcome: Sendable, Equatable, CustomStringConvertible {
    /// 200: a verified, acceptable document was cached (it is active if its revision beats the bundled one).
    case updated(revision: Int)
    /// 304: the cached copy is current; only `fetchedAt` moved.
    case notModified
    /// The server's document was refused; the previous active document stays.
    case rejected(FeedRejection)
    /// No usable response (network, HTTP status, size); the previous active document stays.
    case failed(RemoteFeedError)
    /// The caller's budget ran out first. The fetch continues in the background; `FeedService.onChange` reports a
    /// later change.
    case timedOut
    /// No feed URL or no trusted key: this build plays its bundled (or cached) snapshot only.
    case disabled(String)

    /// `feed.status`'s `outcome` field.
    public var name: String {
        switch self {
        case .updated: "updated"
        case .notModified: "notModified"
        case .rejected: "rejected"
        case .failed: "failed"
        case .timedOut: "timedOut"
        case .disabled: "disabled"
        }
    }

    public var description: String {
        switch self {
        case .updated(let r): "updated to r\(r)"
        case .notModified: "not modified (304)"
        case .rejected(let r): "rejected: \(r)"
        case .failed(let e): "failed: \(e)"
        case .timedOut: "timed out (still fetching in the background)"
        case .disabled(let why): "disabled: \(why)"
        }
    }
}

/// `FeedService.refresh(budget:)`'s answer.
public struct FeedRefreshResult: Sendable {
    /// The document to play from now (bundled, cached or fetched).
    public let active: LoadedFeed
    public let outcome: FeedRefreshOutcome
    /// Whether `active`'s document differs from before the refresh.
    public let changed: Bool
    /// Wall time of the refresh as seen by the caller.
    public let ms: Double
}

/// When the next background refresh is due (DESIGN §7.2: launch, then every 12 h). A failed attempt retries after
/// `retry` instead of waiting the full interval.
public struct FeedSchedule: Sendable, Equatable {
    public var interval: TimeInterval
    public var retry: TimeInterval

    public init(interval: TimeInterval = 12 * 3600, retry: TimeInterval = 3600) {
        self.interval = interval
        self.retry = retry
    }

    /// - Parameters:
    ///   - lastSuccess: the last 200 or 304 (`meta.json`'s `fetchedAt`).
    ///   - lastFailure: the last attempt that produced nothing usable (failed or rejected), this process only.
    public func next(lastSuccess: Date?, lastFailure: Date?, now: Date) -> Date {
        if let lastFailure, lastFailure >= (lastSuccess ?? .distantPast) { return lastFailure.addingTimeInterval(retry) }
        guard let lastSuccess else { return now }
        return lastSuccess.addingTimeInterval(interval)
    }
}

/// How a `FeedService` behaves.
public struct FeedServiceConfiguration: Sendable {
    /// Compared with `engine.minAppVersion`.
    public var appVersion: String
    /// Keys `feed.json.sig` must verify against (cached copies included).
    public var trust: FeedTrust
    /// `<profile>/feed/`; nil keeps nothing between launches.
    public var cache: FeedCache?
    public var schedule: FeedSchedule

    public init(appVersion: String = BuildInfo.version, trust: FeedTrust = .embedded, cache: FeedCache? = nil,
                schedule: FeedSchedule = FeedSchedule()) {
        self.appVersion = appVersion
        self.trust = trust
        self.cache = cache
        self.schedule = schedule
    }
}

/// The feed the app plays from (DESIGN §7.2): the bundled snapshot, a verified cached copy from `<profile>/feed/`,
/// or a freshly fetched signed document, whichever valid one has the highest revision.
///
/// Typical use (Shell): `let feeds = FeedService.live(paths:bundled:metrics:)`; at launch, in parallel with radio,
/// `await feeds.launchRefresh(budget: .seconds(5))` from a launch task and from the engine gate before EngineStore
/// chooses a version (both share one fetch and one budget); then `feeds.runPeriodicRefresh()` in a task cancelled on
/// quit, with `setOnChange` swapping the catalog into the player. Thread-safe; `refresh` is single-flight (a second
/// caller joins the fetch in progress).
public final class FeedService: Sendable {
    public let bundled: LoadedFeed
    public let configuration: FeedServiceConfiguration
    /// Nil: bundled (and cached) only.
    public let client: (any RemoteFeedFetching)?
    private let disabledReason: String?
    private let time: any TimeSource
    private let metrics: MetricsLog?
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let state: Mutex<State>

    private struct State {
        var active: LoadedFeed
        /// The verified cached (or this process's fetched) document, valid or not for selection.
        var cached: LoadedFeed?
        var lastSuccess: Date?
        var lastFailure: Date?
        var lastOutcome: FeedRefreshOutcome?
        var inFlight: Task<FeedRefreshResult, Never>?
        /// This process's launch refresh, when it started, and its result once finished (`launchRefresh`).
        var launch: (task: Task<FeedRefreshResult, Never>, started: ContinuousClock.Instant)?
        var launchResult: FeedRefreshResult?
        /// The launch's `timedOut` line is written once, however many callers waited.
        var launchTimeoutRecorded = false
        var onChange: (@Sendable (LoadedFeed) -> Void)?
    }

    /// Reads and verifies the cache at once, so `active` is the best local document before any network traffic.
    /// - Parameters:
    ///   - client: nil (or an empty trust list) disables fetching.
    ///   - sleeper: how `runPeriodicRefresh` waits (tests pass one that advances a fake clock).
    public init(bundled: LoadedFeed, configuration: FeedServiceConfiguration = FeedServiceConfiguration(),
                client: (any RemoteFeedFetching)? = nil, time: any TimeSource = SystemTimeSource(),
                metrics: MetricsLog? = nil,
                sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(for: .seconds($0))
                }) {
        self.bundled = bundled
        self.configuration = configuration
        self.time = time
        self.metrics = metrics
        self.sleeper = sleeper
        if configuration.trust.isEmpty {
            self.client = nil
            disabledReason = "no trusted feed key in this build"
        } else if client == nil {
            self.client = nil
            disabledReason = "no feed URL"
        } else {
            self.client = client
            disabledReason = nil
        }
        let local = Self.readCache(configuration: configuration, bundled: bundled)
        let candidate = local.map { FeedCandidate(feed: $0.feed, signatureVerified: true) }
        let active = ActiveFeedSelector.select(bundled: bundled, candidates: candidate.map { [$0] } ?? [],
                                               appVersion: configuration.appVersion, now: time.now)
        state = Mutex(State(active: active, cached: local?.feed, lastSuccess: local?.fetchedAt))
        if let candidate, let rejected = ActiveFeedSelector.rejection(of: candidate, appVersion: configuration.appVersion,
                                                                     now: time.now) {
            Log.logger("feed").notice("cached feed not used: \(rejected.description, privacy: .public)")
        }
    }

    /// The app's service for a profile: `<profile>/feed/` as the cache, `FeedEndpoint.resolve` as the URL (the debug
    /// `SUDAMP_FEED_URL`, else the production URL, nil for now) and `FeedTrust.embedded`.
    public static func live(paths: Paths, bundled: LoadedFeed, metrics: MetricsLog?,
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            time: any TimeSource = SystemTimeSource()) -> FeedService {
        let configuration = FeedServiceConfiguration(trust: .embedded, cache: FeedCache(directory: paths.feedDirectory))
        var client: (any RemoteFeedFetching)?
        if let url = FeedEndpoint.resolve(environment: environment) {
            do { client = try RemoteFeedClient(feedURL: url) } catch {
                Log.logger("feed").error("feed URL refused: \(error.description, privacy: .public)")
                metrics?.record("feed.rejected", ["reason": "url", "detail": error.description])
            }
        }
        return FeedService(bundled: bundled, configuration: configuration, client: client, time: time, metrics: metrics)
    }

    /// Only the bundled feed for this process (app resources, else the dev checkout's `catalog/feed.json`).
    public static func bundledOnly(override: URL? = nil, bundle: Bundle = .main) throws(FeedLoadError) -> FeedService {
        FeedService(bundled: try BundledFeed.loadDefault(override: override, bundle: bundle),
                    configuration: FeedServiceConfiguration(cache: nil), client: nil)
    }

    // MARK: State

    /// The document to play from.
    public var active: LoadedFeed { state.withLock { $0.active } }

    /// The verified cached (or fetched) document, whether or not it is active.
    public var cached: LoadedFeed? { state.withLock { $0.cached } }

    /// The last refresh's outcome in this process.
    public var lastOutcome: FeedRefreshOutcome? { state.withLock { $0.lastOutcome } }

    /// Whether this service ever fetches.
    public var isFetching: Bool { client != nil }

    /// Called (on an arbitrary thread) whenever the active document changes, including when a fetch that outlived
    /// its launch budget finishes later.
    public func setOnChange(_ f: (@Sendable (LoadedFeed) -> Void)?) {
        state.withLock { $0.onChange = f }
    }

    /// When the next periodic refresh is due.
    public func nextRefresh() -> Date {
        let (success, failure) = state.withLock { ($0.lastSuccess, $0.lastFailure) }
        return configuration.schedule.next(lastSuccess: success, lastFailure: failure, now: time.now)
    }

    // MARK: Refresh

    /// Fetches, verifies and caches the remote document, waiting at most `budget`. Single-flight: joins a refresh
    /// already in progress. When the budget runs out first, the outcome is `.timedOut`, the active document is
    /// whatever was best locally, and the fetch carries on (its result lands in the cache and `onChange`).
    public func refresh(budget: Duration) async -> FeedRefreshResult {
        let started = ContinuousClock.now
        let task: Task<FeedRefreshResult, Never> = state.withLock { s in
            if let t = s.inFlight { return t }
            let t = Task { await self.performRefresh() }
            s.inFlight = t
            return t
        }
        if let result = await Self.value(of: task, within: budget) { return result }
        return timedOut(started: started, budget: budget)
    }

    /// The answer when the budget ran out first (the fetch carries on).
    private func timedOut(started: ContinuousClock.Instant, budget: Duration, record: Bool = true) -> FeedRefreshResult {
        let active = self.active
        let ms = Self.ms(since: started)
        guard record else { return FeedRefreshResult(active: active, outcome: .timedOut, changed: false, ms: ms) }
        metrics?.record("feed.status", ["status": 0, "outcome": FeedRefreshOutcome.timedOut.name, "ms": ms,
                                        "budgetMs": Self.ms(budget), "activeRevision": active.document.revision,
                                        "activeOrigin": active.origin.rawValue])
        Log.logger("feed").notice("""
            feed refresh exceeded its \(Self.ms(budget)) ms budget; using r\(active.document.revision) \
            (\(active.origin.rawValue, privacy: .public))
            """)
        return FeedRefreshResult(active: active, outcome: .timedOut, changed: false, ms: ms)
    }

    /// The launch refresh (DESIGN §7.2), at most once per process: the first call starts it (or joins a fetch in
    /// progress); every later call (e.g. the engine gate, after the app's launch task) gets the same fetch and its
    /// result, and `budget` counts from the *first* call, so callers never spend two budgets or make two requests.
    /// Read `active` afterwards for the document to use.
    public func launchRefresh(budget: Duration) async -> FeedRefreshResult {
        let (task, started, done): (Task<FeedRefreshResult, Never>, ContinuousClock.Instant, FeedRefreshResult?) =
            state.withLock { s in
                if let l = s.launch { return (l.task, l.started, s.launchResult) }
                let fetch = s.inFlight ?? Task { await self.performRefresh() }
                s.inFlight = fetch
                let wrapper = Task { () -> FeedRefreshResult in
                    let r = await fetch.value
                    self.state.withLock { $0.launchResult = r }
                    return r
                }
                let started = ContinuousClock.now
                s.launch = (wrapper, started)
                return (wrapper, started, nil)
            }
        if let done { return done }
        let remaining = budget - (ContinuousClock.now - started)
        if remaining > .zero, let result = await Self.value(of: task, within: remaining) { return result }
        let first = state.withLock { s in
            defer { s.launchTimeoutRecorded = true }
            return !s.launchTimeoutRecorded
        }
        return timedOut(started: started, budget: budget, record: first)
    }

    /// Refreshes whenever `nextRefresh()` is due (every 12 h, 1 h after a failure) until the calling task is
    /// cancelled. Waits in steps of at most 15 minutes so clock changes and sleep/wake are noticed.
    public func runPeriodicRefresh(budget: Duration = .seconds(60), maxStep: TimeInterval = 900) async {
        guard client != nil else { return }
        while !Task.isCancelled {
            let wait = nextRefresh().timeIntervalSince(time.now)
            if wait > 0 {
                do { try await sleeper(min(wait, maxStep)) } catch { return }
                continue
            }
            _ = await refresh(budget: budget)
        }
    }

    private func performRefresh() async -> FeedRefreshResult {
        let started = ContinuousClock.now
        let before = active
        let outcome: FeedRefreshOutcome
        var status = 0
        if let client {
            (outcome, status) = await fetchAndApply(client, started: started)
        } else {
            outcome = .disabled(disabledReason ?? "disabled")
        }
        // Re-choose even when nothing was fetched: an active cached copy may have passed its `expiresAt` while the
        // host was unreachable (expired cached → bundled).
        reselect { _ in }
        let (after, onChange) = state.withLock { s in
            s.lastOutcome = outcome
            s.inFlight = nil
            return (s.active, s.onChange)
        }
        let changed = after.document != before.document
        let ms = Self.ms(since: started)
        var fields: [String: any Sendable] = ["status": status, "outcome": outcome.name, "ms": ms, "changed": changed,
                                              "activeRevision": after.document.revision,
                                              "activeOrigin": after.origin.rawValue]
        if case .failed(let e) = outcome { fields["error"] = e.description }
        if case .disabled(let why) = outcome { fields["reason"] = why }
        if case .rejected(let r) = outcome { fields["reason"] = r.reason }
        metrics?.record("feed.status", fields)
        Log.logger("feed").info("""
            feed refresh \(outcome.description, privacy: .public) in \(Int(ms)) ms; active \
            r\(after.document.revision) (\(after.origin.rawValue, privacy: .public))
            """)
        if changed { onChange?(after) }
        return FeedRefreshResult(active: after, outcome: outcome, changed: changed, ms: ms)
    }

    /// One conditional fetch and its consequences; returns the outcome and the HTTP status (0 when none).
    private func fetchAndApply(_ client: any RemoteFeedFetching,
                               started: ContinuousClock.Instant) async -> (FeedRefreshOutcome, Int) {
        let cachedBefore = cached
        let etag = cachedBefore != nil ? configuration.cache?.readMeta()?.etag : nil
        let result: RemoteFeedFetchResult
        do {
            result = try await client.fetch(ifNoneMatch: etag)
        } catch {
            state.withLock { $0.lastFailure = time.now }
            Log.logger("feed").error("feed fetch failed: \(error.description, privacy: .public)")
            return (.failed(error), error.httpStatus)
        }
        let now = time.now
        switch result {
        case .notModified:
            try? configuration.cache?.touch(fetchedAt: now)
            reselect { $0.lastSuccess = now }
            metrics?.record("feed.fetched", ["status": 304, "ms": Self.ms(since: started), "bytes": 0,
                                             "revision": cachedBefore?.document.revision ?? -1,
                                             "url": client.feedURL.absoluteString])
            return (.notModified, 304)
        case .fetched(let response):
            switch evaluate(response, client: client, floor: cachedBefore?.document.revision, now: now) {
            case .failure(let rejection):
                state.withLock { $0.lastFailure = now }
                var fields: [String: any Sendable] = ["reason": rejection.reason, "detail": rejection.description,
                                                      "status": 200, "bytes": response.body.count,
                                                      "url": client.feedURL.absoluteString]
                if let r = Self.peekRevision(response.body) { fields["revision"] = r }
                metrics?.record("feed.rejected", fields)
                Log.logger("feed").error("fetched feed rejected: \(rejection.description, privacy: .public)")
                return (.rejected(rejection), 200)
            case .success(let (feed, key)):
                let revision = feed.document.revision
                do {
                    let meta = FeedCache.Meta(etag: response.etag, fetchedAt: now, revision: revision)
                    try configuration.cache?.store(body: response.body, signature: response.signature, meta: meta)
                } catch {
                    Log.logger("feed").error("feed cache not written: \(error.localizedDescription, privacy: .public)")
                }
                reselect { s in
                    s.cached = feed
                    s.lastSuccess = now
                }
                metrics?.record("feed.fetched", ["status": 200, "ms": Self.ms(since: started), "revision": revision,
                                                 "bytes": response.body.count, "keyID": key.keyID,
                                                 "etag": response.etag != nil, "warnings": feed.warnings.count,
                                                 "url": client.feedURL.absoluteString])
                for w in feed.warnings { Log.logger("feed").warning("fetched feed: \(w, privacy: .public)") }
                return (.updated(revision: revision), 200)
            }
        }
    }

    /// Signature, envelope and selection rules for a fetched body (DESIGN §7.2). Engine strings are validated over
    /// the active document's values, so a failing value keeps the value in use.
    private func evaluate(_ response: RemoteFeedResponse, client: any RemoteFeedFetching, floor: Int?,
                          now: Date) -> Result<(LoadedFeed, FeedPublicKey), FeedRejection> {
        guard let key = FeedSignature.verify(response.signature, of: response.body, trust: configuration.trust) else {
            return .failure(.signature)
        }
        let feed: LoadedFeed
        do {
            feed = try BundledFeed.load(data: response.body, url: configuration.cache?.feedFile ?? client.feedURL,
                                        origin: .fetched, previousEngine: active.document.engine)
        } catch {
            return .failure(.invalid(error.description))
        }
        if let r = ActiveFeedSelector.rejection(of: FeedCandidate(feed: feed, signatureVerified: true),
                                                appVersion: configuration.appVersion, now: now, minimumRevision: floor) {
            return .failure(r)
        }
        return .success((feed, key))
    }

    /// Applies `update`, then re-chooses the active document from the bundled and cached ones.
    private func reselect(_ update: (inout State) -> Void) {
        let now = time.now
        state.withLock { s in
            update(&s)
            let candidates = s.cached.map { [FeedCandidate(feed: $0, signatureVerified: true)] } ?? []
            s.active = ActiveFeedSelector.select(bundled: bundled, candidates: candidates,
                                                 appVersion: configuration.appVersion, now: now)
        }
    }

    // MARK: Helpers

    /// The verified cached document and its `fetchedAt`, or nil (missing, unverifiable or undecodable copies are
    /// ignored, not deleted: another build with other keys may share the profile).
    private static func readCache(configuration: FeedServiceConfiguration,
                                  bundled: LoadedFeed) -> (feed: LoadedFeed, fetchedAt: Date)? {
        guard let cache = configuration.cache, let entry = cache.read() else { return nil }
        let log = Log.logger("feed")
        guard FeedSignature.verify(entry.signature, of: entry.body, trust: configuration.trust) != nil else {
            log.notice("cached feed ignored: its signature does not verify against this build's keys")
            return nil
        }
        do {
            let feed = try BundledFeed.load(data: entry.body, url: cache.feedFile, origin: .cached,
                                            previousEngine: bundled.document.engine)
            return (feed, entry.meta.fetchedAt)
        } catch {
            log.notice("cached feed ignored: \(error.description, privacy: .public)")
            return nil
        }
    }

    /// The `revision` of a document that was refused, for the metrics line (best effort).
    private static func peekRevision(_ body: Data) -> Int? {
        guard body.count <= RemoteFeedClient.defaultMaxBytes, let root = try? JSONValue.parse(body) else { return nil }
        return root["revision"]?.intValue
    }

    /// Waits for `task` at most `budget`; nil if the budget ran out first (the task keeps running).
    static func value<T: Sendable>(of task: Task<T, Never>, within budget: Duration) async -> T? {
        let once = ResumeOnce<T?>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            once.set(continuation)
            let timer = Task {
                // An explicit tolerance: the default leeway let a 5 s budget run 265 ms late [measured].
                try? await Task.sleep(for: budget, tolerance: .milliseconds(5))
                once.resume(nil)
            }
            Task {
                let v = await task.value
                timer.cancel()
                once.resume(v)
            }
        }
    }

    static func ms(since start: ContinuousClock.Instant) -> Double { ms(ContinuousClock.now - start) }

    static func ms(_ d: Duration) -> Double {
        let c = d.components
        return (Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15).rounded()
    }
}

/// A continuation resumed by whichever of two racers finishes first.
private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<T, Never>?>(nil)

    func set(_ c: CheckedContinuation<T, Never>) { continuation.withLock { $0 = c } }

    func resume(_ value: T) {
        let c = continuation.withLock { c in
            defer { c = nil }
            return c
        }
        c?.resume(returning: value)
    }
}
