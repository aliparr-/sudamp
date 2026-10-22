// SPDX-License-Identifier: GPL-3.0-or-later
// Scale maths, the SkinPlayerState → WindowState mapping, the visualiser adapter and the marquee/blink clock.
import Foundation
import SkinKit
import Testing
@testable import SkinUI

@Suite struct ScaleTests {
    @Test(arguments: [1, 2, 3])
    func everyWindowIsItsSkinSizeTimesTheScale(scale: Int) {
        for kind in WindowKind.allCases {
            let size = SkinScale.pointSize(kind, scale: scale)
            #expect(size.width == CGFloat(kind.size.width * scale))
            #expect(size.height == CGFloat(kind.size.height * scale))
            #expect(SkinScale.intSize(kind, scale: scale) == IntSize(kind.size.width * scale, kind.size.height * scale))
        }
        #expect(SkinScale.pointSize(.main, scale: scale) == CGSize(width: 275 * scale, height: 116 * scale))
        #expect(SkinScale.pointSize(.playlist, scale: scale) == CGSize(width: 275 * scale, height: 232 * scale))
        #expect(SkinScale.pointSize(.shade, scale: scale) == CGSize(width: 275 * scale, height: 14 * scale))
    }

    @Test func scalesAreClampedAndDefaultToTwoOnRetina() {
        #expect(SkinScale.clamp(0) == 1)
        #expect(SkinScale.clamp(2) == 2)
        #expect(SkinScale.clamp(7) == 3)
        #expect(SkinScale.defaultScale(backingScaleFactor: 2) == 2)
        #expect(SkinScale.defaultScale(backingScaleFactor: 1) == 1)
        #expect(SkinScale.defaultScale(backingScaleFactor: 3) == 2)
    }

    @Test func skinRectsMapToWholePointRects() {
        #expect(SkinScale.viewRect(MainLayout.marqueeText, scale: 2) == CGRect(x: 222, y: 54, width: 308, height: 12))
        #expect(SkinScale.viewRect(MainLayout.visualizer, scale: 3) == CGRect(x: 72, y: 129, width: 228, height: 48))
        #expect(SkinScale.unflippedViewRect(IntRect(0, 0, 275, 14), scale: 2, viewHeight: 232)
            == CGRect(x: 0, y: 204, width: 550, height: 28))
    }

    @Test func viewPointsMapToSkinPixels() {
        let p = SkinScale.skinPoint(CGPoint(x: 223.9, y: 55), scale: 2)
        #expect(p == CGPoint(x: 111.95, y: 27.5))
        #expect(SkinScale.skinPixel(p) == IntPoint(111, 27))
        #expect(SkinScale.skinPixel(SkinScale.skinPoint(CGPoint(x: 2.99, y: 0), scale: 3)) == IntPoint(0, 0))
        #expect(SkinScale.skinPixel(SkinScale.skinPoint(CGPoint(x: 3, y: 0), scale: 3)) == IntPoint(1, 0))
        #expect(SkinScale.skinPixel(CGPoint(x: -0.5, y: 0)) == IntPoint(-1, 0))
    }

    @Test func theTitleOverlayNeedsTwoDevicePixelsPerSkinPixel() {
        #expect(SkinScale.devicePixelsPerSkinPixel(scale: 1, backingScaleFactor: 1) < 2)
        #expect(SkinScale.devicePixelsPerSkinPixel(scale: 1, backingScaleFactor: 2) >= 2)
        #expect(SkinScale.devicePixelsPerSkinPixel(scale: 2, backingScaleFactor: 1) >= 2)
    }
}

@Suite struct StateMappingTests {
    @Test func defaultsMapToTheComposerDefaults() {
        let s = SkinStateMapper.windowState(SkinPlayerState(), kind: .main, local: SkinLocalState())
        #expect(s.window == .main)
        #expect(s.playback == .stopped)
        #expect(s.volume == 75)
        #expect(s.balance == 0)
        #expect(s.eq.bands == [Double](repeating: 50, count: 10))
        #expect(s.eq.preamp == 50)
        #expect(s.channels == 0)
        #expect(s.visualizer == nil)
        #expect(s.options.drawDynamicLayers == false)
        #expect(s.playlist.rows.isEmpty && s.playlist.runningTime == "")
    }

    @Test func appUnitsBecomeSkinUnits() {
        var p = SkinPlayerState()
        p.volume = 0.333
        p.balance = -1
        p.elapsed = 83.97
        p.duration = 3720
        p.stereo = false
        p.timeDisplay = .remaining
        p.equalizer = .init(enabled: false, auto: true, preamp: 6, bands: [12, -12, 0, 6, -6, 3, -3, 1.5, 0, 0])
        let s = SkinStateMapper.windowState(p, kind: .eq, local: SkinLocalState())
        #expect(s.volume == 33)
        #expect(s.balance == -100)
        #expect(s.elapsed == 83, "whole seconds, so sub-second ticks never recompose")
        #expect(s.duration == 3720)
        #expect(s.channels == 1)
        #expect(s.timeMode == .remaining)
        #expect(s.eq.on == false && s.eq.auto == true)
        #expect(s.eq.preamp == 75)
        #expect(s.eq.bands == [100, 0, 50, 75, 25, 62.5, 37.5, 56.25, 50, 50])
        p.stereo = true
        #expect(SkinStateMapper.windowState(p, kind: .main, local: SkinLocalState()).channels == 2)
    }

