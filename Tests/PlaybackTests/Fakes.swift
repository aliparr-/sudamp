// SPDX-License-Identifier: GPL-3.0-or-later
import Audio
import Catalog
import Core
import Feeds
import Foundation
import MPV
import Picker
@testable import Resolver
import Synchronization
import Testing
@testable import Playback

let deepHouse = GenreID(rawValue: "deep-house")!
let techno = GenreID(rawValue: "techno")!
let fakeT0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A catalog stream; `n` makes the ref unique.
func stream(_ source: SourceKind, _ n: Int, genre: GenreID = deepHouse) -> StreamRef {
    let ref: String, id: StreamID
    switch source {
    case .youtube: ref = String(format: "VID%08d", n); id = StreamID.make(source: source, ref: ref)!
    case .youtubeLive: ref = "@live\(n)x"; id = StreamID.make(source: source, ref: ref)!
    case .soundcloud: ref = "user/sc\(n)"; id = StreamID.make(source: source, ref: ref)!
    case .mixcloud: ref = "User/mc\(n)"; id = StreamID.make(source: source, ref: ref)!
    case .radio: ref = "https://r\(n).example.com/s"; id = StreamID(rawValue: "radio:r\(n)")!
    }
    return StreamRef(id: id, source: source, ref: ref, kind: .default(for: source), title: "Title \(n)", creator: "Creator",
                     genres: [genre], durationSec: source == .radio ? nil : 3600,
                     homepage: source == .radio ? URL(string: "https://example.com/") : nil)
}

func feed(_ streams: [StreamRef], engine: EngineConfig = .defaults) -> LoadedFeed {
    let doc = FeedDocument(revision: 3, generatedAt: fakeT0, expiresAt: nil,
                           catalog: FeedCatalog(genres: [Genre(id: deepHouse, name: "Deep House", order: 1),
                                                         Genre(id: techno, name: "Techno", order: 2)], streams: streams),
                           engine: engine)
    return LoadedFeed(document: doc, origin: .bundled, url: URL(filePath: "/dev/null"))
}

/// What yt-dlp would have returned for a stream.
func resolution(for s: StreamRef, availableAt: Double? = nil, expires: Double? = nil) -> ResolvedStream {
    let hls = s.source != .youtube
    let host: String = switch s.source {
    case .youtube, .youtubeLive: "rr1---sn-x.googlevideo.com"
    case .soundcloud: "playback.media-streaming.soundcloud.cloud"
    case .mixcloud: "aod.mixcloud.stream"
    case .radio: "radio.example.com"
    }
    return ResolvedStream(source: s.source, tier: 1, url: URL(string: "https://\(host)/\(s.id.ref)\(hls ? ".m3u8" : "")")!,
                          httpHeaders: ["User-Agent": "UA/1", "Accept": "*/*"], userAgent: "UA/1",
                          protocol: hls ? "m3u8_native" : "https", httpChunkSize: hls ? nil : 10_485_760,
                          availableAt: availableAt, expiresAt: expires ?? fakeT0.timeIntervalSince1970 + 6 * 3600,
                          resolvedAt: fakeT0.timeIntervalSince1970, title: s.title, uploader: s.creator)
}

