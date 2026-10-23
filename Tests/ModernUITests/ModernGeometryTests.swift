// SPDX-License-Identifier: GPL-3.0-or-later
// DESIGN §8.4: the modern window's card stack, the panels' motion, the marquee's timing, slider and EQ maths.
import CoreGraphics
import Foundation
import Testing
@testable import ModernUI

@Suite struct CardStackTests {
    @Test func cardsStackUnderThePlayerWithGaps() {
        let player = ModernGeometry.frames(open: [])
        #expect(player.count == 1 && player[.nowPlaying]?.origin == CGPoint(x: Metrics.margin, y: Metrics.margin))
        let all = ModernGeometry.frames(open: [.equalizer, .stations])
        let np = all[.nowPlaying]!, eq = all[.equalizer]!, st = all[.stations]!
        #expect(eq.minY == np.maxY + Metrics.gap && st.minY == eq.maxY + Metrics.gap)
        let stationsOnly = ModernGeometry.frames(open: [.stations])
        #expect(stationsOnly[.stations]!.minY == np.maxY + Metrics.gap && stationsOnly[.equalizer] == nil)
        #expect(ModernGeometry.windowSize(open: [.equalizer, .stations]).height == st.maxY + Metrics.margin)
        #expect(ModernGeometry.windowSize(open: []).width == Metrics.cardWidth + Metrics.margin * 2)
    }

    /// A panel opens like a drawer from its top edge, a gap under the card above, and the cards below follow it: no
    /// card ever passes over another (the closing Equalizer used to slide up into the player).
    @Test func panelsOpenAndCloseLikeDrawers() {
        let np = ModernGeometry.frames(open: [])[.nowPlaying]!
        let half = ModernGeometry.frames(presence: [.nowPlaying: 1, .equalizer: 0.5, .stations: 1])
        #expect(half[.nowPlaying] == np)
        #expect(half[.equalizer]!.minY == np.maxY + Metrics.gap, "the top edge stays put")
        #expect(half[.equalizer]!.height == Metrics.equalizerHeight / 2)
        #expect(half[.stations]!.minY == half[.equalizer]!.maxY + Metrics.gap / 2)
        let closed = ModernGeometry.frames(presence: [.nowPlaying: 1, .equalizer: 0, .stations: 1])
        #expect(closed[.equalizer]!.height == 0)
        #expect(closed[.stations] == ModernGeometry.frames(open: [.stations])[.stations], "lands where it rests")
        #expect(ModernGeometry.frames(presence: ModernGeometry.presence(open: [.equalizer, .stations]))
            == ModernGeometry.frames(open: [.equalizer, .stations]))
        for e in stride(from: 0.0, through: 1.0, by: 0.05) {
            for s in stride(from: 0.0, through: 1.0, by: 0.25) {
                let f = ModernGeometry.frames(presence: [.nowPlaying: 1, .equalizer: CGFloat(e), .stations: CGFloat(s)])
                #expect(f[.equalizer]!.minY >= np.maxY + Metrics.gap && f[.stations]!.minY >= f[.equalizer]!.maxY,
                        "no overlap at equalizer \(e), stations \(s)")
            }
        }
    }

    @Test func layoutRoundTripsAndKnowsItsPanels() throws {
        let layout = ModernLayout(x: 120, top: 800, panels: ["stations", "bogus"], alwaysOnTop: true)
        #expect(layout.openPanels == [.stations])
        let dir = FileManager.default.temporaryDirectory.appending(path: "modern-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "modern-layout.json")
        try layout.save(to: url)
        #expect(ModernLayout.load(from: url) == layout)
        #expect(ModernLayout.load(from: dir.appending(path: "missing.json")) == nil)
    }
}

@Suite struct MotionTests {
    @Test func theSpringStartsAtZeroLandsExactlyAndNeverOvershoots() {
        #expect(CardSpring.position(0) == 0)
        #expect(CardSpring.position(1) == 1 && CardSpring.position(2) == 1)
        let samples = stride(from: 0.0, through: 1.0, by: 0.01).map(CardSpring.position)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, "always onwards")
        #expect(samples.max()! <= 1, "a drawer never opens past its content or closes past shut")
        #expect(samples[40] > 0.75, "most of the move is early: \(samples[40])")
    }

    @Test func pagesFadeInLateAndOutEarly() {
        #expect(CardSpring.fade(0.1, from: 0, to: 1) == 0, "waits for the drawer to have some depth")
        #expect(CardSpring.fade(1, from: 0, to: 1) == 1)
        #expect(CardSpring.fade(0.35, from: 1, to: 0) == 0, "gone before the drawer has shut")
        #expect(CardSpring.position(0.35) < 0.8)
        #expect(CardSpring.fade(0.15, from: 1, to: 0) > 0.3, "still there while the drawer starts to move")
        #expect(CardSpring.fade(0.5, from: 1, to: 1) == 1)
        #expect(CardSpring.interpolate(10, 30, 0.5) == 20)
    }

    @Test func theMarqueeGlidesOnlyWhenTheTitleDoesNotFit() {
        #expect(MarqueeTiming.loop(textWidth: 200, viewWidth: 240) == nil)
        #expect(MarqueeTiming.loop(textWidth: 240, viewWidth: 240) == nil)
        let loop = MarqueeTiming.loop(textWidth: 400, viewWidth: 240)!
        #expect(loop.distance == 400 + MarqueeTiming.gap)
        #expect(abs(loop.duration - (MarqueeTiming.hold + Double((400 + MarqueeTiming.gap) / MarqueeTiming.speed))) < 1e-9)
        #expect(abs(loop.holdFraction * loop.duration - MarqueeTiming.hold) < 1e-9)
        #expect(MarqueeTiming.speed == 30, "30 points a second, smooth at the display's refresh rate")
    }
}

