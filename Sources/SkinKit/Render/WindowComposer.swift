// SPDX-License-Identifier: GPL-3.0-or-later
// The pure window compositor (DESIGN §8.1): `render(window, state, skin)` returns the window as an RGBA8 frame at
// 1x plus metadata about choices made (marquee font fallback, region shaping). Draw order and per-state sprite
// choices follow Webamp's components and css (@ 7734cd3, MIT © 2015 Jordan Eldredge), which is what museum
// screenshots show; deliberate differences are commented where they happen.
//
// Notices for the sources named above:
//
// Webamp — The MIT License (MIT), Copyright (c) [2015] [Jordan Eldredge]
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation

public struct RenderMetadata: Codable, Sendable, Equatable {
    public struct Marquee: Codable, Sendable, Equatable {
        /// "none" (skin font), "system" (the UI should draw `title` with Core Text in the colours below) or
        /// "transliterated" (drawn in the skin font after Latin transliteration).
        public var fallback: String
        /// The title as given.
        public var title: String
        /// The characters drawn with the skin font (FONT_LOOKUP form).
        public var text: String
        /// Pixel offset of the scrolling text (Webamp stepOffset).
        public var offset: Int
        public var rect: IntRect
        public var foreground: String
        public var background: String
    }

    public var window: WindowKind
    public var width: Int
    public var height: Int
    public var sha256: String
    public var skin: String
    public var marquee: Marquee?
    /// "system" when a playlist row needs characters the pixel font lacks (the UI overlays Core Text).
    public var playlistFallback: String?
    public var regionApplied: Bool
    /// Sheets this render drew from the fallback skin.
    public var fallbackSheets: [String]
}

public struct RenderResult: Sendable {
    public let bitmap: Bitmap
    public let metadata: RenderMetadata
}

public enum WindowComposer {
    /// - Parameter hash: fill `metadata.sha256` (goldens and tools); the live UI, which recomposes every second,
    ///   skips it.
    public static func render(_ window: WindowKind, state: WindowState, skin: Skin, hash: Bool = true) -> RenderResult {
        var context = Context(skin: skin, state: state, frame: Bitmap(window.size))
        var marquee: RenderMetadata.Marquee?
        var playlistFallback: String?
        switch window {
        case .main: marquee = context.drawMain()
        case .shade: context.drawShade()
        case .eq: context.drawEQ()
        case .eqShade: context.drawEQShade()
        case .playlist: playlistFallback = context.drawPlaylist()
        }

        var regionApplied = false
        if state.options.applyRegion, let section = window.regionSection, let polygons = skin.regions[section] {
            let mask = RegionRasterizer.mask(polygons, size: window.size)
            context.frame.applyAlphaMask(mask)
            regionApplied = true
        }
        let metadata = RenderMetadata(
            window: window, width: window.size.width, height: window.size.height, sha256: hash ? context.frame.sha256 : "",
            skin: skin.name, marquee: marquee, playlistFallback: playlistFallback, regionApplied: regionApplied,
            fallbackSheets: context.fallbackSheets.sorted())
        return RenderResult(bitmap: context.frame, metadata: metadata)
    }

    /// The marquee as its own 154x6 layer over `base` (a frame rendered with `drawDynamicLayers = false`): the
    /// base's pixels under the text area with the text drawn at the state's scroll step.
    public static func marqueeLayer(state: WindowState, skin: Skin, base: Bitmap) -> (bitmap: Bitmap, metadata: RenderMetadata.Marquee) {
        // Draw on the 154x6 strip itself (the same pixels as drawing on the whole frame and cropping, without copying
        // the frame on every scroll step).
        let rect = MainLayout.marqueeText
        var context = Context(skin: skin, state: state, frame: base.cropped(rect))
        let metadata = context.drawMarquee(origin: rect.origin)
        return (context.frame, metadata)
    }

