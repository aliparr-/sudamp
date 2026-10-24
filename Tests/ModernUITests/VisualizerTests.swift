// SPDX-License-Identifier: GPL-3.0-or-later
// DESIGN §8.4: the modern visualiser. Its scenes draw offscreen, deterministically, in music and in silence; the
// beat tracker finds kicks, keeps time through a break, and hears a breakdown and its drop; the renderer cross-fades
// and lays its effects over the frame; the rotation moves on with the clock, the music and the genre; the artwork's
// colour schemes keep the visualiser legible; and the artwork view draws bitmaps, never animated paths (an in-flight
// shape layer path has a different element structure, which tore the old bars apart).
import AppKit
import QuartzCore
import Testing
@testable import ModernUI

/// Analyser-like frames: a kick every half second (124-ish bpm) that jumps the low bars and falls back, mids that
/// wander, hats in the treble, and a scope sine; `breakAt` stops the kick, leaving the low bars at `breakBass`.
nonisolated func testMusic(seconds: Double, fps: Double = 60, kickEvery: Double = 0.5,
                           breakAt: ClosedRange<Double>? = nil, breakBass: Float = 0.4) -> [ModernVisualizerFrame] {
    let count = Int(seconds * fps)
    var bass: Float = 0
    var lastKick = -1.0
    return (0..<count).map { i in
        let t = Double(i) / fps
        let inBreak = breakAt?.contains(t) ?? false
        if !inBreak, t - lastKick >= kickEvery - 1e-9 {
            lastKick = t
            bass = 0.92
        } else {
            bass = max(0.35, bass - Float(1.4 / fps))
        }
        let bars = (0..<ModernVisualizerFrame.barCount).map { b -> Float in
            if b < 4 { return inBreak ? breakBass : bass - Float(b) * 0.04 }
            let x = Float(b) / Float(ModernVisualizerFrame.barCount)
            let hats: Float = x > 0.6 ? 0.25 * Float(max(0, sin(t * 2 * .pi * 4))) : 0
            return min(1, 0.5 - 0.3 * x + 0.1 * Float(sin(t * 1.7 + Double(b))) + hats)
        }
        let scope = (0..<ModernVisualizerFrame.scopeCount).map { Float(0.6 * sin(Double($0) / 6 + t * 9)) }
        return ModernVisualizerFrame(bars: bars, peaks: bars.map { min(1, $0 + 0.05) }, scope: scope)
    }
}

/// The non-transparent pixels in an image.
nonisolated func litPixels(_ image: CGImage?) -> Int {
    guard let image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
    let alphaFirst = [.premultipliedFirst, .first, .noneSkipFirst].contains(image.alphaInfo)
    var lit = 0
    for i in 0..<(image.width * image.height) {
        let alpha = bytes[i * 4 + (alphaFirst ? 0 : 3)]
        if alpha > 8 { lit += 1 }
    }
    return lit
}

nonisolated func bytes(_ image: CGImage?) -> [UInt8] {
    guard let image, let data = image.dataProvider?.data else { return [] }
    return Array(Data(referencing: data as NSData))
}

/// Whether `draw` makes the same image twice. Core Graphics can rasterise a few shapes differently while other threads
/// draw (the tests run in parallel; measured with Speaker, Pendulums and the original Fireworks, never with one
/// thread drawing), so a pair that differs is drawn again: a scene that isn't deterministic differs every time.
nonisolated func drawsTheSameTwice(_ draw: () -> CGImage?) -> Bool {
    for _ in 0..<4 where bytes(draw()) == bytes(draw()) { return true }
    return false
}

/// Plays `mode` through `frames` at 60 a second and returns the last frame's image.
nonisolated func play(_ mode: ModernPlayerState.Visualizer, _ frames: [ModernVisualizerFrame?], seed: UInt64 = 7,
                      palette: ArtworkPalette = ArtworkPalette.make(genreKey: "house", tint: .teal, dark: true),
                      scale: CGFloat = 2) -> CGImage? {
    let renderer = SceneRenderer(seed: seed)
    renderer.style = SceneStyle(palette)
    renderer.show(mode, animated: false)
    var features = AudioFeatures()
    for frame in frames { renderer.update(features.next(frame, dt: 1.0 / 60), dt: 1.0 / 60) }
    return renderer.image(size: CGSize(width: 92, height: 92), scale: scale)
}

@Suite struct VisualizerModeTests {
    typealias Visualizer = ModernPlayerState.Visualizer

