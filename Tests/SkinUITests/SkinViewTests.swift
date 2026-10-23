// SPDX-License-Identifier: GPL-3.0-or-later
// SkinView and SkinWindow offscreen: the layer tree shows exactly SkinKit's composer frames (RGBA hashes against
// the M4 goldens), layer geometry is pixel-exact per scale, mouse events reach the interaction model through
// AppKit's coordinate conversion, and every hotspot has an accessibility element.
import AppKit
import SkinKit
import Testing
@testable import SkinUI

/// A fixed visualiser frame (the fixture's bars and peaks, 0...16 → 0...1).
func fixtureVisualizer(_ state: WindowState) -> VisualizerSnapshot? {
    guard let vis = state.visualizer else { return nil }
    // A fixture without peaks draws none: pass zeros so SkinUI's falling-peak tracker stays out of it.
    return VisualizerSnapshot(bars: vis.bars.map { Float($0) / 16 }, scope: vis.scope.map { _ in 0 },
                              peaks: vis.peaks.isEmpty ? [Float](repeating: 0, count: 19) : vis.peaks.map { Float($0) / 16 })
}

/// The 1x picture the layer tree shows: base + marquee + visualiser layers.
@MainActor func composite(_ view: SkinView) -> Bitmap? {
    guard var frame = view.baseBitmap else { return nil }
    if view.kind == .main, let marquee = view.marqueeBitmap { frame.draw(marquee, at: MainLayout.marqueeText.origin) }
    if view.isVisualizerShown, let vis = view.visualizerBitmap {
        frame.draw(vis, at: view.kind == .shade ? ShadeLayout.visualizer.origin : MainLayout.visualizer.origin)
    }
    return frame
}

@MainActor func makeView(_ role: SkinWindowRole, shaded: Bool = false, scale: Double = 2, skin: Skin = SudampDark.skin,
                         state: SkinPlayerState, now: Double = 100, provider: VisualizerProvider? = nil) -> SkinView {
    TestApp.prepare()
    let view = SkinView(role: role, skin: skin, scale: scale, shaded: shaded)
    view.clock = { now }
    view.visualizerProvider = provider
    view.setFocused(true)
    view.playerState = state
    view.tick(now: now)
    return view
}

@MainActor @Suite(.serialized) struct SkinViewLayerTests {
    static func mainPlaying() -> SkinPlayerState {
        var p = SkinPlayerState()
        p.title = "[DEEP HOUSE] SOLAR CREW - SUNSET"
        p.playState = .playing
        p.elapsed = 83
        p.duration = 3720
        p.kbps = 128
        p.khz = 48
        p.stereo = true
        p.volume = 0.75
        return p
    }

    @Test func baseLayerContentsAreTheComposerFrame() throws {
        let fixture = try Repo.fixtureState("02-main-playing")
        let view = makeView(.main, state: Self.mainPlaying(), provider: { fixtureVisualizer(fixture) })
        let image = try #require(view.baseLayer.contents.map { $0 as! CGImage })
        #expect(image.width == 275 && image.height == 116, "1x frame, scaled by the layer")
        var expected = fixture
        expected.options.drawDynamicLayers = false
        let frame = WindowComposer.render(.main, state: expected, skin: SudampDark.skin).bitmap
        #expect(sha256(try #require(rawRGBA(image))) == frame.sha256)
        #expect(view.baseBitmap == frame)
    }

    @Test func theLayerTreeShowsTheMainPlayingGolden() throws {
        let fixture = try Repo.fixtureState("02-main-playing")
        let view = makeView(.main, state: Self.mainPlaying(), provider: { fixtureVisualizer(fixture) })
        #expect(view.isVisualizerShown)
        let marquee = try #require(view.marqueeLayer.contents.map { $0 as! CGImage })
        #expect(sha256(try #require(rawRGBA(marquee))) == view.marqueeBitmap?.sha256)
        let vis = try #require(view.visualizerLayer.contents.map { $0 as! CGImage })
        #expect(sha256(try #require(rawRGBA(vis))) == view.visualizerBitmap?.sha256)
        #expect(try #require(composite(view)).sha256 == (try Repo.golden("sudamp-dark", "02-main-playing")))
    }

