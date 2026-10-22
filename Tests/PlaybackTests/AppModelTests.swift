// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import Picker
import Testing
@testable import Playback

/// The pure models Shell draws and acts on: resume rule, genre menu, Now Playing mapping, plain-window text.
@Suite struct ResumePolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let vod = stream(.soundcloud, 1)  // 3600 s in the fake catalog
    let live = stream(.youtubeLive, 2)
    let radio = stream(.radio, 3)
    var catalog: FeedCatalog { feed([vod, live, radio]).document.catalog }

    func last(_ s: StreamRef?, at position: Double? = nil, ago: TimeInterval = 600, playing: Bool = true) -> LastSession {
        LastSession(genre: deepHouse, stream: s?.id, positionSec: position, wasPlaying: playing,
                    savedAt: now.addingTimeInterval(-ago))
    }

    func plan(_ l: LastSession?, enabled: Bool = true, engineReady: Bool = true) -> ResumePlan {
        ResumePolicy.plan(last: l, catalog: catalog, now: now, enabled: enabled, engineReady: engineReady)
    }

    @Test func nothingToResume() {
        #expect(plan(nil) == .none(reason: "nothing played before"))
        #expect(plan(last(vod, at: 100), enabled: false) == .none(reason: "auto-resume is off"))
        #expect(plan(last(vod, at: 100, playing: false)) == .none(reason: "was not playing at quit"))
        let gone = LastSession(genre: GenreID(rawValue: "gone")!, wasPlaying: true, savedAt: now)
        #expect(plan(gone) == .none(reason: "genre gone is gone"))
    }

    @Test func aRecentVODResumesAtItsPosition() {
        #expect(plan(last(vod, at: 1200)) == .stream(deepHouse, vod.id, startAt: 1200))
        #expect(plan(last(vod, at: 1200, ago: 6 * 3600 - 1)) == .stream(deepHouse, vod.id, startAt: 1200))
    }

    @Test func anOldOrNearlyFinishedVODPlaysTheNextBagItem() {
        #expect(plan(last(vod, at: 1200, ago: 6 * 3600)) == .genre(deepHouse), "quit 6 h ago or more")
        #expect(plan(last(vod, at: 3600 - 300)) == .genre(deepHouse), "5 min or less left")
        #expect(plan(last(vod, at: 3600 - 301)) == .stream(deepHouse, vod.id, startAt: 3299))
        #expect(plan(last(vod, at: nil)) == .genre(deepHouse), "no saved position")
        #expect(plan(last(vod, at: 100, ago: -60)) == .genre(deepHouse), "a clock that went backwards")
    }

    @Test func liveAndRadioRejoinTheLiveEdge() {
        #expect(plan(last(live, at: 5000)) == .stream(deepHouse, live.id, startAt: nil))
        #expect(plan(last(radio, ago: 30 * 86400)) == .stream(deepHouse, radio.id, startAt: nil), "age doesn't matter live")
    }

    @Test func withoutTheEngineOnlyRadioReplays() {
        #expect(plan(last(vod, at: 100), engineReady: false) == .genre(deepHouse))
        #expect(plan(last(radio), engineReady: false) == .stream(deepHouse, radio.id, startAt: nil))
    }

    @Test func aStreamNoLongerInTheGenrePlaysTheGenre() {
        #expect(plan(last(stream(.mixcloud, 9))) == .genre(deepHouse))
        #expect(plan(last(nil)) == .genre(deepHouse))
    }
}

@Suite struct GenreMenuModelTests {
    let genres = [Genre(id: techno, name: "Techno", order: 2), Genre(id: deepHouse, name: "Deep House", order: 1)]

