// SPDX-License-Identifier: GPL-3.0-or-later
// DESIGN §8.4: PlayerSnapshot → ModernPlayerState (ModernDisplay), the skin-class switch's pure parts, and the
// appearance and tint menus.
import AppKit
import Audio
import Catalog
import ModernUI
import Picker
import Playback
import Testing
@testable import Shell

@Suite struct ModernDisplayTests {
    let streams = [mix(1), mix(2, source: .soundcloud, duration: 461), mix(3, source: .radio), mix(4, source: .youtubeLive)]

    func state(_ s: PlayerSnapshot, prefs: ModernDisplay.Prefs = .init(), eq: EQSettings = EQSettings(),
               remembered: String? = nil) -> ModernPlayerState {
        ModernDisplay.state(s, playlist: streams.map(StreamInfo.init), equalizer: eq, prefs: prefs, rememberedGenre: remembered)
    }

    @Test func firstLaunchAsksForAGenre() {
        let m = state(snapshot(.idle, genre: nil))
        #expect(m.title == ModernDisplay.idleTitle && m.subtitle == ModernDisplay.idleSubtitle)
        #expect(m.genre == nil && m.playback == .stopped && !m.working && m.notice == nil && m.source == nil)
        #expect(state(snapshot(.idle, genre: nil), remembered: "Deep House").title == "Press play for Deep House")
        let stopped = state(snapshot(.idle))
        #expect(stopped.title == "Stopped" && stopped.genre == "Deep House" && stopped.genreKey == "deep-house")
    }

    @Test func aPlayingMixShowsTitleCreatorTimeAndFormat() {
        var s = snapshot(.playing, stream: streams[1])
        s.position = 127.6
        s.duration = 461
        s.audioFormat = AudioFormatInfo(kbps: 256, sampleRate: 44_100, channels: 2)
        s.isFavourite = true
        let m = state(s, prefs: .init(timeRemaining: true))
        #expect(m.title == "Track 2" && m.subtitle == "User 2" && m.playback == .playing)
        #expect(m.source == .soundcloud && !m.isLive && m.duration == 461 && m.elapsed == 127.6 && m.canSeek)
        #expect(m.showsRemaining && m.format == "256 kbps · 44.1 kHz")
        #expect(m.isFavourite && m.canFavourite && m.currentStation == 1)
        #expect(m.volume == 0.8)
    }

    @Test func radioShowsItsICYTitleOverTheStation() {
        var s = snapshot(.playing, stream: streams[2])
        s.icyTitle = "DJ Nova - Midnight"
        let m = state(s)
        #expect(m.title == "DJ Nova - Midnight" && m.subtitle == "Station 3")
        #expect(m.isLive && m.duration == nil && !m.canSeek && m.source == .radio)
        s.icyTitle = nil
        #expect(state(s).title == "Station 3" && state(s).subtitle == "Radio")
        #expect(state(snapshot(.playing, stream: streams[3])).isLive, "YouTube live")
    }

    @Test func tuningSpinsAndSkippingSaysSo() {
        let tuning = state(snapshot(.tuning, status: FlashMessage.tuning.text))
        #expect(tuning.working && tuning.playback == .playing && tuning.title == "Tuning…" && tuning.subtitle == "Deep House")
        #expect(!tuning.isAnimating)
        let skipping = state(snapshot(.buffering, stream: streams[0], status: FlashMessage.skipping.text))
        #expect(skipping.notice == .info("Skipped an unavailable stream") && skipping.title == "Mix 1")
    }

    @Test func failuresAndOfflineAreProblems() {
        let failed = state(snapshot(.failed))
        #expect(failed.title == "Can't reach streams" && failed.notice?.isProblem == true && failed.offersRetry)
        let offline = state(snapshot(.offline, stream: streams[0]))
        #expect(offline.notice == .problem("Offline · sudamp carries on by itself") && !offline.offersRetry)
        #expect(offline.playback == .stopped && offline.title == "Mix 1")
        var broken = snapshot(.playing, stream: streams[0])
        broken.audioEngineError = "guard failed"
        let m = state(broken)
        #expect(m.title == "Audio engine error" && m.playback == .stopped && m.notice?.isProblem == true)
    }

