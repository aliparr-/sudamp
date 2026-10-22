// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import Synchronization
import Testing
@testable import Resolver

/// A backend that answers each call with the next scripted outcome (then succeeds), counting calls.
actor SequenceBackend: ResolveBackend {
    enum Step: Sendable {
        case ok
        case fail(ResolveFailure)
    }

    private var steps: [Step]
    private(set) var calls: [ResolveTier] = []
    private var engine: URL?
    let delay: Duration

    init(_ steps: [Step], delay: Duration = .zero) {
        self.steps = steps
        self.delay = delay
    }

    func resolve(_ request: ResolveRequest, tier: ResolveTier, priority: ResolvePriority) async throws -> ResolveOutcome {
        calls.append(tier)
        if delay > .zero { try await Task.sleep(for: delay) }
        let step = steps.isEmpty ? .ok : steps.removeFirst()
        switch step {
        case .ok:
            return ResolveOutcome(stream: resolvedStream(request.source, resolvedAt: cacheT0, expires: cacheT0 + 6 * 3600,
                                                         hls: request.source != .youtube, tier: tier.rawValue),
                                  elapsedMs: 50, warnings: [])
        case .fail(var f):
            f.tier = tier.rawValue
            throw f
        }
    }

    func setEngine(_ url: URL?) { engine = url }
    func setProxy(_ url: URL?) {}
    func hasQuickJS() -> Bool { false }
}

@Suite struct ResolverResilienceTests {
    let clock = FakeTimeSource(Date(timeIntervalSince1970: cacheT0))
    let dir = FileManager.default.temporaryDirectory.appending(path: "resolver-m6-\(UUID().uuidString)")

    func make(_ backend: any ResolveBackend, stateFile: URL? = nil, faults: ResolverFaults = .none) async -> StreamResolver {
        let r = StreamResolver(backend: backend, time: clock, stateFile: stateFile, faults: faults, proxyProvider: { nil })
        await r.setEngine(URL(filePath: "/nonexistent/yt-dlp_macos"))
        return r
    }

    // MARK: Faults

    @Test func faultGrammar() {
        let f = ResolverFaults.parse("youtube:403, youtube:botcheck,youtube:timeout,mixcloud:repeat_play,resolve:delay=5,net:offline")
        #expect(f.youtube403 && f.youtubeBotCheck && f.youtubeTimeout && f.mixcloudRepeatPlay && f.resolveDelay == 5)
        #expect(ResolverFaults.parse("resolve:delay=-1").resolveDelay == nil)
        #expect(ResolverFaults.parse("resolve:delay=1000").resolveDelay == nil)
        #expect(!ResolverFaults.parse("engine:corrupt").isActive)
        #if !DEBUG
        #expect(ResolverFaults.from(environment: ["SUDAMP_FAULT": "youtube:403"]) == .none)
        #endif
    }

    @Test func injectedFailuresGoThroughTheRealClassifier() {
        let yt = ResolveRequest(source: .youtube, url: ref(.youtube, 1).url)
        let mc = ResolveRequest(source: .mixcloud, url: ref(.mixcloud, 1).url)
        let cases: [(ResolverFaults, ResolveRequest, ResolveFailureClass, String)] = [
            (ResolverFaults(youtube403: true), yt, .engine, "http403"),
            (ResolverFaults(youtubeBotCheck: true), yt, .botCheck, "notABot"),
            (ResolverFaults(youtubeTimeout: true), yt, .transient, "timeout"),
            (ResolverFaults(mixcloudRepeatPlay: true), mc, .unavailable, "mixcloudRepeatPlay"),
        ]
        for (faults, request, cls, reason) in cases {
            let f = faults.injectedFailure(request, tier: .jsless)
            #expect(f?.failureClass == cls && f?.reason == reason, "\(String(describing: f))")
            #expect(faults.injectedFailure(request, tier: .quickjs)?.failureClass == cls, "every tier")
        }
        #expect(ResolverFaults(youtube403: true).injectedFailure(mc, tier: .jsless) == nil)
        #expect(ResolverFaults(mixcloudRepeatPlay: true).injectedFailure(yt, tier: .jsless) == nil)
    }