    @Test func pausedRemainingMonoMatchesItsGolden() throws {
        let fixture = try Repo.fixtureState("03-main-paused-remaining")
        var p = SkinPlayerState()
        p.title = fixture.title
        p.playState = .paused
        p.elapsed = 1325
        p.duration = 3720
        p.timeDisplay = .remaining
        p.kbps = 96
        p.khz = 44
        p.stereo = false
        p.volume = 0.30
        p.balance = -0.6
        let view = makeView(.main, state: p, provider: { fixtureVisualizer(fixture) })
        var chrome = SkinChrome()
        chrome.eqOpen = false
        view.chrome = chrome  // redrawn at the fake clock's t = 100: just paused, digits shown, marquee at step 0
        #expect(try #require(composite(view)).sha256 == (try Repo.golden("sudamp-dark", "03-main-paused-remaining")))
        let shown = try #require(view.baseBitmap)
        view.tick(now: 102.5)  // the blink's hidden phase
        #expect(view.baseBitmap != shown)
        #expect(view.baseBitmap?.cropped(MainLayout.time) != shown.cropped(MainLayout.time))
    }

    @Test func shadeAndEqualizerMatchTheirGoldens() throws {
        let shadeFixture = try Repo.fixtureState("08-shade-playing")
        var p = Self.mainPlaying()
        p.elapsed = 754
        let shade = makeView(.main, shaded: true, state: p, provider: { fixtureVisualizer(shadeFixture) })
        #expect(shade.kind == .shade && shade.frame.size == CGSize(width: 550, height: 28))
        #expect(try #require(composite(shade)).sha256 == (try Repo.golden("sudamp-dark", "08-shade-playing")))

        let eqFixture = try Repo.fixtureState("09-eq-curve")
        var e = SkinPlayerState()
        e.equalizer.preamp = (eqFixture.eq.preamp - 50) / 50 * 12
        e.equalizer.bands = eqFixture.eq.bands.map { ($0 - 50) / 50 * 12 }
        let eq = makeView(.equalizer, state: e)
        #expect(eq.baseBitmap?.sha256 == (try Repo.golden("sudamp-dark", "09-eq-curve")))
        #expect(eq.marqueeLayer.isHidden && eq.visualizerLayer.isHidden)
    }

    @Test(arguments: [1.0, 2, 3])
    func layerGeometryIsWholePointsAtEveryScale(scale: Double) {
        let view = makeView(.main, scale: scale, state: Self.mainPlaying())
        let s = CGFloat(scale)
        #expect(view.frame.size == CGSize(width: 275 * s, height: 116 * s))
        #expect(view.baseLayer.frame == CGRect(x: 0, y: 0, width: 275 * s, height: 116 * s))
        #expect(view.marqueeLayer.frame == CGRect(x: 111 * s, y: 27 * s, width: 154 * s, height: 6 * s))
        #expect(view.visualizerLayer.frame == CGRect(x: 24 * s, y: 43 * s, width: 76 * s, height: 16 * s))
        for layer in [view.baseLayer, view.marqueeLayer, view.visualizerLayer] {
            #expect(layer.magnificationFilter == .nearest && layer.minificationFilter == .nearest)
            #expect(layer.contentsGravity == .resize)
        }
        #expect(view.layer?.isGeometryFlipped == true, "sublayer frames use the skin's top-left origin")
        #expect(view.isFlipped)
    }

