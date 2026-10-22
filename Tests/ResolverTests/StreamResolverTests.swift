// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import Synchronization
import Testing
@testable import Resolver

/// A scripted yt-dlp backend: per URL and tier, a stream or a classified failure, optionally after a delay.
actor FakeBackend: ResolveBackend {
    enum Script: Sendable {
        case ok(ResolvedStream)
        case fail(ResolveFailure)
    }

    struct Call: Sendable, Equatable {
        var url: String
        var tier: ResolveTier
        var priority: ResolvePriority
    }

    private var scripts: [String: [ResolveTier: Script]] = [:]
    private(set) var calls: [Call] = []
    private(set) var proxies: [URL?] = []
    private(set) var engine: URL?
    private(set) var cancellations = 0
    var quickJS: Bool
    var delay: Duration = .zero

    init(quickJS: Bool = true) { self.quickJS = quickJS }

    func script(_ url: URL, _ tier: ResolveTier, _ s: Script) { scripts[url.absoluteString, default: [:]][tier] = s }
    func setDelay(_ d: Duration) { delay = d }

    func resolve(_ request: ResolveRequest, tier: ResolveTier, priority: ResolvePriority) async throws -> ResolveOutcome {
        calls.append(Call(url: request.url.absoluteString, tier: tier, priority: priority))
        guard engine != nil else { throw ResolverError.engineMissing }
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch {
                cancellations += 1
                throw error
            }
        }
        let script = scripts[request.url.absoluteString]?[tier]
            ?? .ok(resolvedStream(request.source, resolvedAt: cacheT0, expires: cacheT0 + 6 * 3600,
                                  hls: request.source != .youtube, tier: tier.rawValue))
        switch script {
        case .ok(var s):
            s.tier = tier.rawValue
            return ResolveOutcome(stream: s, elapsedMs: 100, warnings: [])
        case .fail(var f):
            f.tier = tier.rawValue
            throw f
        }
    }

    func setEngine(_ url: URL?) { engine = url }
    func setProxy(_ url: URL?) { proxies.append(url) }
    func hasQuickJS() -> Bool { quickJS }
}

/// A probe that answers with a fixed result and counts calls.
final class FakeProbe: MediaProbing {
    let result: MediaProbeResult
    let calls = Mutex(0)
    init(_ result: MediaProbeResult) { self.result = result }
    func probe(_ stream: ResolvedStream, proxy: URL?) async -> MediaProbeResult {
        calls.withLock { $0 += 1 }
        return result
    }
}

func ref(_ source: SourceKind, _ n: Int) -> StreamRef {
    let r: String, id: StreamID
    switch source {
    case .youtube: r = String(format: "VID%08d", n); id = StreamID.make(source: source, ref: r)!
    case .youtubeLive: r = "@live\(n)x"; id = StreamID.make(source: source, ref: r)!
    case .soundcloud: r = "user/sc\(n)"; id = StreamID.make(source: source, ref: r)!
    case .mixcloud: r = "User/mc\(n)"; id = StreamID.make(source: source, ref: r)!
    case .radio: r = "https://r\(n).example.com/s"; id = StreamID(rawValue: "radio:r\(n)")!
    }
    return StreamRef(id: id, source: source, ref: r, kind: .default(for: source), title: "T\(n)", creator: "C",
                     genres: [GenreID(rawValue: "deep-house")!], homepage: source == .radio ? URL(string: "https://example.com/") : nil)
}

@Suite struct StreamResolverTests {
    let clock = FakeTimeSource(Date(timeIntervalSince1970: cacheT0))
    let engine = URL(filePath: "/nonexistent/yt-dlp_macos")
    let dir = FileManager.default.temporaryDirectory.appending(path: "streamresolver-\(UUID().uuidString)")

    func make(_ backend: FakeBackend, stateFile: URL? = nil, probe: (any MediaProbing)? = nil,
              faults: ResolverFaults = .none, proxy: @escaping @Sendable () -> URL? = { nil }) async -> StreamResolver {
        let r = StreamResolver(backend: backend, time: clock, stateFile: stateFile, probe: probe, faults: faults,
                               proxyProvider: proxy)
        await r.setEngine(engine)
        return r
    }

    @Test func radioAndMissingEngineAreRefused() async throws {
        let backend = FakeBackend()
        let r = StreamResolver(backend: backend, time: clock, proxyProvider: { nil })
        await #expect(throws: StreamResolveError.notResolvable(.radio)) { try await r.resolve(ref(.radio, 1), purpose: .userPick) }
        await #expect(throws: StreamResolveError.engineMissing) { try await r.resolve(ref(.soundcloud, 1), purpose: .userPick) }
        #expect(await backend.calls.isEmpty)
    }

