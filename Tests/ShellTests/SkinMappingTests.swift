// SPDX-License-Identifier: GPL-3.0-or-later
// PLAN M5 mapping logic: PlayerSnapshot → SkinPlayerState (SkinDisplay) and SkinControlEvent → action (SkinActions).
import Audio
import Catalog
import CoreGraphics
import Picker
import Playback
import SkinKit
import SkinUI
import Testing
@testable import Shell

@Suite struct SkinDisplayTests {
    let streams = [mix(1), mix(2, source: .soundcloud, duration: 461), mix(3, source: .radio), mix(4, source: .youtubeLive)]

    func state(_ s: PlayerSnapshot, prefs: SkinPrefs = SkinPrefs(), eq: EQSettings = EQSettings(),
               remembered: String? = nil) -> SkinPlayerState {
        SkinDisplay.playerState(s, playlist: streams.map(StreamInfo.init), equalizer: eq, prefs: prefs,
                                rememberedGenre: remembered)
    }

    @Test func firstLaunchInvitesAPick() {
        let p = state(snapshot(.idle, genre: nil))
        #expect(p.title == "*** CLICK HERE TO PICK A GENRE ***")
        #expect(p.playState == .stopped && !p.working && p.duration == nil && p.kbps == nil)
    }

    @Test func theEngineNoticeRidesAlongWhileOnlyRadioCanPlay() {
        var s = snapshot(.idle, genre: nil)
        s.engine = EngineStatus(state: .installing, progress: 0.63)
        s.radioOnly = true
        #expect(state(s).title == "*** CLICK HERE TO PICK A GENRE ***  ***  PREPARING STREAM ENGINE 63%")
        var radio = snapshot(.playing, stream: streams[2], status: "[DEEP HOUSE] DJ NOVA - MIDNIGHT")
        radio.engine = s.engine
        radio.radioOnly = true
        #expect(state(radio).title == "[DEEP HOUSE] DJ NOVA - MIDNIGHT  ***  PREPARING STREAM ENGINE 63%")
    }

    @Test func aRememberedGenreIsOffered() {
        let p = state(snapshot(.idle, genre: nil), remembered: "Deep House")
        #expect(p.title == "PRESS PLAY FOR DEEP HOUSE, OR CLICK HERE TO PICK A GENRE")
        #expect(state(snapshot(.idle)).title == "[DEEP HOUSE] STOPPED - PRESS PLAY, OR CLICK HERE TO PICK A GENRE")
    }

    @Test func aPlayingMixShowsItsTimeFormatAndRow() {
        var s = snapshot(.playing, stream: streams[1], status: "[DEEP HOUSE] USER 2 - TRACK 2")
        s.position = 127.6
        s.duration = 461
        s.audioFormat = AudioFormatInfo(kbps: 256, sampleRate: 44_100, channels: 2)
        s.balance = -0.5
        let p = state(s)
        #expect(p.title == "[DEEP HOUSE] USER 2 - TRACK 2" && p.playState == .playing)
        #expect(p.elapsed == 127.6 && p.duration == 461)
        #expect(p.kbps == 256 && p.khz == 44 && p.stereo == true, "44.1 kHz shows as 44, like Winamp")
        #expect(p.volume == 0.8 && p.balance == -0.5)
        #expect(p.currentRow == 1)
        #expect(p.playlist.map(\.tag) == [.youtube, .soundcloud, .radio, .youtube])
        #expect(p.playlist[1].title == "User 2 - Track 2" && p.playlist[1].duration == 461)
        #expect(p.playlist[2].duration == nil && p.playlist[3].duration == nil && p.liveLabel == "LIVE")
    }