    @Test(arguments: [1.2, 1.5, 2.5])
    func atInBetweenScalesTheLayersLineUpWithTheBase(scale: Double) {
        let view = makeView(.main, scale: scale, state: Self.mainPlaying())
        let size = SkinScale.pointSize(.main, scale: scale)
        #expect(size.width == size.width.rounded() && size.height == size.height.rounded(), "whole points")
        #expect(view.frame.size == size && view.baseLayer.frame == CGRect(origin: .zero, size: size))
        // CALayer keeps a frame as position and bounds, so it reads back within rounding of what was set.
        func near(_ a: CGRect, _ b: CGRect) -> Bool {
            [a.minX - b.minX, a.minY - b.minY, a.width - b.width, a.height - b.height].allSatisfy { abs($0) < 1e-9 }
        }
        #expect(near(view.marqueeLayer.frame, SkinScale.viewRect(MainLayout.marqueeText, in: .main, scale: scale)))
        #expect(near(view.visualizerLayer.frame, SkinScale.viewRect(MainLayout.visualizer, in: .main, scale: scale)))
    }

    @Test func theBaseOnlyRecomposesWhenItsPixelsChange() throws {
        var p = Self.mainPlaying()
        p.title = String(repeating: "A LONG SCROLLING TITLE ", count: 3)
        let view = makeView(.main, state: p, now: 100)
        let base = try #require(view.baseLayer.contents as AnyObject?)
        let marquee = try #require(view.marqueeBitmap)
        view.tick(now: 100.5)  // two marquee steps later
        #expect((view.baseLayer.contents as AnyObject?) === base, "the base is untouched by scrolling")
        #expect(view.marqueeBitmap != marquee)
        p.elapsed = 83.9
        view.playerState = p
        #expect((view.baseLayer.contents as AnyObject?) === base, "sub-second time changes draw nothing")
        p.elapsed = 84
        view.playerState = p
        #expect((view.baseLayer.contents as AnyObject?) !== base)
        var short = p
        short.title = "SHORT"
        view.playerState = short
        let still = view.marqueeBitmap
        view.tick(now: 103)
        #expect(view.marqueeBitmap == still, "short titles do not scroll")
    }

    @Test func visualizerShowsOnlyWhilePlayingOrPaused() {
        var p = Self.mainPlaying()
        let view = makeView(.main, state: p, provider: { VisualizerSnapshot(bars: [1, 0.5], scope: []) })
        #expect(view.isVisualizerShown)
        #expect(view.visualizerBitmap?.size == IntSize(76, 16))
        p.visualizerMode = .off
        view.playerState = p
        #expect(!view.isVisualizerShown)
        p.visualizerMode = .oscilloscope
        p.playState = .stopped
        view.playerState = p
        #expect(!view.isVisualizerShown)
        p.playState = .paused
        view.playerState = p
        #expect(view.isVisualizerShown)
        let eq = makeView(.equalizer, state: p, provider: { .silent })
        #expect(!eq.isVisualizerShown)
    }

    @Test func pausedVisualizerFreezesOnItsLastFrame() throws {
        final class Level { var value: Float = 1 }
        let level = Level()
        var p = Self.mainPlaying()
        let view = makeView(.main, state: p, provider: { VisualizerSnapshot(bars: [Float](repeating: level.value, count: 19), scope: []) })
        let loud = try #require(view.visualizerBitmap)
        level.value = 0.25
        view.tick(now: 100.1)
        let quiet = try #require(view.visualizerBitmap)
        #expect(quiet != loud, "playing: every frame pulls the provider")
        p.playState = .paused
        view.playerState = p
        level.value = 1
        view.tick(now: 100.2)
        #expect(view.visualizerBitmap == quiet && view.isVisualizerShown, "paused: the last frame stays")
        p.playState = .stopped
        view.playerState = p
        #expect(!view.isVisualizerShown)
    }