    @Test func cacheHitsSkipYtDlp() async throws {
        let backend = FakeBackend()
        let r = await make(backend)
        let s = ref(.soundcloud, 1)
        let first = try await r.resolve(s, purpose: .prefetch)
        #expect(!first.fromCache && first.availability == .now)
        let second = try await r.resolve(s, purpose: .userPick)
        #expect(second.fromCache && second.stream == first.stream)
        #expect(await backend.calls.count == 1)
        #expect(await r.status().readyIDs == [s.id])
        await r.evict(s.id)
        #expect(await r.cached(s.id) == nil)
    }

    @Test func youTubeSpendsTokensOthersDont() async throws {
        let backend = FakeBackend()
        let r = await make(backend)
        for n in 1...5 { _ = try await r.resolve(ref(.soundcloud, n), purpose: .userPick) }
        #expect(await r.status().youtubeTokens == 3)
        _ = try await r.resolve(ref(.youtube, 1), purpose: .userPick)
        _ = try await r.resolve(ref(.youtubeLive, 1), purpose: .prefetch)
        #expect(await r.status().youtubeTokens == 1)
        await #expect(throws: StreamResolveError.noToken(.hover)) { try await r.resolve(ref(.youtube, 2), purpose: .hover) }
        _ = try await r.resolve(ref(.youtube, 3), purpose: .userPick)
        await #expect(throws: StreamResolveError.noToken(.userPick)) { try await r.resolve(ref(.youtube, 4), purpose: .userPick) }
        #expect(await backend.calls.count == 8, "refused requests never reach yt-dlp")
        // Cached YouTube needs no token.
        _ = try await r.resolve(ref(.youtube, 1), purpose: .userPick)
        clock.advance(by: 30)
        _ = try await r.resolve(ref(.youtube, 4), purpose: .userPick)
    }