    @Test func liveAndRadioHaveNoLength() {
        var s = snapshot(.playing, stream: streams[3], status: "[DEEP HOUSE] CHANNEL 4 - LIVE 4")
        s.position = 30
        s.duration = 30  // live ICY reports a growing duration
        let p = state(s, prefs: SkinPrefs(timeRemaining: true))
        #expect(p.duration == nil && p.timeDisplay == .elapsed, "remaining time needs a length")
        var mono = snapshot(.paused, stream: streams[2], status: "[DEEP HOUSE] STATION 3")
        mono.audioFormat = AudioFormatInfo(kbps: 64, sampleRate: 22_050, channels: 1)
        let m = state(mono)
        #expect(m.stereo == false && m.khz == 22 && m.playState == .paused)
    }

    @Test func tuningOfflineFailedAndTheEngineGuard() {
        let tuning = state(snapshot(.tuning, genre: technoID, status: "TUNING…"))
        #expect(tuning.title == "[TECHNO] TUNING…" && tuning.working && tuning.playState == .playing)
        let offline = state(snapshot(.offline, status: "OFFLINE"))
        #expect(offline.title == "OFFLINE" && offline.working && offline.playState == .stopped)
        #expect(state(snapshot(.failed)).title == "CAN'T REACH STREAMS - CLICK TO RETRY")
        var fault = snapshot(.playing, stream: streams[0], status: "[DEEP HOUSE] X")
        fault.audioEngineError = "guard"
        #expect(state(fault).title == "AUDIO ENGINE ERROR" && state(fault).playState == .stopped)
    }

    @Test func togglesPrefsAndEQReachTheSkin() {
        var s = snapshot(.playing, stream: streams[0], status: "[FAVOURITES] CREATOR 1 - MIX 1")
        s.shuffleGenres = true
        s.repeatStream = true
        s.favouritesMode = true
        let eq = EQPresets.named("Rock")!.settings(enabled: false)
        let p = state(s, prefs: SkinPrefs(timeRemaining: true, visualizer: .oscilloscope, alwaysSkinFont: true, eqAuto: true),
                      eq: eq)
        #expect(p.shuffle && p.repeat && p.timeDisplay == .remaining && p.visualizerMode == .oscilloscope)
        #expect(p.alwaysSkinFont && p.equalizer.auto && !p.equalizer.enabled)
        #expect(p.equalizer.bands == eq.bands.map(Double.init) && p.equalizer.preamp == Double(eq.preamp))
        #expect(SkinDisplay.label(s) == "[FAVOURITES]")
    }

    @Test func thePlaylistIsTheGenreLessItsBans() {
        let all = [mix(1), mix(2), mix(3, genre: technoID), mix(4, source: .radio)]
        let catalog = catalogOf(all)
        let list = SkinDisplay.playlist(genre: deepHouseID, favouritesMode: false, catalog: catalog, favourites: [],
                                        banned: [all[1].id])
        #expect(list.map(\.id) == [all[0].id, all[3].id])
        let favourites = SkinDisplay.playlist(genre: deepHouseID, favouritesMode: true, catalog: catalog,
                                              favourites: [all[2]], banned: [])
        #expect(favourites.map(\.id) == [all[2].id], "★ Favourites lists the favourites")
        #expect(SkinDisplay.playlist(genre: nil, favouritesMode: false, catalog: catalog, favourites: [], banned: []).isEmpty)
    }

    @Test func prefsReadSettings() {
        var settings = AppSettings()
        settings.visualizer = "off"
        settings.timeRemaining = true
        #expect(SkinPrefs(settings) == SkinPrefs(timeRemaining: true, visualizer: .off))
        #expect(SkinPrefs.mode(SkinPrefs.name(.oscilloscope)) == .oscilloscope)
    }
}

@Suite struct SkinActionsTests {
    let point = CGPoint(x: 10, y: 20)

    func action(_ e: SkinControlEvent, _ s: PlayerSnapshot, canPlay: Bool = true) -> SkinAction {
        SkinActions.action(for: e, snapshot: s, canPlayWithoutPick: canPlay)
    }