    @Test func displayLinkDemandFollowsWhatAnimates() {
        var p = Self.mainPlaying()
        p.title = "SHORT"
        let main = makeView(.main, state: p)
        #expect(main.desiredFrameRate == 30, "visualiser")
        #expect(main.nextTimedRedraw(after: 100) == nil, "a short title doesn't scroll")
        p.visualizerMode = .off
        main.playerState = p
        #expect(main.desiredFrameRate == 0, "nothing moves; state changes redraw by themselves")
        p.title = String(repeating: "A LONG SCROLLING TITLE ", count: 3)
        main.playerState = p
        #expect(main.desiredFrameRate == 0, "a scrolling title needs no display link")
        let step = main.nextTimedRedraw(after: 100.05)
        #expect(step.map { abs($0 - 100.22) < 1e-9 } == true, "the next 220 ms marquee step")
        p.title = "SHORT"
        p.playState = .paused
        main.playerState = p
        #expect(main.desiredFrameRate == 0)
        #expect(main.nextTimedRedraw(after: 100.5) == 102, "the blink starts after 2 s paused")
        #expect(main.nextTimedRedraw(after: 102.3) == 103, "then toggles every second")
        let playlist = makeView(.playlist, state: p)
        #expect(playlist.nextTimedRedraw(after: 100) == 102, "the playlist's mini time blinks too")
        p.playState = .playing
        playlist.playerState = p
        #expect(playlist.desiredFrameRate == 0 && playlist.nextTimedRedraw(after: 100) == nil)
        #expect(makeView(.equalizer, state: p).desiredFrameRate == 0)
        #expect(!main.isDisplayLinkRunning, "no window, no link")
    }

    @Test func titlesTheSkinFontLacksGetTheCoreTextOverlay() throws {
        var p = Self.mainPlaying()
        p.title = "[LOFI] 東京の夜 - ローファイ"
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let big = makeView(.main, scale: 2, state: p)
        #expect(big.marqueeMetadata?.fallback == "system")
        #expect(big.isTitleOverlayShown)
        let small = makeView(.main, scale: 1, state: p)
        let overlay = SkinScale.devicePixelsPerSkinPixel(scale: 1, backingScaleFactor: backing) >= 2
        #expect(small.marqueeMetadata?.fallback == (overlay ? "system" : "transliterated"))
        #expect(small.isTitleOverlayShown == overlay)
        p.alwaysSkinFont = true
        big.playerState = p
        #expect(big.marqueeMetadata?.fallback == "transliterated" && !big.isTitleOverlayShown)
    }

    @Test func regionSkinsAreTransparentOutsideTheirShape() throws {
        let andamp = try #require(SkinLoader.load(url: Repo.url("Fixtures/skins/AndAmp-Dark.wsz")).skin)
        let view = makeView(.main, skin: andamp, state: Self.mainPlaying())
        let mask = try #require(andamp.regionMask(.main))
        let base = try #require(view.baseBitmap)
        for i in 0..<(275 * 116) { #expect(base.pixels[i * 4 + 3] == mask[i]) }
        view.configure(kind: .shade)
        #expect(view.baseBitmap?.size == IntSize(275, 14) && view.frame.size == CGSize(width: 550, height: 28))
    }
}

@MainActor @Suite(.serialized) struct SkinWindowTests {
    @Test(arguments: SkinScale.allowed)
    func windowsAreBorderlessClearAndSizedPerScale(scale: Double) {
        TestApp.prepare()
        let window = SkinWindow(role: .playlist, skin: SudampDark.skin, scale: scale)
        defer { window.skinView.stopDisplayLink() }
        #expect(window.frame.size == SkinScale.pointSize(.playlist, scale: scale))
        #expect(window.styleMask == [.borderless, .miniaturizable])
        #expect(!window.isOpaque && window.backgroundColor == .clear && window.hasShadow)
        #expect(window.canBecomeKey && window.canBecomeMain)
        #expect(window.contentView === window.skinView)
        let far = CGRect(x: -5000, y: 9000, width: 10, height: 10)
        #expect(window.constrainFrameRect(far, to: NSScreen.main) == far, "WindowManager keeps groups on screen")
        #expect(!window.ignoresMouseEvents)
    }