    @Test func theStreamEngineNoticeShowsWhileOnlyRadioPlays() {
        var s = snapshot(.playing, stream: streams[2])
        s.radioOnly = true
        s.engine = EngineStatus(state: .installing, progress: 0.63)
        #expect(state(s).notice == .info("Preparing stream engine 63% · radio meanwhile") && !state(s).offersRetry)
        s.engine = EngineStatus(state: .failed, download: "unreachable")
        #expect(state(s).notice == .problem("Engine download failed · radio only") && state(s).offersRetry)
        s.engine = EngineStatus(state: .failed, download: "noSpace")
        #expect(state(s).notice == .problem("Stream engine needs 180 MB free · radio only"))
        s.engine = EngineStatus(state: .ready)
        s.radioOnly = false
        #expect(state(s).notice == nil)
    }

    @Test func mutedIsSaidOnlyBeforeAnythingPlays() {
        #expect(state(snapshot(.idle, genre: nil), prefs: .init(muted: true)).notice == .info("Muted for this launch"))
        #expect(state(snapshot(.playing, stream: streams[0]), prefs: .init(muted: true)).notice == nil)
    }

    @Test func favouritesAndTheStationList() {
        var s = snapshot(.playing, stream: streams[0])
        s.favouritesMode = true
        let m = state(s)
        #expect(m.genre == "Favourites" && m.stationsTitle == "Favourites" && m.genreKey == "favourites")
        #expect(m.stations.map(\.tag) == [.youtube, .soundcloud, .radio, .youtube])
        #expect(m.stations[0].title == "Mix 1" && m.stations[0].subtitle == "Creator 1" && m.stations[0].duration == 3720)
        #expect(m.stations[2].title == "Station 3" && m.stations[2].subtitle.isEmpty && m.stations[2].duration == nil)
        #expect(m.stations[3].duration == nil, "live")
        #expect(state(snapshot(.idle, genre: nil)).stationsTitle == "Stations")
    }

    @Test func equalizerAndVisualizerPrefs() {
        var eq = EQSettings()
        eq.enabled = false
        eq.preamp = 3
        eq.bands[0] = -6
        let m = state(snapshot(.idle), prefs: .init(visualizer: "oscilloscope", eqPreset: "Rock"), eq: eq)
        #expect(!m.equalizer.enabled && m.equalizer.preamp == 3 && m.equalizer.bands[0] == -6 && m.equalizer.preset == "Rock")
        #expect(m.visualizer == .oscilloscope)
        #expect(state(snapshot(.idle), prefs: .init(visualizer: "bogus")).visualizer == .spectrum)
        let rotating = state(snapshot(.idle), prefs: .init(visualizer: "rotate", visualizerInterval: 30, artworkColors: "source"))
        #expect(rotating.visualizer == .rotate && rotating.visualizerInterval == 30 && rotating.artworkColors == .source)
        #expect(state(snapshot(.idle), prefs: .init(visualizer: "pixel-dj")).visualizer == .pixelDJ)
        #expect(state(snapshot(.idle), prefs: .init(visualizer: "breakfast-band")).visualizer == .breakfastBand)
        #expect(state(snapshot(.idle), prefs: .init(visualizerEffect: "kaleidoscope")).visualizerEffect == .kaleidoscope)
        #expect(state(snapshot(.idle), prefs: .init(visualizerEffect: "sepia")).visualizerEffect == .none)
        let odd = state(snapshot(.idle), prefs: .init(visualizerInterval: .nan, artworkColors: "plaid"))
        #expect(odd.visualizerInterval == ModernPlayerState.defaultVisualizerInterval && odd.artworkColors == .genre)
        #expect(state(snapshot(.idle), prefs: .init(visualizerInterval: 1)).visualizerInterval == 5, "at least 5 s a scene")
    }

    /// The source colours need the source: it is known while a stream plays, not before.
    @Test func theSourceTagFollowsThePlayingStream() {
        #expect(state(snapshot(.playing, stream: mix(5, source: .mixcloud))).source == .mixcloud)
        #expect(state(snapshot(.playing, stream: streams[2])).source == .radio)
        #expect(state(snapshot(.idle, genre: nil)).source == nil)
    }