    @Test func transport() {
        let playing = snapshot(.playing, stream: mix(1))
        let paused = snapshot(.paused, stream: mix(1))
        #expect(action(.play, paused) == .resume)
        #expect(action(.play, snapshot(.failed)) == .retry)
        #expect(action(.play, snapshot(.idle, genre: nil), canPlay: false) == .genreMenu(.marquee),
                "Play with nothing to play opens the genre menu")
        #expect(action(.play, snapshot(.idle, genre: nil), canPlay: true) == .play)
        #expect(action(.pause, playing) == .pause && action(.pause, paused) == .resume, "Winamp's pause toggles")
        #expect(action(.pause, snapshot(.idle)) == SkinAction.none)
        #expect(action(.stop, playing) == .stop && action(.next, playing) == .next && action(.previous, playing) == .previous)
        #expect(action(.eject, playing) == .openStreamURL)
    }

    @Test func seekOnlyWhereItWorks() {
        #expect(action(.seek(fraction: 0.4), snapshot(.playing, stream: mix(1))) == .seek(fraction: 0.4))
        #expect(action(.seek(fraction: 0.4), snapshot(.playing, stream: mix(1, source: .radio))) == SkinAction.none)
    }

    @Test func slidersBecomeAppUnits() {
        let s = snapshot(.playing, stream: mix(1))
        #expect(action(.volume(0.5), s) == .volume(50))
        #expect(action(.volume(3), s) == .volume(100))
        #expect(action(.balance(-2), s) == .balance(-1))
        #expect(action(.eqBand(index: 3, decibels: 6), s) == .eqBand(index: 3, decibels: 6))
        #expect(action(.eqBand(index: 12, decibels: 6), s) == SkinAction.none)
        #expect(action(.preamp(decibels: -3), s) == .preamp(decibels: -3))
        #expect(action(.eqSetAll(decibels: 12), s) == .eqSetAll(decibels: 12))
        #expect(action(.eqToggle, s) == .eqToggle && action(.eqAuto, s) == .eqAuto)
    }

    @Test func everyGenreAnchorOpensTheGenreMenu() {
        let idle = snapshot(.idle, genre: nil)
        #expect(action(.marqueeClick(screenPoint: point), idle) == .genreMenu(.marquee))
        #expect(action(.optionsMenu(screenPoint: point), idle) == .genreMenu(.options))
        #expect(action(.contextMenu(screenPoint: point), idle) == .contextMenu(point), "right-click: Genre ▸ inside")
        #expect(action(.marqueeClick(screenPoint: point), snapshot(.failed)) == .retry, "CLICK TO RETRY")
    }

    @Test func menusTogglesAndWindows() {
        let s = snapshot(.playing, stream: mix(1))
        #expect(action(.presetsMenu(screenPoint: point), s) == .presetsMenu(point))
        #expect(action(.clutter(.options, screenPoint: point), s) == .contextMenu(point))
        #expect(action(.clutter(.visualizer, screenPoint: point), s) == .visualizerMenu(point))
        #expect(action(.clutter(.info, screenPoint: point), s) == .streamInfoMenu(point))
        #expect(action(.playlistMenu(.list, screenPoint: point), s) == .playlistMenu(.list, point))
        #expect(action(.shuffle, s) == .toggleShuffle && action(.repeat, s) == .toggleRepeat)
        #expect(action(.timeModeToggle, s) == .toggleTimeDisplay && action(.visualizerModeToggle, s) == .cycleVisualizer)
        #expect(action(.playlistRowActivated(index: 4), s) == .playRow(4))
        #expect(action(.close(.main), s) == .quit, "closing Main quits through the quit path")
        for windowEvent: SkinControlEvent in [.plToggle, .eqWindowToggle, .minimize, .shade(.main), .close(.playlist),
                                              .clutter(.alwaysOnTop, screenPoint: point), .clutter(.doubleSize, screenPoint: point),
                                              .playlistRowSelected(index: 1), .playlistScroll(firstRow: 2)] {
            #expect(action(windowEvent, s) == SkinAction.none, "\(windowEvent) is WindowManager's or the view's")
        }
        #expect(action(.about, s) == .about)
    }
}
