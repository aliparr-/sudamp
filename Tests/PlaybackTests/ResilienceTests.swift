// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import MPV
import Picker
import Resolver
import Testing
@testable import Playback

/// Per-host DNS answers (anything unlisted is public).
struct MapHosts: HostResolving {
    var map: [String: [IPAddress]]
    func addresses(for host: String) async throws -> [IPAddress] { map[host] ?? [.v4(0x0102_0304)] }
}

/// PLAN M6 through the controller: breakers, engine updates and rollback, offline, mid-stream recovery, the
/// background re-resolve, the `stream:expire` fault and the radio redirect rule.
@MainActor @Suite struct ResilienceTests {
    static let http403 = ResolveFailure(.engine, "http403", message: "HTTP Error 403: Forbidden")
    static let botCheck = ResolveFailure(.botCheck, "notABot", message: "Sign in to confirm you're not a bot")

    // MARK: Breakers and engine updates

    @Test func twoEngineFailuresOpenTheBreakerAskForOneUpdateAndPlaybackMovesOn() async {
        let yt1 = stream(.youtube, 1), yt2 = stream(.youtube, 2), sc = stream(.soundcloud, 3)
        let clock = FakeTimeSource(fakeT0)
        let engines = UpdateRecordingEngines(clock: clock)
        let h = Harness([yt1, yt2, sc], engines: engines)
        await h.resolver.script(yt1.id, .fail(Self.http403))
        await h.resolver.script(yt2.id, .fail(Self.http403))
        await h.controller.prepare()
        h.controller.play(stream: yt1.id)
        await h.until("advanced past yt1") { h.controller.currentStream?.id != yt1.id }
        h.controller.play(stream: yt2.id)
        await h.until("update check") { await engines.checks == [.engineFailures] }
        await h.until("advanced to SoundCloud") { h.controller.currentStream?.id == sc.id }
        let yt = h.controller.breakerSummary()["youtube"]
        #expect(yt?.state == .open && yt?.kind == .engine)
        #expect(yt?.reopenAt == h.clock.now.addingTimeInterval(15 * 60))
        #expect(await h.controller.eligibleCount(genre: deepHouse) == 1, "only SoundCloud is eligible")
        #expect(h.metricsEvents("breaker").contains { $0["change"] as? String == "open" && $0["kind"] as? String == "engine" })
        // Two more engine failures inside the 2 h floor: no second update check.
        h.controller.play(stream: yt1.id)
        await h.until("advanced") { h.controller.currentStream?.id != yt1.id }
        h.controller.play(stream: yt2.id)
        await h.until("advanced") { h.controller.currentStream?.id != yt2.id }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await engines.checks == [.engineFailures])
    }

    @Test func aRecentUpdateIsRolledBackInsteadOfCheckingAgain() async {
        let yt1 = stream(.youtube, 1), yt2 = stream(.youtube, 2), sc = stream(.soundcloud, 3)
        let clock = FakeTimeSource(fakeT0)
        let engines = UpdateRecordingEngines(clock: clock)
        await engines.setRollback(.ready(version: "2026.08.19", executable: URL(filePath: "/nonexistent/old")))
        let h = Harness([yt1, yt2, sc], engines: engines)
        await h.resolver.script(yt1.id, .fail(Self.http403))
        await h.resolver.script(yt2.id, .fail(Self.http403))
        await h.controller.prepare()
        h.controller.play(stream: yt1.id)
        await h.until("advanced") { h.controller.currentStream?.id != yt1.id }
        h.controller.play(stream: yt2.id)
        await h.until("rolled back") { h.controller.snapshot.engine.version == "2026.08.19" }
        #expect(await engines.rollbacks == 1)
        #expect(await engines.checks.isEmpty)
        #expect(await h.resolver.engine == URL(filePath: "/nonexistent/old"))
    }

    @Test func botCheckBreakerSurvivesARelaunchAndEscalates() async {
        let yt1 = stream(.youtube, 1), yt2 = stream(.youtube, 2)
        let h = Harness([yt1, yt2]) { $0.allowedSources = [.youtube] }
        await h.resolver.script(yt1.id, .fail(Self.botCheck))
        await h.resolver.script(yt2.id, .fail(Self.botCheck))
        await h.controller.prepare()
        h.controller.start(genre: deepHouse)
        await h.until("failed") { h.controller.phase == .failed }
        let first = h.controller.breakerSummary()["youtube"]
        #expect(first?.state == .open && first?.kind == .botCheck)
        #expect(first?.reopenAt == fakeT0.addingTimeInterval(6 * 3600))
        await h.until("resolver paused") { await h.resolver.blocks.contains { $0.0 == .youtube } }
        await h.controller.shutdown()   // persists session.json
        let text = (try? String(contentsOf: h.paths.sessionFile, encoding: .utf8)) ?? ""
        #expect(text.contains("\"breakers\"") && text.contains("reopenAt"))

        // Relaunch 21,700 s later (past the reopen, as PLAN M6's SUDAMP_CLOCK_OFFSET rerun): one probe, which trips
        // it again for 12 h.
        h.clock.advance(by: 21_700)
        let relaunched = h.make([yt1, yt2]) { $0.allowedSources = [.youtube] }
        #expect(relaunched.breakerSummary()["youtube"]?.state == .halfOpen)
        await relaunched.prepare()
        relaunched.start(genre: deepHouse)
        await h.until("probe tripped") { relaunched.breakerSummary()["youtube"]?.state == .open }
        let second = relaunched.breakerSummary()["youtube"]
        #expect(second?.reopenAt == h.clock.now.addingTimeInterval(12 * 3600))
        #expect(second?.trips["botCheck"] == 2)
        await relaunched.shutdown()
    }

    @Test func threeTransientFailuresOnTwoSoundCloudStreamsOpenItsBreaker() async {
        let streams = (1...4).map { stream(.soundcloud, $0) } + [stream(.radio, 5)]
        let h = Harness(streams) { $0.allowedSources = [.soundcloud, .radio] }
        for s in streams.prefix(4) { await h.resolver.script(s.id, .fail(ResolveFailure(.transient, "http5xx"))) }
        await h.controller.prepare()
        for s in streams.prefix(3) {
            h.controller.play(stream: s.id)
            await h.until("advanced past \(s.id)") { h.controller.currentStream?.id != s.id }
        }
        let sc = h.controller.breakerSummary()["soundcloud"]
        #expect(sc?.state == .open && sc?.kind == .transient)
        #expect(sc?.reopenAt == h.clock.now.addingTimeInterval(15 * 60))
        await h.until("radio") { h.controller.currentStream?.source == .radio }
    }

    @Test func aCorruptEngineIsRepairedWhileRadioPlays() async {
        let engines = UpdateRecordingEngines([.corrupt("tree.json mismatch: modified _internal/x"), UpdateRecordingEngines.ready],
                                       clock: FakeTimeSource(fakeT0))
        let h = Harness([stream(.radio, 1), stream(.soundcloud, 2)], engines: engines)
        await h.controller.prepare()
        await h.until("repaired") { h.controller.snapshot.engine.state == .ready }
        #expect(await engines.repairs == 1)
        #expect(h.metricsEvents("engine.corrupt").count == 1)
    }

    @Test func aBuildTheFeedBlocksIsNeverRun() async {
        var engine = EngineConfig.defaults
        engine.block = ["2026.10.21"]
        let engines = UpdateRecordingEngines(clock: FakeTimeSource(fakeT0))
        await engines.setInstallVersion("2026.08.19")
        let h = Harness([stream(.radio, 1), stream(.soundcloud, 2)], engines: engines, engine: engine)
        await h.controller.prepare()
        await h.until("replaced") { h.controller.snapshot.engine.version == "2026.08.19" && h.controller.snapshot.engine.isReady }
        #expect(await engines.installs == 1)
        #expect(await h.resolver.engine == URL(filePath: "/nonexistent/2026.08.19"), "the blocked build never reached the resolver")
        #expect(h.metricsEvents("engine.blocked").first?["version"] as? String == "2026.10.21")
    }

    @Test func aPinFirstInstallAsksForAnUpdateRightAway() async {
        let engines = UpdateRecordingEngines([.missing], clock: FakeTimeSource(fakeT0))
        let h = Harness([stream(.radio, 1)], engines: engines) { $0.engineMode = .install }
        await h.controller.prepare()
        await h.until("update check") { await engines.checks == [.afterPinInstall] }
        #expect(await engines.installs == 1)
    }

    @Test func theLaunchCheckWaitsAndTheDailyOneRepeats() async {
        let engines = UpdateRecordingEngines(clock: FakeTimeSource(fakeT0))
        let h = Harness([stream(.radio, 1)], engines: engines)
        await h.controller.prepare()
        await h.until("warm-up") { await engines.notedWarmUps.count == 1 }
        #expect(await h.resolver.warmUps == 1)
        #expect(await engines.notedWarmUps.first?.version == "2026.10.21")
        h.scheduler.advance(by: 29)
        #expect(await engines.checks.isEmpty)
        h.scheduler.advance(by: 1)
        await h.until("launch check") { await engines.checks == [.launch] }
        h.scheduler.advance(by: 24 * 3600)
        await h.until("daily check") { await engines.checks == [.launch, .daily] }
        #expect(await h.resolver.warmUps == 1, "once per launch")
    }

    @Test func noUpdatesWhenTurnedOff() async {
        let engines = UpdateRecordingEngines(clock: FakeTimeSource(fakeT0))
        let h = Harness([stream(.radio, 1)], engines: engines) { $0.engineUpdates = false }
        await h.controller.prepare()
        h.scheduler.advance(by: 3600)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await engines.checks.isEmpty)
    }

    // MARK: Offline

    @Test func aBlipIsIgnoredALongerLossGoesOfflineAndResumesAtThePosition() async {
        let sc = stream(.soundcloud, 1)
        let h = Harness([sc])
        await h.startPlaying()
        let loads = h.player.loads.count
        h.network.send(NetworkPathStatus(isSatisfied: false))
        await h.until("seen") { h.metricsEvents("network").count == 1 }
        h.scheduler.advance(by: 8)
        h.network.send(NetworkPathStatus(isSatisfied: true, interfaces: ["en0/wifi"]))
        await h.until("seen") { h.metricsEvents("network").count == 2 }
        h.scheduler.advance(by: 15)
        #expect(h.controller.phase == .playing, "an 8 s blip while playing is carried by the cache")

        h.player.positionNow = PlayerPosition(timePos: 42, duration: 3600, seekable: true)
        h.network.send(NetworkPathStatus(isSatisfied: false))
        await h.until("seen") { h.metricsEvents("network").count == 3 }
        h.scheduler.advance(by: 9.9)
        #expect(h.controller.phase == .playing)
        h.scheduler.advance(by: 0.1)
        #expect(h.controller.phase == .offline)
        #expect(h.controller.snapshot.statusText == "OFFLINE")
        #expect(h.player.calls.last == "stop")
        h.network.send(NetworkPathStatus(isSatisfied: true, interfaces: ["en0/wifi"]))
        await h.until("reloaded") { h.player.loads.count == loads + 1 }
        #expect(h.player.lastLoad?.request.options.start == 42)
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.phase == .playing }
        let t = h.metricsEvents("ttfa").last
        #expect(t?["trigger"] as? String == "networkRestored" && t?["reload"] as? Bool == true)
        #expect(h.controller.debugCounters.streamsStarted == 1, "the resume is not a new stream")
        #expect(h.controller.debugCounters.offlineEpisodes == 1)
    }

    @Test func whileNotPlayingTheDebounceIsTwoSeconds() async {
        let sc = stream(.soundcloud, 1)
        let h = Harness([sc])
        await h.resolver.script(sc.id, .hang)
        await h.controller.prepare()
        h.controller.start(genre: deepHouse)
        await h.until("tuning") { await h.resolver.calls.count == 1 }
        h.network.send(NetworkPathStatus(isSatisfied: false))
        await h.until("seen") { h.metricsEvents("network").count == 1 }
        h.scheduler.advance(by: 1.9)
        #expect(h.controller.phase == .tuning)
        h.scheduler.advance(by: 0.1)
        #expect(h.controller.phase == .offline)
    }

    @Test func aFailureWhileThePathIsDownGoesOfflineInsteadOfSkipping() async {
        let h = Harness([stream(.radio, 1), stream(.radio, 2)])
        await h.startPlaying()
        h.network.send(NetworkPathStatus(isSatisfied: false))
        await h.until("seen") { h.metricsEvents("network").count == 1 }
        h.player.emitEnd(.error("Connection reset by peer", .transient))
        await h.until("offline") { h.controller.phase == .offline }
        #expect(h.controller.debugCounters.failures == 0)
        #expect(h.player.loads.count == 1)
    }

    // MARK: Mid-stream recovery (DESIGN §6.3)

    @Test func aMidStream403ReloadsAtThePositionThenMovesOnIfItKeepsFailing() async {
        let yt = stream(.youtube, 1), sc = stream(.soundcloud, 2)
        let h = Harness([yt, sc])
        await h.controller.prepare()
        h.controller.play(stream: yt.id)
        await h.until("load") { h.player.loads.count == 1 }
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.phase == .playing }
        h.scheduler.advance(by: 10)
        h.player.positionNow = PlayerPosition(timePos: 600, duration: 3600, seekable: true)
        h.player.emitEnd(.error("HTTP error 403 Forbidden", .engine))
        await h.until("reload") { h.player.loads.count == 2 }
        #expect(h.controller.currentStream?.id == yt.id)
        #expect(await h.resolver.evictions == [yt.id], "the 403'd URL is not reused")
        let reload = h.player.loads[1].request
        #expect(reload.options.start == 600)
        #expect(reload.url != h.player.loads[0].request.url, "re-resolved")
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.phase == .playing }
        let resumed = h.metricsEvents("recover.resumed").first
        #expect(resumed?["savedPosition"] as? Double == 600)
        #expect(h.metricsEvents("ttfa").last?["trigger"] as? String == "recover")
        #expect(h.controller.debugCounters.recoveries == 1 && h.controller.debugCounters.failures == 0)
        // Dying again at once (under the 5 s minimum): it moves on.
        h.player.emitEnd(.error("HTTP error 403 Forbidden", .engine))
        await h.until("moved on") { h.controller.currentStream?.id == sc.id }
        #expect(h.controller.debugCounters.failures == 1)
    }

    @Test func recoveriesAreLimitedPerStream() async {
        let r = stream(.radio, 1)
        let h = Harness([r, stream(.radio, 2)]) { $0.timings.recoveryLimit = 2 }
        await h.startPlaying()
        for n in 1...2 {
            h.scheduler.advance(by: 6)
            h.player.emitEnd(.error("Connection reset", .transient))
            await h.until("reload \(n)") { h.player.loads.count == n + 1 }
            h.player.emitFirstAudio()
            await h.until("playing") { h.controller.phase == .playing }
        }
        h.scheduler.advance(by: 6)
        h.player.emitEnd(.error("Connection reset", .transient))
        await h.until("moved on") { h.controller.currentStream?.id != r.id }
        #expect(h.controller.debugCounters.recoveries == 2)
    }

    @Test func aPrematureEndOfFileIsRecovered() async {
        let h = Harness([stream(.soundcloud, 1), stream(.soundcloud, 2)])
        let sc = await h.startPlaying()
        h.player.positionNow = PlayerPosition(timePos: 100, duration: 3600, seekable: true)
        h.scheduler.advance(by: 10)
        h.player.emitEnd(.endOfFile)
        await h.until("reload") { h.player.loads.count == 2 }
        #expect(h.controller.currentStream?.id == sc?.id)
        #expect(h.player.lastLoad?.request.options.start == 100)
        #expect(h.metricsEvents("recover").first?["reason"] as? String == "prematureEOF")
        #expect(await h.resolver.evictions.isEmpty, "a premature EOF reuses the unexpired URL")
    }

    @Test func theBackgroundReResolveRunsTenMinutesBeforeExpiryAndRecoveryUsesIt() async {
        let sc = stream(.soundcloud, 1)
        // The fake's URLs expire 6 h after fakeT0; move "10 min before expiry" to 20 s after the start.
        let h = Harness([sc]) { $0.timings.refreshBeforeExpiry = 6 * 3600 - 20 }
        await h.startPlaying()
        h.scheduler.advance(by: 19)
        #expect(await !h.resolver.calls.contains { $0.purpose == .prefetch })
        h.scheduler.advance(by: 1)
        await h.until("refresh") { h.metricsEvents("refresh").count == 1 }
        #expect(await h.resolver.calls.last == .init(id: sc.id, purpose: .prefetch))
        #expect(h.metricsEvents("refresh").first?["ok"] as? Bool == true)
        let fresh = await h.resolver.cached(sc.id)?.url
        #expect(fresh != nil && fresh != h.player.loads[0].request.url)
        h.player.emitEnd(.error("HTTP error 403 Forbidden", .engine))
        await h.until("reload") { h.player.loads.count == 2 }
        #expect(h.player.loads[1].request.url == fresh, "the refreshed URL is used without another resolve")
        #expect(await h.resolver.evictions == [sc.id], "only the refresh evicted (the expiring entry)")
        #expect(h.metricsEvents("recover").first?["refreshed"] as? Bool == true)
    }

    @Test func streamExpireFaultRefreshesThenDiesWithA403AndResumes() async {
        let yt = stream(.youtube, 1)
        let h = Harness([yt]) { $0.faults = PlaybackFaults(streamExpire: true, refreshAfter: 15, failAfter: 25) }
        await h.startPlaying()
        h.player.positionNow = PlayerPosition(timePos: 25, duration: 3600, seekable: true)
        h.scheduler.advance(by: 15)
        await h.until("refresh") { h.metricsEvents("refresh").count == 1 }
        h.scheduler.advance(by: 10)
        await h.until("reload") { h.player.loads.count == 2 }
        #expect(h.metricsEvents("fault.streamExpire").count == 1)
        #expect(h.player.loads[1].request.options.start == 25)
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.phase == .playing }
        // Once per stream.
        h.scheduler.advance(by: 60)
        #expect(h.metricsEvents("fault.streamExpire").count == 1)
    }

    // MARK: Radio redirects (security item)

    @Test func ffmpegFollowsNoRedirectWeFollowAndRememberTheHop() async {
        let r = stream(.radio, 1)
        let cdn = "https://cdn.example.net/live?t=1"
        let redirects = FakeRedirects([r.url.absoluteString: cdn])
        let h = Harness([r], redirects: redirects)
        await h.controller.prepare()
        h.controller.play(stream: r.id)
        await h.until("load") { h.player.loads.count == 1 }
        // First play: FFmpeg goes straight to the station, following nothing (no request of ours yet).
        #expect(h.player.loads[0].request.url == r.url)
        #expect(h.player.loads[0].request.options.lavf == [LavfOption("reconnect_streamed", "1"), LavfOption("max_redirects", "0")])
        #expect(redirects.calls.withLock { $0 }.isEmpty)
        // It answers with a redirect, which FFmpeg refuses: we follow it (checked) in the same attempt.
        h.player.emitEnd(.error("Failed to open", .transient))
        await h.until("redirected") { h.player.loads.count == 2 }
        #expect(h.player.loads[1].request.url.absoluteString == cdn)
        #expect(h.controller.debugCounters.failures == 0)
        h.player.emitFirstAudio()
        await h.until("playing") { h.controller.phase == .playing }
        // The hop is remembered (session.json): the next play walks it first and opens the CDN directly.
        h.controller.persistNow()
        let text = (try? String(contentsOf: h.paths.sessionFile, encoding: .utf8)) ?? ""
        #expect(text.contains("radioRedirectHops"))
        h.controller.play(stream: r.id)
        await h.until("third load") { h.player.loads.count == 3 }
        #expect(h.player.loads[2].request.url.absoluteString == cdn)
        #expect(redirects.calls.withLock { $0 } == [r.url.absoluteString, r.url.absoluteString])
        #expect(h.metricsEvents("radio.redirects").last?["hops"] as? Int == 1)
    }

    @Test func aRedirectToAPrivateAddressIsRefused() async {
        let r = stream(.radio, 1), ok = stream(.radio, 2)
        let redirects = FakeRedirects([r.url.absoluteString: "https://evil.example.org/x"])
        let h = Harness([r, ok], hosts: MapHosts(map: ["evil.example.org": [.v4(0x7F00_0001)]]), redirects: redirects)
        await h.controller.prepare()
        h.controller.play(stream: r.id)
        await h.until("load") { h.player.loads.count == 1 }
        h.player.emitEnd(.error("Failed to open", .transient))
        await h.until("moved on") { h.player.loads.count == 2 }
        #expect(h.player.loads[1].request.url == ok.url, "FFmpeg never saw the 127.0.0.1 hop")
        let failure = h.metricsEvents("failure").first
        #expect(failure?["stage"] as? String == "dns" && failure?["kind"] as? String == "unavailable")
        #expect((failure?["message"] as? String)?.contains("evil.example.org") == true)
    }

    /// PLAN M6 `make test`: radio hosts resolving to 127.0.0.1, 10.0.0.0/8 or 169.254.0.0/16 are rejected before
    /// mpv sees them.
    @Test func radioHostsResolvingToPrivateAddressesAreRejected() async {
        for addr: IPAddress in [.v4(0x7F00_0001), .v4(0x0A01_0203), .v4(0xA9FE_A9FE)] {
            let r = stream(.radio, 1)
            let h = Harness([r], hosts: FakeHosts(addresses: [addr]))
            await h.controller.prepare()
            h.controller.play(stream: r.id)
            await h.until("refused \(addr)") { h.controller.phase == .failed || h.metricsEvents("failure").count == 1 }
            #expect(h.player.loads.isEmpty, "\(addr) reached mpv")
            let failure = h.metricsEvents("failure").first
            #expect(failure?["stage"] as? String == "dns" && failure?["kind"] as? String == "unavailable")
            #expect((failure?["message"] as? String)?.contains(addr.description) == true)
        }
    }

    @Test func aGenuineFailureIsReportedAfterOneLook() async {
        let r = stream(.radio, 1), ok = stream(.radio, 2)
        let redirects = FakeRedirects()
        let h = Harness([r, ok], redirects: redirects)
        await h.controller.prepare()
        h.controller.play(stream: r.id)
        await h.until("load") { h.player.loads.count == 1 }
        h.player.emitEnd(.error("HTTP error 503", .transient))
        await h.until("moved on") { h.player.loads.count == 2 && h.controller.currentStream?.id == ok.id }
        #expect(redirects.calls.withLock { $0 } == [r.url.absoluteString])
        #expect(h.controller.debugCounters.failures == 1)
    }

    @Test func theWalkChecksEveryHop() async {
        let start = URL(string: "https://a.example.com/s")!
        // A redirect to an IP literal (the cloud metadata address) is refused by the URL rule itself …
        let toIP = FakeRedirects([start.absoluteString: "http://169.254.169.254/latest/meta-data"])
        await #expect(throws: RadioRedirects.WalkError.self) {
            try await RadioRedirects.walk(start, hosts: FakeHosts(), fetch: toIP, hops: 3)
        }
        // … and names answering with 10.0.0.0/8, 169.254.0.0/16 or 127.0.0.0/8 by the DNS rule.
        let toName = FakeRedirects([start.absoluteString: "https://lan.example.org/x"])
        for addr: IPAddress in [.v4(0x0A00_0001), .v4(0xA9FE_A9FE), .v4(0x7F00_0001)] {
            await #expect(throws: RadioRedirects.WalkError.self) {
                try await RadioRedirects.walk(start, hosts: MapHosts(map: ["lan.example.org": [addr]]), fetch: toName, hops: 3)
            }
        }
        // A walk stops at its hop budget without fetching the URL it ends on (FFmpeg opens it).
        let chain = FakeRedirects([start.absoluteString: "https://b.example.com/s", "https://b.example.com/s": "https://c.example.com/s"])
        let one = try? await RadioRedirects.walk(start, hosts: FakeHosts(), fetch: chain, hops: 1)
        #expect(one?.url.absoluteString == "https://b.example.com/s" && one?.hops == 1 && one?.complete == false)
        #expect(chain.calls.withLock { $0 } == [start.absoluteString])
        let none = try? await RadioRedirects.walk(start, hosts: FakeHosts(), fetch: chain, hops: 0)
        #expect(none?.url == start && chain.calls.withLock { $0 }.count == 1, "zero hops: no request")
        await #expect(throws: RadioRedirects.WalkError.tooManyRedirects) {
            try await RadioRedirects.next(after: start, hops: RadioRedirects.maxHops, hosts: FakeHosts(), fetch: chain)
        }
    }
}
