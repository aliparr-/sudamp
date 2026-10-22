// SPDX-License-Identifier: GPL-3.0-or-later
//
// Paints every sprite of the original "sudamp Dark" skin in code from a `SkinTheme`. No pixels come from any
// existing skin: shapes are flat fills, 1 px bevels, ridges and the original pixel font.
//
// Ported from Bitamp, Sources/BitampKit/Skin/DefaultSkin.swift
// (https://github.com/ryanromanov/Bitamp @ 91952819c9cc0394dd03a961dd27a101a52ee6ef).
// sudamp changes: retheme only for the art (sudamp Dark palette, "SUDAMP" titles, an original "S" about mark in
// place of Bitamp's "b"); draws into `Canvas`/`Bitmap` instead of CGImage; the brushed/gloss/gel/Orb branches are
// removed; the sprites Bitamp did not paint (clutter bar, work indicator, playlist menu buttons and bars, the
// playlist visualiser panel, playlist scroll arrows, unpressed EQ close buttons) are added in the same style;
// shade mini-time positions follow Webamp's layout.
//
// Original notice:
//
// MIT License
//
// Copyright (c) 2026 Ryan Romanosky and Bitamp contributors
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

/// Bitamp's DefaultSkin, rethemed: renders each element once and caches it. Used only by the generator.
final class SudampDarkPainter {
    let theme: SkinTheme
    private var cache: [SkinElement: Bitmap] = [:]
    private var glyphs: [Character: Bitmap] = [:]

    private enum Playlist {
        static let top = 20, bottom = 38, left = 12, right = 20, heightStep = 29
        static let scrollThumb = IntSize(8, 18)
    }

    private enum Shade {
        static let height = 14
        static let thumb = IntSize(3, 7)
        static let mainVisualizer = IntRect(79, 5, 38, 5)
        static let mainTimeY = 4
        static let mainPosition = IntRect(226, 4, 17, 7)
        static let eqVolume = IntRect(61, 4, 97, 7)
        static let eqBalance = IntRect(164, 4, 43, 7)
    }