    /// S1: assigning ignoresMouseEvents (even false) disables WindowServer's click-through of alpha-0 pixels, and a
    /// hitTest override cannot produce it. Guard the sources against both.
    @Test func sourcesNeverAssignIgnoresMouseEventsOrOverrideHitTest() throws {
        let dir = Repo.url("Sources/SkinUI")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        #expect(files.count >= 10)
        for file in files {
            let text = try String(contentsOf: dir.appending(path: file), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                #expect(!code.contains("ignoresMouseEvents"), "\(file): \(line)")
                #expect(!code.contains("func hitTest("), "\(file): \(line)")
            }
        }
    }

    /// A real NSEvent sequence on a window that is never shown: AppKit's conversion → skin pixels → event.
    @Test func mouseEventsReachTheInteractionModel() throws {
        TestApp.prepare()
        let window = SkinWindow(role: .main, skin: SudampDark.skin, scale: 2)
        defer { window.skinView.stopDisplayLink() }
        window.setFrameOrigin(CGPoint(x: 300, y: 400))
        let view = window.skinView
        view.playerState = SkinViewLayerTests.mainPlaying()
        var outputs: [SkinInteractionOutput] = []
        view.onOutput = { output, _ in outputs.append(output) }
        // Play button centre (50.5, 97) in skin px → (101, 194) flipped view points → (101, 232 - 194) in the window.
        let play = CGPoint(x: 101, y: 232 - 194)
        func send(_ type: NSEvent.EventType, _ at: CGPoint, clicks: Int = 1) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: clicks, pressure: 1))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            case .rightMouseDown: view.rightMouseDown(with: event)
            default: break
            }
        }
        try send(.leftMouseDown, play)
        #expect(view.interaction.pressed == .play)
        #expect(view.baseState?.pressed == .play, "the pressed sprite is drawn")
        try send(.leftMouseUp, play)
        #expect(outputs == [.event(.play)])
        #expect(view.baseState?.pressed == nil)

        outputs = []
        try send(.leftMouseDown, CGPoint(x: 200, y: 232 - 10))  // title bar
        guard case .beginWindowDrag(let screen)? = outputs.first else {
            Issue.record("expected a window drag, got \(outputs)")
            return
        }
        #expect(screen == CGPoint(x: 500, y: 400 + 222), "window-relative point converted to the screen")
        try send(.leftMouseUp, CGPoint(x: 200, y: 232 - 10))
        try send(.rightMouseDown, play)
        #expect(outputs.last == .event(.contextMenu(screenPoint: CGPoint(x: 401, y: 438))))
    }

    @Test func clicksLandOnTheirControlAtInBetweenScales() throws {
        TestApp.prepare()
        let window = SkinWindow(role: .main, skin: SudampDark.skin, scale: 1.5)
        defer { window.skinView.stopDisplayLink() }
        let view = window.skinView
        #expect(window.frame.size == CGSize(width: 413, height: 174))
        var outputs: [SkinInteractionOutput] = []
        view.onOutput = { output, _ in outputs.append(output) }
        // Play's centre (50.5, 97) in skin px → (50.5 × 413/275, 145.5) flipped view points.
        let play = CGPoint(x: 50.5 * 413 / 275, y: 174 - 145.5)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: play, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        #expect(outputs == [.event(.play)])
    }

    @Test func aWindowWithoutAManagerDragsItself() throws {
        TestApp.prepare()
        let window = SkinWindow(role: .playlist, skin: SudampDark.skin, scale: 1)
        defer { window.skinView.stopDisplayLink() }
        window.setFrameOrigin(CGPoint(x: 100, y: 100))
        func send(_ type: NSEvent.EventType, _ at: CGPoint) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: window.skinView.mouseDown(with: event)
            case .leftMouseDragged: window.skinView.mouseDragged(with: event)
            default: window.skinView.mouseUp(with: event)
            }
        }
        try send(.leftMouseDown, CGPoint(x: 150, y: 225))  // title bar
        try send(.leftMouseDragged, CGPoint(x: 180, y: 215))
        try send(.leftMouseUp, CGPoint(x: 150, y: 225))
        #expect(window.frame.origin == CGPoint(x: 130, y: 90))
    }

    @Test func eqShadePressedSpriteMatchesItsGolden() throws {
        TestApp.prepare()
        let window = SkinWindow(role: .equalizer, skin: SudampDark.skin, scale: 2, shaded: true)
        defer { window.skinView.stopDisplayLink() }
        let view = window.skinView
        var p = SkinPlayerState()
        p.volume = 0.4
        p.balance = -1
        view.playerState = p
        view.setFocused(true)
        // Shade button centre (258.5, 7.5) → (517, 15) flipped → (517, 28 - 15) in the window.
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 517, y: 13), modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        #expect(view.baseBitmap?.sha256 == (try Repo.golden("sudamp-dark", "13-eq-shade")))
    }

    @Test func keysAndSelectionStayLocal() {
        let view = makeView(.playlist, state: playingState())
        var outputs: [SkinInteractionOutput] = []
        view.onOutput = { output, _ in outputs.append(output) }
        view.deliver([.event(.playlistRowSelected(index: 4))])
        #expect(view.selectedRows == [4])
        #expect(view.windowState().playlist.selected == [4])
        view.deliver([.event(.playlistScroll(firstRow: 2))])
        #expect(view.firstVisibleRow == 2 && view.windowState().playlist.firstRow == 2)
        #expect(outputs.count == 2)
    }
}

