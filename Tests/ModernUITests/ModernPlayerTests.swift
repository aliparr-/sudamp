// SPDX-License-Identifier: GPL-3.0-or-later
// DESIGN §8.4: the modern window offscreen (never ordered on screen): controls send their events, panels open and
// close and size the window, appearance and tint apply, the layout persists.
import AppKit
import Foundation
import Testing
@testable import ModernUI

@MainActor func makePlayer(layoutURL: URL? = nil, panels: Set<ModernPanel> = []) -> (ModernPlayer, Recorder) {
    _ = NSApplication.shared
    var configuration = ModernPlayer.Configuration()
    configuration.layoutURL = layoutURL
    configuration.initialPanels = panels
    let player = ModernPlayer(configuration: configuration)
    let recorder = Recorder()
    player.onEvent = { recorder.events.append($0) }
    return (player, recorder)
}

@MainActor final class Recorder {
    var events: [ModernEvent] = []
}

@MainActor func playing() -> ModernPlayerState {
    var s = ModernPlayerState()
    s.playback = .playing
    s.title = "Sunset Sessions"
    s.subtitle = "Solar Crew"
    s.genre = "Deep House"
    s.genreKey = "deep-house"
    s.source = .soundcloud
    s.duration = 600
    s.elapsed = 60
    s.canSeek = true
    s.canFavourite = true
    s.stations = [.init(tag: .soundcloud, title: "Sunset Sessions", subtitle: "Solar Crew", duration: 600),
                  .init(tag: .radio, title: "Deep Radio")]
    s.currentStation = 0
    return s
}

@MainActor @Suite(.serialized) struct ModernPlayerTests {
    @Test func controlsSendTheirEvents() {
        let (player, recorder) = makePlayer()
        player.state = playing()
        #expect(player.press(.next) && player.press(.previous) && player.press(.favourite))
        #expect(player.press(.pause), "playing: the button pauses")
        #expect(!player.press(.retry), "no Retry without a failure")
        #expect(player.drag(.volume, to: 0.25))
        #expect(player.drag(.position, to: 0.5))
        #expect(player.playStation(1) && !player.playStation(9))
        #expect(recorder.events.contains(.next) && recorder.events.contains(.previous) && recorder.events.contains(.favourite))
        #expect(recorder.events.contains(.playPause))
        #expect(recorder.events.contains(.volume(0.25)) && recorder.events.contains(.seek(0.5)))
        #expect(recorder.events.contains(.playStation(1)))
        player.close()
    }

    @Test func liveStreamsCannotSeek() {
        let (player, recorder) = makePlayer()
        var s = playing()
        s.isLive = true
        s.duration = nil
        s.canSeek = false
        player.state = s
        #expect(!player.drag(.position, to: 0.5))
        #expect(!recorder.events.contains { if case .seek = $0 { true } else { false } })
        player.close()
    }

    @Test func theEqualizerSendsDecibels() {
        let (player, recorder) = makePlayer(panels: [.equalizer])
        player.state = playing()
        #expect(player.drag(.eq3, to: ModernPlayer.eqFraction(decibels: 6)))
        #expect(player.drag(.preamp, to: ModernPlayer.eqFraction(decibels: -3)))
        #expect(player.press(.eqToggle) && player.press(.eqReset) == false, "flat: nothing to reset")
        #expect(recorder.events.contains(.eqBand(3, 6)) && recorder.events.contains(.preamp(-3)))
        #expect(recorder.events.contains(.eqEnabled(false)))
        player.close()
    }

    @Test func panelsSizeTheWindowAndPersist() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "modern-player-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "modern-layout.json")
        let (player, recorder) = makePlayer(layoutURL: url)
        let closed = player.window.frame
        #expect(closed.size == ModernGeometry.windowSize(open: []))
        player.setPanel(.stations, open: true, animated: false)
        #expect(player.openPanels == [.stations])
        #expect(player.window.frame.size == ModernGeometry.windowSize(open: [.stations]))
        #expect(player.window.frame.maxY == closed.maxY, "the top stays put")
        player.togglePanel(.equalizer)
        #expect(player.openPanels == [.equalizer, .stations])
        #expect(recorder.events.contains(.layoutChanged))
        player.setAlwaysOnTop(true)
        player.saveLayout()
        let saved = try #require(ModernLayout.load(from: url))
        #expect(saved.openPanels == [.equalizer, .stations] && saved.alwaysOnTop)
        player.close()
        let (restored, _) = makePlayer(layoutURL: url)
        #expect(restored.openPanels == [.equalizer, .stations] && restored.alwaysOnTop)
        restored.close()
    }

    @Test func appearanceAndTintApplyLive() {
        let (player, _) = makePlayer()
        player.appearance = .dark
        #expect(player.window.appearance?.name == .darkAqua)
        player.appearance = .light
        #expect(player.window.effectiveAppearance.isDark == false)
        player.appearance = .auto
        #expect(player.window.appearance == nil)
        player.tint = .red
        #expect(player.tint == .red)
        player.close()
    }

    @Test func nothingAnimatesWhileTheWindowIsHidden() {
        let (player, _) = makePlayer()
        player.state = playing()
        #expect(!player.isVisualizerRunning, "never ordered on screen")
        player.close()
    }
}