    @Test func scenesRotateAndOff() {
        #expect(Visualizer.scenes.count == 27 && !Visualizer.scenes.contains(.rotate) && !Visualizer.scenes.contains(.off))
        #expect(Visualizer.default == .spectrum && Visualizer.allCases.last == .off)
        #expect(Set(Visualizer.allCases.map(\.title)).count == Visualizer.allCases.count, "every choice has its own name")
        // The rotation plays every scene once, in its own mixed-up order; clicking the artwork walks it and comes round
        // again; off and rotate start at the first.
        #expect(Visualizer.rotation.count == Visualizer.scenes.count && Set(Visualizer.rotation) == Set(Visualizer.scenes))
        var mode = Visualizer.rotation[0]
        var seen: [Visualizer] = []
        for _ in Visualizer.scenes {
            seen.append(mode)
            mode = mode.nextScene
        }
        #expect(seen == Visualizer.rotation && mode == .spectrum)
        #expect(Visualizer.off.nextScene == .spectrum && Visualizer.rotate.nextScene == .spectrum)
        // Neighbours in the rotation come from different sections, mostly (no two meters in a row, say).
        let neighbours = zip(Visualizer.rotation, Visualizer.rotation.dropFirst() + [Visualizer.rotation[0]])
        #expect(neighbours.filter { $0.section == $1.section }.count <= 3)
        #expect(Visualizer(rawValue: "pixel-dj") == .pixelDJ && Visualizer(rawValue: "vu-meters") == .vuMeters)
        #expect(Visualizer(rawValue: "breakfast-band") == .breakfastBand && Visualizer(rawValue: "drumming-cat") == .drummingCat)
    }

    /// The menus list the scenes a section at a time, every scene in exactly one, in the scenes' order.
    @Test func sectionsHoldEveryScene() {
        #expect(Visualizer.Section.allCases.flatMap(\.scenes) == Visualizer.scenes)
        #expect(Visualizer.scenes.allSatisfy { $0.section != nil } && Visualizer.rotate.section == nil && Visualizer.off.section == nil)
        #expect(Visualizer.Section.allCases.allSatisfy { $0.scenes.count >= 5 })
        // Both moods are well represented.
        let calm = Visualizer.scenes.filter(\.isCalm)
        #expect(calm.count >= 6 && Visualizer.scenes.count - calm.count >= 12)
        #expect(Visualizer.lava.isCalm && Visualizer.campfire.isCalm && !Visualizer.fireworks.isCalm && !Visualizer.rally.isCalm)
    }

    @Test func genresHaveScenesThatSuitThem() {
        #expect(Visualizer.suited(toGenre: "lo-fi").first == .campfire)
        #expect(Visualizer.suited(toGenre: "deep-house").first == .skyline, "deep house before house")
        #expect(Visualizer.suited(toGenre: "house").first == .pixelDJ)
        #expect(Visualizer.suited(toGenre: "techno").first == .tunnel)
        #expect(Visualizer.suited(toGenre: "Ambient Drone").first == .aurora, "matched on words, in any case")
        #expect(Visualizer.suited(toGenre: nil).isEmpty && Visualizer.suited(toGenre: "").isEmpty)
        #expect(Visualizer.suited(toGenre: "polka").isEmpty && Visualizer.suited(toGenre: "favourites").isEmpty)
        // The catalogue's genres all have some, and every one each lists is a scene.
        for genre in ["ambient", "deep-house", "drum-and-bass", "house", "lo-fi", "techno"] {
            let suited = Visualizer.suited(toGenre: genre)
            #expect(suited.count >= 4 && suited.allSatisfy(\.isScene) && Set(suited).count == suited.count, "\(genre)")
        }
        #expect(VisualizerRotation.opening(forGenre: "lo-fi", showing: .spectrum) == .campfire)
        #expect(VisualizerRotation.opening(forGenre: "lo-fi", showing: .rain) == nil, "a suited scene carries on")
        #expect(VisualizerRotation.opening(forGenre: "polka", showing: .spectrum) == nil)
    }

    @Test @MainActor func everyChoiceHasASymbol() {
        for mode in Visualizer.allCases {
            #expect(NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil) != nil, "\(mode.symbol)")
        }
    }

    @Test func rotationMovesOnAfterItsInterval() {
        var rotation = VisualizerRotation(interval: 10)
        var due = 0
        for _ in 0..<(60 * 25) where rotation.advance(1.0 / 60) { due += 1 }
        #expect(due == 2, "25 s at 10 s a scene")
        rotation.restart()
        #expect(!rotation.advance(9.9) && rotation.advance(0.2))
        #expect(VisualizerRotation.next(after: nil) == .spectrum && VisualizerRotation.next(after: .oscilloscope) == .spectrum)
        #expect(VisualizerRotation.next(after: .starfield) == .pixelDJ && VisualizerRotation.next(after: .pixelDJ) == .loops)
    }

