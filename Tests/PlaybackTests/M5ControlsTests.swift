// SPDX-License-Identifier: GPL-3.0-or-later
// PLAN M5's controller additions: seek (VOD only), EQ, shuffle (Surprise-genre mode), repeat, favourites, bans
// (persisted in library.json, undoable), ★ Favourites, Recently Played, one-off streams, the skin's audio format
// fields, the shell's state.json sections and the settings it restores.
import Audio
import Catalog
import Core
import Foundation
import Picker
import Testing
@testable import Playback

@MainActor @Suite(.serialized) struct M5ControlsTests {
    @Test func seekWorksOnPlayingMixesOnly() async {
        let mix = stream(.soundcloud, 1)
        let h = Harness([mix])
        h.player.positionNow = PlayerPosition(timePos: 12, duration: 600, seekable: true)
        #expect(!h.controller.canSeek, "nothing plays")
        await h.startPlaying()
        #expect(h.controller.canSeek && h.controller.snapshot.canSeek)
        h.controller.seek(toFraction: 0.5)
        #expect(h.player.seeks == [300])
        #expect(h.controller.snapshot.position == 300, "the slider follows at once")
        h.controller.seek(toFraction: 2)
        #expect(h.player.seeks.last == 599, "clamped inside the file")
    }

    @Test func liveStreamsAndRadioCannotSeek() async {
        for source in [SourceKind.radio, .youtubeLive] {
            let h = Harness([stream(source, 1)])
            h.player.positionNow = PlayerPosition(timePos: 40, duration: 40, seekable: false)
            await h.startPlaying()
            #expect(!h.controller.canSeek, "\(source)")
            h.controller.seek(toFraction: 0.5)
            #expect(h.player.seeks.isEmpty, "\(source)")
        }
    }

    @Test func equalizerReachesTheEngineOnce() {
        let h = Harness([stream(.radio, 1)])
        var eq = EQPresets.named("Rock")!.settings()
        h.controller.setEqualizer(eq)
        h.controller.setEqualizer(eq)
        #expect(h.player.equalizers == [eq], "unchanged settings are not re-applied")
        eq.enabled = false
        h.controller.setEqualizer(eq)
        #expect(h.player.equalizers.last?.enabled == false && h.controller.equalizer == eq)
    }

    @Test func repeatReplaysAMixThatEnds() async {
        let a = stream(.soundcloud, 1), b = stream(.soundcloud, 2)
        let h = Harness([a, b])
        h.controller.setRepeatStream(true)
        #expect(h.controller.snapshot.repeatStream)
        h.player.positionNow = PlayerPosition(timePos: 590, duration: 600, seekable: true)
        let first = await h.startPlaying()
        let loads = h.player.loads.count
        h.player.emitEnd(.endOfFile)
        await h.until("reload") { h.player.loads.count > loads }
        #expect(h.controller.currentStream?.id == first?.id, "the same mix again")
    }

    @Test func repeatDoesNotLoopAFileThatEndsAtOnce() async {
        let a = stream(.soundcloud, 1), b = stream(.soundcloud, 2)
        let h = Harness([a, b])
        h.controller.setRepeatStream(true)
        h.player.positionNow = PlayerPosition(timePos: 0, duration: 600, seekable: true)
        let first = await h.startPlaying()
        let loads = h.player.loads.count
        h.player.emitEnd(.endOfFile)
        await h.until("next pick") { h.player.loads.count > loads }
        #expect(h.controller.currentStream?.id != first?.id, "a file that ends within 5 s moves on")
    }

    @Test func shuffleMovesNextToARandomGenre() async {
        var streams: [StreamRef] = []
        for n in 1...3 { streams.append(stream(.radio, n)) }
        for n in 4...6 { streams.append(stream(.radio, n, genre: techno)) }
        let h = Harness(streams)
        await h.startPlaying(deepHouse)
        h.controller.setShuffleGenres(true)
        var genres = Set<GenreID>()
        for _ in 0..<12 {
            let loads = h.player.loads.count
            h.controller.next()
            await h.until("next") { h.player.loads.count > loads }
            h.player.emitFirstAudio()
            await h.until("playing") { h.controller.phase == .playing }
            if let g = h.controller.snapshot.genre { genres.insert(g) }
        }
        #expect(genres == [deepHouse, techno], "Surprise-genre mode visits both genres")
    }