@Suite struct SliderAndEQMathTests {
    @Test func valuesMapToPositionsBothWays() {
        #expect(SliderMath.value(at: 50, start: 0, end: 100) == 0.5)
        #expect(SliderMath.value(at: 150, start: 0, end: 100) == 1 && SliderMath.value(at: -5, start: 0, end: 100) == 0)
        #expect(SliderMath.value(at: 25, start: 100, end: 0) == 0.75, "vertical sliders grow upwards")
        #expect(SliderMath.position(of: 0.25, start: 10, end: 50) == 20)
        #expect(SliderMath.value(at: 5, start: 5, end: 5) == 0)
    }

    @Test func detentsCatchNearbyValues() {
        #expect(SliderMath.snapped(0.51, detents: [0.5], radius: 0.025) == 0.5)
        #expect(SliderMath.snapped(0.56, detents: [0.5], radius: 0.025) == 0.56)
        #expect(SliderMath.snapped(0.3, detents: [], radius: 0.025) == 0.3)
    }

    @Test func decibelsRoundTripThroughTheSliders() {
        #expect(EQCurve.value(decibels: 0) == 0.5 && EQCurve.value(decibels: 12) == 1 && EQCurve.value(decibels: -40) == 0)
        for db in stride(from: -12.0, through: 12.0, by: 0.5) {
            #expect(EQCurve.decibels(value: EQCurve.value(decibels: db)) == db)
        }
        #expect(EQCurve.label(0) == "0 dB" && EQCurve.label(3.25) == "+3.3 dB" && EQCurve.label(-6) == "−6.0 dB")
        #expect(ModernPlayer.eqFraction(decibels: 6) == 0.75)
    }

    @Test func theCurvePassesThroughEveryThumb() {
        let points = [CGPoint(x: 10, y: 40), CGPoint(x: 30, y: 10), CGPoint(x: 50, y: 70)]
        let path = EQCurve.path(through: points, minX: 0, maxX: 60)
        #expect(path.currentPoint == CGPoint(x: 60, y: 70))
        let box = path.boundingBoxOfPath
        #expect(box.minX == 0 && box.maxX == 60)
        let fill = EQCurve.fillPath(through: points, minX: 0, maxX: 60, baseline: 50)
        #expect(fill.boundingBoxOfPath.maxY >= 70 && fill.boundingBoxOfPath.minY <= 10)
    }

    @Test func visualizerShapes() {
        let rect = CGRect(x: 0, y: 0, width: 95, height: 40)
        let bars = VisualizerGeometry.barsPath(levels: [0, 0.5, 1, .nan, 2], in: rect, gap: 5)
        let box = bars.boundingBoxOfPath
        #expect(abs(box.minX) < 0.001 && abs(box.maxX - 95) < 0.001 && abs(box.maxY - 40) < 0.001 && abs(box.minY) < 0.001)
        #expect(VisualizerGeometry.bass([1, 1, 1, 1, 0, 0]) == 1 && VisualizerGeometry.bass([]) == 0)
        let scope = VisualizerGeometry.scopePath(samples: [-1, 0, 1, 0], in: rect)
        #expect(scope.boundingBoxOfPath.minX == 0 && scope.boundingBoxOfPath.maxX == 95)
        #expect(VisualizerGeometry.scopePath(samples: [0.3], in: rect).isEmpty)
    }

    @Test func stateHelpers() {
        #expect(ModernPlayerState.clock(0) == "0:00" && ModernPlayerState.clock(61.9) == "1:01")
        #expect(ModernPlayerState.clock(3725) == "1:02:05" && ModernPlayerState.clock(-4) == "0:00" && ModernPlayerState.clock(.nan) == "0:00")
        var s = ModernPlayerState()
        s.elapsed = 30
        #expect(s.remaining == nil && s.progress == nil)
        s.duration = 120
        #expect(s.remaining == 90 && s.progress == 0.25)
        s.playback = .playing
        #expect(s.isAnimating)
        s.working = true
        #expect(!s.isAnimating, "tuning: the spinner, not the visualiser")
        #expect(ModernControl.eq3.bandIndex == 3 && ModernControl.volume.bandIndex == nil)
        #expect(ModernPlayerState.Equalizer().isFlat && !ModernPlayerState.Equalizer(preamp: 1).isFlat)
    }
}