@MainActor @Suite(.serialized) struct AccessibilityTests {
    @Test func everyHotspotHasALabelledElement() {
        for (role, shaded) in [(SkinWindowRole.main, false), (.main, true), (.equalizer, false), (.equalizer, true), (.playlist, false)] {
            let view = makeView(role, shaded: shaded, state: playingState())
            let elements = view.accessibilityElementsForTesting
            let hotspots = Layout.hitRects(view.kind).filter { $0.0 != .titleBar }
            #expect(elements.count == hotspots.count, "\(view.kind)")
            #expect(Set(elements.map(\.control)) == Set(hotspots.map(\.0)))
            for element in elements {
                #expect(!(element.accessibilityLabel() ?? "").isEmpty)
                #expect(element.accessibilityRole() != nil)
                #expect(element.accessibilityParent() as AnyObject? === view)
            }
            #expect(Set(elements.compactMap { $0.accessibilityIdentifier() }).count == elements.count, "unique identifiers")
            #expect((view.accessibilityChildren() ?? []).count == elements.count)
        }
    }

    @Test func pressAndIncrementGoThroughTheEventPath() throws {
        let view = makeView(.main, state: playingState())
        var outputs: [SkinInteractionOutput] = []
        view.onOutput = { output, _ in outputs.append(output) }
        let elements = view.accessibilityElementsForTesting
        let play = try #require(elements.first { $0.control == .play })
        #expect(play.accessibilityRole() == .button && play.accessibilityLabel() == "Play")
        #expect(play.accessibilityPerformPress())
        #expect(outputs == [.event(.play)])
        let volume = try #require(elements.first { $0.control == .volume })
        #expect(volume.accessibilityRole() == .slider)
        #expect((volume.accessibilityValue() as? NSNumber)?.doubleValue == 0.75)
        #expect(volume.accessibilityPerformIncrement())
        guard case .event(.volume(let v))? = outputs.last else {
            Issue.record("expected volume, got \(outputs)")
            return
        }
        #expect(abs(v - 0.8) < 1e-9)
        let marquee = try #require(elements.first { $0.control == .marquee })
        #expect(marquee.accessibilityRole() == .menuButton)
        #expect(marquee.accessibilityPerformPress())
        guard case .event(.marqueeClick)? = outputs.last else {
            Issue.record("expected a marquee click, got \(outputs)")
            return
        }
        let shuffle = try #require(elements.first { $0.control == .shuffle })
        #expect(shuffle.accessibilityRole() == .checkBox && (shuffle.accessibilityValue() as? NSNumber)?.intValue == 0)
        let band = makeView(.equalizer, state: playingState()).accessibilityElementsForTesting.first { $0.control == .band0 }
        #expect(band?.accessibilityLabel() == "Equalizer 60 Hz")
    }
}