    /// The visualiser as its own layer: 76x16 for the main window, 38x5 for the shade strip.
    public static func visualizerLayer(_ frame: VisualizerFrame, skin: Skin, shade: Bool) -> Bitmap {
        let size = shade ? ShadeLayout.visualizer.size : MainLayout.visualizer.size
        var bitmap = Bitmap(size)
        let rect = IntRect(origin: .zero, size: size)
        if shade {
            VisualizerRenderer.drawShade(frame, colors: skin.viscolors, into: &bitmap, at: rect)
        } else {
            VisualizerRenderer.draw(frame, colors: skin.viscolors, into: &bitmap, at: rect)
        }
        return bitmap
    }

    private struct Context {
        let skin: Skin
        let state: WindowState
        var frame: Bitmap
        var fallbackSheets: Set<String> = []

        init(skin: Skin, state: WindowState, frame: Bitmap) {
            self.skin = skin
            self.state = state
            self.frame = frame
        }

        // MARK: Primitives

        /// Draws `sprite` at `at`, optionally only its top-left `size` (a draw rect smaller than the sprite) and
        /// starting `offset` into it (a frame of a multi-frame strip).
        mutating func draw(_ sprite: Sprite, at: IntPoint, size: IntSize? = nil, offset: IntPoint = .zero) {
            guard let resolved = skin.resolve(sprite) else { return }
            if resolved.origin == .fallback { fallbackSheets.insert(sprite.source.sheet.fileBase) }
            // Never read past the sprite into its neighbours on the sheet, whatever the draw rect says.
            let full = resolved.rect
            let width = min(size?.width ?? full.width, full.width - offset.x)
            let height = min(size?.height ?? full.height, full.height - offset.y)
            guard width > 0, height > 0 else { return }
            frame.draw(resolved.sheet, from: IntRect(full.x + offset.x, full.y + offset.y, width, height), at: at)
        }

        mutating func draw(_ sprite: Sprite, in rect: IntRect) {
            draw(sprite, at: rect.origin, size: rect.size)
        }

        /// Draws text.bmp glyphs for already-mapped characters, one 5 px cell each, clipped to `clip`.
        mutating func drawText(_ characters: [Character], at origin: IntPoint, clip: IntRect? = nil) {
            guard let (sheet, sheetOrigin) = skin.sheet(.text) else { return }
            if sheetOrigin == .fallback { fallbackSheets.insert("text") }
            var x = origin.x
            for character in characters {
                defer { x += FontLookup.cellWidth }
                guard let cell = FontLookup.cells[character] else { continue }  // unmapped: draws nothing
                var src = IntRect(cell.column * FontLookup.cellWidth, cell.row * FontLookup.cellHeight,
                                  FontLookup.cellWidth, FontLookup.cellHeight)
                var dest = IntPoint(x, origin.y)
                if let clip {
                    let visible = IntRect(x, origin.y, src.width, src.height).intersection(clip)
                    guard !visible.isEmpty else { continue }
                    src = IntRect(src.x + visible.x - x, src.y + visible.y - origin.y, visible.width, visible.height)
                    dest = visible.origin
                }
                frame.draw(sheet, from: src, at: dest)
            }
        }

        mutating func drawText(_ string: String, at origin: IntPoint, clip: IntRect? = nil) {
            drawText(SkinFontText.map(string).characters, at: origin, clip: clip)
        }

        func pressed(_ control: Control) -> Bool { state.pressed == control }

        // MARK: Main window