/// A scripted resolver with a simple cache, so the controller is driven without yt-dlp.
actor FakeResolver: StreamResolving {
    enum Script: Sendable {
        case ok(availableAt: Double? = nil)
        case fail(ResolveFailure)
        case refuse(StreamResolveError)
        /// Never answers (until cancelled).
        case hang
    }

    struct Call: Sendable, Equatable {
        var id: StreamID
        var purpose: ResolvePurpose
    }

    private var scripts: [StreamID: Script] = [:]
    private(set) var calls: [Call] = []
    private(set) var cache: [StreamID: ResolvedStream] = [:]
    private(set) var networkChanges = 0
    private(set) var engine: URL?
    private(set) var cancelled = 0
    private(set) var evictions: [StreamID] = []
    private(set) var blocks: [(SourceKind, Date)] = []
    private(set) var tokenSpends: [ResolvePurpose] = []
    /// A stream's second and later fresh resolutions get a new URL (so a re-resolve differs from a cache hit).
    private var serial: [StreamID: Int] = [:]
    var tokens = 3
    let clock: FakeTimeSource

    init(clock: FakeTimeSource) { self.clock = clock }

    func script(_ id: StreamID, _ s: Script) { scripts[id] = s }
    func setTokens(_ n: Int) { tokens = n }

    func resolve(_ stream: StreamRef, purpose: ResolvePurpose) async throws -> StreamResolution {
        calls.append(Call(id: stream.id, purpose: purpose))
        if let hit = cache[stream.id] {
            return StreamResolution(stream: hit, fromCache: true, tier: .jsless, elapsedMs: 0,
                                    availability: .of(hit, now: clock.now))
        }
        switch scripts[stream.id] ?? .ok() {
        case .ok(let availableAt):
            let n = (serial[stream.id] ?? 0) + 1
            serial[stream.id] = n
            var r = resolution(for: stream, availableAt: availableAt)
            if n > 1, var c = URLComponents(url: r.url, resolvingAgainstBaseURL: false) {
                c.queryItems = [URLQueryItem(name: "n", value: String(n))]
                r.url = c.url ?? r.url
            }
            cache[stream.id] = r
            return StreamResolution(stream: r, fromCache: false, tier: .jsless, elapsedMs: 500,
                                    availability: .of(r, now: clock.now))
        case .fail(let f):
            throw f
        case .refuse(let e):
            throw e
        case .hang:
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                cancelled += 1
                throw error
            }
            throw CancellationError()
        }
    }

    func cached(_ id: StreamID) -> ResolvedStream? { cache[id] }

    func status() -> ResolverStatus {
        ResolverStatus(youtubeTokens: tokens, readyIDs: Set(cache.keys), cachedIDs: Set(cache.keys), engineReady: engine != nil)
    }

    func networkPathChanged() -> [StreamID] {
        networkChanges += 1
        let dropped = cache.keys.filter { $0.source.platform == .youtube }
        for id in dropped { cache[id] = nil }
        return dropped
    }

    func evict(_ id: StreamID) {
        evictions.append(id)
        cache[id] = nil
    }

    func blockPlatform(_ platform: SourceKind, until: Date) { blocks.append((platform, until)) }

    private(set) var warmUps = 0
    func warmUp(version: String?) -> EngineWarmUp? {
        warmUps += 1
        return EngineWarmUp(version: version ?? "?", versionMs: 150, ok: true, identifier: "darwin_dir Python 3")
    }

    func spendToken(for purpose: ResolvePurpose) -> Bool {
        tokenSpends.append(purpose)
        guard tokens > 0 else { return false }
        tokens -= 1
        return true
    }
    func clearCache() { cache = [:] }
    func setEngine(_ executable: URL?) { engine = executable }
}

/// Records what the controller asks of the engine; tests emit first audio and end-of-file by hand.
final class FakePlayer: PlayerEngine {
    let events: AsyncStream<PlayerEvent>
    private let continuation: AsyncStream<PlayerEvent>.Continuation
    private(set) var calls: [String] = []
    private(set) var loads: [(id: PlayerLoadID, request: PlayerLoadRequest)] = []
    var startupFailures: [String] = []
    var guardFailuresNow: [String] = []
    var loadError: (any Error)?
    private(set) var isOutputSuspended = false
    private var nextID: UInt64 = 1
    private(set) var volume: Double = -1

    init() { (events, continuation) = AsyncStream.makeStream(of: PlayerEvent.self) }

    func startupGuardFailures() -> [String] { startupFailures }
    func guardFailures() -> [String] { guardFailuresNow }

    func load(_ request: PlayerLoadRequest) throws -> PlayerLoadID {
        if let loadError { throw loadError }
        isOutputSuspended = false
        let id = PlayerLoadID(nextID)
        nextID += 1
        loads.append((id, request))
        calls.append("load")
        return id
    }