@MainActor @Suite(.serialized) struct PausedMarqueeTests {
    @Test func aPausedTitleStandsStillAndContinuesOnPlay() {
        var p = SkinViewLayerTests.mainPlaying()
        p.title = String(repeating: "A LONG SCROLLING TITLE ", count: 3)
        var now = 100.0
        let view = makeView(.main, state: p)
        view.clock = { now }
        now = 101.15  // five steps in
        view.tick(now: now)
        let scrolled = view.windowState(now: now).marqueeStep
        #expect(scrolled == 5)
        p.playState = .paused
        view.playerState = p
        now = 105
        #expect(view.windowState(now: now).marqueeStep == scrolled, "paused: the title stays where it is")
        let next = view.nextTimedRedraw(after: now)
        #expect(next.map { abs($0 - 105.15) < 1e-9 } == true, "only the blink still moves")
        p.playState = .playing
        view.playerState = p
        now = 105.23
        #expect(view.windowState(now: now).marqueeStep == scrolled + 1, "playing again: on from there, at once")
    }
}

@MainActor @Suite(.serialized) struct BasePatchTests {
    /// On screen, a second's tick uploads only the time digits: the base layer keeps its image and a patch layer
    /// covers what changed, so the two together are exactly the new frame.
    @Test func aTickingClockIsPatchedPixelExactly() throws {
        TestApp.prepare()
        var p = SkinViewLayerTests.mainPlaying()
        let window = SkinWindow(role: .main, skin: SudampDark.skin, scale: 2)
        let view = window.skinView
        view.clock = { 100 }
        view.playerState = p
        let base = try #require(view.baseLayer.contents as AnyObject?)
        #expect(view.patchLayer.isHidden)
        p.elapsed = 84
        view.playerState = p
        #expect((view.baseLayer.contents as AnyObject?) === base, "the base image stays")
        let patch = try #require(view.patchRect)
        #expect(!view.patchLayer.isHidden && MainLayout.time.contains(patch), "only the time digits: \(patch)")
        #expect(view.patchLayer.frame == SkinScale.viewRect(patch, in: .main, scale: 2))
        // base layer image + patch == the composer's frame for the new state.
        let shown = try #require(rawRGBA(view.baseLayer.contents as! CGImage))
        var picture = Bitmap(width: 275, height: 116, pixels: shown)
        let patchPixels = try #require(rawRGBA(view.patchLayer.contents as! CGImage))
        picture.draw(Bitmap(width: patch.width, height: patch.height, pixels: patchPixels), at: patch.origin)
        #expect(picture == view.baseBitmap)
        // Many changed pixels (here: the EQ and PL buttons and the volume) replace the base image and drop the patch.
        p.volume = 0.1
        p.balance = 1
        p.shuffle = true
        p.repeat = true
        p.stereo = false
        view.playerState = p
        view.chrome.eqOpen = false
        #expect(view.patchLayer.isHidden == (view.patchRect == nil))
        // A reconfigured view (skin, scale, shade) starts again from a whole image.
        view.configure(skin: SudampDark.skin)
        #expect(view.patchLayer.isHidden && view.patchRect == nil)
        #expect((view.baseLayer.contents as AnyObject?) !== base)
    }

    @Test func changedRectFindsTheDifference() {
        var a = Bitmap(width: 10, height: 6)
        var b = a
        #expect(SkinView.changedRect(a, b) == nil)
        b.fill(IntRect(3, 2, 2, 3), .white)
        #expect(SkinView.changedRect(a, b) == IntRect(3, 2, 2, 3))
        a.fill(IntRect(9, 5, 1, 1), .white)
        #expect(SkinView.changedRect(a, b) == IntRect(3, 2, 7, 4))
        #expect(SkinView.union(IntRect(0, 0, 2, 2), IntRect(5, 5, 1, 1)) == IntRect(0, 0, 6, 6))
    }
}
