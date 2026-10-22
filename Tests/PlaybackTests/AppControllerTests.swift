// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import Picker
@testable import Resolver
import Testing
@testable import Playback

/// An engine store whose installs fail with the given errors, then succeed.
actor ScriptedEngines: EngineProviding {
    private var failures: [EngineStoreError]
    private(set) var installs = 0

    init(failing failures: [EngineStoreError]) { self.failures = failures }

    func readiness() async -> EngineReadiness { .missing }

    func install(policy: EngineInstallPolicy, progress: @escaping @Sendable (EngineInstallPhase) -> Void) async throws
        -> EngineReadiness {
        installs += 1
        progress(.choosing)
        if !failures.isEmpty { throw failures.removeFirst() }
        progress(.downloading(onDisk: 27, expected: 54))
        return .ready(version: "2026.10.21", executable: URL(filePath: "/nonexistent/yt-dlp_macos"))
    }
}

/// The controller features M2's Shell relies on: auto-resume, the engine retry, Now Playing in state.json,
/// genre availability.
@MainActor @Suite struct AppControllerTests {
    // MARK: Returning launch

    @Test func aVODResumesAtItsPositionBehindTheLaunchFade() async throws {
        let sc = stream(.soundcloud, 1)
        let other = stream(.mixcloud, 2)
        let h = Harness([sc, other])
        await h.controller.prepare()
        h.controller.resume(.stream(deepHouse, sc.id, startAt: 1234))
        await h.until("load") { h.player.loads.count == 1 }
        #expect(h.player.fades == [PlaybackController.launchFadeSeconds])
        #expect(h.player.loads[0].request.options.start == 1234)
        #expect(h.controller.snapshot.genre == deepHouse && h.controller.currentStream?.id == sc.id)
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.phase == .playing }
        #expect(h.controller.snapshot.lastTTFA?.trigger == "resume")
        let state = await h.controller.debugState()
        #expect(state.resumed && state.resumePlan == "stream sc:user/sc1 in deep-house at 1234 s")
        #expect(h.metricsEvents("resume").first?["startAt"] as? Double == 1234)