    @Test func favouritesToggleAndPersistInLibraryJSON() async {
        let a = stream(.soundcloud, 1), b = stream(.soundcloud, 2)
        let h = Harness([a, b]) { $0.persistState = true }
        let playing = await h.startPlaying()
        let id = try! #require(playing?.id)
        #expect(h.controller.toggleFavourite() == true)
        #expect(h.controller.snapshot.isFavourite && h.controller.isFavourite(id))
        #expect(h.controller.favouriteStreams.map(\.id) == [id])
        h.controller.persistNow()
        let reopened = h.make([a, b]) { $0.persistState = true }
        #expect(reopened.library.favourites == [id], "library.json keeps favourites")
        #expect(h.controller.toggleFavourite() == false)
        #expect(!h.controller.snapshot.isFavourite)
    }

    @Test func banSkipsAtOncePersistsAndCanBeUndone() async {
        let a = stream(.soundcloud, 1), b = stream(.soundcloud, 2)
        let h = Harness([a, b]) { $0.persistState = true }
        let first = await h.startPlaying()
        let loads = h.player.loads.count
        let banned = h.controller.banCurrent()
        #expect(banned == first?.id)
        await h.until("skip") { h.player.loads.count > loads }
        #expect(h.controller.currentStream?.id != banned, "never played again: skipped now")
        #expect(h.controller.recentlyBanned().map(\.id) == [banned!])
        h.controller.persistNow()
        #expect(h.make([a, b]) { $0.persistState = true }.library.banned == [banned!])
        #expect(h.controller.unban() == banned)
        #expect(h.controller.library.banned.isEmpty)
    }

    @Test func favouritesModePlaysOnlyFavourites() async {
        var streams: [StreamRef] = []
        for n in 1...6 { streams.append(stream(.radio, n)) }
        let h = Harness(streams)
        await h.controller.prepare()
        h.controller.toggleFavourite(streams[1].id)
        h.controller.toggleFavourite(streams[4].id)
        h.controller.startFavourites()
        #expect(h.controller.favouritesMode)
        var played = Set<StreamID>()
        for _ in 0..<8 {
            let loads = h.player.loads.count
            if played.isEmpty {
                await h.until("load") { h.player.loads.count > loads }
            } else {
                h.controller.next()
                await h.until("next") { h.player.loads.count > loads }
            }
            h.player.emitFirstAudio()
            await h.until("playing") { h.controller.phase == .playing }
            if let id = h.controller.currentStream?.id { played.insert(id) }
        }
        #expect(played == [streams[1].id, streams[4].id])
        #expect(h.controller.snapshot.statusText.hasPrefix("[FAVOURITES] "))
        h.controller.start(genre: deepHouse)
        #expect(!h.controller.favouritesMode, "choosing a genre leaves ★ Favourites")
    }

    @Test func recentlyPlayedIsDistinctAndNewestFirst() async {
        let a = stream(.radio, 1), b = stream(.radio, 2)
        let h = Harness([a, b])
        await h.controller.prepare()
        for s in [a, b, a] {
            let loads = h.player.loads.count
            h.controller.play(stream: s.id)
            await h.until("load") { h.player.loads.count > loads }
            h.player.emitFirstAudio()
            await h.until("playing") { h.controller.phase == .playing && h.controller.currentStream?.id == s.id }
        }
        #expect(h.controller.recentlyPlayed().map(\.id) == [a.id, b.id])
    }

    @Test func aPastedStreamPlaysWithoutBeingInTheCatalog() async {
        let h = Harness([stream(.radio, 1)])
        await h.controller.prepare()
        let id = StreamID.make(source: .soundcloud, ref: "someone/pasted")!
        let pasted = StreamRef(id: id, source: .soundcloud, ref: "someone/pasted", kind: .mix, title: "someone/pasted",
                               creator: "SoundCloud", genres: [deepHouse])
        h.controller.play(adHoc: pasted, startAt: 90)
        await h.until("load") { !h.player.loads.isEmpty }
        #expect(h.controller.currentStream?.id == id)
        #expect(h.player.lastLoad?.request.options.start == 90, "a pasted #t= starts there")
    }