        mutating func drawMain() -> RenderMetadata.Marquee {
            let s = state
            draw(.mainWindowBackground, at: .zero)
            draw(s.focused ? .mainTitleBarSelected : .mainTitleBar, at: .zero)
            drawTitleButtonsPressed(shade: false)

            // Clutter bar: always drawn; a lit button for double size or while pressed.
            draw(.mainClutterBarBackground, in: MainLayout.clutterBar)
            let clutterSprites: [Sprite] = [.mainClutterBarButtonOSelected, .mainClutterBarButtonASelected,
                                            .mainClutterBarButtonISelected, .mainClutterBarButtonDSelected,
                                            .mainClutterBarButtonVSelected]
            for (index, (control, rect)) in MainLayout.clutter.enumerated()
            where pressed(control) || (control == .clutterD && s.doubleSize) {
                draw(clutterSprites[index], in: rect)
            }

            // Play state, hidden while working; the 3 px work strip shows while playing or working.
            if !s.working {
                switch s.playback {
                case .playing: draw(.mainPlayingIndicator, in: MainLayout.playPause)
                case .paused: draw(.mainPausedIndicator, in: MainLayout.playPause)
                case .stopped: draw(.mainStoppedIndicator, in: MainLayout.playPause)
                }
            }
            if s.working {
                draw(.mainWorkingIndicator, in: MainLayout.workIndicator)
            } else if s.playback == .playing {
                draw(.mainNotWorkingIndicator, in: MainLayout.workIndicator)
            }

            // Time: hidden when stopped; paused blinks.
            if s.playback != .stopped, s.playback != .paused || s.blinkVisible {
                drawTime()
            }

            if let vis = s.visualizer, s.playback != .stopped, s.options.drawDynamicLayers {
                VisualizerRenderer.draw(vis, colors: skin.viscolors, into: &frame, at: MainLayout.visualizer)
            }

            let marquee = drawMarquee(drawText: s.options.drawDynamicLayers)

            if s.playback != .stopped {
                if let kbps = s.kbps {
                    drawText(SkinFontText.rightAligned(String(min(max(kbps, 0), 999)), width: 3), at: MainLayout.kbps.origin, clip: MainLayout.kbps)
                }
                if let khz = s.khz {
                    drawText(SkinFontText.rightAligned(String(min(max(khz, 0), 99)), width: 2), at: MainLayout.khz.origin, clip: MainLayout.khz)
                }
            }
            let live = s.playback != .stopped
            draw(live && s.channels == 2 ? .mainStereoSelected : .mainStereo, in: MainLayout.stereo)
            draw(live && s.channels == 1 ? .mainMonoSelected : .mainMono, in: MainLayout.mono)

            drawVolume()
            drawBalance()

            draw(toggleSprite(eq: true, on: s.eqOpen, pressed: pressed(.eqToggle)), in: MainLayout.eqToggle)
            draw(toggleSprite(eq: false, on: s.playlistOpen, pressed: pressed(.playlistToggle)), in: MainLayout.playlistToggle)

            draw(.mainPositionSliderBackground, in: MainLayout.position)
            if s.playback != .stopped, let p = s.effectivePosition {
                let x = MainLayout.position.x + Int((Double(MainLayout.positionTravel) * p).rounded(.toNearestOrAwayFromZero))
                draw(pressed(.position) ? .mainPositionSliderThumbSelected : .mainPositionSliderThumb,
                     at: IntPoint(x, MainLayout.position.y), size: MainLayout.positionThumb)
            }

            draw(pressed(.previous) ? .mainPreviousButtonActive : .mainPreviousButton, in: MainLayout.previous)
            draw(pressed(.play) ? .mainPlayButtonActive : .mainPlayButton, in: MainLayout.play)
            draw(pressed(.pause) ? .mainPauseButtonActive : .mainPauseButton, in: MainLayout.pause)
            draw(pressed(.stop) ? .mainStopButtonActive : .mainStopButton, in: MainLayout.stop)
            draw(pressed(.next) ? .mainNextButtonActive : .mainNextButton, in: MainLayout.next)
            draw(pressed(.eject) ? .mainEjectButtonActive : .mainEjectButton, in: MainLayout.eject)

            let shuffle: Sprite = switch (s.shuffle, pressed(.shuffle)) {
            case (false, false): .mainShuffleButton
            case (false, true): .mainShuffleButtonDepressed
            case (true, false): .mainShuffleButtonSelected
            case (true, true): .mainShuffleButtonSelectedDepressed
            }
            draw(shuffle, in: MainLayout.shuffle)
            let repeatSprite: Sprite = switch (s.repeat, pressed(.repeat)) {
            case (false, false): .mainRepeatButton
            case (false, true): .mainRepeatButtonDepressed
            case (true, false): .mainRepeatButtonSelected
            case (true, true): .mainRepeatButtonSelectedDepressed
            }
            draw(repeatSprite, in: MainLayout.repeat)
            return marquee
        }