        h.controller.next()
        await h.until("next load") { h.player.loads.count == 2 }
        #expect(h.player.loads[1].request.options.start == nil, "the saved position applies once")
        #expect(h.player.fades.count == 1, "Next doesn't fade")
    }

    @Test func aGenrePlanPicksTheNextBagItem() async {
        let h = Harness([stream(.radio, 1), stream(.radio, 2)])
        await h.controller.prepare()
        h.controller.resume(.genre(deepHouse))
        await h.until("load") { h.player.loads.count == 1 }
        #expect(h.player.fades.count == 1 && h.player.loads[0].request.options.start == nil)
        #expect(await h.controller.debugState().resumed)
    }

    @Test func noPlanLeavesItQuiet() async {
        let h = Harness([stream(.radio, 1)])
        await h.controller.prepare()
        h.controller.resume(.none(reason: "first launch"))
        #expect(h.controller.phase == .idle && h.player.loads.isEmpty && h.player.fades.isEmpty)
        let state = await h.controller.debugState()
        #expect(!state.resumed && state.resumePlan == "none (first launch)")
    }

    @Test func aStreamInSeveralGenresResumesInTheSavedGenre() async {
        let base = stream(.radio, 7)
        let shared = StreamRef(id: base.id, source: base.source, ref: base.ref, kind: base.kind, title: base.title,
                               creator: base.creator, genres: [techno, deepHouse], durationSec: nil,
                               homepage: base.homepage)
        let h = Harness([shared])
        await h.controller.prepare()
        h.controller.resume(.stream(deepHouse, shared.id, startAt: nil))
        await h.until("load") { h.player.loads.count == 1 }
        #expect(h.controller.snapshot.genre == deepHouse, "not the stream's first genre")
        #expect(h.player.loads.count == 1, "the genre's own pick was superseded")
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.phase == .playing }
        #expect(h.controller.currentStream?.id == shared.id)
    }

    @Test func theSessionFileFeedsThePolicyOnTheNextLaunch() async {
        let sc = stream(.soundcloud, 1)
        let h = Harness([sc])
        await h.startPlaying()
        h.controller.persistNow()
        let relaunched = h.make([sc])
        let plan = ResumePolicy.plan(last: relaunched.resumedFrom, catalog: relaunched.catalog, now: h.clock.now,
                                     engineReady: true)
        #expect(plan == .stream(deepHouse, sc.id, startAt: 12), "FakePlayer reports time-pos 12")
    }

    // MARK: Engine download retry

    @Test func aFailedInstallIsRetriedWithBackoffUntilItSucceeds() async {
        let engines = ScriptedEngines(failing: [.unreachable("offline"), .unreachable("still offline")])
        let h = Harness([stream(.radio, 1)], engines: engines)
        await h.controller.prepare()
        h.controller.ensureEngine()
        await h.until("failed") { h.controller.snapshot.engine.state == .failed }
        var e = h.controller.snapshot.engine
        #expect(e.download == "unreachable" && e.attempts == 1)
        #expect(e.retryAt == h.clock.now.addingTimeInterval(15))
        #expect(e.notice == "ENGINE DOWNLOAD FAILED - RADIO ONLY" && h.controller.snapshot.radioOnly)
        #expect(h.metricsEvents("engine.installFailed").first?["kind"] as? String == "unreachable")

        h.scheduler.advance(by: 15)
        await h.until("second failure") { h.controller.snapshot.engine.attempts == 2 }
        e = h.controller.snapshot.engine
        #expect(e.state == .failed && e.retryAt == h.clock.now.addingTimeInterval(60))
        #expect(await engines.installs == 2)

        h.scheduler.advance(by: 59)
        #expect(await engines.installs == 2)
        h.scheduler.advance(by: 1)
        await h.until("ready") { h.controller.snapshot.engine.state == .ready }
        #expect(await engines.installs == 3)
        #expect(h.controller.snapshot.engine.attempts == nil && !h.controller.snapshot.radioOnly)
    }

    @Test func theNetworkComingBackRetriesAnUnreachableInstallAtOnce() async {
        let engines = ScriptedEngines(failing: [.unreachable("offline")])
        let h = Harness([stream(.radio, 1)], engines: engines)
        await h.controller.prepare()
        h.controller.ensureEngine()
        await h.until("failed") { h.controller.snapshot.engine.state == .failed }
        h.network.send(NetworkPathStatus(isSatisfied: false))
        h.network.send(NetworkPathStatus(isSatisfied: true, interfaces: ["en0/wifi"]))
        await h.until("ready") { h.controller.snapshot.engine.state == .ready }
        #expect(await engines.installs == 2)
    }

    @Test func noSpaceIsReportedAndRetryEngineRetriesNow() async {
        let engines = ScriptedEngines(failing: [.insufficientSpace(available: 0, required: 180_000_000)])
        let h = Harness([stream(.radio, 1)], engines: engines)
        await h.controller.prepare()
        h.controller.ensureEngine()
        await h.until("failed") { h.controller.snapshot.engine.state == .failed }
        #expect(h.controller.snapshot.engine.download == "noSpace")
        #expect(h.controller.snapshot.engine.notice == "STREAM ENGINE NEEDS 180 MB FREE - RADIO ONLY")
        h.controller.retryEngine()
        await h.until("ready") { h.controller.snapshot.engine.state == .ready }
        h.controller.retryEngine()  // ready: nothing to retry
        #expect(await engines.installs == 2)
    }

    @Test func shutdownCancelsAPendingRetry() async {
        let engines = ScriptedEngines(failing: [.unreachable("offline")])
        let h = Harness([stream(.radio, 1)], engines: engines)
        await h.controller.prepare()
        h.controller.ensureEngine()
        await h.until("failed") { h.controller.snapshot.engine.state == .failed }
        await h.controller.shutdown()
        h.scheduler.advance(by: 3600)
        #expect(await engines.installs == 1)
    }

    @Test func aLaterPickWinsOverAnUnfinishedSurpriseMe() async {
        // Surprise Me weighs genres by eligible streams: (seeded) it would choose Deep House.
        let h = Harness((1...9).map { stream(.radio, $0) } + [stream(.radio, 10, genre: techno)])
        await h.controller.prepare()
        h.controller.surpriseMe()          // chooses its genre after an actor hop
        h.controller.start(genre: techno)  // the user picks before it lands
        await h.until("load") { h.player.loads.count == 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(h.controller.snapshot.genre == techno && h.player.loads.count == 1)
    }

    // MARK: Now Playing, availability

    @Test func publishedNowPlayingLandsInStateJSON() async throws {
        let h = Harness([stream(.radio, 1)]) { $0.writeDebugState = true }
        await h.startPlaying()
        let info = NowPlayingInfo.from(h.controller.snapshot)
        h.controller.recordPublishedNowPlaying(info)
        await h.controller.writeDebugStateNow()
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: h.paths.debugState)) as? [String: Any])
        let np = try #require(json["nowPlaying"] as? [String: Any])
        #expect(np["playbackState"] as? String == "playing" && np["isLiveStream"] as? Bool == true)
        #expect(np["excludeFromSuggestions"] as? Bool == true)
    }

    @Test func genreAvailabilityCountsEligibleStreams() async {
        let h = Harness([stream(.radio, 1), stream(.soundcloud, 2), stream(.soundcloud, 3, genre: techno)],
                        engineReady: false)
        await h.controller.prepare()
        let a = await h.controller.genreAvailability()
        #expect(a[deepHouse] == GenreAvailability(eligible: 1, total: 2))
        #expect(a[techno] == GenreAvailability(eligible: 0, total: 1, reason: .engineNotReady))
    }
}