    /// A breakdown hands a lively scene over to a calm one, the timer keeps to calm scenes through it, and the drop
    /// brings a lively one back; never before a scene has had a fair turn.
    @Test func rotationFollowsTheMusic() {
        var playing = VisualizerInput.silence
        playing.level = 0.5
        var breakdown = playing
        breakdown.breakdown = 1
        var drop = playing
        drop.drop = true
        let dt = 1.0 / 30
        var rotation = VisualizerRotation(interval: 30)
        // Too soon: the scene has only just started.
        #expect(rotation.advance(1, input: breakdown, showing: .fireworks) == nil)
        rotation = VisualizerRotation(interval: 30)
        for _ in 0..<150 { #expect(rotation.advance(dt, input: playing, showing: .fireworks) == nil) }
        let calm = rotation.advance(dt, input: breakdown, showing: .fireworks)
        #expect(calm?.isCalm == true && calm != .fireworks, "\(String(describing: calm))")
        // Through a long breakdown the timer moves on to another calm scene.
        var next: ModernPlayerState.Visualizer?
        for _ in 0..<(31 * 30) where next == nil { next = rotation.advance(dt, input: breakdown, showing: calm) }
        #expect(next?.isCalm == true && next != calm)
        // The drop: a lively scene, once the calm one has had its turn.
        rotation.restart()
        #expect(rotation.advance(dt, input: drop, showing: .lava) == nil)
        for _ in 0..<150 { _ = rotation.advance(dt, input: playing, showing: .lava) }
        let lively = rotation.advance(dt, input: drop, showing: .lava)
        #expect(lively?.isCalm == false, "\(String(describing: lively))")
        // A calm scene stays calm in a breakdown, and a lively one isn't moved on by a drop.
        for _ in 0..<150 { _ = rotation.advance(dt, input: playing, showing: .rain) }
        #expect(rotation.advance(dt, input: breakdown, showing: .rain) == nil)
        #expect(rotation.advance(dt, input: drop, showing: .rally) == nil)
        // A genre's own scenes come first for a mood.
        var lofi = VisualizerRotation(interval: 30, genre: "lo-fi")
        for _ in 0..<150 { _ = lofi.advance(dt, input: playing, showing: .rally) }
        let cosy = lofi.advance(dt, input: breakdown, showing: .rally)
        #expect(cosy.map { ModernPlayerState.Visualizer.suited(toGenre: "lo-fi").contains($0) && $0.isCalm } == true)
    }
}

@Suite struct AudioFeaturesTests {
    @Test func kicksAreFoundAndTheClockLocksToThem() {
        var features = AudioFeatures()
        var kicks: [Double] = []
        for frame in testMusic(seconds: 8) {
            let input = features.next(frame, dt: 1.0 / 60)
            if input.beat { kicks.append(input.time) }
        }
        #expect(kicks.count >= 14 && kicks.count <= 17, "\(kicks.count) kicks in 8 s at 2 a second")
        let gaps = zip(kicks.dropFirst(), kicks).map { $0 - $1 }
        #expect(gaps.allSatisfy { abs($0 - 0.5) < 0.05 }, "\(gaps)")
        #expect(abs(features.input.beatInterval - 0.5) < 0.03, "tempo \(features.input.beatInterval)")
    }

    @Test func theClockKeepsTimeThroughABreak() {
        var features = AudioFeatures()
        var grooveAtKicks: [Double] = []
        var beatsInBreak = 0
        for frame in testMusic(seconds: 12, breakAt: 4...8) {
            let input = features.next(frame, dt: 1.0 / 60)
            if input.beat {
                if (4.05...8).contains(input.time) { beatsInBreak += 1 }
                if input.time > 8 { grooveAtKicks.append(input.groove) }
            }
        }
        #expect(beatsInBreak == 0)
        // After four seconds without a kick the clock still sits on the downbeat when they return.
        #expect(!grooveAtKicks.isEmpty && grooveAtKicks.allSatisfy { $0 < 0.12 || $0 > 0.88 }, "\(grooveAtKicks)")
    }

