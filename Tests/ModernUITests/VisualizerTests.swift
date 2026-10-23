// SPDX-License-Identifier: GPL-3.0-or-later
// DESIGN §8.4: the modern visualiser. Its scenes draw offscreen, deterministically, in music and in silence; the
// beat tracker finds kicks and keeps time through a break; the renderer cross-fades and the rotation moves on; the
// artwork's colour schemes keep the visualiser legible; and the artwork view draws bitmaps, never animated paths (an
// in-flight shape layer path has a different element structure, which tore the old bars apart).
import AppKit
import QuartzCore
import Testing
@testable import ModernUI

/// Analyser-like frames: a kick every half second (124-ish bpm) that jumps the low bars and falls back, mids that
/// wander, hats in the treble, and a scope sine; `breakAt` stops the kick.
nonisolated func testMusic(seconds: Double, fps: Double = 60, kickEvery: Double = 0.5,
                           breakAt: ClosedRange<Double>? = nil) -> [ModernVisualizerFrame] {
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
            if b < 4 { return inBreak ? 0.4 : bass - Float(b) * 0.04 }
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
        #expect(Visualizer.scenes.count == 11 && !Visualizer.scenes.contains(.rotate) && !Visualizer.scenes.contains(.off))
        #expect(Visualizer.default == .spectrum && Visualizer.allCases.last == .off)
        #expect(Set(Visualizer.allCases.map(\.title)).count == Visualizer.allCases.count, "every choice has its own name")
        // Clicking the artwork walks every scene and comes round again; off and rotate start at the first.
        var mode = Visualizer.spectrum
        var seen: [Visualizer] = []
        for _ in Visualizer.scenes {
            seen.append(mode)
            mode = mode.nextScene
        }
        #expect(seen == Visualizer.scenes && mode == .spectrum)
        #expect(Visualizer.off.nextScene == .spectrum && Visualizer.rotate.nextScene == .spectrum)
        #expect(Visualizer(rawValue: "pixel-dj") == .pixelDJ)
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
        #expect(VisualizerRotation.next(after: nil) == .spectrum && VisualizerRotation.next(after: .lava) == .spectrum)
        #expect(VisualizerRotation.next(after: .starfield) == .pixelDJ && VisualizerRotation.next(after: .pixelDJ) == .toast)
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
        #expect(bytes(play(mode, music, seed: 3)) == bytes(play(mode, music, seed: 3)), "\(mode)")
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
        let popover = AppearancePopover(appearance: .dark, tint: .pink, visualizer: .starfield, interval: 30, colors: .source)
        var events: [ModernEvent] = []
        popover.onEvent = { events.append($0) }
        _ = popover.view
        #expect(popover.tiles.count == ModernPlayerState.Visualizer.allCases.count)
        #expect(popover.tiles.filter(\.isSelected).map(\.mode) == [.starfield])
        #expect(popover.intervals.selectedSegment == 2 && popover.backgrounds.selectedSegment == 3)
        _ = popover.tiles.first { $0.mode == .rotate }?.accessibilityPerformPress()
        #expect(events.last == .setVisualizer(.rotate) && popover.tiles.filter(\.isSelected).map(\.mode) == [.rotate])
        popover.intervals.selectedSegment = 0
        popover.intervals.sendAction(popover.intervals.action, to: popover.intervals.target)
        #expect(events.last == .setVisualizerInterval(10))
        popover.backgrounds.selectedSegment = 1
        popover.backgrounds.sendAction(popover.backgrounds.action, to: popover.backgrounds.target)
        #expect(events.last == .setArtworkColors(.window))
        #expect(AppearancePopover.nearestInterval(45) == 2 || AppearancePopover.nearestInterval(45) == 3)
        #expect(AppearancePopover.shortInterval(60) == "1m" && AppearancePopover.shortInterval(20) == "20s")
    }
}