    @Test func formatText() {
        #expect(ModernDisplay.formatText(AudioFormatInfo(kbps: 128, sampleRate: 48_000, channels: 1)) == "128 kbps · 48 kHz · Mono")
        #expect(ModernDisplay.formatText(AudioFormatInfo()) == nil)
    }
}

@MainActor @Suite struct SkinClassMenuTests {
    @Test func skinClassesAndTheirSettings() {
        #expect(SkinClass.allCases.map(\.rawValue) == AppSettings.skinClasses)
        #expect(SkinClass(rawValue: AppSettings.defaultSkinClass) == .modern, "the modern skin is the default")
        var settings = AppSettings()
        #expect(ModernPlayerUI.appearance(settings) == .auto && ModernPlayerUI.tint(settings) == .teal)
        settings.modernAppearance = "dark"
        settings.modernTint = "bogus"
        #expect(ModernPlayerUI.appearance(settings) == .dark && ModernPlayerUI.tint(settings) == .teal)
    }

    @Test func appearanceAndTintMenusTickTheCurrentChoice() {
        let target = NSObject()
        let appearance = PlayerStyleHost.appearanceMenu(current: .light, target: target, action: #selector(NSObject.description))
        #expect(appearance.items.map(\.title) == ["Automatic", "Light", "Dark"])
        #expect(appearance.items.filter { $0.state == .on }.map(\.title) == ["Light"])
        let tints = PlayerStyleHost.tintMenu(current: .blue, target: target, action: #selector(NSObject.description))
        #expect(tints.items.count == ModernTint.allCases.count)
        #expect(tints.items.filter { $0.state == .on }.compactMap { $0.representedObject as? String } == ["blue"])
        #expect(tints.items.allSatisfy { $0.image != nil }, "every tint shows its swatch")
    }

    @Test func theVisualizerMenuListsEveryChoiceTicked() {
        let target = NSObject()
        let action = #selector(NSObject.description)
        let menu = ModernPlayerUI.visualizerMenu(current: .pixelDJ, interval: 30, colors: .source, effect: .vhs, target: target,
                                                 choose: action, every: action, background: action, finish: action)
        let titles = menu.items.filter { !$0.isSeparatorItem && !$0.isSectionHeader }.map(\.title)
        #expect(titles == ModernPlayerState.Visualizer.scenes.map(\.title) + ["Rotate", "Rotate Every", "Off", "Background", "Effect"])
        // The scenes sit under their sections' headers.
        var section: String?
        for item in menu.items {
            if item.isSectionHeader { section = item.title }
            if let raw = item.representedObject as? String, let mode = ModernPlayerState.Visualizer(rawValue: raw), mode.isScene {
                #expect(section == mode.section?.title, "\(mode)")
            }
        }
        #expect(menu.items.filter(\.isSectionHeader).map(\.title) == ModernPlayerState.Visualizer.Section.allCases.map(\.title))
        #expect(menu.items.filter { $0.state == .on }.compactMap { $0.representedObject as? String } == ["pixel-dj"])
        let every = menu.items.first { $0.title == "Rotate Every" }?.submenu
        #expect(every?.items.map(\.title) == ["10 Seconds", "20 Seconds", "30 Seconds", "1 Minute"])
        #expect(every?.items.filter { $0.state == .on }.compactMap { $0.representedObject as? Double } == [30])
        let background = menu.items.first { $0.title == "Background" }?.submenu
        #expect(background?.items.map(\.title) == ["Genre", "Window", "Cycle", "Source"])
        #expect(background?.items.filter { $0.state == .on }.compactMap { $0.representedObject as? String } == ["source"])
        let effect = menu.items.first { $0.title == "Effect" }?.submenu
        #expect(effect?.items.map(\.title) == ["None", "VHS", "Kaleidoscope"])
        #expect(effect?.items.filter { $0.state == .on }.compactMap { $0.representedObject as? String } == ["vhs"])
        #expect(ModernPlayerUI.intervalTitle(120) == "2 Minutes")
    }
}