    @Test func badNumbersStayInRange() {
        var p = SkinPlayerState()
        p.volume = .nan
        p.balance = 7
        p.elapsed = -.infinity
        p.duration = .infinity
        p.equalizer.bands = [.nan]
        let s = SkinStateMapper.windowState(p, kind: .main, local: SkinLocalState())
        #expect(s.volume == 0 && s.balance == 100 && s.elapsed == 0 && s.duration == nil)
        #expect(s.eq.bands.count == 10 && s.eq.bands.allSatisfy { $0 == 50 })
        p.duration = 0
        #expect(SkinStateMapper.windowState(p, kind: .main, local: SkinLocalState()).duration == nil)
    }

    @Test func stationRowsCarryTagsLengthsAndLive() {
        var p = SkinPlayerState()
        p.playlist = [
            .init(tag: .radio, title: "Deep House Radio"),
            .init(tag: .youtube, title: "Solar Crew - Sunset Mix", duration: 3720),
            .init(tag: .soundcloud, title: "Nightdrive", duration: 461),
            .init(tag: .mixcloud, title: "Warehouse 004", duration: 3492),
        ]
        p.currentRow = 1
        var local = SkinLocalState()
        local.playlistSelected = [3, 9]
        var s = SkinStateMapper.windowState(p, kind: .playlist, local: local)
        #expect(s.playlist.rows.map(\.tag) == ["FM", "YT", "SC", "MC"])
        #expect(s.playlist.rows.map(\.duration) == [nil, "62:00", "7:41", "58:12"])
        #expect(s.playlist.current == 1)
        #expect(s.playlist.selected == [3])
        #expect(s.playlist.runningTime == "58:12/2:07:53+")
        p.liveLabel = "LIVE"
        s = SkinStateMapper.windowState(p, kind: .playlist, local: local)
        #expect(s.playlist.rows[0].duration == "LIVE")
        p.currentRow = 4
        #expect(SkinStateMapper.windowState(p, kind: .playlist, local: local).playlist.current == nil)
    }

    @Test func playlistScrollFollowsTheFirstRow() {
        var p = SkinPlayerState()
        p.playlist = (0..<16).map { .init(title: "Station \($0)") }
        var local = SkinLocalState()
        local.playlistFirstRow = 10
        var s = SkinStateMapper.windowState(p, kind: .playlist, local: local)
        #expect(SkinStateMapper.maxFirstRow(rowCount: 16) == 3)
        #expect(s.playlist.firstRow == 3 && s.playlist.scroll == 1)
        local.playlistFirstRow = 1
        s = SkinStateMapper.windowState(p, kind: .playlist, local: local)
        #expect(s.playlist.firstRow == 1 && abs(s.playlist.scroll - 1.0 / 3) < 1e-9)
        local.overrides.scroll = 0.5
        s = SkinStateMapper.windowState(p, kind: .playlist, local: local)
        #expect(s.playlist.scroll == 0.5 && s.playlist.firstRow == 2)
        #expect(SkinStateMapper.maxFirstRow(rowCount: 5) == 0)
    }

    @Test func overridesWinUntilCleared() {
        var p = SkinPlayerState()
        p.duration = 100
        p.elapsed = 10
        var local = SkinLocalState()
        local.overrides.volume = 0.2
        local.overrides.position = 0.9
        local.overrides.bands[3] = 12
        local.overrides.preamp = -12
        var s = SkinStateMapper.windowState(p, kind: .main, local: local)
        #expect(s.volume == 20 && s.position == 0.9)
        let eq = SkinStateMapper.windowState(p, kind: .eq, local: local)
        #expect(eq.eq.bands[3] == 100 && eq.eq.preamp == 0, "EQ state is mapped for the EQ window")
        #expect(s.eq == WindowState.EQState(), "the main window doesn't draw EQ sliders, so it skips them")
        p.duration = nil
        s = SkinStateMapper.windowState(p, kind: .main, local: local)
        #expect(s.position == nil, "no seek preview without a length")
        local.overrides.clear(keeping: .band3)
        #expect(local.overrides.volume == nil && local.overrides.bands == [3: 12] && local.overrides.position == nil)
        local.overrides.clear(keeping: nil)
        #expect(local.overrides.isEmpty)
    }