    func pause() async { calls.append("pause") }
    func resume(fadeSeconds: Double) {
        isOutputSuspended = false
        calls.append("resume")
    }
    func stop() { calls.append("stop") }
    func setVolume(_ volume: Double) { self.volume = volume }
    func setBalance(_ balance: Double) { calls.append("balance \(balance)") }
    /// Launch fades requested (kept out of `calls`, whose order other tests check).
    private(set) var fades: [Double] = []
    func fadeIn(seconds: Double) { fades.append(seconds) }
    var positionNow = PlayerPosition(timePos: 12, duration: 3600, seekable: true)
    func position() -> PlayerPosition { positionNow }
    /// Seek targets and EQ settings the controller asked for (kept out of `calls`).
    private(set) var seeks: [Double] = []
    private(set) var equalizers: [EQSettings] = []
    func seek(to seconds: Double) { seeks.append(seconds) }
    func applyEqualizer(_ settings: EQSettings) { equalizers.append(settings) }
    var aoErrorCount: Int64 = 0
    func diagnostics() -> PlayerDiagnostics {
        var d = PlayerDiagnostics()
        d.aoErrorCount = aoErrorCount
        return d
    }
    func suspendOutput() {
        isOutputSuspended = true
        calls.append("suspend")
    }
    func shutdown() {
        calls.append("shutdown")
        continuation.finish()
    }

    var lastLoad: (id: PlayerLoadID, request: PlayerLoadRequest)? { loads.last }

    /// The C stamp arrives: "first non-silent sample" of the newest load.
    func emitFirstAudio(_ id: PlayerLoadID? = nil) {
        guard let id = id ?? loads.last?.id else { return }
        continuation.yield(.firstAudio(id, nanos: monotonicNanos()))
    }

    func emitEnd(_ reason: PlayerEndReason, _ id: PlayerLoadID? = nil) {
        guard let id = id ?? loads.last?.id else { return }
        continuation.yield(.ended(id, reason))
    }
}

struct FakeEngines: EngineProviding {
    var ready: Bool
    func readiness() async -> EngineReadiness {
        ready ? .ready(version: "2026.10.21", executable: URL(filePath: "/nonexistent/yt-dlp_macos")) : .missing
    }
    func install(policy: EngineInstallPolicy, progress: @escaping @Sendable (EngineInstallPhase) -> Void) async throws
        -> EngineReadiness {
        progress(.downloading(onDisk: 27, expected: 54))
        return .ready(version: policy.pin?.version ?? "2026.10.21", executable: URL(filePath: "/nonexistent/yt-dlp_macos"))
    }
}

/// An engine store that records update checks and rollbacks (M6).
actor UpdateRecordingEngines: EngineProviding {
    var states: [EngineReadiness]
    private(set) var checks: [EngineUpdateTrigger] = []
    private(set) var installs = 0
    private(set) var repairs = 0
    private(set) var rollbacks = 0
    var installReason: EngineChoice.Reason? = .pin
    /// What `checkForUpdate` answers.
    var outcome: EngineUpdateOutcome.Result = .upToDate
    /// A rollback answers with this (nil: nothing to roll back).
    var rollbackTo: EngineReadiness?
    /// The 2 h floor, as EngineUpdater keeps it.
    private var lastFailureCheck: Date?
    let clock: FakeTimeSource

    static let ready = EngineReadiness.ready(version: "2026.10.21", executable: URL(filePath: "/nonexistent/yt-dlp_macos"))

    init(_ states: [EngineReadiness] = [UpdateRecordingEngines.ready], clock: FakeTimeSource) {
        self.states = states
        self.clock = clock
    }

    func setOutcome(_ r: EngineUpdateOutcome.Result) { outcome = r }
    func setRollback(_ r: EngineReadiness?) { rollbackTo = r }

    func readiness() -> EngineReadiness { states.count > 1 ? states.removeFirst() : states[0] }

    /// What `install` installs (a real store honours the feed's block, so a test may install another version).
    var installVersion = "2026.10.21"
    func setInstallVersion(_ v: String) { installVersion = v }

    func install(policy: EngineInstallPolicy, progress: @escaping @Sendable (EngineInstallPhase) -> Void) async throws
        -> EngineReadiness {
        installs += 1
        let r = EngineReadiness.ready(version: installVersion, executable: URL(filePath: "/nonexistent/\(installVersion)"))
        states = [r]
        return r
    }

    func lastInstallReason() -> EngineChoice.Reason? { installReason }

    func repair(policy: EngineInstallPolicy, progress: @escaping @Sendable (EngineInstallPhase) -> Void) async -> EngineReadiness {
        repairs += 1
        states = [Self.ready]
        return Self.ready
    }

    /// Warm-ups reported by the controller (they run through the resolver).
    private(set) var notedWarmUps: [EngineWarmUp] = []
    func noteWarmUp(_ warm: EngineWarmUp) { notedWarmUps.append(warm) }

    func updateDue(_ trigger: EngineUpdateTrigger) -> Bool {
        guard trigger == .engineFailures else { return true }
        if let last = lastFailureCheck, clock.now.timeIntervalSince(last) < 7200 { return false }
        return true
    }

    func checkForUpdate(_ request: EngineUpdateRequest) -> EngineUpdateOutcome {
        checks.append(request.trigger)
        if request.trigger == .engineFailures { lastFailureCheck = clock.now }
        return EngineUpdateOutcome(trigger: request.trigger, result: outcome, from: "2026.10.21", current: "2026.10.21")
    }

    func rollbackAfterEngineFailures() -> EngineReadiness? {
        guard let r = rollbackTo else { return nil }
        rollbacks += 1
        rollbackTo = nil
        return r
    }
}