    /// A breakdown (the bass's low points sinking for a while) is heard, and the first kick on the downbeat after it is
    /// the drop: once.
    @Test func theBreakdownAndTheDrop() {
        var features = AudioFeatures()
        var drops: [Double] = []
        var deepest: Float = 0
        var afterDrop: Float = 1
        for frame in testMusic(seconds: 12, breakAt: 4...8, breakBass: 0.1) {
            let input = features.next(frame, dt: 1.0 / 60)
            if input.time < 4 { #expect(input.breakdown == 0 && !input.drop) }
            if (6...8).contains(input.time) { deepest = max(deepest, input.breakdown) }
            if input.drop { drops.append(input.time) }
            if input.time > 10 { afterDrop = min(afterDrop, input.breakdown) }
            #expect((0...1).contains(input.breakdown))
        }
        #expect(deepest > 0.9, "\(deepest)")
        #expect(drops.count == 1 && (8...8.6).contains(drops[0]), "\(drops)")
        #expect(afterDrop < 0.05)
        // Steady music has none, and silence clears it.
        features = AudioFeatures()
        for frame in testMusic(seconds: 8) {
            let input = features.next(frame, dt: 1.0 / 60)
            #expect(input.breakdown == 0 && !input.drop)
        }
        // A break that keeps the bass up (a bassline alone) isn't one.
        features = AudioFeatures()
        for frame in testMusic(seconds: 12, breakAt: 4...8) { #expect(!features.next(frame, dt: 1.0 / 60).drop) }
        features = AudioFeatures()
        for frame in testMusic(seconds: 6, breakAt: 4...8, breakBass: 0.1) { _ = features.next(frame, dt: 1.0 / 60) }
        #expect(features.input.breakdown > 0.5)
        for _ in 0..<60 { _ = features.next(nil, dt: 1.0 / 60) }
        #expect(features.input.breakdown < 0.05)
    }

    @Test func theCaptionRidesAlong() {
        var features = AudioFeatures()
        features.caption = "Sunset Sessions · Solar Crew"
        #expect(features.next(testMusic(seconds: 0.1).first, dt: 1.0 / 60).caption == "Sunset Sessions · Solar Crew")
        features.reset()
        #expect(features.next(nil, dt: 1.0 / 60).caption == "Sunset Sessions · Solar Crew", "a reset keeps it")
        #expect(VisualizerInput.silence.caption.isEmpty && !VisualizerInput.silence.drop)
    }

    @Test func silenceAndBadInput() {
        var features = AudioFeatures()
        var input = features.next(nil, dt: 1.0 / 60)
        #expect(input.isSilent && !input.beat && input.bars.count == 19 && input.scope.count == 76)
        let bad = ModernVisualizerFrame(bars: [.nan, 2, -1], peaks: [], scope: [.infinity])
        input = features.next(bad, dt: .nan)
        #expect(input.bars.count == 19 && input.bars[0] == 0 && input.bars[1] == 1 && input.bars[2] == 0)
        #expect(input.scope.count == 76 && input.scope[0] == 0)
        #expect(input.band(at: 0) == 0 && input.band(at: 1) == 0 && input.band(at: 2) == 0)
    }

    @Test func levelsSmoothAndThePulseDecays() {
        var features = AudioFeatures()
        let frames = testMusic(seconds: 2)
        var sawPulse = false
        var lowestAfterPulse: Float = 1
        for frame in frames {
            let input = features.next(frame, dt: 1.0 / 60)
            #expect((0...1).contains(input.bass) && (0...1).contains(input.level) && (0..<1).contains(input.groove))
            if input.beat { sawPulse = true }
            if sawPulse { lowestAfterPulse = min(lowestAfterPulse, input.pulse) }
        }
        #expect(sawPulse && lowestAfterPulse < 0.2)
    }
}

@Suite struct SceneTests {
    typealias Visualizer = ModernPlayerState.Visualizer

    /// Every scene draws something in music and in silence (the still frame shown while paused), at 1x and 2x.
    @Test(arguments: Visualizer.scenes)
    func drawsInMusicAndSilence(_ mode: Visualizer) {
        let music = testMusic(seconds: 3)
        for scale: CGFloat in [1, 2] {
            let playing = play(mode, music, scale: scale)
            #expect(playing?.width == Int(92 * scale), "\(mode) \(scale)x")
            #expect(litPixels(playing) > 20, "\(mode) draws while playing at \(scale)x")
        }
        let still = play(mode, music + [ModernVisualizerFrame?](repeating: nil, count: 40))
        #expect(litPixels(still) > 0, "\(mode) still frame")
        #expect(litPixels(play(mode, [nil, nil, nil])) > 0, "\(mode) before any music")
    }

    @Test(arguments: Visualizer.scenes)
    func deterministicForASeed(_ mode: Visualizer) {
        let music = testMusic(seconds: 2)
        #expect(drawsTheSameTwice { play(mode, music, seed: 3) }, "\(mode)")
    }

    /// Light artwork (the light window scheme) and every other scheme draw too.
    @Test(arguments: Visualizer.scenes)
    func drawsOnEveryScheme(_ mode: Visualizer) {
        let music = testMusic(seconds: 1.5)
        for colors in ArtworkColors.allCases {
            for dark in [false, true] {
                let palette = ArtworkPalette.make(.init(colors: colors, genreKey: "techno", source: .youtube, tint: .indigo, dark: dark))
                #expect(litPixels(play(mode, music, palette: palette, scale: 1)) > 20, "\(mode) \(colors) \(dark)")
            }
        }
    }

    /// A generous bound that only catches a scene gone badly wrong (the release budget is 0.3 ms at 2x; tests run
    /// unoptimised and in parallel).
    @Test(arguments: Visualizer.scenes)
    func drawsQuickly(_ mode: Visualizer) {
        var options = SceneSheet.Options()
        options.start = 1
        options.snapshots = 4
        let result = SceneSheet.render(mode, frames: testMusic(seconds: 2), palette: .make(genreKey: "house", tint: .teal, dark: true),
                                       options: options)
        #expect(result.image != nil)
        #expect(result.meanMilliseconds < 25, "\(mode): \(result.meanMilliseconds) ms a frame")
    }

    /// The real-sounding song (a breakdown and a drop) never trips a scene up, at the app's 30 frames a second.
    @Test(arguments: Visualizer.scenes)
    func survivesABreakdownAndADrop(_ mode: Visualizer) {
        let music = testMusic(seconds: 12, fps: 30, breakAt: 4...8, breakBass: 0.1)
        let renderer = SceneRenderer(seed: 9)
        renderer.show(mode, animated: false)
        var features = AudioFeatures()
        var sawDrop = false
        for frame in music {
            let input = features.next(frame, dt: 1.0 / 30)
            sawDrop = sawDrop || input.drop
            renderer.update(input, dt: 1.0 / 30)
        }
        #expect(sawDrop)
        #expect(litPixels(renderer.image(size: CGSize(width: 92, height: 92), scale: 1)) > 20, "\(mode)")
    }

    /// VHS lines the whole artwork and fringes the scene; Kaleidoscope folds the scene into a figure that's as full
    /// above the middle as below it. Both are deterministic, and both draw still frames.
    @Test func effectsLayOverTheScene() {
        let music = testMusic(seconds: 2)
        func render(_ effect: ModernPlayerState.VisualizerEffect, _ frames: [ModernVisualizerFrame?]) -> CGImage? {
            let renderer = SceneRenderer(seed: 4)
            renderer.effect = effect
            renderer.show(.spectrum, animated: false)
            var features = AudioFeatures()
            for frame in frames { renderer.update(features.next(frame, dt: 1.0 / 60), dt: 1.0 / 60) }
            return renderer.image(size: CGSize(width: 92, height: 92), scale: 2)
        }
        func halves(_ image: CGImage?) -> (top: Int, bottom: Int) {
            guard let image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return (0, 0) }
            var top = 0, bottom = 0
            for y in 0..<image.height {
                for x in 0..<image.width where bytes[y * image.bytesPerRow + x * 4 + 3] > 40 {
                    if y < image.height / 2 { top += 1 } else { bottom += 1 }
                }
            }
            return (top, bottom)
        }
        let plain = render(.none, music), vhs = render(.vhs, music), kaleidoscope = render(.kaleidoscope, music)
        #expect(litPixels(vhs) > litPixels(plain) * 2, "scan lines over the artwork too")
        #expect(drawsTheSameTwice { render(.vhs, music) } && drawsTheSameTwice { render(.kaleidoscope, music) })
        let bars = halves(plain), folded = halves(kaleidoscope)
        #expect(bars.top * 3 < bars.bottom, "the spectrum stands at the foot: \(bars)")
        #expect(folded.top > 0 && abs(folded.top - folded.bottom) < max(folded.top, folded.bottom) / 3, "\(folded)")
        let pausedVHS = render(.vhs, music + [ModernVisualizerFrame?](repeating: nil, count: 40))
        #expect(litPixels(pausedVHS) > 20 && litPixels(render(.kaleidoscope, [nil, nil])) > 0)
    }

    /// A palette that turns a step (the Cycle colours, eight times a second) stays close enough to keep pictures
    /// cached for it; a real change of palette doesn't.
    @Test func aTurningPaletteStaysCloseForAWhile() {
        let key = ArtworkPalette.Key(colors: .cycle, tint: .teal)
        let start = SceneStyle(.make(key, cycle: 0.1))
        #expect(start.isClose(to: start) && start.isClose(to: SceneStyle(.make(key, cycle: 0.1 + 1.0 / 720))))
        #expect(!start.isClose(to: SceneStyle(.make(key, cycle: 0.2))))
        let dark = SceneStyle(.make(genreKey: "house", tint: .teal, dark: true))
        #expect(!dark.isClose(to: SceneStyle(.make(genreKey: "house", tint: .teal, dark: false))))
        #expect(!dark.isClose(to: SceneStyle(.make(genreKey: "lo-fi", tint: .teal, dark: true))))
    }

    @Test func pixelFontWritesWhatItKnows() {
        #expect(PixelFont.width("") == 0 && PixelFont.width("128") == 11 && PixelFont.width("ab", spacing: 2) == 8)
        #expect(PixelFont.glyph("a") == PixelFont.glyph("A") && PixelFont.glyph("0") != nil)
        #expect(PixelFont.glyph("ß") == nil && PixelFont.glyph("é") == nil && PixelFont.glyph("🙂") == nil)
        var canvas = PixelCanvas(width: 12, height: 6)
        PixelFont.draw("1 ?", into: &canvas, x: 0, y: 0, color: .white)
        #expect(canvas.isLit(1, 0) && canvas.isLit(0, 1) && !canvas.isLit(0, 0), "the 1's top and its flag")
        #expect(!canvas.isLit(4, 2) && !canvas.isLit(5, 2), "the space")
        #expect(canvas.isLit(8, 0) && canvas.isLit(9, 4) && !canvas.isLit(9, 3), "the question mark and its dot")
        PixelFont.draw("Ünïcode ß 夜", into: &canvas, x: -3, y: 4, color: .white)
    }

    @Test func theRendererCrossFades() {
        let renderer = SceneRenderer()
        renderer.show(.spectrum, animated: false)
        #expect(renderer.mode == .spectrum && !renderer.isFading)
        renderer.show(.starfield, animated: true)
        #expect(renderer.mode == .starfield && renderer.isFading)
        var features = AudioFeatures()
        for frame in testMusic(seconds: 0.5) { renderer.update(features.next(frame, dt: 1.0 / 60), dt: 1.0 / 60) }
        #expect(renderer.isFading && renderer.fade > 0.3 && renderer.fade < 1)
        #expect(litPixels(renderer.image(size: CGSize(width: 92, height: 92), scale: 1)) > 20)
        for frame in testMusic(seconds: 1) { renderer.update(features.next(frame, dt: 1.0 / 60), dt: 1.0 / 60) }
        #expect(!renderer.isFading && renderer.fade == 1)
        renderer.show(.off, animated: true)
        renderer.show(.rotate, animated: true)
        #expect(renderer.mode == .starfield, "off and rotate are not scenes")
    }

    /// The toast's limbs bend outwards at the elbows and knees, and never stretch past their length.
    @Test func toastLimbsBendAndReach() {
        let shoulder = CGPoint(x: 0, y: 0)
        let elbow = ToastScene.joint(shoulder, CGPoint(x: 0, y: 12), 8, bend: 1)
        #expect(elbow.x > 0 && abs(hypot(elbow.x, elbow.y) - 8) < 0.01, "a right arm hanging down bends out to the right")
        #expect(ToastScene.joint(shoulder, CGPoint(x: 0, y: 12), 8, bend: -1).x < 0)
        #expect(ToastScene.joint(shoulder, CGPoint(x: 12, y: 0), 8, bend: 1).y > 0, "an arm held out bends down at the elbow")
        let far = ToastScene.reach(shoulder, CGPoint(x: 0, y: 100), 16)
        #expect(far.y < 16 && far.y > 15)
        #expect(ToastScene.slice(width: 34, height: 36).boundingBoxOfPath.maxY == 0, "the slice stands on its base")
    }

    /// The toast's pixel slice: mirror-symmetric, outlined all round, its crown wider than its body.
    @Test func theToastIsAnOutlinedPixelSlice() {
        let sprite = ToastScene.sprite(width: 34, height: 36)
        func width(_ row: Int) -> Int { sprite.columns.filter { sprite[$0, row] != 0 }.count }
        for row in sprite.rows {
            for col in 0...sprite.columns.upperBound {
                #expect(sprite[col, row] == sprite[-1 - col, row], "row \(row) column \(col)")
                guard sprite[col, row] != 0 else { continue }
                let outside = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { sprite[col + $0.0, row + $0.1] == 0 }
                #expect(!outside || sprite[col, row] == 1, "the edge is outline at \(col), \(row)")
            }
        }
        let rows = sprite.rows.filter { width($0) > 0 }
        let widest = rows.max { width($0) < width($1) }!
        #expect(widest < (rows.first! + rows.last!) / 2, "the crown is the widest part")
        // The topping sits on the middle of the crown, in the dip between its two shoulders.
        #expect(sprite.crown - rows.first! <= 1 && sprite[-1, sprite.crown] == 1 && sprite[-1, sprite.crown - 1] == 0)
        #expect(sprite.rows.contains { row in sprite.columns.contains { sprite[$0, row] == 4 } }, "a paler middle")
    }

    @Test func pixelCanvasBlendsAndClips() {
        var canvas = PixelCanvas(width: 4, height: 3)
        canvas.set(-1, 0, .white)
        canvas.set(4, 0, .white)
        #expect(!canvas.isLit(0, 0))
        canvas.set(1, 1, RGB(1, 0, 0))
        canvas.set(1, 1, RGB(0, 0, 1), 0.5)
        #expect(canvas.isLit(1, 1) && canvas.pixels[1 * 4 + 1] == 0xFF80_0080, "\(String(canvas.pixels[5], radix: 16))")
        canvas.rect(2, 1, 9, 9, .white, 0.5)
        #expect(canvas.isLit(3, 2) && !canvas.isLit(0, 2))
        #expect(canvas.makeImage()?.width == 4)
        canvas.clear()
        #expect(!canvas.isLit(1, 1))
    }

    @Test func scopeAndSpectrumGeometry() {
        let rect = CGRect(x: 0, y: 0, width: 95, height: 40)
        let scope = ScopeScene.path([-1, 0, 1, 0], in: rect)
        #expect(scope.boundingBoxOfPath.minX == 0 && scope.boundingBoxOfPath.maxX == 95)
        #expect(ScopeScene.path([0.3], in: rect).isEmpty)
        let bars = SpectrumScene.barsRect(CGSize(width: 92, height: 92))
        #expect(bars.minX > 0 && bars.maxX < 92 && bars.maxY < 92 && bars.minY > 92 * 0.3)
    }
}

@Suite struct ArtworkColorsTests {
    @Test func everySchemeHasANameAndHelp() {
        #expect(ArtworkColors.default == .genre && ArtworkColors.allCases.count == 4)
        #expect(ArtworkColors.allCases.allSatisfy { !$0.title.isEmpty && !$0.help.isEmpty })
    }

