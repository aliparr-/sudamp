// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import MPV
import Picker
import Resolver
import Testing
@testable import Playback

/// The PlaybackController driven through fakes: no network, no audio, hand-advanced time.
@MainActor @Suite struct PlaybackControllerTests {
    // MARK: The north star

    @Test func pickResolveLoadPlaying() async {
        let sc = stream(.soundcloud, 1)
        let h = Harness([sc])
        await h.controller.prepare()
        h.controller.start(genre: deepHouse)
        await h.until("load") { h.player.loads.count == 1 }
        #expect(await h.resolver.calls == [.init(id: sc.id, purpose: .userPick)])
        #expect(h.controller.phase == .buffering)
        let request = h.player.loads[0].request
        #expect(request.url == resolution(for: sc).url)
        #expect(request.options.httpHeaders == ["User-Agent": "UA/1", "Accept": "*/*"])
        #expect(request.options.userAgent == "UA/1" && request.options.mediaTitle == "Creator - Title 1")
        #expect(request.options.lavf.isEmpty, "HLS gets no progressive options")
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.phase == .playing }
        let snap = h.controller.snapshot
        #expect(snap.stream?.id == sc.id && snap.stream?.tag == "SC" && snap.genreName == "Deep House")
        #expect(snap.statusText == "[DEEP HOUSE] CREATOR - TITLE 1")
        #expect(snap.engine.state == .ready && !snap.radioOnly)
        let t = snap.lastTTFA
        #expect(t != nil)
        #expect(t?.streamId == sc.id && t?.prefetched == false && t?.fromCache == false && t?.trigger == "selectGenre")
        let events = h.metricsEvents("ttfa")
        #expect(events.count == 1)
        #expect(events.first?["streamId"] as? String == sc.id.rawValue && events.first?["source"] as? String == "soundcloud")
        #expect(events.first?["ms"] is NSNumber && events.first?["tier"] as? Int == 1)
        #expect(events.first?["prefetched"] as? Bool == false)
    }

    @Test func progressiveYouTubeGetsRangedRequests() async {
        let yt = stream(.youtube, 1)
        let h = Harness([yt])
        await h.startPlaying()
        let lavf = h.player.loads[0].request.options.lavf
        #expect(lavf.contains(LavfOption("request_size", "10485760")) && lavf.contains(LavfOption("reconnect", "1")))
    }

    @Test func radioIsLoadedWithoutResolving() async {
        let r = stream(.radio, 1)
        let h = Harness([r])
        await h.startPlaying()
        #expect(await h.resolver.calls.isEmpty)
        let request = h.player.loads[0].request
        #expect(request.url == r.url)
        // M6: FFmpeg follows no redirect (the controller walked them under the private-address rule).
        #expect(request.options.lavf == [LavfOption("reconnect_streamed", "1"), LavfOption("max_redirects", "0")])
        #expect(h.controller.snapshot.stream?.link == r.homepage, "Copy Link credits the broadcaster")
    }

    @Test func radioHostsWithPrivateAddressesAreRefused() async {
        let h = Harness([stream(.radio, 1), stream(.radio, 2)], hosts: FakeHosts(addresses: [.v4(0x7F00_0001)]))
        await h.controller.prepare()
        h.controller.start(genre: deepHouse)
        await h.until("failed") { h.controller.phase == .failed }
        #expect(h.player.loads.isEmpty)
        #expect(h.metricsEvents("failure").filter { $0["stage"] as? String == "dns" }.count == 2)
    }

    // MARK: Prefetch

    @Test func nextUsesThePrefetchedPick() async {
        let h = Harness([stream(.soundcloud, 1), stream(.soundcloud, 2), stream(.mixcloud, 3)])
        let first = await h.startPlaying()
        h.scheduler.advance(by: 9)
        #expect(await !h.resolver.calls.contains { $0.purpose == .prefetch }, "not before ~10 s")
        h.scheduler.advance(by: 1)
        await h.until("prefetch") { await h.resolver.calls.contains { $0.purpose == .prefetch } }
        let prefetched = await h.resolver.calls.first { $0.purpose == .prefetch }!.id
        #expect(prefetched != first?.id)
        await h.until("prefetch done") { h.metricsEvents("prefetch").count == 1 }
        h.controller.next()
        await h.until("second load") { h.player.loads.count == 2 }
        #expect(h.controller.currentStream?.id == prefetched)
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.snapshot.lastTTFA?.streamId == prefetched }
        let t = h.controller.snapshot.lastTTFA
        #expect(t?.prefetched == true && t?.fromCache == true && t?.trigger == "next")
        #expect(h.metricsEvents("ttfa").last?["prefetched"] as? Bool == true)
    }

    @Test func hoveringAGenrePreResolvesItsPick() async {
        let tech = stream(.soundcloud, 7, genre: techno)
        let h = Harness([stream(.radio, 1), tech])
        await h.startPlaying()
        h.controller.preresolve(genre: techno)
        await h.until("hover resolve") { await h.resolver.calls.contains(.init(id: tech.id, purpose: .hover)) }
        await h.until("ready") { h.metricsEvents("prefetch").count == 1 }
        h.controller.start(genre: techno)
        await h.until("load") { h.player.loads.count == 2 }
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.snapshot.lastTTFA?.streamId == tech.id }
        #expect(h.controller.snapshot.lastTTFA?.prefetched == true && h.controller.snapshot.lastTTFA?.fromCache == true)
        h.controller.preresolve(genre: techno)   // the playing genre: nothing to do
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await h.resolver.calls.filter { $0.purpose == .hover }.count == 1)
    }

    @Test func aPrefetchForAnotherGenreIsDropped() async {
        let h = Harness([stream(.radio, 1), stream(.radio, 2), stream(.radio, 3, genre: techno)])
        await h.startPlaying()
        h.scheduler.advance(by: 10)
        await h.until("prefetch") { h.metricsEvents("prefetch.pick").count == 1 }
        h.controller.start(genre: techno)
        await h.until("techno") { h.player.loads.count == 2 }
        #expect(h.controller.currentStream?.genres == [techno])
    }

    // MARK: Failures

    @Test func aFailedResolveAdvancesAndBacksOff() async {
        let sc = stream(.soundcloud, 1), mc = stream(.mixcloud, 2)
        let h = Harness([sc, mc])
        await h.resolver.script(sc.id, .fail(ResolveFailure(.unavailable, "removed", message: "This video is unavailable")))
        await h.controller.prepare()
        h.controller.start(genre: deepHouse)   // fast-start ranks SoundCloud before Mixcloud
        await h.until("advanced") { h.player.loads.count == 1 }
        #expect(h.controller.currentStream?.id == mc.id)
        #expect(h.controller.snapshot.lastError?.kind == "unavailable")
        #expect(h.controller.snapshot.statusText == "SKIPPING - UNAVAILABLE")
        #expect(h.controller.debugCounters.failures == 1)
        #expect(await h.controller.eligibleCount(genre: deepHouse) == 1, "the unavailable stream skips 24 h")
        #expect(h.metricsEvents("failure").first?["reason"] as? String == "removed")
    }

    @Test func playbackErrorsTimeoutsAndEndOfFileAdvance() async {
        let h = Harness((1...5).map { stream(.radio, $0) })
        let first = await h.startPlaying()
        h.player.emitEnd(.error("HTTP error 503", .transient))
        await h.until("second load") { h.player.loads.count == 2 }
        #expect(h.controller.currentStream?.id != first?.id)
        h.scheduler.advance(by: 19.9)
        #expect(h.player.loads.count == 2)
        h.scheduler.advance(by: 0.1)
        await h.until("third load") { h.player.loads.count == 3 }
        #expect(h.player.calls.contains("stop"))
        #expect(h.controller.snapshot.lastError?.stage == "firstAudio")
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.phase == .playing }
        h.player.emitEnd(.endOfFile)
        await h.until("fourth load") { h.player.loads.count == 4 }
        #expect(h.controller.debugCounters.failures == 2, "end of file is not a failure")
        // A late event for an old load is ignored.
        h.player.emitEnd(.error("late", .transient), h.player.loads[0].id)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.player.loads.count == 4)
    }

    @Test func aRadioForbiddenIsUnavailableNotEngine() async {
        let h = Harness([stream(.radio, 1), stream(.radio, 2)])
        let first = await h.startPlaying()
        h.player.emitEnd(.error("HTTP error 403 Forbidden", .engine))
        await h.until("advanced") { h.player.loads.count == 2 }
        #expect(h.controller.snapshot.lastError?.kind == "unavailable")
        #expect(await h.controller.eligibleCount(genre: deepHouse) == 1, "\(first?.id.rawValue ?? "") backs off")
    }

    @Test func aSlowResolveTimesOutAt15Seconds() async {
        let a = stream(.soundcloud, 1), b = stream(.soundcloud, 2)
        let h = Harness([a, b])
        await h.resolver.script(a.id, .hang)
        await h.resolver.script(b.id, .hang)
        await h.controller.prepare()
        h.controller.start(genre: deepHouse)
        await h.until("resolve") { await h.resolver.calls.count == 1 }
        h.scheduler.advance(by: 14.9)
        #expect(await h.resolver.calls.count == 1)
        h.scheduler.advance(by: 0.1)
        await h.until("advanced") { await h.resolver.calls.count == 2 }
        await h.until("killed") { await h.resolver.cancelled == 1 }
        let failure = h.metricsEvents("failure").first
        #expect(failure?["reason"] as? String == "timeout" && failure?["kind"] as? String == "transient")
    }

    @Test func fiveFailuresInARowStopThenRetry() async {
        // Two streams per platform: no source breaker opens (M6: 3 transient failures on one platform would), so
        // the five-in-a-row rule is what stops playback.
        let streams = [stream(.soundcloud, 1), stream(.soundcloud, 2), stream(.mixcloud, 3), stream(.mixcloud, 4),
                       stream(.youtube, 5), stream(.youtube, 6)]
        let h = Harness(streams)
        for s in streams { await h.resolver.script(s.id, .fail(ResolveFailure(.transient, "http5xx"))) }
        await h.controller.prepare()
        h.controller.start(genre: deepHouse)
        await h.until("failed") { h.controller.phase == .failed }
        #expect(await h.resolver.calls.count == 5)
        #expect(h.controller.snapshot.statusText == "CAN'T REACH STREAMS - CLICK TO RETRY")
        #expect(h.controller.snapshot.failuresInARow == 5)
        #expect(h.player.calls.contains("stop"))
        for s in streams { await h.resolver.script(s.id, .ok()) }
        h.controller.retry()
        await h.until("retried") { h.player.loads.count == 1 }
        #expect(h.controller.snapshot.failuresInARow == 0)
    }

    @Test func aLoadfileErrorAdvancesAndCounts() async {
        let h = Harness([stream(.radio, 1), stream(.radio, 2)])
        h.player.loadError = MPVError.command(-1)
        await h.controller.prepare()
        h.controller.start(genre: deepHouse)
        await h.until("failed") { h.controller.phase == .failed }
        #expect(h.controller.debugCounters.unhandledErrors == 2)
    }

    // MARK: available_at and tokens

    @Test func aShortAvailableAtWaitsBeforeLoading() async {
        let sc = stream(.soundcloud, 1)
        let h = Harness([sc])
        await h.resolver.script(sc.id, .ok(availableAt: fakeT0.timeIntervalSince1970 + 2))
        await h.controller.prepare()
        h.controller.start(genre: deepHouse)
        await h.until("resolved") { h.metricsEvents("availableAt.wait").count == 1 }
        #expect(h.player.loads.isEmpty, "never load before available_at")
        h.scheduler.advance(by: 2)
        await h.until("load") { h.player.loads.count == 1 }
    }

    @Test func aFarAvailableAtIsDeferredNotFailed() async {
        let sc = stream(.soundcloud, 1), mc = stream(.mixcloud, 2)
        let h = Harness([sc, mc])
        await h.resolver.script(sc.id, .ok(availableAt: fakeT0.timeIntervalSince1970 + 20))
        await h.controller.prepare()
        h.controller.start(genre: deepHouse)
        await h.until("next pick") { h.player.loads.count == 1 }
        #expect(h.controller.currentStream?.id == mc.id)
        #expect(h.controller.debugCounters.deferrals == 1 && h.controller.debugCounters.failures == 0)
        #expect(h.metricsEvents("deferred").first?["waitSec"] as? Double == 20)
        #expect(await h.resolver.cached(sc.id) != nil, "the resolution is kept for later")
        #expect(await h.controller.eligibleCount(genre: deepHouse) == 2, "no backoff")
    }

    @Test func withoutTokensYouTubeIsDeferredNotConsumed() async throws {
        let yt1 = stream(.youtube, 1), yt2 = stream(.youtube, 2)
        let h = Harness([yt1, yt2, stream(.radio, 3), stream(.radio, 4)])
        await h.resolver.setTokens(0)
        await h.startPlaying()
        #expect(h.controller.currentStream?.isRadio == true)
        #expect(await h.resolver.calls.isEmpty)
        h.controller.persistNow()
        let saved = try #require(StateFile.load(SessionFile.self, from: h.paths.sessionFile))
        let bag = try #require(saved.picker.bags[deepHouse])
        #expect(Set(bag.upcoming).isSuperset(of: [yt1.id, yt2.id]), "deferred items stay ahead of the cursor")
        #expect(await h.controller.unavailableReason(genre: deepHouse) == nil)
    }

    @Test func aRefusedTokenDefersTheItem() async {
        let yt = stream(.youtube, 1), r = stream(.radio, 2)
        let h = Harness([yt, r]) { $0.allowedSources = [.youtube, .radio] }
        // The bucket emptied between the pick and the spend (a prefetch took the last token).
        await h.resolver.script(yt.id, .refuse(.noToken(.userPick)))
        await h.resolver.setTokens(0)
        await h.controller.prepare()
        h.controller.play(stream: yt.id)
        await h.until("next pick") { h.player.loads.count == 1 }
        #expect(h.controller.currentStream?.id == r.id)
        #expect(h.controller.snapshot.genre == deepHouse, "the stream's genre")
        #expect(h.controller.debugCounters.deferrals == 1 && h.controller.debugCounters.failures == 0)
    }

    // MARK: Pause, live edge, idle

    @Test func pauseAndResumeUseTheEngine() async {
        let h = Harness([stream(.soundcloud, 1)])
        await h.startPlaying()
        h.controller.togglePause()
        #expect(h.controller.phase == .paused && h.controller.snapshot.phase == .paused)
        await h.until("paused") { h.player.calls.contains("pause") }
        h.scheduler.advance(by: 45)
        h.controller.togglePause()
        #expect(h.controller.phase == .playing)
        #expect(Array(h.player.calls.suffix(3)) == ["pause", "suspend", "resume"])
        #expect(h.player.loads.count == 1, "a VOD resumes in place, even after 45 s")
        #expect(h.metricsEvents("liveReload").isEmpty)
    }

    @Test func transportOrderFollowsTheEngineRules() async {
        var steps: [String] = []
        await TransportOrder.pause(hostPauseAndWaitForRamp: { steps.append("host pause, wait for ramp") },
                                   pauseDecoder: { steps.append("mpv pause") })
        TransportOrder.resume(resumeDecoder: { steps.append("mpv resume") }, hostResume: { steps.append("host resume") })
        TransportOrder.shutdown(stopAudio: { steps.append("audio stop") }, shutdownDecoder: { steps.append("mpv shutdown") })
        #expect(steps == ["host pause, wait for ramp", "mpv pause", "mpv resume", "host resume", "audio stop", "mpv shutdown"])
    }

    @Test func radioPausedOver30SecondsRejoinsTheLiveEdge() async {
        let r = stream(.radio, 1)
        let h = Harness([r])
        await h.startPlaying()
        h.controller.pause()
        await h.until("paused") { h.player.calls.contains("pause") }
        h.scheduler.advance(by: 10)
        h.controller.play()
        #expect(h.player.calls.last == "resume" && h.player.loads.count == 1, "10 s: no reload")
        #expect(h.metricsEvents("liveReload").isEmpty)

        h.controller.pause()
        h.scheduler.advance(by: 30)
        #expect(h.player.isOutputSuspended, "the audio engine stops after 30 s paused")
        h.scheduler.advance(by: 15)
        h.controller.play()
        await h.until("reload") { h.player.loads.count == 2 }
        #expect(h.player.loads[1].request.url == r.url && h.controller.phase == .buffering)
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.phase == .playing }
        let reload = h.metricsEvents("liveReload")
        #expect(reload.count == 1 && reload.first?["pausedSec"] as? Double == 45)
        #expect(h.controller.snapshot.lastTTFA?.trigger == "liveReload")
        #expect(h.controller.debugCounters.streamsStarted == 1, "a reload isn't a new stream")
        #expect(h.controller.library.history.count == 1)
    }

    @Test func youTubeLiveReResolvesOnlyAnExpiredURL() async {
        let live = stream(.youtubeLive, 1)
        let h = Harness([live])
        await h.startPlaying()
        h.controller.pause()
        h.scheduler.advance(by: 45)
        h.controller.play()
        await h.until("reload") { h.player.loads.count == 2 }
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.phase == .playing }
        #expect(h.controller.snapshot.lastTTFA?.fromCache == true, "a still-valid /live URL is reused")

        h.controller.pause()
        h.scheduler.advance(by: 45)
        await h.resolver.evict(live.id)   // the URL expired
        h.controller.play()
        await h.until("re-resolved") { h.player.loads.count == 3 }
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.phase == .playing && h.controller.snapshot.lastTTFA?.fromCache == false }
        #expect(await h.resolver.calls.count == 3)
    }

    @Test func theOutputStopsAfter30SecondsIdle() async {
        let h = Harness([stream(.radio, 1)])
        await h.startPlaying()
        h.controller.stop()
        #expect(h.controller.phase == .idle && h.player.calls.last == "stop")
        h.scheduler.advance(by: 29)
        #expect(!h.player.isOutputSuspended)
        h.scheduler.advance(by: 1)
        #expect(h.player.isOutputSuspended)
    }

    // MARK: Engine readiness and guards

    @Test func radioOnlyWithoutTheEngine() async {
        let streams = [stream(.youtube, 1), stream(.soundcloud, 2), stream(.mixcloud, 3), stream(.radio, 4), stream(.radio, 5)]
        let h = Harness(streams, engineReady: false)
        await h.startPlaying()
        for _ in 0..<3 {
            #expect(h.controller.currentStream?.isRadio == true)
            let n = h.player.loads.count
            h.controller.next()
            await h.until("next") { h.player.loads.count == n + 1 }
            h.player.emitFirstAudio()
            await h.until("playing") { h.controller.phase == .playing }
        }
        #expect(await h.resolver.calls.isEmpty)
        #expect(await h.resolver.engine == nil)
        #expect(h.controller.snapshot.radioOnly && h.controller.snapshot.engine.state == .missing)
        #expect(h.controller.snapshot.engine.notice == "STREAM ENGINE MISSING - RADIO ONLY")
    }

    @Test func ensureEngineInstallsAndUnlocksResolvedSources() async {
        var engine = EngineConfig.defaults
        engine.pin = EnginePin(version: "2026.10.21", sha256: String(repeating: "a", count: 64))
        let h = Harness([stream(.radio, 1)], engineReady: false)
        await h.controller.prepare()
        #expect(h.controller.snapshot.engine.state == .missing)
        h.controller.ensureEngine()
        #expect(h.controller.snapshot.engine.state == .installing)
        await h.until("ready") { h.controller.snapshot.engine.state == .ready }
        #expect(await h.resolver.engine != nil)
        #expect(!h.controller.snapshot.radioOnly)
    }

    @Test func disabledEngineIsRadioOnlyByChoice() async {
        let h = Harness([stream(.soundcloud, 1), stream(.radio, 2)]) { $0.engineMode = .disabled }
        await h.startPlaying()
        #expect(h.controller.currentStream?.isRadio == true)
        #expect(h.controller.snapshot.engine.state == .disabled)
    }

    @Test func aFailedGuardRefusesToPlay() async {
        let h = Harness([stream(.radio, 1), stream(.radio, 2)])
        h.player.guardFailuresNow = ["audio-out-params s16/44100/stereo, expected floatp/48000/stereo"]
        await h.controller.prepare()
        h.controller.start(genre: deepHouse)
        await h.until("load") { h.player.loads.count == 1 }
        h.player.emitFirstAudio()
        await h.until("fault") { h.controller.snapshot.audioEngineError != nil }
        let snap = h.controller.snapshot
        #expect(snap.statusText == "AUDIO ENGINE ERROR" && snap.stateName == "audioEngineError")
        #expect(snap.lastError?.kind == "audioEngine" && h.controller.phase == .idle)
        #expect(h.player.calls.contains("stop"))
        h.controller.start(genre: deepHouse)
        h.controller.next()
        h.controller.play()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(h.player.loads.count == 1, "refused")
        #expect(h.metricsEvents("guard").count == 1)
    }

    @Test func refusedReadsWhilePlayingRaiseTheGuard() async {
        let h = Harness([stream(.radio, 1)])
        await h.startPlaying()
        h.player.guardFailuresNow = ["audio-out-params nil, expected floatp/48000/stereo"]
        h.scheduler.advance(by: 1)
        #expect(h.controller.snapshot.audioEngineError == nil, "between files mpv may report no AO params: not a fault")
        h.player.aoErrorCount = 3
        h.scheduler.advance(by: 1)
        #expect(h.controller.snapshot.audioEngineError == "pull AO refused 3 read(s)")
        #expect(h.controller.phase == .idle)
    }

    @Test func aFailedStartupGuardRefusesToPlay() async {
        let h = Harness([stream(.radio, 1)])
        h.player.startupFailures = ["mpv-version mpv v0.40.0 does not start with mpv v0.41."]
        await h.controller.prepare()
        h.controller.start(genre: deepHouse)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(h.player.loads.isEmpty)
        #expect(h.controller.snapshot.audioEngineError?.contains("mpv-version") == true)
    }

    // MARK: Network

    @Test func offlineAndBackReResolvesIPBoundStreams() async {
        let yt = stream(.youtube, 1)
        let h = Harness([yt])
        await h.startPlaying()
        h.network.send(NetworkPathStatus(isSatisfied: false))
        await h.until("seen") { h.metricsEvents("network").count == 1 }
        h.scheduler.advance(by: 10)   // M6: the loss must outlast the debounce (10 s while playing)
        await h.until("offline") { h.controller.phase == .offline }
        #expect(h.controller.snapshot.statusText == "OFFLINE" && h.controller.snapshot.offline)
        h.network.send(NetworkPathStatus(isSatisfied: true, interfaces: ["en0/ethernet"]))
        await h.until("back") { h.player.loads.count == 2 }
        #expect(await h.resolver.networkChanges == 1)
        #expect(await h.resolver.calls.count == 2)
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.phase == .playing }
        #expect(h.controller.snapshot.lastTTFA?.fromCache == false, "the IP-bound URL was dropped, not reused")
    }

    @Test func aRouteChangeDropsYouTubeButKeepsPlaying() async {
        let h = Harness([stream(.soundcloud, 1)])
        await h.startPlaying()
        h.network.send(NetworkPathStatus(isSatisfied: true, interfaces: ["en0/ethernet"]))
        await h.until("dropped") { await h.resolver.networkChanges == 1 }
        #expect(h.controller.phase == .playing && h.player.loads.count == 1)
        #expect(h.metricsEvents("network").first?["change"] as? String == "changed")
    }

    // MARK: Previous, sources, persistence, observation

    @Test func previousReturnsToTheLastStream() async {
        let h = Harness((1...4).map { stream(.radio, $0) })
        let first = await h.startPlaying()
        h.controller.next()
        await h.until("second") { h.player.loads.count == 2 }
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.phase == .playing }
        h.controller.previous()
        await h.until("back") { h.player.loads.count == 3 }
        #expect(h.controller.currentStream?.id == first?.id)
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.snapshot.lastTTFA?.trigger == "previous" }
    }

    @Test func allowedSourcesRestrictPicks() async {
        let streams = [stream(.youtube, 1), stream(.soundcloud, 2), stream(.mixcloud, 3), stream(.radio, 4)]
        let h = Harness(streams) { $0.allowedSources = [.mixcloud] }
        await h.startPlaying()
        #expect(h.controller.currentStream?.source == .mixcloud)
        #expect(await h.controller.eligibleCount(genre: deepHouse) == 1)
        #expect(!h.controller.engineConfig.isSourceEnabled(.radio))
    }

    @Test func surpriseMePicksAGenreWithPlayableStreams() async {
        let h = Harness([stream(.radio, 1), stream(.soundcloud, 2, genre: techno)], engineReady: false)
        await h.controller.prepare()
        h.controller.surpriseMe()
        await h.until("load") { h.player.loads.count == 1 }
        #expect(h.controller.snapshot.genre == deepHouse, "techno has nothing playable without the engine")
    }

    @Test func sessionAndLibraryArePersistedDebouncedAndRestored() async {
        let streams = (1...3).map { stream(.radio, $0) }
        let h = Harness(streams)
        let played = await h.startPlaying()
        #expect(!FileManager.default.fileExists(atPath: h.paths.sessionFile.path), "debounced")
        h.scheduler.advance(by: 2)
        let saved = StateFile.load(SessionFile.self, from: h.paths.sessionFile)
        #expect(saved?.last?.genre == deepHouse && saved?.last?.stream == played?.id && saved?.last?.wasPlaying == true)
        #expect(StateFile.load(Library.self, from: h.paths.libraryFile)?.history.last?.stream == played?.id)
        await h.controller.shutdown()
        #expect(Array(h.player.calls.suffix(2)) == ["pause", "shutdown"], "the quit fade, then the engine shutdown")
        let relaunched = h.make(streams)
        #expect(relaunched.resumedFrom?.stream == played?.id)
        #expect(relaunched.library.history.count == 1)
    }

    @Test func snapshotsArePublished() async {
        let h = Harness([stream(.radio, 1)])
        let updates = h.controller.snapshots()
        let collector = Task { () -> [PlaybackPhase] in
            var seen: [PlaybackPhase] = []
            for await s in updates {
                if seen.last != s.phase { seen.append(s.phase) }
                if s.phase == .playing { break }
            }
            return seen
        }
        await h.startPlaying()
        let phases = await collector.value
        #expect(phases.first == .idle && phases.contains(.buffering) && phases.last == .playing)
    }

    @Test func debugStateHasTheFlatKeysThePlanChecks() async throws {
        let h = Harness([stream(.radio, 1)]) { $0.writeDebugState = true }
        await h.startPlaying()
        await h.controller.writeDebugStateNow()
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: h.paths.debugState)) as? [String: Any])
        #expect(json["state"] as? String == "playing")
        #expect(json["genre"] as? String == "deep-house" && json["source"] as? String == "radio")
        #expect(json["ttfaMs"] is NSNumber && json["resumed"] as? Bool == false)
        #expect((json["stream"] as? [String: Any])?["id"] as? String == "radio:r1")
        #expect((json["engine"] as? [String: Any])?["state"] as? String == "ready")
        await h.controller.shutdown()
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: h.paths.debugState)) as? [String: Any])
        #expect(after["state"] as? String == "shutdown")
    }

    @Test func volumeAndBalancePassThrough() {
        let h = Harness([stream(.radio, 1)])
        #expect(h.player.volume == 100)
        h.controller.setVolume(150)
        #expect(h.player.volume == 100 && h.controller.snapshot.volume == 100)
        h.controller.setVolume(25)
        #expect(h.player.volume == 25)
        h.controller.setBalance(-0.5)
        #expect(h.player.calls.last == "balance -0.5" && h.controller.snapshot.balance == -0.5)
    }
}

