// SPDX-License-Identifier: GPL-3.0-or-later
// Marquee tests are Webamp's Marquee.test.js and marqueeUtils cases (MIT © 2015 Jordan Eldredge), ported.
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
import Testing
@testable import SkinKit

@Suite struct MarqueeModelTests {
    let long = "This is a long string. Longer than 30 characters!"

    @Test func modIsAlwaysPositive() {
        #expect(MarqueeModel.mod(-17, 5) != -17 % 5)
        #expect(MarqueeModel.mod(-17, 5) == 3)
    }

    @Test func stepOffset() {
        #expect(MarqueeModel.stepOffset(long, step: 0, pixels: 0) == 0)
        #expect(MarqueeModel.stepOffset(long, step: 1, pixels: 0) == 5)
        #expect(MarqueeModel.stepOffset(long, step: long.count + 7, pixels: 0) == 0)
        #expect(MarqueeModel.stepOffset(long, step: long.count + 7 + 1, pixels: 0) == 5)
        #expect(MarqueeModel.stepOffset("hello", step: 15, pixels: 0) == 0)
        #expect(MarqueeModel.stepOffset("hello", step: 1, pixels: 51) == 0)
        #expect(MarqueeModel.stepOffset(long, step: 0, pixels: -3) == (long.count + 7) * 5 - 3)
    }

    @Test func loopText() {
        #expect(MarqueeModel.loopText(long) == "\(long)  ***  \(long)")
        let short = "This is a short string."
        #expect(MarqueeModel.loopText(short).trimmingCharacters(in: .whitespaces) == short)
        #expect(MarqueeModel.loopText(short).count == 31)
    }

    @Test func stepsEvery220ms() {
        #expect(MarqueeModel.step(elapsed: 0) == 0)
        #expect(MarqueeModel.step(elapsed: 0.219) == 0)
        #expect(MarqueeModel.step(elapsed: 0.221) == 1)
        #expect(MarqueeModel.step(elapsed: 2.2) == 10)
        #expect(MarqueeModel.resumeDelay == 1.0)
    }
}

@Suite struct SkinFontTextTests {
    @Test func deburrsLikeLodash() {
        #expect(SkinFontText.deburr("déjà vu") == "deja vu")
        #expect(SkinFontText.deburr("Ærø Straße Łódź Œuvre ŉ") == "Aero Strasse Lodz Oeuvre 'n")
        #expect(SkinFontText.deburr("Ångström") == "Angstrom")
        #expect(SkinFontText.deburr("Șțefan") == "Stefan")  // beyond lodash's table, via NFD
    }

    @Test func mapsToFontLookupKeys() {
        let mapped = SkinFontText.map("Björk – “Jóga” {Live}")
        #expect(mapped.text == "bjork - \"joga\" {live}")
        #expect(!mapped.needsFallback)
        #expect(mapped.characters.allSatisfy { FontLookup.cells[$0] != nil })
    }

    @Test func unmappableAsciiDrawsBlankWithoutFallback() {
        let mapped = SkinFontText.map("a~b|c")
        #expect(!mapped.needsFallback)
        #expect(FontLookup.cells["~"] == nil)
    }

    @Test func nonLatinScriptsNeedAFallback() {
        #expect(SkinFontText.map("東京").needsFallback)
        #expect(SkinFontText.map("Привет").needsFallback)
        #expect(SkinFontText.map("party 🎉").needsFallback)
        #expect(!SkinFontText.map("Mötley Crüe").needsFallback)
    }

    @Test func transliteratesToLatin() {
        #expect(SkinFontText.transliterate("Привет") == "Privet")
        #expect(SkinFontText.transliterate("東京").lowercased().contains("dong"))
        #expect(!SkinFontText.map(SkinFontText.transliterate("Привет мир")).needsFallback)
    }

    @Test func rightAlignedReadouts() {
        #expect(SkinFontText.rightAligned("96", width: 3) == " 96")
        #expect(SkinFontText.rightAligned("1411", width: 3) == "411")
    }
}

@Suite struct RegionRasterizerTests {
    func count(_ mask: [UInt8]) -> Int { mask.filter { $0 != 0 }.count }

    @Test func rectanglesAreRightAndBottomExclusive() {
        let size = IntSize(275, 116)
        let full = RegionRasterizer.mask([[RegionPoint(0, 0), RegionPoint(275, 0), RegionPoint(275, 116), RegionPoint(0, 116)]], size: size)
        #expect(count(full) == 275 * 116)
        let square = RegionRasterizer.mask([[RegionPoint(1, 1), RegionPoint(3, 1), RegionPoint(3, 3), RegionPoint(1, 3)]], size: IntSize(5, 5))
        #expect(square == [
            0, 0, 0, 0, 0,
            0, 255, 255, 0, 0,
            0, 255, 255, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
        ])
    }

    @Test func evenOddLeavesAPentagramCentreEmpty() {
        // A five-pointed star drawn as one self-intersecting polygon.
        let c = 50.0, r = 45.0
        let star = (0..<5).map { i -> RegionPoint in
            let angle = -Double.pi / 2 + Double(i * 2) * 2 * Double.pi / 5
            return RegionPoint(c + r * cos(angle), c + r * sin(angle))
        }
        let mask = RegionRasterizer.mask([star], size: IntSize(100, 100))
        #expect(mask[50 * 100 + 50] == 0, "centre is covered twice, so even-odd leaves it out")
        #expect(mask[20 * 100 + 50] == 255, "a point inside the top arm")
    }

    @Test func polygonsUnionLikeWebampsClipPath() throws {
        // Satellite M: four overlapping rectangles; a single even-odd pass would cancel the overlaps.
        let regions = RegionParser.parse(SkinTextDecoding.decode(try Repo.data("Fixtures/skins/webamp-fixtures/region_satellite.txt")))
        let mask = RegionRasterizer.mask(try #require(regions["normal"]), size: IntSize(275, 116))
        #expect(mask[50 * 275 + 137] == 255)
        #expect(mask[0] == 0 && mask[274] == 0, "rounded top corners")
        #expect(mask[4 * 275 + 0] == 255)
    }

    @Test func degeneratePolygonsCoverNothing() {
        #expect(count(RegionRasterizer.mask([[RegionPoint(1, 1), RegionPoint(5, 5)]], size: IntSize(10, 10))) == 0)
        #expect(count(RegionRasterizer.mask([[RegionPoint(-50, -50), RegionPoint(500, -50), RegionPoint(500, 500), RegionPoint(-50, 500)]],
                                            size: IntSize(10, 10))) == 100)
        #expect(count(RegionRasterizer.mask([[RegionPoint(.nan, 1), RegionPoint(5, .infinity), RegionPoint(2, 2)]], size: IntSize(10, 10))) == 0)
    }
}