    /// The visualiser's ink reads on its artwork: clearly on the window scheme, and never worse than the genre
    /// colours have always been (white on golden yellow).
    @Test func inkReadsOnTheArtwork() {
        let genres: [String?] = [nil, "deep-house", "house", "techno", "lo-fi", "ambient", "drum-and-bass", "jazz", "polka"]
        for tint in ModernTint.allCases {
            for dark in [false, true] {
                var palettes: [(String, ArtworkPalette, Double)] = []
                for genre in genres {
                    palettes.append(("genre \(genre ?? "-")", .make(.init(colors: .genre, genreKey: genre, tint: tint, dark: dark)), 1.5))
                }
                palettes.append(("window", .make(.init(colors: .window, tint: tint, dark: dark)), 3))
                for step in 0..<12 {
                    palettes.append(("cycle \(step)", .make(.init(colors: .cycle, tint: tint, dark: dark), cycle: Double(step) / 12), 1.5))
                }
                for source in [nil] + ModernPlayerState.SourceTag.allCases {
                    palettes.append(("source \(source?.rawValue ?? "-")", .make(.init(colors: .source, source: source, tint: tint, dark: dark)), 1.5))
                }
                for (name, p, least) in palettes {
                    let contrast = min(p.ink.contrast(with: p.base.0), p.ink.contrast(with: p.base.1))
                    #expect(contrast >= least, "\(name) \(tint) \(dark ? "dark" : "light"): \(contrast)")
                }
            }
        }
    }