/// The per-file option mapping (DESIGN §5.2) on its own.
@Test func loadPlanMapsResolvedStreamsAndTheProxy() {
    let yt = resolution(for: stream(.youtube, 1))
    let o = LoadPlan.options(for: yt, title: "C - T", proxy: URL(string: "http://127.0.0.1:8899"), start: 30)
    #expect(o.httpProxy == "http://127.0.0.1:8899" && o.start == 30 && o.mediaTitle == "C - T")
    #expect(o.lavf.first == LavfOption("request_size", "10485760"))
    #expect((try? o.optionMap())?["http-proxy"] == "http://127.0.0.1:8899")
    let hls = LoadPlan.options(for: resolution(for: stream(.soundcloud, 1)), title: nil, proxy: nil)
    #expect(hls.lavf.isEmpty && hls.httpProxy == nil)
    let radio = LoadPlan.radio(title: "R", proxy: URL(string: "https://secure.example.net:8443"))
    #expect(radio.httpProxy == nil, "mpv's http-proxy takes http:// only")
    #expect(radio.lavf == [LavfOption("reconnect_streamed", "1")])
    // M6: bounded back buffers (a VOD keeps 8 MiB for backward seeks; radio and live, which can't seek, 1 MiB).
    #expect(o.extra == [MPVOption("cache-secs", "30"), MPVOption("demuxer-donate-buffer", "no"),
                        MPVOption("demuxer-max-back-bytes", "8MiB")])
    #expect(radio.extra == [MPVOption("cache-secs", "30"), MPVOption("demuxer-donate-buffer", "no"),
                            MPVOption("demuxer-max-back-bytes", "1MiB")])
    var live = resolution(for: stream(.youtubeLive, 1))
    live.liveStatus = "is_live"
    #expect(LoadPlan.options(for: live, title: nil, proxy: nil).extra.last == MPVOption("demuxer-max-back-bytes", "1MiB"))
    #expect((try? radio.optionMap())?["demuxer-donate-buffer"] == "no")
    var noChunk = yt
    noChunk.httpChunkSize = nil
    #expect(LoadPlan.options(for: noChunk, title: nil, proxy: nil).lavf.map(\.key) == ["reconnect", "reconnect_streamed", "reconnect_delay_max"])
}