    private static let eqLabelY = 104
    private static let bandLabels = ["60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]

    init(theme: SkinTheme = SudampDarkTheme.theme) {
        self.theme = theme
    }

    func image(for element: SkinElement) -> Bitmap {
        if let image = cache[element] { return image }
        let image = render(element)
        cache[element] = image
        return image
    }

    /// A 5x6 text.bmp cell: the glyph in LCD colour on transparent.
    func glyph(for character: Character) -> Bitmap {
        if let image = glyphs[character] { return image }
        let canvas = Canvas(PixelFont.cellWidth, PixelFont.cellHeight)
        canvas.glyph(character, 0, 0, theme.lcdOn)
        let image = canvas.image()
        glyphs[character] = image
        return image
    }

    private func render(_ element: SkinElement) -> Bitmap {
        switch element {
        case .mainBackground: return background()
        case .titleBar(let active): return titleBar(theme.title, active: active, ridgesEnd: 240)
        case .titleButton(let button, let pressed): return titleButton(button, pressed: pressed)
        case .transport(let button, let pressed): return transportButton(button, pressed: pressed)
        case .playStatus(let status): return playStatus(status)
        case .workIndicator(let working): return workIndicator(working: working)
        case .mono(let active): return indicator("MONO", size: MainLayout.mono.size, x: 4, active: active)
        case .stereo(let active): return indicator("STEREO", size: MainLayout.stereo.size, x: 0, active: active)
        case .volumeBackground(let level): return volumeBackground(level)
        case .balanceBackground(let level): return balanceBackground(level)
        case .volumeThumb(let pressed), .balanceThumb(let pressed): return sliderThumb(pressed: pressed)
        case .positionBackground: return positionBackground()
        case .positionThumb(let pressed): return positionThumb(pressed: pressed)
        case .toggle(let button, let on, let pressed): return toggleButton(button, on: on, pressed: pressed)
        case .about(let pressed): return aboutButton(pressed: pressed)
        case .digit(let digit): return self.digit(digit)
        case .minus:
            let c = Canvas(9, 13)
            c.fill(1, 5, 6, 2, theme.lcdOn)
            return c.image()
        case .clutterBar(let enabled): return clutterBar(enabled: enabled)
        case .clutterButton(let index): return clutterButton(index)

        case .eqBackground: return eqBackground()
        case .eqTitleBar(let active): return titleBar(theme.eqTitle, active: active, ridgesEnd: 249)
        case .eqCloseButton(let pressed), .playlistCloseButton(let pressed): return titleButton(.close, pressed: pressed)
        case .eqButton(let button, let on, let pressed): return eqButton(button, on: on, pressed: pressed)
        case .eqSliderBackground(let level): return eqSliderBackground(level)
        case .eqSliderThumb(let pressed):
            let c = Canvas(EQLayout.thumb)
            thumb(c, pressed: pressed, grips: [])
            c.fill(2, 5, 7, 1, theme.faceDark)
            c.fill(2, 6, 7, 1, theme.faceLight)
            return c.image()
        case .eqGraphBackground: return eqGraphBackground()
        case .eqPreampLine:
            let c = Canvas(EQLayout.graph.width, 1)
            for x in stride(from: 0, to: c.width, by: 2) { c.fill(x, 0, 1, 1, theme.accentDim) }
            return c.image()

        case .playlistTopLeft(let active): return playlistTop(width: 25, active: active, leftEdge: true)
        case .playlistTopTile(let active): return playlistTop(width: 25, active: active)
        case .playlistTopRight(let active): return playlistTop(width: 25, active: active, rightEdge: true)
        case .playlistTitle(let active): return playlistTitle("PLAYLIST", width: 100, active: active)
        case .playlistLeftTile: return playlistSide(width: Playlist.left, left: true)
        case .playlistRightTile: return playlistSide(width: Playlist.right, left: false)
        case .playlistBottomLeft: return playlistBottomLeft()
        case .playlistBottomRight: return playlistBottomRight()
        case .playlistBottomTile: return playlistBottom(width: 25)
        case .playlistVisualizerBackground: return playlistVisualizerBackground()
        case .playlistScrollThumb(let pressed):
            let c = Canvas(Playlist.scrollThumb)
            thumb(c, pressed: pressed, grips: [])
            for y in [6, 8, 10] {
                c.fill(2, y, 4, 1, theme.faceDark)
                c.fill(2, y + 1, 4, 1, theme.faceLight)
            }
            return c.image()
        case .playlistMenu(let button, let selected): return playlistMenuButton(button.label, selected: selected)
        case .playlistMenuBar(let index): return playlistMenuBar(height: index == 1 ? 72 : 54)

        case .mainShadeBackground(let active): return mainShadeBackground(active: active)
        case .mainUnshadeButton(let pressed), .eqUnshadeButton(let pressed), .playlistUnshadeButton(let pressed):
            return unshadeButton(pressed: pressed)
        case .mainShadePosition:
            let c = Canvas(Shade.mainPosition.size)
            groove(c, 0, 1, c.width, 5)
            return c.image()
        case .mainShadeThumb, .eqShadeVolumeThumb, .eqShadeBalanceThumb:
            let c = Canvas(Shade.thumb)
            c.fill(0, 0, c.width, c.height, theme.icon)
            c.fill(0, c.height - 1, c.width, 1, theme.faceLight)
            return c.image()
        case .eqShadeButton(let pressed), .playlistShadeButton(let pressed):
            return titleButton(.shade, pressed: pressed)
        case .eqShadeCloseButton(let pressed):
            return titleButton(.close, pressed: pressed)
        case .eqShadeBackground(let active): return eqShadeBackground(active: active)
        case .playlistShadeLeft(let active):
            return playlistShade(width: 25, lcdFrom: 4, lcdTo: 25, active: active, leftEdge: true)
        case .playlistShadeTile: return playlistShade(width: 25, lcdFrom: 0, lcdTo: 25)
        case .playlistShadeRight(let active):
            return playlistShade(width: 50, lcdFrom: 0, lcdTo: 23, active: active, rightEdge: true)
        }
    }

    // MARK: - Styles

    private func panel(_ c: Canvas, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        c.fill(x, y, w, h, theme.face)
    }

    private func titlePanel(_ c: Canvas, _ x: Int, _ y: Int, _ w: Int, _ h: Int, active: Bool) {
        c.fill(x, y, w, h, active ? theme.titleBar : theme.titleBarInactive)
    }

    private func titleLabel(_ c: Canvas, _ text: String, _ x: Int, _ y: Int, active: Bool) {
        c.text(text, x, y, active ? theme.titleText : theme.titleTextInactive)
    }

    /// A square button with a 1-pixel bevel; pressed buttons look pushed in.
    private func buttonFace(_ c: Canvas, _ x: Int, _ y: Int, _ w: Int, _ h: Int, pressed: Bool) {
        c.fill(x, y, w, h, pressed ? theme.facePressed : theme.faceButton)
        if pressed {
            c.bevel(x, y, w, h, light: theme.faceDark, dark: theme.faceLight)
        } else {
            c.bevel(x, y, w, h, light: theme.faceLight, dark: theme.faceDark)
        }
    }

    // MARK: - Shade mode

    private func shadeStrip(_ c: Canvas, active: Bool) {
        titlePanel(c, 0, 0, c.width, c.height, active: active)
        c.bevel(0, 0, c.width, c.height, light: theme.faceLight, dark: theme.faceDark)
    }

    private func mainShadeBackground(active: Bool) -> Bitmap {
        let c = Canvas(275, 14)
        shadeStrip(c, active: active)
        ridges(c, 18, 74, rows: [4, 7, 10], active: active)
        let vis = Shade.mainVisualizer
        inset(c, vis.minX, vis.minY, vis.width, vis.height)
        inset(c, 126, 3, 32, 8)
        c.glyph(":", 143, Shade.mainTimeY, theme.lcdOn)

        // Mini transport icons, matching the click areas.
        let ink = theme.icon
        let y = 3
        c.fill(170, y + 1, 1, 6, ink)
        for i in 0..<3 { c.fill(171 + i, y + 3 - i, 1, 1 + 2 * i, ink) }
        for i in 0..<4 { c.fill(179 + i, y + i, 1, 8 - 2 * i, ink) }
        c.fill(188, y + 1, 2, 6, ink); c.fill(191, y + 1, 2, 6, ink)
        c.fill(197, y + 1, 6, 6, ink)
        for i in 0..<3 { c.fill(206 + i, y + 1 + i, 1, 5 - 2 * i, ink) }
        c.fill(209, y + 1, 1, 6, ink)
        for i in 0..<4 { c.fill(220 - i, y + 1 + i, 1 + 2 * i, 1, ink) }
        c.fill(217, y + 6, 7, 1, ink)
        return c.image()
    }

    private func unshadeButton(pressed: Bool) -> Bitmap {
        let c = Canvas(9, 9)
        raised(c, pressed: pressed)
        let o = pressed ? 1 : 0
        c.fill(2 + o, 2 + o, 5, 1, theme.icon)
        c.fill(2 + o, 2 + o, 1, 5, theme.icon)
        c.fill(6 + o, 2 + o, 1, 5, theme.icon)
        c.fill(2 + o, 6 + o, 5, 1, theme.icon)
        return c.image()
    }

    private func eqShadeBackground(active: Bool) -> Bitmap {
        let c = Canvas(275, 14)
        shadeStrip(c, active: active)
        titleLabel(c, "EQ", 6, 4, active: active)
        ridges(c, 18, 56, rows: [4, 7, 10], active: active)
        for rect in [Shade.eqVolume, Shade.eqBalance] {
            groove(c, rect.minX, rect.minY + 1, rect.width, 5)
        }
        ridges(c, 210, 250, rows: [4, 7, 10], active: active)
        return c.image()
    }

    private func playlistShade(width: Int, lcdFrom: Int, lcdTo: Int, active: Bool = true, leftEdge: Bool = false,
                               rightEdge: Bool = false) -> Bitmap {
        let c = Canvas(width, Shade.height)
        titlePanel(c, 0, 0, width, c.height, active: active)
        c.fill(0, 0, width, 1, theme.faceLight)
        c.fill(0, c.height - 1, width, 1, theme.faceDark)
        if leftEdge { c.fill(0, 0, 1, c.height, theme.faceLight) }
        if rightEdge { c.fill(width - 1, 0, 1, c.height, theme.faceDark) }
        c.fill(lcdFrom, 3, lcdTo - lcdFrom, 8, theme.lcd)
        return c.image()
    }

    // MARK: - Window

    private func background() -> Bitmap {
        let c = Canvas(MainLayout.size)
        panel(c, 0, 0, c.width, c.height)
        c.bevel(0, 0, c.width, c.height, light: theme.faceLight, dark: theme.faceDark)

        // Grip dots down the left edge (under the clutter bar).
        for y in stride(from: 24, to: 62, by: 4) {
            c.fill(13, y, 2, 2, theme.faceDark)
            c.fill(13, y, 1, 1, theme.faceLight)
        }

        // Time and visualizer display.
        inset(c, 22, 24, 80, 38)
        c.fill(72, 29, 2, 2, theme.lcdOn)
        c.fill(72, 34, 2, 2, theme.lcdOn)

        // Marquee and readouts.
        inset(c, 108, 25, 160, 10)
        inset(c, 109, 41, 19, 10)
        c.text("KBPS", 131, 43, theme.label)
        inset(c, 154, 41, 14, 10)
        c.text("KHZ", 171, 43, theme.label)

        // Groove above the transport row.
        c.fill(10, 85, 255, 1, theme.faceDark)
        c.fill(10, 86, 255, 1, theme.faceLight)
        return c.image()
    }

    /// A recessed LCD panel whose inside is exactly (x, y, w, h).
    private func inset(_ c: Canvas, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        c.fill(x - 1, y - 1, w + 2, h + 2, theme.faceLight)
        c.fill(x - 1, y - 1, w + 1, h + 1, theme.faceDark)
        c.fill(x, y, w, h, theme.lcd)
    }

    /// A 275x14 title bar: centered name between ridges that run from x 18 to `ridgesEnd`.
    private func titleBar(_ name: String, active: Bool, ridgesEnd: Int) -> Bitmap {
        let c = Canvas(275, 14)
        titlePanel(c, 0, 0, c.width, c.height, active: active)
        c.bevel(0, 0, c.width, c.height, light: theme.faceLight, dark: theme.faceDark)

        let textWidth = PixelFont.width(of: name) - 1
        let textX = (c.width - textWidth) / 2
        for (start, end) in [(18, textX - 6), (textX + textWidth + 6, ridgesEnd)] {
            ridges(c, start, end, rows: [4, 7, 10], active: active)
        }
        titleLabel(c, name, textX, 4, active: active)
        return c.image()
    }

    private func ridges(_ c: Canvas, _ start: Int, _ end: Int, rows: [Int], active: Bool) {
        for y in rows {
            c.fill(start, y, end - start, 1, active ? theme.accent : theme.faceLight)
            c.fill(start, y + 1, end - start, 1, active ? theme.accentDim : theme.faceDark)
        }
    }

    private func titleButton(_ button: TitleButton, pressed: Bool) -> Bitmap {
        let c = Canvas(button.rect.size)
        raised(c, pressed: pressed)
        let o = pressed ? 1 : 0
        let ink = theme.icon
        switch button {
        case .options:
            for i in 0..<3 { c.fill(2 + o + i, 3 + o + i, 5 - 2 * i, 1, ink) }
        case .minimize:
            c.fill(2 + o, 6 + o, 5, 1, ink)
        case .shade:
            c.fill(2 + o, 2 + o, 5, 1, ink)
            c.fill(2 + o, 4 + o, 5, 1, ink)
        case .close:
            for i in 0..<5 {
                c.fill(2 + o + i, 2 + o + i, 1, 1, ink)
                c.fill(6 + o - i, 2 + o + i, 1, 1, ink)
            }
        }
        return c.image()
    }

    // MARK: - Buttons

    private func raised(_ c: Canvas, pressed: Bool) {
        buttonFace(c, 0, 0, c.width, c.height, pressed: pressed)
    }

    private func transportButton(_ button: TransportButton, pressed: Bool) -> Bitmap {
        let c = Canvas(button.rect.size)
        raised(c, pressed: pressed)
        let o = pressed ? 1 : 0
        let ink = theme.icon
        switch button {
        case .previous:
            c.fill(7 + o, 5 + o, 1, 7, ink)
            triangleLeft(c, 8 + o, 5 + o, width: 4, ink)
            triangleLeft(c, 12 + o, 5 + o, width: 4, ink)
        case .play:
            triangleRight(c, 9 + o, 4 + o, width: 5, ink)
        case .pause:
            c.fill(8 + o, 5 + o, 2, 8, ink)
            c.fill(12 + o, 5 + o, 2, 8, ink)
        case .stop:
            c.fill(8 + o, 5 + o, 7, 7, ink)
        case .next:
            triangleRight(c, 6 + o, 5 + o, width: 4, ink)
            triangleRight(c, 10 + o, 5 + o, width: 4, ink)
            c.fill(14 + o, 5 + o, 1, 7, ink)
        case .eject:
            for row in 0..<5 { c.fill(10 - row + o, 4 + row + o, 1 + 2 * row, 1, ink) }
            c.fill(6 + o, 10 + o, 9, 2, ink)
        }
        return c.image()
    }

    /// A right-pointing triangle `width` wide and `2 * width - 1` tall.
    private func triangleRight(_ c: Canvas, _ x: Int, _ y: Int, width: Int, _ color: RGBA) {
        for i in 0..<width {
            c.fill(x + i, y + i, 1, 2 * (width - i) - 1, color)
        }
    }

    private func triangleLeft(_ c: Canvas, _ x: Int, _ y: Int, width: Int, _ color: RGBA) {
        for i in 0..<width {
            let inset = width - 1 - i
            c.fill(x + i, y + inset, 1, 2 * (width - inset) - 1, color)
        }
    }

    private func toggleButton(_ button: ToggleButton, on: Bool, pressed: Bool) -> Bitmap {
        let c = Canvas(button.rect.size)
        raised(c, pressed: pressed)
        let o = pressed ? 1 : 0
        let label: String
        switch button {
        case .shuffle: label = "SHUFFLE"
        case .repeatTrack: label = "REP"
        case .equalizer: label = "EQ"
        case .playlist: label = "PL"
        }
        let ledY = (c.height - 3) / 2
        c.fill(4 + o, ledY + o, 3, 3, on ? theme.accent : theme.accentDim)
        buttonLabel(c, label, 9 + o, (c.height - 5) / 2 + o, on: on)
        return c.image()
    }

    private func aboutButton(pressed: Bool) -> Bitmap {
        let c = Canvas(MainLayout.about.size)
        raised(c, pressed: pressed)
        let o = pressed ? 1 : 0
        // A small original "S" mark (sudamp), in place of Bitamp's "b".
        c.fill(4 + o, 2 + o, 5, 2, theme.accent)
        c.fill(3 + o, 3 + o, 2, 3, theme.accent)
        c.fill(4 + o, 6 + o, 5, 2, theme.accent)
        c.fill(8 + o, 7 + o, 2, 3, theme.accent)
        c.fill(4 + o, 10 + o, 5, 2, theme.accent)
        return c.image()
    }

    private func workIndicator(working: Bool) -> Bitmap {
        let c = Canvas(3, 9)
        c.fill(1, 1, 1, 7, working ? theme.accent : theme.lcdGhost)
        return c.image()
    }

    private func clutterBar(enabled: Bool) -> Bitmap {
        // The bar sits on the grip dots at 10,22; paint the same panel so the dots read through.
        let c = Canvas(MainLayout.clutterBar.size)
        c.draw(image(for: .mainBackground), -MainLayout.clutterBar.minX, -MainLayout.clutterBar.minY)
        if !enabled { c.fill(1, 1, c.width - 2, c.height - 2, theme.face) }
        return c.image()
    }

    /// A lit clutter button: the bar's panel with an accent dot.
    private func clutterButton(_ index: Int) -> Bitmap {
        let rect = MainLayout.clutter[index].1
        let c = Canvas(rect.size)
        c.draw(image(for: .mainBackground), -rect.minX, -rect.minY)
        c.fill(3, rect.height / 2 - 1, 2, 2, theme.accent)
        return c.image()
    }

    // MARK: - Sliders

    private func groove(_ c: Canvas, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        c.fill(x, y, w, h, theme.faceLight)
        c.fill(x, y, w - 1, h - 1, theme.faceDark)
        c.fill(x + 1, y + 1, w - 2, h - 2, theme.groove)
    }

    private func volumeBackground(_ level: Int) -> Bitmap {
        let c = Canvas(MainLayout.volume.size)
        let t = Double(level) / Double(SkinElement.sliderLevels - 1)
        groove(c, 1, 4, c.width - 2, 5)
        let fillWidth = Int((Double(c.width - 4) * t).rounded())
        c.fill(2, 5, fillWidth, 3, levelColor(t))
        return c.image()
    }

    private func balanceBackground(_ level: Int) -> Bitmap {
        let c = Canvas(MainLayout.balance.size)
        let t = Double(level) / Double(SkinElement.sliderLevels - 1)
        groove(c, 1, 4, c.width - 2, 5)
        c.fill(2, 5, c.width - 4, 3, mix(theme.groove, levelColor(t), 0.55))
        c.fill(c.width / 2 - 1, 5, 2, 3, theme.faceLight)
        return c.image()
    }

    private func levelColor(_ t: Double) -> RGBA {
        t < 0.5
            ? mix(theme.levelLow, theme.levelMid, t * 2)
            : mix(theme.levelMid, theme.levelHigh, (t - 0.5) * 2)
    }

    private func sliderThumb(pressed: Bool) -> Bitmap {
        let c = Canvas(MainLayout.sliderThumb)
        thumb(c, pressed: pressed, grips: [4, 7, 10])
        return c.image()
    }

    private func positionBackground() -> Bitmap {
        let c = Canvas(MainLayout.position.size)
        groove(c, 1, 3, c.width - 2, 4)
        return c.image()
    }

    private func positionThumb(pressed: Bool) -> Bitmap {
        let c = Canvas(MainLayout.positionThumb)
        thumb(c, pressed: pressed, grips: [10, 13, 16])
        return c.image()
    }

    private func thumb(_ c: Canvas, pressed: Bool, grips: [Int]) {
        c.fill(0, 0, c.width, c.height, pressed ? theme.thumbPressed : theme.faceButton)
        c.bevel(0, 0, c.width, c.height, light: theme.faceHighlight, dark: theme.faceDark)
        for x in grips {
            c.fill(x, 3, 1, c.height - 6, theme.faceDark)
            c.fill(x + 1, 3, 1, c.height - 6, theme.faceLight)
        }
    }

    // MARK: - Equalizer

    private func eqBackground() -> Bitmap {
        let c = Canvas(EQLayout.size)
        panel(c, 0, 0, c.width, c.height)
        c.bevel(0, 0, c.width, c.height, light: theme.faceLight, dark: theme.faceDark)
        let graph = EQLayout.graph
        inset(c, graph.minX, graph.minY, graph.width, graph.height)

        // A dotted 0 dB line behind the band sliders.
        let zeroY = EQLayout.preamp.minY + EQLayout.preamp.height / 2
        for x in stride(from: 76, to: 256, by: 2) { c.fill(x, zeroY, 1, 1, theme.faceLight) }

        func rightAligned(_ text: String, _ y: Int) {
            c.text(text, 75 - (PixelFont.width(of: text) - 1), y, theme.label)
        }
        rightAligned("+12", EQLayout.preamp.minY + 3)
        rightAligned("0", zeroY - 2)
        rightAligned("-12", EQLayout.preamp.maxY - 8)

        func centered(_ text: String, under rect: IntRect) {
            c.text(text, rect.minX + rect.width / 2 - (PixelFont.width(of: text) - 1) / 2, Self.eqLabelY, theme.label)
        }
        centered("PRE", under: EQLayout.preamp)
        for (index, label) in Self.bandLabels.enumerated() {
            centered(label, under: EQLayout.band(index))
        }
        return c.image()
    }

    private func eqButton(_ button: EQButton, on: Bool, pressed: Bool) -> Bitmap {
        let c = Canvas(button.rect.size)
        raised(c, pressed: pressed)
        let o = pressed ? 1 : 0
        let textY = (c.height - 5) / 2 + o
        switch button {
        case .on, .auto:
            c.fill(4 + o, (c.height - 3) / 2 + o, 3, 3, on ? theme.accent : theme.accentDim)
            buttonLabel(c, button == .on ? "ON" : "AUTO", 9 + o, textY, on: on)
        case .presets:
            let text = "PRESETS"
            buttonLabel(c, text, (c.width - PixelFont.width(of: text) + 1) / 2 + o, textY, on: false)
        }
        return c.image()
    }

    /// A vertical groove, lit from the middle (0 dB) to the slider's value.
    private func eqSliderBackground(_ level: Int) -> Bitmap {
        let c = Canvas(EQLayout.sliderSize)
        groove(c, 4, 0, 6, c.height)
        let last = SkinElement.sliderLevels - 1
        let t = Double(level) / Double(last)  // 0 is -12 dB, 1 is +12 dB.
        let middle = c.height / 2
        let travel = c.height - EQLayout.thumb.height
        let y = EQLayout.thumb.height / 2 + Int((Double(travel) * (1 - t)).rounded())
        let color = levelColor(abs(t - 0.5) * 2)
        c.fill(5, min(y, middle), 4, abs(y - middle) + 1, color)
        return c.image()
    }

    private func eqGraphBackground() -> Bitmap {
        let c = Canvas(EQLayout.graph.size)
        c.fill(0, 0, c.width, c.height, theme.lcd)
        for x in stride(from: 0, to: c.width, by: 2) { c.fill(x, c.height / 2, 1, 1, theme.lcdGhost) }
        return c.image()
    }

    // MARK: - Playlist

    private func playlistTop(width: Int, active: Bool, leftEdge: Bool = false, rightEdge: Bool = false) -> Bitmap {
        let c = Canvas(width, Playlist.top)
        titlePanel(c, 0, 0, width, c.height, active: active)
        c.fill(0, 0, width, 1, theme.faceLight)
        c.fill(0, c.height - 1, width, 1, theme.faceDark)
        if leftEdge { c.fill(0, 0, 1, c.height, theme.faceLight) }
        if rightEdge { c.fill(width - 1, 0, 1, c.height, theme.faceDark) }
        // The top-right corner leaves room for the shade and close buttons.
        ridges(c, leftEdge ? 6 : 0, rightEdge ? 3 : width, rows: [5, 8, 11], active: active)
        return c.image()
    }

    private func playlistTitle(_ name: String, width: Int, active: Bool) -> Bitmap {
        let c = Canvas(width, Playlist.top)
        titlePanel(c, 0, 0, c.width, c.height, active: active)
        c.fill(0, 0, c.width, 1, theme.faceLight)
        c.fill(0, c.height - 1, c.width, 1, theme.faceDark)
        let textWidth = PixelFont.width(of: name) - 1
        let textX = (c.width - textWidth) / 2
        ridges(c, 0, textX - 6, rows: [5, 8, 11], active: active)
        ridges(c, textX + textWidth + 6, c.width, rows: [5, 8, 11], active: active)
        titleLabel(c, name, textX, 6, active: active)
        return c.image()
    }

    private func playlistSide(width: Int, left: Bool) -> Bitmap {
        let c = Canvas(width, Playlist.heightStep)
        panel(c, 0, 0, width, c.height)
        c.fill(0, 0, 1, c.height, theme.faceLight)
        c.fill(width - 1, 0, 1, c.height, theme.faceDark)
        if !left {
            c.fill(5, 0, 8, c.height, theme.groove)
            c.fill(4, 0, 1, c.height, theme.faceDark)
            c.fill(13, 0, 1, c.height, theme.faceLight)
        }
        return c.image()
    }

    private func playlistBottom(width: Int) -> Bitmap {
        let c = Canvas(width, Playlist.bottom)
        panel(c, 0, 0, width, c.height)
        c.fill(0, 0, width, 1, theme.faceLight)
        c.fill(0, c.height - 1, width, 1, theme.faceDark)
        return c.image()
    }

    private func playlistBottomLeft() -> Bitmap {
        let c = Canvas(125, Playlist.bottom)
        panel(c, 0, 0, c.width, c.height)
        c.fill(0, 0, c.width, 1, theme.faceLight)
        c.fill(0, 0, 1, c.height, theme.faceLight)
        c.fill(0, c.height - 1, c.width, 1, theme.faceDark)
        for (x, label) in [(14, "ADD"), (43, "REM"), (72, "SEL"), (101, "MISC")] {
            playlistButton(c, x, 8, label)
        }
        return c.image()
    }

    private func playlistBottomRight() -> Bitmap {
        let c = Canvas(150, Playlist.bottom)
        panel(c, 0, 0, c.width, c.height)
        c.fill(0, 0, c.width, 1, theme.faceLight)
        c.fill(0, c.height - 1, c.width, 1, theme.faceDark)
        c.fill(c.width - 1, 0, 1, c.height, theme.faceDark)

        // Running time, mini transport and mini time.
        inset(c, 5, 8, 72, 9)
        let ink = theme.label
        let y = 22
        c.fill(6, y + 1, 1, 5, ink)  // Previous
        for i in 0..<3 { c.fill(7 + i, y + 3 - i, 1, 1 + 2 * i, ink) }
        for i in 0..<3 { c.fill(16 + i, y + 1 + i, 1, 5 - 2 * i, ink) }  // Play
        c.fill(24, y + 1, 2, 5, ink); c.fill(27, y + 1, 2, 5, ink)  // Pause
        c.fill(33, y + 1, 5, 5, ink)  // Stop
        for i in 0..<3 { c.fill(42 + i, y + 1 + i, 1, 5 - 2 * i, ink) }  // Next
        c.fill(45, y + 1, 1, 5, ink)
        for i in 0..<3 { c.fill(54 - i, y + 1 + i, 1 + 2 * i, 1, ink) }  // Eject
        c.fill(52, y + 5, 5, 1, ink)
        inset(c, 67, 22, 32, 8)
        // The mini time draws only its five characters; the colon belongs to the background (as in the shade).
        c.glyph(":", 83, 23, theme.lcdOn)

        playlistButton(c, 106, 8, "LIST")

        // Scroll arrows (Webamp's up/down hit areas at 135,2 and 135,8).
        for i in 0..<3 { c.fill(138 - i, 3 + i, 1 + 2 * i, 1, ink) }
        for i in 0..<3 { c.fill(136 + i, 9 + i, 5 - 2 * i, 1, ink) }

        // Resize grip.
        for i in 0..<4 {
            let x = 136 + i * 3
            c.fill(x, 34 - i * 3 - 1, 1, 1, theme.faceLight)
            c.fill(x + 1, 34 - i * 3, 1, 1, theme.faceDark)
            for j in 0..<i { c.fill(x - (j + 1) * 3, 34 - i * 3 + (j + 1) * 3 - 1, 1, 1, theme.faceLight) }
        }
        return c.image()
    }

    /// The panel left of the bottom-right corner on wide playlists, with an LCD for the mini visualiser.
    private func playlistVisualizerBackground() -> Bitmap {
        let c = Canvas(75, Playlist.bottom)
        panel(c, 0, 0, c.width, c.height)
        c.fill(0, 0, c.width, 1, theme.faceLight)
        c.fill(0, c.height - 1, c.width, 1, theme.faceDark)
        inset(c, 2, 12, 72, 16)
        return c.image()
    }

    private func playlistButton(_ c: Canvas, _ x: Int, _ y: Int, _ label: String) {
        buttonFace(c, x, y, 22, 18, pressed: false)
        let textX = x + (22 - PixelFont.compactWidth(of: label)) / 2
        c.compactText(label, textX, y + 7, buttonText(on: false))
    }

    /// One entry of a playlist pop-up menu: a 22x18 button with a compact label, lit when hovered.
    private func playlistMenuButton(_ label: String, selected: Bool) -> Bitmap {
        let c = Canvas(22, 18)
        buttonFace(c, 0, 0, 22, 18, pressed: selected)
        let textX = (22 - PixelFont.compactWidth(of: label)) / 2
        c.compactText(label, textX, 7, selected ? theme.accent : theme.label)
        return c.image()
    }

    private func playlistMenuBar(height: Int) -> Bitmap {
        let c = Canvas(3, height)
        c.fill(0, 0, 3, height, theme.faceDark)
        c.fill(1, 0, 1, height, theme.accentDim)
        return c.image()
    }

    private func buttonLabel(_ c: Canvas, _ text: String, _ x: Int, _ y: Int, on: Bool) {
        c.text(text, x, y, buttonText(on: on))
    }

    private func buttonText(on: Bool) -> RGBA {
        on ? theme.icon : theme.label
    }

    // MARK: - Display

    private func playStatus(_ status: PlayStatus) -> Bitmap {
        let c = Canvas(9, 9)
        switch status {
        case .playing:
            triangleRight(c, 2, 0, width: 5, theme.lcdOn)
        case .paused:
            c.fill(2, 1, 2, 7, theme.accent)
            c.fill(5, 1, 2, 7, theme.accent)
        case .stopped:
            c.fill(2, 2, 5, 5, theme.stopRed)
        }
        return c.image()
    }

    private func indicator(_ label: String, size: IntSize, x: Int, active: Bool) -> Bitmap {
        let c = Canvas(size)
        c.text(label, x, 3, active ? theme.lcdOn : theme.indicatorOff)
        return c.image()
    }

    /// Seven-segment digit: lit segments over faint "ghost" segments, like a real LCD. 10 is all ghost.
    private func digit(_ value: Int) -> Bitmap {
        let c = Canvas(9, 13)
        let segments: [(Character, IntRect)] = [
            ("a", IntRect(2, 0, 5, 2)), ("b", IntRect(7, 2, 2, 4)), ("c", IntRect(7, 7, 2, 4)), ("d", IntRect(2, 11, 5, 2)),
            ("e", IntRect(0, 7, 2, 4)), ("f", IntRect(0, 2, 2, 4)), ("g", IntRect(2, 5, 5, 2)),
        ]
        let lit = Self.digitSegments[value] ?? ""
        for (name, r) in segments {
            c.fill(r.x, r.y, r.width, r.height, lit.contains(name) ? theme.lcdOn : theme.lcdGhost)
        }
        return c.image()
    }

    private static let digitSegments: [Int: String] = [
        0: "abcdef", 1: "bc", 2: "abged", 3: "abgcd", 4: "fgbc",
        5: "afgcd", 6: "afgedc", 7: "abc", 8: "abcdefg", 9: "abcdfg",
    ]
}