    @Test func windowFollowsLightAndDark() {
        let dark = ArtworkPalette.make(.init(colors: .window, tint: .blue, dark: true))
        let light = ArtworkPalette.make(.init(colors: .window, tint: .blue, dark: false))
        #expect(!dark.isLight && light.isLight)
        #expect(dark.base.0.luminance < 0.05 && light.base.0.luminance > 0.6)
        #expect(abs(dark.base.1.hsb.hue - ModernTint.blue.hue) < 0.03, "tinted")
        #expect(ArtworkPalette.make(.init(colors: .window, tint: .graphite, dark: true)).base.1.hsb.saturation < 0.1)
    }

    @Test func sourcesHaveTheirColoursAndNothingPlayingTakesTheTint() {
        let palettes = ModernPlayerState.SourceTag.allCases.map { ArtworkPalette.make(.init(colors: .source, source: $0, tint: .teal)) }
        #expect(Set(palettes.map(\.base.1.hex)).count == 4)
        let youtube = ArtworkPalette.make(.init(colors: .source, source: .youtube))
        #expect(youtube.base.1.hsb.hue < 0.02 || youtube.base.1.hsb.hue > 0.95, "red")
        let soundcloud = ArtworkPalette.make(.init(colors: .source, source: .soundcloud))
        #expect((0.03...0.1).contains(soundcloud.base.1.hsb.hue), "orange")
        #expect(ArtworkPalette.make(.init(colors: .source, source: nil, tint: .pink)) == ArtworkPalette.make(genreKey: nil, tint: .pink, dark: true))
    }

