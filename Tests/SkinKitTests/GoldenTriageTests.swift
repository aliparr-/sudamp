// SPDX-License-Identifier: GPL-3.0-or-later
// Regressions for SkinKit bugs the museum golden metric found (docs/spikes/golden.md). The 16-bit BMP decoding fix
// has its own suite (BMP16Tests).
import Foundation
import Testing
@testable import SkinKit

@Suite struct GoldenTriageTests {
    /// A skin whose eqmain.bmp stops at y=164 (8 corpus skins): the graph background, its 19 line colours and the
    /// preamp line lie outside the sheet. Webamp's canvas then draws nothing there; SkinKit used to write the
    /// out-of-sheet (transparent) colours and punch see-through holes along the curve.
    @Test func shortEqmainLeavesNoTransparentPixels() throws {
        let colour = RGBA(0x40, 0x80, 0xC0)
        let data = ZipWriter.archive([ZipWriter.Entry(path: "eqmain.bmp", data: solidBMP(width: 275, height: 164, colour))])
        let skin = try #require(SkinLoader.load(data: data).skin)
        var state = MuseumScreenshot.state(.eq)
        state.eq.bands = [0, 100, 0, 100, 0, 100, 0, 100, 0, 100]   // a curve through every graph row
        let frame = WindowComposer.render(.eq, state: state, skin: skin).bitmap
        var transparent = 0
        for y in 0..<frame.height { for x in 0..<frame.width where frame[x, y].a != 255 { transparent += 1 } }
        #expect(transparent == 0)
        // The graph shows the window background from eqmain.bmp itself, untouched by the curve.
        for y in EQLayout.graph.minY..<EQLayout.graph.maxY {
            for x in EQLayout.graph.minX..<EQLayout.graph.maxX { #expect(frame[x, y] == colour, "(\(x),\(y))") }
        }
    }

    @Test func fullEqmainStillDrawsTheCurve() throws {
        let skin = try #require(SkinLoader.load(url: Repo.url("Fixtures/skins/AndAmp-Dark.wsz")).skin)
        let colors = skin.eqGraphColors
        #expect(colors.count == EQGraph.height && colors.allSatisfy { $0.a == 255 })
    }

    /// text.bmp narrower than the space glyph (x 150..154): its colours come from the fallback skin instead of a
    /// transparent sample, so the system-font marquee field stays opaque.
    @Test func narrowTextSheetTakesTheFallbackColours() throws {
        let data = ZipWriter.archive([ZipWriter.Entry(path: "text.bmp", data: solidBMP(width: 100, height: 18, RGBA(9, 9, 9)))])
        let skin = try #require(SkinLoader.load(data: data).skin)
        #expect(skin.textColors.background.a == 255)
        #expect(skin.textColors.background == SudampDark.skin.textColors.background)
        var state = WindowState()
        state.title = "東京"   // needs the system font
        state.playback = .playing
        let result = WindowComposer.render(.main, state: state, skin: skin)
        #expect(result.metadata.marquee?.fallback == "system")
        #expect(result.bitmap[MainLayout.marqueeText.x + 3, MainLayout.marqueeText.y + 2].a == 255)
    }

    @Test func fullTextSheetKeepsItsOwnColours() throws {
        let skin = try #require(SkinLoader.load(url: Repo.url("Fixtures/skins/AndAmp-Dark.wsz")).skin)
        let text = try #require(skin.sheets["text"])
        let own = try #require(Skin.textColorsOf(text))
        #expect(skin.textColors.background == own.background && skin.textColors.foreground == own.foreground)
    }
}