    @Test func genresInOrderThenSurpriseMeWithShortcuts() {
        let rows = GenreMenuModel.items(genres: genres, availability: [:], current: techno, shortcuts: true)
        #expect(rows.map(\.title) == ["Deep House", "Techno", "", "Surprise Me"])
        #expect(rows.map(\.keyEquivalent) == ["1", "2", nil, "0"])
        #expect(rows.map(\.isChecked) == [false, true, false, false])
        #expect(rows.allSatisfy { $0.isEnabled }, "unknown availability is shown enabled")
        #expect(rows[2].kind == .separator && rows[3].kind == .surpriseMe && rows[0].genre == deepHouse)
        #expect(GenreMenuModel.items(genres: genres, availability: [:], current: nil, shortcuts: false)
            .allSatisfy { $0.keyEquivalent == nil })
    }

    @Test func aGenreWithNothingPlayableIsDisabledWithItsReason() {
        let availability: [GenreID: GenreAvailability] = [
            deepHouse: GenreAvailability(eligible: 3, total: 13),
            techno: GenreAvailability(eligible: 0, total: 12, reason: .engineNotReady),
        ]
        let rows = GenreMenuModel.items(genres: genres, availability: availability, current: nil, shortcuts: false)
        #expect(rows[0].isEnabled && rows[0].subtitle == nil)
        #expect(!rows[1].isEnabled && rows[1].subtitle == "Waiting for the stream engine")
        #expect(rows[3].isEnabled, "Surprise Me needs only one playable genre")
        let none = GenreMenuModel.items(genres: genres, availability: availability.mapValues {
            GenreAvailability(eligible: 0, total: $0.total, reason: .breakerOpen)
        }, current: nil, shortcuts: false)
        #expect(!none[3].isEnabled && none[3].subtitle != nil)
    }

    @Test func everyReasonHasWords() {
        for reason in Ineligibility.allCases {
            #expect(GenreAvailability(eligible: 0, total: 1, reason: reason).unavailableText?.isEmpty == false)
        }
        #expect(GenreAvailability(eligible: 0, total: 0).unavailableText == "No streams yet")
        #expect(GenreAvailability(eligible: 1, total: 1).unavailableText == nil)
    }

    @Test func automationStatesMatchThePhases() {
        let phases = Set(PlaybackPhase.allCases.map(\.rawValue)).union(["audioEngineError"])
        #expect(AutomationScript.knownStates == phases)
    }
}

@Suite struct NowPlayingInfoTests {
    func snapshot(_ s: StreamRef?, phase: PlaybackPhase, icy: String? = nil, position: Double? = nil,
                  duration: Double? = nil) -> PlayerSnapshot {
        PlayerSnapshot(phase: phase, genre: deepHouse, genreName: "Deep House", stream: s.map(StreamInfo.init),
                       icyTitle: icy, position: position, duration: duration, statusText: "TUNING…")
    }

    @Test func playbackStateFollowsEveryPhase() {
        #expect(PlaybackPhase.allCases.map(NowPlayingInfo.state(for:)) == [
            .stopped, .interrupted, .interrupted, .playing, .paused, .interrupted, .stopped,
        ])
        var s = snapshot(stream(.radio, 1), phase: .playing)
        s.audioEngineError = "guard"
        #expect(NowPlayingInfo.from(s).playbackState == .stopped)
    }

    @Test func aVODHasDurationAndElapsed() {
        let sc = stream(.soundcloud, 1)
        let info = NowPlayingInfo.from(snapshot(sc, phase: .playing, position: 61, duration: 3500))
        #expect(info == NowPlayingInfo(playbackState: .playing, title: "Title 1", artist: "Creator",
                                       albumTitle: "Deep House", isLiveStream: false, duration: 3500, elapsed: 61, rate: 1,
                                       excludeFromSuggestions: true, streamId: sc.id.rawValue, sourceTag: "SC"))
        #expect(NowPlayingInfo.from(snapshot(sc, phase: .playing)).duration == 3600, "the feed's duration until mpv's")
        #expect(NowPlayingInfo.from(snapshot(sc, phase: .paused, position: 61)).rate == 0)
    }

    @Test func liveRadioIsALiveStreamWithItsICYTitle() {
        let r = stream(.radio, 2)
        let info = NowPlayingInfo.from(snapshot(r, phase: .playing, icy: "Artist - Track", position: 999, duration: 999))
        #expect(info.isLiveStream && info.duration == nil && info.elapsed == nil)
        #expect(info.title == "Artist - Track" && info.artist == "Creator - Title 2" && info.sourceTag == "FM")
        #expect(NowPlayingInfo.from(snapshot(r, phase: .playing, icy: "")).title == "Title 2")
        #expect(NowPlayingInfo.from(snapshot(stream(.youtubeLive, 3), phase: .buffering)).playbackState == .interrupted)
    }

    @Test func nothingChosenIsStoppedWithoutATitle() {
        let idle = NowPlayingInfo.from(PlayerSnapshot())
        #expect(idle.playbackState == .stopped && idle.title == nil && idle.streamId == nil)
        #expect(NowPlayingInfo.from(snapshot(nil, phase: .tuning)).title == "TUNING…")
    }

    @Test func elapsedAloneIsNotAChange() {
        let a = NowPlayingInfo(playbackState: .playing, title: "t", elapsed: 1, rate: 1)
        var b = a
        b.elapsed = 9
        #expect(a.sameExceptElapsed(b))
        b.title = "u"
        #expect(!a.sameExceptElapsed(b))
    }
}

@Suite struct PlainDisplayTests {
    func snapshot(_ s: StreamRef?, phase: PlaybackPhase, status: String = "", position: Double? = nil,
                  duration: Double? = nil, icy: String? = nil) -> PlayerSnapshot {
        PlayerSnapshot(phase: phase, genre: s == nil ? nil : deepHouse, genreName: s == nil ? nil : "Deep House",
                       stream: s.map(StreamInfo.init), icyTitle: icy, position: position, duration: duration,
                       engine: EngineStatus(state: .ready), statusText: status)
    }