        /// Title-bar buttons have no sprite until pressed: the title bar bitmap carries their normal look.
        mutating func drawTitleButtonsPressed(shade: Bool) {
            if pressed(.options) { draw(.mainOptionsButtonDepressed, in: MainLayout.options) }
            if pressed(.minimize) { draw(.mainMinimizeButtonDepressed, in: MainLayout.minimize) }
            if pressed(.close) { draw(.mainCloseButtonDepressed, in: MainLayout.close) }
            if shade {
                if pressed(.shade) {
                    draw(.mainShadeButtonSelectedDepressed, in: MainLayout.shade)
                } else if state.focused {
                    draw(.mainShadeButtonSelected, in: MainLayout.shade)
                }
            } else if pressed(.shade) {
                draw(.mainShadeButtonDepressed, in: MainLayout.shade)
            }
        }

        func toggleSprite(eq: Bool, on: Bool, pressed: Bool) -> Sprite {
            switch (eq, on, pressed) {
            case (true, false, false): return .mainEqButton
            case (true, true, false): return .mainEqButtonSelected
            case (true, false, true): return .mainEqButtonDepressed
            case (true, true, true): return .mainEqButtonDepressedSelected
            case (false, false, false): return .mainPlaylistButton
            case (false, true, false): return .mainPlaylistButtonSelected
            case (false, false, true): return .mainPlaylistButtonDepressed
            case (false, true, true): return .mainPlaylistButtonDepressedSelected
            }
        }

        /// Minutes and seconds; past 99:59 the display shows hours and minutes (Bitamp's rule; Webamp would draw
        /// blank cells), since radio sessions run for hours.
        static func clockDigits(_ seconds: Double) -> [Int] {
            let total = Int(min(max(seconds.isFinite ? seconds : 0, 0), 1e9).rounded(.down))
            var (a, b) = (total / 60, total % 60)
            if a > 99 { (a, b) = (total / 3600, (total / 60) % 60) }
            return [min(a / 10, 9), a % 10, b / 10, b % 10]
        }

        func displayedSeconds() -> (seconds: Double, negative: Bool) {
            if state.timeMode == .remaining, let duration = state.duration, duration.isFinite {
                return (clamped(duration - clamped(state.elapsed, 0, 1e9), 0, 1e9), true)
            }
            return (state.elapsed, false)
        }

        mutating func drawTime() {
            let (seconds, negative) = displayedSeconds()
            let numsEx = skin.digitSet == .numsEx
            if negative {
                if numsEx {
                    draw(.minusSignEx, in: MainLayout.minusNumsEx)
                } else {
                    draw(.minusSign, in: MainLayout.minusNumbers)
                }
            }
            for (i, digit) in Self.clockDigits(seconds).enumerated() {
                draw(skin.digit(digit), at: IntPoint(MainLayout.digitX[i], MainLayout.digitY), size: MainLayout.digitSize)
            }
        }

        /// - Parameter origin: where the marquee text rect's top-left lies in `frame`'s coordinates: `.zero` when
        ///   `frame` is the window, the rect's own origin when `frame` is the 154x6 strip (`marqueeLayer`).
        mutating func drawMarquee(drawText shouldDraw: Bool = true, origin: IntPoint = .zero) -> RenderMetadata.Marquee {
            let s = state
            let colors = skin.textColors
            let mapped = SkinFontText.map(s.title)
            var fallback = "none"
            var characters = mapped.characters
            if mapped.needsFallback {
                if !s.options.alwaysSkinFont, s.options.systemFontAvailable {
                    fallback = "system"
                } else {
                    fallback = "transliterated"
                    characters = SkinFontText.map(SkinFontText.transliterate(s.title)).characters
                }
            }
            let rect = MainLayout.marqueeText
            let local = IntRect(rect.x - origin.x, rect.y - origin.y, rect.width, rect.height)
            let offset = MarqueeModel.stepOffset(length: characters.count, step: s.marqueeStep, pixels: s.marqueeDrag)
            if !shouldDraw {
                // Left to the marquee layer.
            } else if fallback == "system" {
                // The UI overlays Core Text here; give it a clean field in text.bmp's background colour.
                frame.fill(local, colors.background)
            } else {
                let looped: [Character] = MarqueeModel.isLong(characters.count)
                    ? characters + Array(MarqueeModel.separator) + characters
                    : characters + [Character](repeating: " ", count: max(0, MarqueeModel.maxLength - characters.count))
                drawText(looped, at: IntPoint(local.x - offset, local.y), clip: local)
            }
            return RenderMetadata.Marquee(
                fallback: fallback, title: s.title, text: String(characters), offset: offset, rect: rect,
                foreground: colors.foreground.hexString, background: colors.background.hexString)
        }