    @Test func cycleTurnsTheHueAndComesRound() {
        let key = ArtworkPalette.Key(colors: .cycle, tint: .red)
        let start = ArtworkPalette.make(key, cycle: 0)
        #expect(start == ArtworkPalette.make(key, cycle: 1))
        let quarter = ArtworkPalette.make(key, cycle: 0.25)
        let delta = abs(quarter.base.0.hsb.hue - start.base.0.hsb.hue)
        #expect(min(delta, 1 - delta) > 0.15)
    }

    @Test func genreSchemeIsTheGenrePalette() {
        #expect(ArtworkPalette.make(.init(colors: .genre, genreKey: "techno", tint: .teal, dark: false))
            == ArtworkPalette.make(genreKey: "techno", tint: .teal, dark: false))
    }
}

@MainActor @Suite(.serialized) struct ArtworkViewTests {
    func artwork(_ player: ModernPlayer) -> ArtworkView {
        func find(_ view: NSView) -> ArtworkView? {
            if let art = view as? ArtworkView { return art }
            for sub in view.subviews { if let art = find(sub) { return art } }
            return nil
        }
        let root = player.window.contentView!
        root.layoutSubtreeIfNeeded()
        return find(root)!
    }

    /// The scene is a bitmap each frame: no layer in the artwork animates a path (the old bars' tearing).
    @Test func framesAreBitmapsNotAnimatedPaths() {
        let (player, _) = makePlayer()
        player.state = playing()
        let art = artwork(player)
        art.layoutSubtreeIfNeeded()
        for frame in testMusic(seconds: 0.5) { art.step(frame, dt: 1.0 / 60) }
        #expect(art.sceneLayer.contents != nil && art.framesDrawn >= 30)
        var pathAnimations: [String] = []
        func walk(_ layer: CALayer) {
            for key in layer.animationKeys() ?? [] where (layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath == "path" {
                pathAnimations.append(key)
            }
            for sub in layer.sublayers ?? [] { walk(sub) }
            if let mask = layer.mask { walk(mask) }
        }
        walk(art.layer!)
        #expect(pathAnimations.isEmpty, "\(pathAnimations)")
        player.close()
    }

    @Test func rotateTakesTurnsAndAClickSkips() {
        let (player, recorder) = makePlayer()
        var state = playing()
        state.visualizer = .rotate
        state.visualizerInterval = 10
        player.state = state
        let art = artwork(player)
        art.layoutSubtreeIfNeeded()
        let first = art.currentScene
        #expect(first != nil)
        for frame in testMusic(seconds: 9) { art.step(frame, dt: 1.0 / 60) }
        #expect(art.currentScene == first)
        for frame in testMusic(seconds: 1.5) { art.step(frame, dt: 1.0 / 60) }
        #expect(art.currentScene == first?.nextScene, "moved on after 10 s")
        _ = art.accessibilityPerformPress()
        #expect(art.currentScene == first?.nextScene.nextScene, "a click skips ahead")
        #expect(recorder.events.contains(.cycleVisualizer))
        player.close()
    }

    /// Rotate opens on a scene that suits the genre, and a new genre brings one of its own.
    @Test func rotateOpensOnTheGenresScene() {
        let (player, _) = makePlayer()
        var state = playing()
        state.genreKey = "lo-fi"
        state.visualizer = .rotate
        player.state = state
        let art = artwork(player)
        #expect(art.currentScene == .campfire)
        #expect(art.caption == "Sunset Sessions · Solar Crew")
        state.genreKey = "techno"
        player.state = state
        #expect(art.currentScene == .tunnel)
        // A scene that already suits the new genre carries on.
        state.genreKey = "acid-techno"
        player.state = state
        #expect(art.currentScene == .tunnel)
        // Not rotating: the pick stays.
        state.visualizer = .halo
        player.state = state
        state.genreKey = "lo-fi"
        player.state = state
        #expect(art.currentScene == .halo)
        player.close()
    }

    @Test func anEffectRedrawsTheStillFrame() {
        let (player, _) = makePlayer()
        var state = playing()
        state.playback = .paused
        player.state = state
        let art = artwork(player)
        art.layoutSubtreeIfNeeded()
        let before = art.framesDrawn
        state.visualizerEffect = .vhs
        player.state = state
        #expect(art.effect == .vhs && art.framesDrawn > before)
        state.playback = .stopped
        player.state = state
        #expect(art.caption.isEmpty)
        player.close()
    }

    @Test func offHidesTheSceneAndAPickShowsIt() {
        let (player, _) = makePlayer()
        var state = playing()
        state.visualizer = .off
        player.state = state
        let art = artwork(player)
        #expect(art.sceneLayer.isHidden && art.currentScene == nil)
        state.visualizer = .pixelDJ
        player.state = state
        #expect(!art.sceneLayer.isHidden && art.currentScene == .pixelDJ && player.visualizerScene == .pixelDJ)
        player.close()
    }

    /// Paused, a scene change or a new palette still draws: a still frame.
    @Test func pausedChangesDrawAStillFrame() {
        let (player, _) = makePlayer()
        var state = playing()
        state.playback = .paused
        player.state = state
        let art = artwork(player)
        art.layoutSubtreeIfNeeded()
        let before = art.framesDrawn
        state.visualizer = .halo
        player.state = state
        #expect(art.framesDrawn > before && art.sceneLayer.contents != nil)
        let afterScene = art.framesDrawn
        state.artworkColors = .window
        player.state = state
        #expect(art.framesDrawn > afterScene, "a new palette redraws the still frame")
        player.close()
    }

    @Test func cycleColoursTurnWhilePlaying() {
        let (player, _) = makePlayer()
        var state = playing()
        state.artworkColors = .cycle
        player.state = state
        let art = artwork(player)
        let start = art.palette
        for frame in testMusic(seconds: 6) { art.step(frame, dt: 1.0 / 60) }
        #expect(art.palette != start)
        player.close()
    }
}

@MainActor @Suite struct VisualizerPopoverTests {
    @Test func tilesAndControlsSendTheirChoices() {
        _ = NSApplication.shared
        let popover = AppearancePopover(appearance: .dark, tint: .pink, visualizer: .starfield, interval: 30, colors: .source,
                                        effect: .kaleidoscope)
        var events: [ModernEvent] = []
        popover.onEvent = { events.append($0) }
        _ = popover.view
        #expect(popover.tiles.count == ModernPlayerState.Visualizer.allCases.count)
        #expect(popover.tiles.filter(\.isSelected).map(\.mode) == [.starfield])
        #expect(popover.intervals.selectedSegment == 2 && popover.backgrounds.selectedSegment == 3)
        #expect(popover.effects.selectedSegment == 2)
        _ = popover.tiles.first { $0.mode == .rotate }?.accessibilityPerformPress()
        #expect(events.last == .setVisualizer(.rotate) && popover.tiles.filter(\.isSelected).map(\.mode) == [.rotate])
        popover.intervals.selectedSegment = 0
        popover.intervals.sendAction(popover.intervals.action, to: popover.intervals.target)
        #expect(events.last == .setVisualizerInterval(10))
        popover.backgrounds.selectedSegment = 1
        popover.backgrounds.sendAction(popover.backgrounds.action, to: popover.backgrounds.target)
        #expect(events.last == .setArtworkColors(.window))
        popover.effects.selectedSegment = 1
        popover.effects.sendAction(popover.effects.action, to: popover.effects.target)
        #expect(events.last == .setVisualizerEffect(.vhs))
        // Every tile fits inside the popover, none overlapping.
        let frames = popover.tiles.map(\.frame)
        #expect(frames.allSatisfy { popover.view.bounds.contains($0) })
        #expect(Set(frames.map { "\($0.minX),\($0.minY)" }).count == frames.count)
        #expect(AppearancePopover.nearestInterval(45) == 2 || AppearancePopover.nearestInterval(45) == 3)
        #expect(AppearancePopover.shortInterval(60) == "1m" && AppearancePopover.shortInterval(20) == "20s")
    }
}