    @Test func audioFormatComesFromThePositionSample() {
        let format = AudioFormatInfo(PlayerPosition(audioBitrate: 128_400, sampleRate: 44_100, channelCount: 2))
        #expect(format == AudioFormatInfo(kbps: 128, sampleRate: 44_100, channels: 2))
        #expect(AudioFormatInfo(PlayerPosition(timePos: 3)) == nil)
    }

    @Test func shellStateAndErrorsReachTheDebugState() async {
        let h = Harness([stream(.radio, 1)])
        let skin = AppSkinDebugInfo(id: "andamp-dark", name: "AndAmp Dark", origin: "bundled")
        h.controller.setShellState(skin: skin, ui: AppUIDebugInfo(mode: "skinned", scale: 2, menuAutoOpened: true))
        h.controller.noteShellError(kind: "skinRejected", message: "bomb.wsz: entryTooLarge", stage: "skin")
        let state = await h.controller.debugState()
        #expect(state.skin?.id == "andamp-dark" && state.ui?.menuAutoOpened == true && state.ui?.scale == 2)
        #expect(state.lastError?.kind == "skinRejected" && h.controller.snapshot.lastError?.stage == "skin")
        #expect(state.library?.favourites == [])
    }
}

@Suite struct AppSettingsM5Tests {
    @Test func skinEQAndTogglesRoundTrip() throws {
        var s = AppSettings()
        s.skin = "andamp-light"
        s.equalizer = EQPresets.named("Techno")!.settings(enabled: false)
        s.eqPreset = "Techno"
        s.shuffle = true
        s.repeat = true
        s.timeRemaining = true
        s.visualizer = "oscilloscope"
        s.regionEnabled = false
        s.balance = -0.25
        s.addUserPreset(EQPreset(name: "Mine", preamp: 3, bands: [1, 2, 3]))
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == s)
    }

    @Test func badFieldsKeepTheirDefaults() throws {
        let json = #"{"volume": "loud", "visualizer": "milkdrop", "equalizer": {"bands": [40, -40]}, "balance": 7}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.volume == AppSettings.defaultVolume && s.visualizer == "spectrum" && s.regionEnabled)
        #expect(s.equalizer.bands.prefix(2) == [12, -12], "EQ gains are clamped to ±12 dB")
        #expect(s.balance == 1)
    }

    @Test func theModernVisualizerCarriesTheClassicChoiceOver() throws {
        // Settings from before the modern visualiser had its own choice.
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"visualizer": "off"}"#.utf8))
        #expect(old.visualizer == "off" && old.modernVisualizer == "off")
        #expect(old.visualizerInterval == 20 && old.artworkColors == "genre" && old.visualizerEffect == "none")
        let json = #"{"visualizer": "oscilloscope", "modernVisualizer": "starfield", "visualizerInterval": 9999, "artworkColors": "cycle", "visualizerEffect": "vhs"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.visualizer == "oscilloscope" && s.modernVisualizer == "starfield" && s.artworkColors == "cycle")
        #expect(s.visualizerEffect == "vhs")
        #expect(s.visualizerInterval == 600, "clamped")
        var round = AppSettings()
        round.modernVisualizer = "rotate"
        round.visualizerInterval = 30
        round.artworkColors = "source"
        round.visualizerEffect = "kaleidoscope"
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(round)) == round)
    }

    @Test func userPresetsReplaceByNameAndStayBounded() {
        var s = AppSettings()
        for n in 0..<(AppSettings.maxUserPresets + 5) { s.addUserPreset(EQPreset(name: "P\(n)", preamp: 0, bands: [])) }
        #expect(s.userPresets.count == AppSettings.maxUserPresets)
        s.addUserPreset(EQPreset(name: "p54", preamp: 6, bands: []))
        #expect(s.userPresets.last?.preamp == 6 && s.userPresets.filter { $0.name.lowercased() == "p54" }.count == 1)
    }
}

@Suite struct SnapshotProgressTests {
    @Test func positionAloneIsProgress() {
        var a = PlayerSnapshot(phase: .playing, statusText: "x")
        var b = a
        b.position = 12
        b.duration = 600
        b.audioFormat = AudioFormatInfo(kbps: 128)
        #expect(b.sameExceptProgress(a), "state.json may wait for these")
        a.phase = .paused
        #expect(!b.sameExceptProgress(a), "a phase change is written at once")
    }
}