        mutating func drawVolume() {
            let v = min(max(state.volume, 0), 100)
            // Webamp: sprite = round(v/100*28), offset (sprite-1)*15; a negative offset is invalid CSS, so 0 -> 0.
            let frameIndex = max(0, Int((Double(v) / 100 * 28).rounded(.toNearestOrAwayFromZero)) - 1)
            draw(.mainVolumeBackground, at: MainLayout.volume.origin, size: MainLayout.volume.size,
                 offset: IntPoint(0, frameIndex * 15))
            let x = MainLayout.volume.x + Int((Double(MainLayout.volumeTravel) * Double(v) / 100).rounded(.toNearestOrAwayFromZero))
            draw(pressed(.volume) ? .mainVolumeThumbSelected : .mainVolumeThumb,
                 at: IntPoint(x, MainLayout.volume.y + 1), size: MainLayout.sliderThumb)
        }

        mutating func drawBalance() {
            let b = min(max(state.balance, -100), 100)
            let frameIndex = Int((Double(abs(b)) / 100 * 27).rounded(.down))
            draw(.mainBalanceBackground, at: MainLayout.balance.origin, size: MainLayout.balance.size,
                 offset: IntPoint(0, frameIndex * 15))
            let x = MainLayout.balance.x
                + Int((Double(MainLayout.balanceTravel) * Double(b + 100) / 200).rounded(.toNearestOrAwayFromZero))
            draw(pressed(.balance) ? .mainBalanceThumbActive : .mainBalanceThumb,
                 at: IntPoint(x, MainLayout.balance.y + 1), size: MainLayout.sliderThumb)
        }

        // MARK: Main shade

        mutating func drawShade() {
            let s = state
            draw(s.focused ? .mainShadeBackgroundSelected : .mainShadeBackground, at: .zero)
            drawTitleButtonsPressed(shade: true)
            drawMiniTime(xs: ShadeLayout.miniTimeX, y: ShadeLayout.miniTimeY)
            if let vis = s.visualizer, s.playback != .stopped, s.options.drawDynamicLayers {
                VisualizerRenderer.drawShade(vis, colors: skin.viscolors, into: &frame, at: ShadeLayout.visualizer)
            }
            draw(.mainShadePositionBackground, in: ShadeLayout.position)
            if s.playback != .stopped, let p = s.effectivePosition {
                let percent = p * 100
                let sprite: Sprite = percent <= 33 ? .mainShadePositionThumbLeft
                    : percent >= 66 ? .mainShadePositionThumbRight : .mainShadePositionThumb
                let x = ShadeLayout.position.x + Int((Double(ShadeLayout.positionTravel) * p).rounded(.toNearestOrAwayFromZero))
                draw(sprite, at: IntPoint(x, ShadeLayout.position.y), size: ShadeLayout.positionThumb)
            }
        }

        /// Webamp's MiniTime: five space glyphs as a background, then minus/digits unless stopped; paused blinks.
        mutating func drawMiniTime(xs: [Int], y: Int) {
            for x in xs { drawText([" "], at: IntPoint(x, y)) }
            guard state.playback != .stopped, state.playback != .paused || state.blinkVisible else { return }
            let (seconds, negative) = displayedSeconds()
            let digits = Self.clockDigits(seconds).map { Character(String($0)) }
            let characters: [Character] = [negative ? "-" : " "] + digits
            for (x, character) in zip(xs, characters) { drawText([character], at: IntPoint(x, y)) }
        }

        // MARK: Equalizer