@Suite struct EQGraphTests {
    @Test func splinePassesThroughTheBands() {
        let xs = (0..<10).map { Double($0 * 12) }
        let ys: [Double] = [3, 6, 9, 12, 15, 9, 3, 0, 9, 18]
        let curve = EQGraph.spline(xs: xs, ys: ys)
        #expect(curve.count == 109)
        for (i, y) in ys.enumerated() { #expect(abs(curve[i * 12] - y) < 1e-9) }
    }

    @Test func flatBandsDrawAFlatLine() {
        #expect(EQGraph.curveRows(bands: [Double](repeating: 50, count: 10)) == [Int](repeating: 9, count: 109))
        #expect(EQGraph.row(for: 100) == 0)
        #expect(EQGraph.row(for: 0) == 18)
        let rows = EQGraph.curveRows(bands: [100, 0, 100, 0, 100, 0, 100, 0, 100, 0])
        #expect(rows.allSatisfy { (0...18).contains($0) })
    }
}

@Suite struct VisualizerTests {
    let colors = (0..<24).map { RGBA(UInt8($0 * 10), 0, 0) }

    @Test func spectrumRowsUseOneColourPerRow() {
        var bitmap = Bitmap(width: 76, height: 16)
        let bars = [16] + [Int](repeating: 0, count: 18)
        VisualizerRenderer.draw(VisualizerFrame(mode: .spectrum, bars: bars, peaks: [0, 5]), colors: colors, into: &bitmap,
                                at: IntRect(0, 0, 76, 16))
        for row in 0..<16 {
            #expect(bitmap[0, row] == colors[2 + row])
            #expect(bitmap[2, row] == colors[2 + row])
        }
        #expect(bitmap[3, 5] == colors[1] || bitmap[3, 5] == colors[0])  // gap column shows the grid
        #expect(bitmap[4, 11] == colors[23], "peak of 5 sits on row 11")
        #expect(bitmap[0, 1] == colors[2 + 1])
        #expect(bitmap[74, 1] == colors[1] && bitmap[74, 0] == colors[0], "grid: even columns, odd rows")
    }

    @Test func offDrawsNothing() {
        var bitmap = Bitmap(width: 76, height: 16, fill: .white)
        VisualizerRenderer.draw(VisualizerFrame(mode: .off), colors: colors, into: &bitmap, at: IntRect(0, 0, 76, 16))
        #expect(bitmap == Bitmap(width: 76, height: 16, fill: .white))
    }

    @Test func scopeConnectsSamples() {
        var bitmap = Bitmap(width: 76, height: 16)
        VisualizerRenderer.draw(VisualizerFrame(mode: .oscilloscope, scope: [0, 15]), colors: colors, into: &bitmap,
                                at: IntRect(0, 0, 76, 16))
        for row in 0..<16 { #expect(bitmap[1, row] == colors[18 + VisualizerRenderer.scopeColorIndex(row)]) }
    }
}

@Suite struct HostileValueTests {
    @Test func hugeRegionNumbersNeverTrap() {
        let text = "[Normal]\nNumPoints=99999999999999999999999,4\nPointList=0,0 99999999999999999999,0 1e400,116 0,116 -5,-5"
        let regions = RegionParser.parse(text)
        for polygons in regions.values {
            _ = RegionRasterizer.mask(polygons, size: IntSize(275, 116))
        }
        let wide = [RegionPoint(-1e9, -1e9), RegionPoint(1e9, -1e9), RegionPoint(1e9, 1e9), RegionPoint(-1e9, 1e9)]
        #expect(RegionRasterizer.mask([wide], size: IntSize(4, 4)).allSatisfy { $0 == 255 })
    }

    @Test func extremeStatesRender() {
        var state = WindowState()
        state.playback = .playing
        state.elapsed = .infinity
        state.duration = .nan
        state.marqueeStep = .max
        state.marqueeDrag = .min
        state.title = String(repeating: "x", count: 500)
        state.volume = .max
        state.balance = .min
        state.eq.bands = [.infinity, -.infinity, .nan]
        state.eq.preamp = .nan
        state.playlist.firstRow = .min
        state.playlist.scroll = .nan
        for window in WindowKind.allCases {
            #expect(WindowComposer.render(window, state: state, skin: SudampDark.skin).bitmap.width == 275)
        }
    }
}