    /// The mapping reproduces the SkinKit fixture it stands for, so SkinUI draws what the goldens show.
    @Test func mappingReproducesTheMainPlayingFixture() throws {
        let fixture = try Repo.fixtureState("02-main-playing")
        var p = SkinPlayerState()
        p.title = "[DEEP HOUSE] SOLAR CREW - SUNSET"
        p.playState = .playing
        p.elapsed = 83.4
        p.duration = 3720
        p.kbps = 128
        p.khz = 48
        p.stereo = true
        p.volume = 0.75
        var local = SkinLocalState()
        local.focused = true
        var mapped = SkinStateMapper.windowState(p, kind: .main, local: local)
        mapped.visualizer = fixture.visualizer
        mapped.options = fixture.options
        #expect(mapped == fixture)
        #expect(WindowComposer.render(.main, state: mapped, skin: SudampDark.skin).metadata.sha256
            == (try Repo.golden("sudamp-dark", "02-main-playing")))
    }

    @Test func durationsAndClocksAreFormattedLikeWinamp() {
        #expect(SkinStateMapper.rowDuration(3720) == "62:00")
        #expect(SkinStateMapper.rowDuration(59.9) == "0:59")
        #expect(SkinStateMapper.clock(3600) == "1:00:00")
        #expect(SkinStateMapper.clock(61) == "1:01")
        #expect(SkinStateMapper.runningTime([], selected: []) == "")
    }
}

@Suite struct VisualizerAdapterTests {
    @Test func barsAndScopeMapToSkinRows() {
        var tracker = PeakTracker()
        let snapshot = VisualizerSnapshot(bars: [0, 0.5, 1, 1.5, -1, .nan], scope: [1, -1, 0, .infinity], peaks: [1, 0.5])
        let frame = VisualizerAdapter.frame(snapshot, mode: .oscilloscope, tracker: &tracker)
        #expect(frame.mode == .oscilloscope)
        #expect(frame.bars.count == 19 && frame.scope.count == 76 && frame.peaks.count == 19)
        #expect(Array(frame.bars.prefix(6)) == [0, 8, 16, 16, 0, 0])
        #expect(Array(frame.scope.prefix(4)) == [0, 15, 8, 8])
        #expect(Array(frame.peaks.prefix(3)) == [16, 8, 0])
        let silent = VisualizerAdapter.frame(nil, mode: .spectrum, tracker: &tracker)
        #expect(silent.bars.allSatisfy { $0 == 0 })
    }

    @Test func peaksJumpHoldAndFall() {
        var tracker = PeakTracker(holdFrames: 2, fallPerFrame: 1)
        var bars = [Int](repeating: 0, count: 19)
        bars[0] = 10
        #expect(tracker.update(bars: bars)[0] == 10)
        bars[0] = 2
        #expect(tracker.update(bars: bars)[0] == 10)  // hold 1
        #expect(tracker.update(bars: bars)[0] == 10)  // hold 2
        #expect(tracker.update(bars: bars)[0] == 9)
        #expect(tracker.update(bars: bars)[0] == 8)
        bars[0] = 12
        #expect(tracker.update(bars: bars)[0] == 12)
        tracker.reset()
        #expect(tracker.update(bars: [Int](repeating: 0, count: 19))[0] == 0)
    }

    @Test func providerPeaksWinOverTheTracker() {
        var tracker = PeakTracker()
        let frame = VisualizerAdapter.frame(VisualizerSnapshot(bars: [0.25], scope: [], peaks: [0.75]), mode: .spectrum,
                                            tracker: &tracker)
        #expect(frame.bars[0] == 4 && frame.peaks[0] == 12)
    }
}

@Suite struct ClockTests {
    @Test func marqueeStepsEvery220ms() {
        var clock = MarqueeClock()
        clock.setTitle("A LONG TITLE", now: 10)
        #expect(clock.step(at: 10) == 0)
        #expect(clock.step(at: 10.219) == 0)
        #expect(clock.step(at: 10.221) == 1)
        #expect(clock.step(at: 12.3) == 10)
        clock.setTitle("A LONG TITLE", now: 12.3)
        #expect(clock.step(at: 12.3) == 10, "the same title keeps scrolling")
        clock.setTitle("ANOTHER", now: 12.3)
        #expect(clock.step(at: 12.3) == 0, "a new title starts from the beginning")
    }

    @Test func scrubbingFreezesThenResumesAfterOneSecond() {
        var clock = MarqueeClock()
        clock.setTitle("T", now: 0)
        clock.freeze(now: 1.2)  // step 5
        #expect(clock.step(at: 5) == 5)
        clock.resume(now: 5)
        #expect(clock.step(at: 5.9) == 5)
        #expect(clock.step(at: 6.0) == 5)
        #expect(clock.step(at: 6.23) == 6)
    }

    @Test func pausedTimeBlinksLikeWebamp() {
        #expect(PauseBlink.isVisible(secondsPaused: 0))
        #expect(PauseBlink.isVisible(secondsPaused: 1.9))
        #expect(!PauseBlink.isVisible(secondsPaused: 2.1))
        #expect(PauseBlink.isVisible(secondsPaused: 3.5))
        #expect(!PauseBlink.isVisible(secondsPaused: 4.0))
        #expect(PauseBlink.isVisible(secondsPaused: .nan))
    }
}