        mutating func drawEQ() {
            let s = state
            draw(.eqWindowBackground, at: .zero)
            draw(s.focused ? .eqTitleBarSelected : .eqTitleBar, at: .zero)
            if pressed(.shade) { draw(.eqMaximizeButtonActive, in: EQLayout.shade) }
            if pressed(.close) { draw(.eqCloseButtonActive, in: EQLayout.close) }

            let on: Sprite = switch (s.eq.on, pressed(.eqOn)) {
            case (false, false): .eqOnButton
            case (false, true): .eqOnButtonDepressed
            case (true, false): .eqOnButtonSelected
            case (true, true): .eqOnButtonSelectedDepressed
            }
            draw(on, in: EQLayout.on)
            let auto: Sprite = switch (s.eq.auto, pressed(.eqAuto)) {
            case (false, false): .eqAutoButton
            case (false, true): .eqAutoButtonDepressed
            case (true, false): .eqAutoButtonSelected
            case (true, true): .eqAutoButtonSelectedDepressed
            }
            draw(auto, in: EQLayout.auto)

            draw(.eqGraphBackground, in: EQLayout.graph)
            if let graph = skin.resolve(.eqGraphBackground), graph.origin == .fallback { fallbackSheets.insert("eqmain") }
            EQGraph.draw(bands: s.eq.bands, preamp: s.eq.preamp, colors: skin.eqGraphColors,
                         preampLine: skin.resolve(.eqPreampLine), into: &frame, origin: EQLayout.graph.origin)
            draw(pressed(.eqPresets) ? .eqPresetsButtonSelected : .eqPresetsButton, in: EQLayout.presets)

            drawBand(EQLayout.preamp, value: s.eq.preamp, pressed: pressed(.preamp))
            for i in 0..<10 {
                let value = i < s.eq.bands.count ? s.eq.bands[i] : 50
                drawBand(EQLayout.band(i), value: value, pressed: pressed(Control.bands[i]))
            }
        }

        mutating func drawBand(_ rect: IntRect, value: Double, pressed: Bool) {
            let offset = EQSliderGeometry.frameOffset(EQSliderGeometry.frame(for: value))
            draw(.eqSliderBackground, at: rect.origin, size: EQLayout.sliderSize, offset: offset)
            draw(pressed ? .eqSliderThumbSelected : .eqSliderThumb,
                 at: IntPoint(rect.x + 1, rect.y + EQSliderGeometry.thumbOffset(for: value)), size: EQLayout.thumb)
        }

        mutating func drawEQShade() {
            let s = state
            draw(s.focused ? .eqShadeBackgroundSelected : .eqShadeBackground, at: .zero)
            if pressed(.shade) { draw(.eqMinimizeButtonActive, in: EQLayout.shade) }
            if pressed(.close) { draw(.eqShadeCloseButtonActive, in: EQLayout.close) }
            let v = Double(min(max(s.volume, 0), 100))
            let volumeSprites: [Sprite] = [.eqShadeVolumeSliderLeft, .eqShadeVolumeSliderCenter, .eqShadeVolumeSliderRight]
            let vx = EQShadeLayout.volume.x + Int((Double(EQShadeLayout.volumeTravel) * v / 100).rounded(.toNearestOrAwayFromZero))
            draw(volumeSprites[Self.segment(v, 0, 100)], at: IntPoint(vx, EQShadeLayout.volume.y), size: EQShadeLayout.thumb)
            let b = Double(min(max(s.balance, -100), 100))
            let balanceSprites: [Sprite] = [.eqShadeBalanceSliderLeft, .eqShadeBalanceSliderCenter, .eqShadeBalanceSliderRight]
            let bx = EQShadeLayout.balance.x
                + Int((Double(EQShadeLayout.balanceTravel) * (b + 100) / 200).rounded(.toNearestOrAwayFromZero))
            draw(balanceSprites[Self.segment(b, -100, 100)], at: IntPoint(bx, EQShadeLayout.balance.y), size: EQShadeLayout.thumb)
        }

        /// Webamp utils.segment for three looks: which third of [min, max] `value` falls in.
        static func segment(_ value: Double, _ min: Double, _ max: Double) -> Int {
            let t = (value - min) / (max - min)
            return Swift.min(2, Swift.max(0, Int((t * 3).rounded(.down))))
        }

        // MARK: Playlist