@Test func mpvErrorLinesAreClassified() {
    #expect(MPVPlayerEngine.classify(errorLines: ["ffmpeg: https: HTTP error 403 Forbidden"]) == .engine)
    #expect(MPVPlayerEngine.classify(errorLines: ["ffmpeg: HTTP error 404 Not Found"]) == .unavailable)
    #expect(MPVPlayerEngine.classify(errorLines: ["Failed to recognize file format."]) == .unavailable)
    #expect(MPVPlayerEngine.classify(errorLines: ["tcp: Connection timed out"]) == .transient)
    #expect(MPVPlayerEngine.classify(errorLines: []) == .transient)
}

@MainActor @Test func manualSchedulerRunsDueWorkInOrderAndMovesTheClock() {
    let clock = FakeTimeSource(fakeT0)
    let s = ManualScheduler(time: clock)
    var fired: [String] = []
    s.schedule(after: 2) { fired.append("b") }
    s.schedule(after: 1) { fired.append("a"); s.schedule(after: 0.5) { fired.append("a2") } }
    let c = s.schedule(after: 1.5) { fired.append("cancelled") }
    c.cancel()
    s.advance(by: 1.6)
    #expect(fired == ["a", "a2"] && clock.now == fakeT0.addingTimeInterval(1.6))
    s.advance(by: 1)
    #expect(fired == ["a", "a2", "b"] && s.pending == 0)
}