    @Test func tier2StepUpAndThe24HourPreference() async throws {
        let backend = FakeBackend()
        let state = dir.appending(path: "resolver.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = await make(backend, stateFile: state)
        let jsFail = ResolveFailure(.engine, "challenge", message: "n challenge solving failed")
        for n in 1...3 { await backend.script(ref(.youtube, n).url, .jsless, .fail(jsFail)) }

        let a = try await r.resolve(ref(.youtube, 1), purpose: .userPick)
        #expect(a.steppedUp && a.tier == .quickjs)
        #expect(await r.status().preferTier2Until == nil, "one rescue isn't enough")
        clock.advance(by: 60)
        let b = try await r.resolve(ref(.youtube, 2), purpose: .userPick)
        #expect(b.steppedUp)
        let until = try #require(await r.status().preferTier2Until)
        #expect(until == clock.now.addingTimeInterval(24 * 3600))
        #expect(await backend.calls.map(\.tier) == [.jsless, .quickjs, .jsless, .quickjs])

        clock.advance(by: 60)
        let c = try await r.resolve(ref(.youtube, 3), purpose: .userPick)
        #expect(c.tier == .quickjs && !c.steppedUp, "picks start at tier 2 now")
        #expect(await backend.calls.last?.tier == .quickjs)

        // Persisted and reloaded: a new resolver (a relaunch) still starts at tier 2 within the window …
        let relaunched = await make(backend, stateFile: state)
        clock.advance(by: 23 * 3600)
        _ = try await relaunched.resolve(ref(.youtube, 4), purpose: .userPick)
        #expect(await backend.calls.last?.tier == .quickjs)
        // … and at tier 1 beyond 24 h.
        clock.advance(by: 3600)
        _ = try await relaunched.resolve(ref(.youtube, 5), purpose: .userPick)
        #expect(await backend.calls.last?.tier == .jsless)
        #expect(await relaunched.status().preferTier2Until == nil)
    }

    @Test func noStepUpWithoutQuickJSOrForOtherClasses() async throws {
        let backend = FakeBackend(quickJS: false)
        let r = await make(backend)
        await backend.script(ref(.youtube, 1).url, .jsless, .fail(ResolveFailure(.engine, "formatUnavailable")))
        await #expect(throws: ResolveFailure.self) { try await r.resolve(ref(.youtube, 1), purpose: .userPick) }
        #expect(await backend.calls.map(\.tier) == [.jsless])

        let withQJS = FakeBackend()
        let r2 = await make(withQJS)
        await withQJS.script(ref(.youtube, 2).url, .jsless, .fail(ResolveFailure(.unavailable, "private")))
        await #expect(throws: ResolveFailure.self) { try await r2.resolve(ref(.youtube, 2), purpose: .userPick) }
        #expect(await withQJS.calls.map(\.tier) == [.jsless], "unavailable never costs a second request")
        await withQJS.script(ref(.soundcloud, 1).url, .jsless, .fail(ResolveFailure(.engine, "unknown")))
        await #expect(throws: ResolveFailure.self) { try await r2.resolve(ref(.soundcloud, 1), purpose: .userPick) }
        #expect(await withQJS.calls.count == 2, "the JS ladder is YouTube-only")
    }

    @Test func stepUpNeedsItsOwnToken() async throws {
        let backend = FakeBackend()
        let r = await make(backend)
        let jsFail = ResolveFailure(.engine, "challenge")
        for n in 1...3 { await backend.script(ref(.youtube, n).url, .jsless, .fail(jsFail)) }
        _ = try await r.resolve(ref(.youtube, 1), purpose: .userPick)   // 2 tokens
        await #expect(throws: ResolveFailure.self) { try await r.resolve(ref(.youtube, 2), purpose: .userPick) }
        #expect(await backend.calls.count == 3, "third token spent on tier 1; no token left for tier 2")
    }

    @Test func faultInjectionFailsTier1WithoutYtDlp() async throws {
        let backend = FakeBackend()
        let r = await make(backend, faults: ResolverFaults(jslessFail: true))
        let out = try await r.resolve(ref(.youtube, 1), purpose: .userPick)
        #expect(out.steppedUp && out.tier == .quickjs)
        #expect(await backend.calls.map(\.tier) == [.quickjs])
        _ = try await r.resolve(ref(.soundcloud, 1), purpose: .userPick)
        #expect(await backend.calls.last?.tier == .jsless, "other sources are unaffected")
        #if DEBUG
        #expect(ResolverFaults.from(environment: ["SUDAMP_FAULT": "net:offline,youtube:jsless-fail"]).jslessFail)
        #endif
        #expect(!ResolverFaults.from(environment: [:]).jslessFail)
    }

    @Test func botCheckPausesYouTubeForSixHours() async throws {
        let backend = FakeBackend()
        let r = await make(backend)
        await backend.script(ref(.youtube, 1).url, .jsless, .fail(ResolveFailure(.botCheck, "notABot")))
        await #expect(throws: ResolveFailure.self) { try await r.resolve(ref(.youtube, 1), purpose: .userPick) }
        #expect(await r.status().openSources == [.youtube])
        await #expect(throws: StreamResolveError.self) { try await r.resolve(ref(.youtubeLive, 2), purpose: .userPick) }
        _ = try await r.resolve(ref(.mixcloud, 1), purpose: .userPick)
        #expect(await backend.calls.count == 2, "no YouTube request after the bot check")
        clock.advance(by: 6 * 3600)
        #expect(await r.status().openSources.isEmpty)
        _ = try await r.resolve(ref(.youtube, 3), purpose: .userPick)
    }

    @Test func availableAtIsReported() async throws {
        let backend = FakeBackend()
        let r = await make(backend)
        let soon = ref(.youtube, 1), late = ref(.youtube, 2)
        await backend.script(soon.url, .jsless, .ok(resolvedStream(.youtube, expires: cacheT0 + 6 * 3600, availableAt: cacheT0 + 2)))
        await backend.script(late.url, .jsless, .ok(resolvedStream(.youtube, expires: cacheT0 + 6 * 3600, availableAt: cacheT0 + 25)))
        #expect(try await r.resolve(soon, purpose: .userPick).availability == .wait(2))
        #expect(try await r.resolve(late, purpose: .userPick).availability == .deferred(25))
        // The deferred one is kept: once its time comes it is ready without another request.
        clock.advance(by: 25)
        let again = try await r.resolve(late, purpose: .userPick)
        #expect(again.fromCache && again.availability == .now)
        #expect(await backend.calls.count == 2)
    }

    @Test func networkChangeDropsYouTubeResolutions() async throws {
        let backend = FakeBackend()
        let r = await make(backend)
        let yt = ref(.youtube, 1), sc = ref(.soundcloud, 1)
        _ = try await r.resolve(yt, purpose: .prefetch)
        _ = try await r.resolve(sc, purpose: .prefetch)
        #expect(await r.networkPathChanged() == [yt.id])
        #expect(await r.status().cachedIDs == [sc.id])
        #expect(try await !r.resolve(yt, purpose: .userPick).fromCache)
    }

    @Test func concurrentRequestsShareOneRun() async throws {
        let backend = FakeBackend()
        await backend.setDelay(.milliseconds(100))
        let r = await make(backend)
        let s = ref(.youtube, 1)
        async let a = r.resolve(s, purpose: .prefetch)
        try await Task.sleep(for: .milliseconds(20))
        async let b = r.resolve(s, purpose: .userPick)
        let (x, y) = try await (a, b)
        #expect(x.stream == y.stream)
        #expect(await backend.calls.count == 1)
        #expect(await r.status().youtubeTokens == 2, "one token for both")
    }

    @Test func cancellingTheOnlyWaiterKillsTheRun() async throws {
        let backend = FakeBackend()
        await backend.setDelay(.seconds(5))
        let r = await make(backend)
        let task = Task { try await r.resolve(ref(.soundcloud, 1), purpose: .userPick) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await backend.cancellations == 1)
    }

    @Test func prefetchProbesProgressiveYouTubeOnly() async throws {
        let forbidden = FakeProbe(.forbidden(status: 403))
        let backend = FakeBackend()
        let r = await make(backend, probe: forbidden)
        let yt = ref(.youtube, 1)
        await #expect(throws: ResolveFailure.self) { try await r.resolve(yt, purpose: .prefetch) }
        #expect(await r.cached(yt.id) == nil, "a 403 evicts the resolution")
        _ = try await r.resolve(ref(.youtube, 2), purpose: .userPick)          // user picks aren't probed
        _ = try await r.resolve(ref(.youtubeLive, 1), purpose: .prefetch)      // HLS isn't probed
        _ = try await r.resolve(ref(.mixcloud, 1), purpose: .prefetch)
        #expect(forbidden.calls.withLock { $0 } == 1)

        let ok = FakeProbe(.ok(status: 206, bytes: 65536, ms: 40))
        let r2 = await make(FakeBackend(), probe: ok)
        #expect(try await !r2.resolve(ref(.youtube, 3), purpose: .prefetch).fromCache)
        #expect(ok.calls.withLock { $0 } == 1)
    }

    @Test func theProxyIsReadBeforeEachResolve() async throws {
        let backend = FakeBackend()
        let current = Mutex<URL?>(nil)
        let r = await make(backend, proxy: { current.withLock { $0 } })
        _ = try await r.resolve(ref(.soundcloud, 1), purpose: .userPick)
        current.withLock { $0 = URL(string: "http://127.0.0.1:8899") }
        _ = try await r.resolve(ref(.soundcloud, 2), purpose: .userPick)
        _ = try await r.resolve(ref(.soundcloud, 3), purpose: .userPick)
        #expect(await backend.proxies == [nil, URL(string: "http://127.0.0.1:8899")], "set once per change")
    }

    @Test func userPicksUseUserPriority() async throws {
        let backend = FakeBackend()
        let r = await make(backend)
        _ = try await r.resolve(ref(.soundcloud, 1), purpose: .userPick)
        _ = try await r.resolve(ref(.soundcloud, 2), purpose: .prefetch)
        #expect(await backend.calls.map(\.priority) == [.user, .background])
    }
}

/// The real ResolverService behind the StreamResolver: the proxy reaches yt-dlp's argv.
@Test func proxyReachesTheYtDlpArgv() async throws {
    let layout = EngineLayout(paths: .profile(FileManager.default.temporaryDirectory.appending(path: "proxyargv-\(UUID().uuidString)")))
    defer { try? FileManager.default.removeItem(at: layout.home.deletingLastPathComponent()) }
    let seen = Mutex<[String]>([])
    let service = ResolverService(layout: layout, engine: URL(filePath: "/nonexistent/yt-dlp_macos"),
                                  time: FakeTimeSource(Date(timeIntervalSince1970: cacheT0)), runner: { spec in
        seen.withLock { $0 = spec.arguments }
        return SubprocessResult(termination: .exited(0), stdout: FakeRunner.json(ResolverServiceTests.scJSON))
    })
    let r = StreamResolver(backend: service, time: FakeTimeSource(Date(timeIntervalSince1970: cacheT0)),
                           proxyProvider: { URL(string: "http://127.0.0.1:8899") })
    await r.setEngine(URL(filePath: "/nonexistent/yt-dlp_macos"))
    _ = try await r.resolve(ref(.soundcloud, 1), purpose: .userPick)
    let argv = seen.withLock { $0 }
    let i = try #require(argv.firstIndex(of: "--proxy"))
    #expect(argv[i + 1] == "http://127.0.0.1:8899")
}