    @Test func idlePromptsForAPick() {
        let d = PlainDisplay(PlayerSnapshot(engine: EngineStatus(state: .installing, progress: 0.634)))
        #expect(d.title == PlainDisplay.pickPrompt && d.status == "READY" && !d.showsPause && !d.offersRetry)
        #expect(d.engineNotice == "PREPARING STREAM ENGINE 63%")
        #expect(PlainDisplay(PlayerSnapshot(), lastGenreName: "Lo-fi").title == "Press Play for Lo-fi, or pick a genre")
    }

    @Test func playingAVODShowsPositionSourceAndTTFA() {
        let yt = stream(.youtube, 1)
        var s = snapshot(yt, phase: .playing, position: 754, duration: 7100)
        s.lastTTFA = TTFAInfo(ms: 1821.4, attemptMs: 1821.4, source: .youtube, streamId: yt.id, tier: 1, prefetched: false,
                              fromCache: false, trigger: "selectGenre", at: Date())
        let d = PlainDisplay(s, muted: true)
        #expect(d.title == "Creator - Title 1")
        #expect(d.detail == "YT  ·  12:34 / 1:58:20")
        #expect(d.status == "PLAYING  ·  YouTube  ·  TTFA 1821 ms  ·  MUTED")
        #expect(d.showsPause && !d.isProblem && d.engineNotice == nil)
    }

    @Test func radioShowsTheICYTitleAndLive() {
        let r = stream(.radio, 2)
        let d = PlainDisplay(snapshot(r, phase: .playing, icy: "Artist - Track"))
        #expect(d.title == "Artist - Track" && d.detail == "FM  ·  Creator - Title 2  ·  LIVE")
        #expect(PlainDisplay(snapshot(r, phase: .playing)).detail == "FM  ·  LIVE")
        var same = StreamInfo(r)
        same.title = "Deep Radio"
        same.creator = "Deep Radio"
        #expect(PlainDisplay.stationName(same) == "Deep Radio")
        let tuning = PlainDisplay(PlayerSnapshot(phase: .tuning, genre: deepHouse, genreName: "Deep House", statusText: "TUNING…"))
        #expect(tuning.title == "Deep House" && tuning.detail == "" && tuning.status == "TUNING…" && tuning.showsPause)
    }

    @Test func failureStatesReadAsProblems() {
        #expect(PlainDisplay(snapshot(nil, phase: .tuning, status: "SKIPPING - UNAVAILABLE")).status == "SKIPPING - UNAVAILABLE")
        #expect(PlainDisplay(snapshot(nil, phase: .tuning, status: "TUNING…")).status == "TUNING…")
        let failed = PlainDisplay(snapshot(nil, phase: .failed))
        #expect(failed.status == "CAN'T REACH STREAMS - CLICK TO RETRY" && failed.offersRetry && failed.isProblem)
        #expect(PlainDisplay(snapshot(nil, phase: .offline)).status == "OFFLINE")
        var broken = snapshot(stream(.radio, 1), phase: .idle)
        broken.audioEngineError = "guard"
        #expect(PlainDisplay(broken).status == "AUDIO ENGINE ERROR")
        var noEngine = PlayerSnapshot(engine: EngineStatus(state: .failed, download: "unreachable"))
        #expect(PlainDisplay(noEngine).engineNotice == "ENGINE DOWNLOAD FAILED - RADIO ONLY" && PlainDisplay(noEngine).offersRetry)
        noEngine.engine.download = "noSpace"
        #expect(PlainDisplay(noEngine).engineNotice == "STREAM ENGINE NEEDS 180 MB FREE - RADIO ONLY")
    }

    @Test func clockFormats() {
        #expect(PlainDisplay.clock(0) == "0:00" && PlainDisplay.clock(59.9) == "0:59" && PlainDisplay.clock(3599) == "59:59")
        #expect(PlainDisplay.clock(3600) == "1:00:00" && PlainDisplay.clock(-5) == "0:00" && PlainDisplay.clock(.nan) == "0:00")
    }
}

@Suite struct AppSettingsTests {
    @Test func defaultsRoundTripAndLenientDecoding() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths.profile(root)
        #expect(AppSettings.load(paths) == AppSettings())
        var s = AppSettings()
        s.volume = 42
        s.genreMenuShown = true
        try s.save(paths)
        #expect(AppSettings.load(paths) == s)
        try Data(#"{"version": 1, "volume": 900, "autoResume": "maybe"}"#.utf8).write(to: AppSettings.file(paths))
        let lenient = AppSettings.load(paths)
        #expect(lenient.volume == 100 && lenient.autoResume && !lenient.genreMenuShown)
    }
}