        mutating func drawPlaylist() -> String? {
            let s = state
            let style = skin.playlistStyle
            let active = s.focused
            frame.fill(IntRect(origin: .zero, size: PlaylistLayout.size), style.normalBackground)

            // Top row: corner, spacer, right-aligned fill, title, spacer, fill, corner.
            let tile: Sprite = active ? .playlistTopTileSelected : .playlistTopTile
            draw(active ? .playlistTopLeftSelected : .playlistTopLeftCorner, in: PlaylistLayout.topLeft)
            draw(tile, in: PlaylistLayout.leftSpacer)
            drawTiled(tile, in: PlaylistLayout.leftFill, alignRight: true)
            draw(active ? .playlistTitleBarSelected : .playlistTitleBar, in: PlaylistLayout.title)
            draw(tile, in: PlaylistLayout.rightSpacer)
            drawTiled(tile, in: PlaylistLayout.rightFill, alignRight: true)
            draw(active ? .playlistTopRightCornerSelected : .playlistTopRightCorner, in: PlaylistLayout.topRight)
            if pressed(.shade) { draw(.playlistCollapseSelected, in: PlaylistLayout.shadeButton) }
            if pressed(.close) { draw(.playlistCloseSelected, in: PlaylistLayout.close) }

            // Sides, tiled down from the top bar.
            for y in stride(from: PlaylistLayout.top, to: PlaylistLayout.size.height - PlaylistLayout.bottom, by: PlaylistLayout.tileHeight) {
                let h = min(PlaylistLayout.tileHeight, PlaylistLayout.size.height - PlaylistLayout.bottom - y)
                draw(.playlistLeftTile, at: IntPoint(0, y), size: IntSize(PlaylistLayout.leftWidth, h))
                draw(.playlistRightTile, at: IntPoint(PlaylistLayout.size.width - PlaylistLayout.rightWidth, y),
                     size: IntSize(PlaylistLayout.rightWidth, h))
            }
            let fallback = drawRows(style)

            let thumbY = PlaylistLayout.scrollTrack.y
                + Int((Double(PlaylistLayout.scrollTravel) * clamped(s.playlist.scroll, 0, 1)).rounded(.down))
            draw(pressed(.playlistScrollbar) ? .playlistScrollHandleSelected : .playlistScrollHandle,
                 at: IntPoint(PlaylistLayout.scrollTrack.x, thumbY), size: PlaylistLayout.scrollThumb)

            draw(.playlistBottomLeftCorner, in: PlaylistLayout.bottomLeft)
            draw(.playlistBottomRightCorner, in: PlaylistLayout.bottomRight)
            let running = String(s.playlist.runningTime.prefix(PlaylistLayout.runningTimeChars))
            drawText(running.padding(toLength: PlaylistLayout.runningTimeChars, withPad: " ", startingAt: 0),
                     at: PlaylistLayout.runningTime)
            drawMiniTime(xs: PlaylistLayout.miniTimeX, y: PlaylistLayout.miniTimeY)
            drawOpenMenu()
            return fallback
        }

        /// Repeats a sprite across `rect`; `alignRight` anchors the pattern at the right edge (CSS
        /// `background-position: right`).
        mutating func drawTiled(_ sprite: Sprite, in rect: IntRect, alignRight: Bool) {
            let w = sprite.source.rect.width
            guard w > 0 else { return }
            var x = alignRight ? rect.maxX - w : rect.x
            if alignRight { while x > rect.x { x -= w } }
            while x < rect.maxX {
                let left = max(x, rect.x), right = min(x + w, rect.maxX)
                draw(sprite, at: IntPoint(left, rect.y), size: IntSize(right - left, rect.height), offset: IntPoint(left - x, 0))
                x += w
            }
        }