    @Test func faultedYouTubeNeverReachesYtDlpButBotCheckPauses() async throws {
        let backend = SequenceBackend([])
        let r = await make(backend, faults: ResolverFaults(youtubeBotCheck: true))
        await #expect(throws: ResolveFailure.self) { try await r.resolve(ref(.youtube, 1), purpose: .userPick) }
        #expect(await backend.calls.isEmpty)
        let until = try #require(await r.persistedState.youtubeBlockedUntil)
        #expect(until == clock.now.addingTimeInterval(6 * 3600))
        await #expect(throws: StreamResolveError.sourceBlocked(.youtube, until: until)) {
            try await r.resolve(ref(.youtube, 2), purpose: .userPick)
        }
        // Mixcloud is unaffected and really runs.
        _ = try await r.resolve(ref(.mixcloud, 1), purpose: .userPick)
        #expect(await backend.calls.count == 1)
    }

    @Test func mixcloudRepeatPlayIsUnavailable() async throws {
        let r = await make(SequenceBackend([]), faults: ResolverFaults(mixcloudRepeatPlay: true))
        do {
            _ = try await r.resolve(ref(.mixcloud, 1), purpose: .userPick)
            Issue.record("should fail")
        } catch let f as ResolveFailure {
            #expect(f.failureClass == .unavailable && f.reason == "mixcloudRepeatPlay")
        }
    }

    @Test func resolveDelayHoldsTheResultWithOneRun() async throws {
        let backend = SequenceBackend([])
        let r = await make(backend, faults: ResolverFaults(resolveDelay: 0.3))
        let started = ContinuousClock.now
        _ = try await r.resolve(ref(.soundcloud, 1), purpose: .userPick)
        #expect(ContinuousClock.now - started >= .milliseconds(290))
        #expect(await backend.calls.count == 1, "the delay is one slow resolve, not a second process")
    }

    // MARK: Retry once (transient), DESIGN §6.4

    @Test func aQuickTransientFailureIsRetriedOnce() async throws {
        let http503 = ResolveFailure(.transient, "http5xx", message: "HTTP Error 503", elapsedMs: 400)
        let backend = SequenceBackend([.fail(http503)])
        let r = await make(backend)
        let s = try await r.resolve(ref(.soundcloud, 1), purpose: .userPick)
        #expect(!s.fromCache)
        #expect(await backend.calls.count == 2)
        // Twice in a row: reported after the one retry.
        let twice = SequenceBackend([.fail(http503), .fail(http503)])
        let r2 = await make(twice)
        await #expect(throws: ResolveFailure.self) { try await r2.resolve(ref(.soundcloud, 2), purpose: .userPick) }
        #expect(await twice.calls.count == 2)
    }

    @Test func timeoutsAndSlowFailuresAreNotRetried() async throws {
        let timeout = ResolveFailure(.transient, "timeout", message: "killed after 10000 ms", elapsedMs: 10_000)
        let slow = ResolveFailure(.transient, "network", message: "timed out", elapsedMs: 9_000)
        for failure in [timeout, slow] {
            let backend = SequenceBackend([.fail(failure)])
            let r = await make(backend)
            await #expect(throws: ResolveFailure.self) { try await r.resolve(ref(.soundcloud, 1), purpose: .userPick) }
            #expect(await backend.calls.count == 1)
        }
    }

    @Test func aYouTubeRetrySpendsAToken() async throws {
        let reset = ResolveFailure(.transient, "network", message: "connection reset", elapsedMs: 300)
        let backend = SequenceBackend([.fail(reset)])
        let r = await make(backend)
        _ = try await r.resolve(ref(.youtube, 1), purpose: .userPick)
        #expect(await r.status().youtubeTokens == 1)
        #expect(await backend.calls.count == 2)
    }

    // MARK: Persisted token bucket

    @Test func theTokenBucketSurvivesARelaunch() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = dir.appending(path: "resolver.json")
        let r = await make(SequenceBackend([]), stateFile: state)
        for n in 1...3 { _ = try await r.resolve(ref(.youtube, n), purpose: .userPick) }
        #expect(await r.status().youtubeTokens == 0)
        // A relaunch 10 s later: still empty (no fresh burst), and the next token arrives on the old schedule.
        clock.advance(by: 10)
        let relaunched = await make(SequenceBackend([]), stateFile: state)
        #expect(await relaunched.status().youtubeTokens == 0)
        await #expect(throws: StreamResolveError.noToken(.userPick)) {
            try await relaunched.resolve(ref(.youtube, 9), purpose: .userPick)
        }
        clock.advance(by: 20)
        #expect(await relaunched.status().youtubeTokens == 1)
        let text = try String(contentsOf: state, encoding: .utf8)
        #expect(text.contains("\"bucket\""))
    }

    @Test func aClockThatWentBackwardsMintsNoTokens() {
        let saved = TokenBucket(now: Date(timeIntervalSince1970: cacheT0 + 3600), tokens: 1)
        let restored = StreamResolver.restoredBucket(saved, now: Date(timeIntervalSince1970: cacheT0))
        #expect(restored.available(now: Date(timeIntervalSince1970: cacheT0)) == 1)
        #expect(restored.anchor == Date(timeIntervalSince1970: cacheT0))
    }

    // MARK: Breaker hooks

    @Test func blockPlatformOnlyExtendsAndSpendTokenRespectsIt() async throws {
        let r = await make(SequenceBackend([]))
        #expect(await r.spendToken(for: .canary))
        let until = clock.now.addingTimeInterval(12 * 3600)
        await r.blockPlatform(.youtube, until: until)
        await r.blockPlatform(.youtube, until: clock.now.addingTimeInterval(3600))
        #expect(await r.persistedState.youtubeBlockedUntil == until)
        #expect(await r.status().openSources == [.youtube])
        #expect(await !r.spendToken(for: .canary))
        await r.blockPlatform(.soundcloud, until: until)
        #expect(await r.status().openSources == [.youtube], "only YouTube is paused at the resolver")
    }

    // MARK: _update_spec identifier

    @Test func identifierFromTheVerboseHeader() {
        let header = """
        [debug] Command-line config: ['--ignore-config', '-v']
        [debug] yt-dlp version stable@2026.10.21 from yt-dlp/yt-dlp [8cdf4fea4] (darwin_dir)
        [debug] Python 3.14.7 (CPython arm64 64bit) - macOS-27.0.1-arm64-arm-64bit-Mach-O (OpenSSL 3.5.7 9 Jun 2026)
        [debug] exe versions: none
        yt-dlp_macos: error: You must provide at least one URL.
        """
        #expect(UpdateSpec.identifier(fromVerbose: header)
                == "darwin_dir Python 3.14.7 (CPython arm64 64bit) - macOS-27.0.1-arm64-arm-64bit-Mach-O (OpenSSL 3.5.7 9 Jun 2026)")
        #expect(UpdateSpec.identifier(fromVerbose: "ERROR: nope") == nil)
    }

    // MARK: Launch warm-up through the serial gate

    static func warmRunner(versionDelay: Duration) -> ResolverService.Runner {
        { spec in
            if spec.arguments == ["--version"] {
                try await Task.sleep(for: versionDelay)
                return SubprocessResult(termination: .exited(0), stdout: Data("2026.10.21\n".utf8))
            }
            if spec.arguments.last == "-v" {
                let header = "[debug] yt-dlp version stable@2026.10.21 from yt-dlp/yt-dlp [x] (darwin_dir)\n"
                    + "[debug] Python 3.14.7 (CPython arm64 64bit) - macOS-27.0.1-arm64\n"
                return SubprocessResult(termination: .exited(2), stderr: Data(header.utf8))
            }
            let json = #"{"url":"https://playback.media-streaming.soundcloud.cloud/x.m3u8","protocol":"m3u8_native"}"#
            return SubprocessResult(termination: .exited(0), stdout: Data(json.utf8))
        }
    }

    @Test func warmUpRunsVersionThenTheIdentifier() async throws {
        let profile = dir.appending(path: "p")
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = ResolverService(layout: EngineLayout(paths: .profile(profile)), engine: URL(filePath: "/x/yt-dlp_macos"),
                                      time: clock, runner: Self.warmRunner(versionDelay: .zero))
        let warm = try #require(await service.warmUp(version: "2026.10.21"))
        #expect(warm.ok && warm.identifier == "darwin_dir Python 3.14.7 (CPython arm64 64bit) - macOS-27.0.1-arm64")
        #expect(await service.warmUp(version: "2026.09.01")?.ok == false, "a build printing another version fails")
    }

    @Test func aUserPickKillsTheWarmUp() async throws {
        let profile = dir.appending(path: "p")
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = ResolverService(layout: EngineLayout(paths: .profile(profile)), engine: URL(filePath: "/x/yt-dlp_macos"),
                                      time: clock, runner: Self.warmRunner(versionDelay: .seconds(5)))
        let warming = Task { await service.warmUp(version: "2026.10.21") }
        try await Task.sleep(for: .milliseconds(50))
        let started = ContinuousClock.now
        _ = try await service.resolve(ResolveRequest(source: .soundcloud, url: ref(.soundcloud, 1).url), priority: .user)
        #expect(ContinuousClock.now - started < .seconds(2), "the pick didn't wait for the warm-up")
        #expect(await warming.value == nil)
    }
}