/// Redirect answers for the radio walk, by URL (none: no redirect).
final class FakeRedirects: RedirectFetching {
    let map: [String: String]
    let calls = Mutex<[String]>([])
    init(_ map: [String: String] = [:]) { self.map = map }
    func redirectTarget(of url: URL) async throws -> URL? {
        calls.withLock { $0.append(url.absoluteString) }
        return map[url.absoluteString].flatMap(URL.init(string:))
    }
}

/// Public DNS answers for every radio host.
struct FakeHosts: HostResolving {
    var addresses: [IPAddress] = [.v4(0x0102_0304)]
    func addresses(for host: String) async throws -> [IPAddress] { addresses }
}

/// One controller over fakes in a fresh profile.
@MainActor
final class Harness {
    let clock = FakeTimeSource(fakeT0)
    let scheduler: ManualScheduler
    let player = FakePlayer()
    let resolver: FakeResolver
    let network = ManualNetworkPath()
    let root = FileManager.default.temporaryDirectory.appending(path: "playback-\(UUID().uuidString)", directoryHint: .isDirectory)
    var paths: Paths { .profile(root) }
    let metrics: MetricsLog
    private(set) var controller: PlaybackController!

    let redirects: FakeRedirects

    init(_ streams: [StreamRef], engineReady: Bool = true, hosts: any HostResolving = FakeHosts(),
         engines: (any EngineProviding)? = nil, redirects: FakeRedirects = FakeRedirects(),
         engine: EngineConfig = .defaults, configure: (inout PlaybackConfiguration) -> Void = { _ in }) {
        scheduler = ManualScheduler(time: clock)
        resolver = FakeResolver(clock: clock)
        metrics = MetricsLog(url: Paths.profile(root).metricsFile, time: clock)
        self.redirects = redirects
        controller = make(streams, engineReady: engineReady, hosts: hosts, engines: engines, engine: engine,
                          configure: configure)
    }

    func make(_ streams: [StreamRef], engineReady: Bool = true, hosts: any HostResolving = FakeHosts(),
              engines: (any EngineProviding)? = nil, engine: EngineConfig = .defaults,
              configure: (inout PlaybackConfiguration) -> Void = { _ in }) -> PlaybackController {
        var config = PlaybackConfiguration(paths: paths)
        config.writeDebugState = false
        config.assertOnGuardFailure = false
        config.randomSeed = 42
        configure(&config)
        let deps = PlaybackDependencies(feed: feed(streams, engine: engine), resolver: resolver, player: player,
                                        engines: engines ?? FakeEngines(ready: engineReady), network: network,
                                        scheduler: scheduler,
                                        time: clock, metrics: metrics, hosts: hosts, proxy: { .direct },
                                        redirects: redirects)
        return PlaybackController(configuration: config, dependencies: deps)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Waits (real time, briefly) for async hops between the controller, the fakes and their streams.
    func until(_ what: String = "", timeout: Double = 2, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("timed out waiting for \(what)")
    }

    /// Plays `start(genre:)` through to `playing`, returning the stream.
    @discardableResult
    func startPlaying(_ genre: GenreID = deepHouse) async -> StreamRef? {
        await controller.prepare()
        let loadsBefore = player.loads.count
        controller.start(genre: genre)
        await until("load") { player.loads.count > loadsBefore }
        player.emitFirstAudio()
        await until("playing") { controller.phase == .playing }
        return controller.currentStream
    }

    func metricsEvents(_ name: String) -> [[String: Any]] {
        guard let text = try? String(contentsOf: paths.metricsFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }.filter { $0["event"] as? String == name }
    }
}