        /// Track rows in pledit colours with the built-in pixel font (deterministic at 1x; the app overlays
        /// Core Text at higher scales, DESIGN §8.3). Returns "system" if a title needed transliteration.
        mutating func drawRows(_ style: PlaylistStyle) -> String? {
            let p = state.playlist
            let list = PlaylistLayout.list
            var needsSystem = false
            for visible in 0..<PlaylistLayout.visibleRows {
                let index = p.firstRow + visible
                guard index >= 0, index < p.rows.count else { break }
                let row = p.rows[index]
                let y = PlaylistLayout.firstRowY + visible * PlaylistLayout.rowHeight
                let rowRect = IntRect(list.x, y, list.width, PlaylistLayout.rowHeight).intersection(list)
                if p.selected.contains(index) { frame.fill(rowRect, style.selectedBackground) }
                let color = p.current == index ? style.current : style.normal

                var right = [row.tag, row.duration].compactMap { $0 }.joined(separator: " ")
                right = PixelFont.normalize(right)
                let rightWidth = right.isEmpty ? 0 : PixelFont.width(of: right) - 1
                let rightX = list.maxX - 3 - rightWidth
                if SkinFontText.map(row.title).needsFallback { needsSystem = true }
                let title = PixelFont.normalize(SkinFontText.transliterate("\(index + 1). \(row.title)"))
                let clip = IntRect(list.x + 1, y, max(0, rightX - 4 - list.x - 1), PlaylistLayout.rowHeight)
                drawPixelText(title, at: IntPoint(list.x + 1, y + 4), color: color, clip: clip)
                drawPixelText(right, at: IntPoint(rightX, y + 4), color: color, clip: rowRect)
            }
            return needsSystem ? "system" : nil
        }

        mutating func drawPixelText(_ text: String, at origin: IntPoint, color: RGBA, clip: IntRect) {
            for (i, character) in text.enumerated() {
                for (r, bits) in PixelFont.rows(for: character).enumerated() {
                    for (c, bit) in bits.enumerated() where bit == "#" {
                        let point = IntPoint(origin.x + i * PixelFont.cellWidth + c, origin.y + r)
                        if clip.contains(point) { frame[point.x, point.y] = color }
                    }
                }
            }
        }

        /// An open playlist pop-up: its entries stacked up from the menu button, with the 3 px bar on the left.
        mutating func drawOpenMenu() {
            guard let menu = state.playlist.openMenu else { return }
            let entries: [(Sprite, Sprite)]
            let anchor: IntRect
            let bar: Sprite
            switch menu {
            case "add":
                anchor = PlaylistLayout.add
                bar = .playlistAddMenuBar
                entries = [(.playlistAddUrl, .playlistAddUrlSelected), (.playlistAddDir, .playlistAddDirSelected),
                           (.playlistAddFile, .playlistAddFileSelected)]
            case "remove":
                anchor = PlaylistLayout.remove
                bar = .playlistRemoveMenuBar
                entries = [(.playlistRemoveAll, .playlistRemoveAllSelected), (.playlistCrop, .playlistCropSelected),
                           (.playlistRemoveSelected, .playlistRemoveSelectedSelected),
                           (.playlistRemoveMisc, .playlistRemoveMiscSelected)]
            case "select":
                anchor = PlaylistLayout.select
                bar = .playlistSelectMenuBar
                entries = [(.playlistInvertSelection, .playlistInvertSelectionSelected),
                           (.playlistSelectZero, .playlistSelectZeroSelected), (.playlistSelectAll, .playlistSelectAllSelected)]
            case "misc":
                anchor = PlaylistLayout.misc
                bar = .playlistMiscMenuBar
                entries = [(.playlistSortList, .playlistSortListSelected), (.playlistFileInfo, .playlistFileInfoSelected),
                           (.playlistMiscOptions, .playlistMiscOptionsSelected)]
            case "list":
                anchor = PlaylistLayout.listMenu
                bar = .playlistListBar
                entries = [(.playlistNewList, .playlistNewListSelected), (.playlistSaveList, .playlistSaveListSelected),
                           (.playlistLoadList, .playlistLoadListSelected)]
            default:
                return
            }
            let top = anchor.maxY - entries.count * 18
            draw(bar, at: IntPoint(anchor.x - 3, top), size: IntSize(3, entries.count * 18))
            for (i, (normal, hover)) in entries.enumerated() {
                draw(state.playlist.menuHover == i ? hover : normal, at: IntPoint(anchor.x, top + i * 18), size: IntSize(22, 18))
            }
        }
    }
}
