// SPDX-License-Identifier: GPL-3.0-or-later
// Sprite table equality with Webamp, and layout/hit-test checks adapted from Bitamp's LayoutTests, ShadeTests and
// EqualizerTests (MIT © 2026 Ryan Romanosky and Bitamp contributors) onto SkinKit's tables.
//
// Notices for the sources named above:
//
// Webamp — The MIT License (MIT), Copyright (c) [2015] [Jordan Eldredge]
// Bitamp — MIT License, Copyright (c) 2026 Ryan Romanosky and Bitamp contributors
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

@Suite struct SpriteTableTests {
    /// Overrides listed in docs/spikes/sprite-overrides.md (the "| `NAME` |" table rows).
    static func documentedOverrides() throws -> Set<String> {
        let doc = try Repo.text("docs/spikes/sprite-overrides.md")
        var names = Set<String>()
        for line in doc.split(separator: "\n") where line.hasPrefix("| `") {
            if let end = line.dropFirst(3).firstIndex(of: "`") { names.insert(String(line[line.index(line.startIndex, offsetBy: 3)..<end])) }
        }
        return names
    }

    @Test func generatedTableEqualsWebampExtraction() throws {
        let json = try JSONSerialization.jsonObject(with: Repo.data("spikes/skins-tools/webamp_sprites.json")) as? [String: [String: Any]]
        let expected = try #require(json)
        #expect(expected.count == 212)
        #expect(Sprite.allCases.count == 212)
        let overrides = try Self.documentedOverrides()
        for (name, value) in expected where !overrides.contains(name) {
            let sprite = try #require(Sprite(rawValue: name), "missing sprite \(name)")
            let source = sprite.source
            #expect(source.sheet.rawValue == value["sheet"] as? String, "\(name) sheet")
            #expect(source.rect == IntRect(value["x"] as! Int, value["y"] as! Int, value["w"] as! Int, value["h"] as! Int), "\(name)")
        }
        #expect(Set(Sprite.allCases.map(\.rawValue)) == Set(expected.keys))
    }

    @Test func overridesDocumentMatchesTheGenerator() throws {
        // gen-sprites.py's OVERRIDES is empty; the document must not claim otherwise.
        #expect(try Self.documentedOverrides().isEmpty)
        let header = try Repo.text("Sources/SkinKit/Generated/SpriteTable.swift").prefix(600)
        #expect(header.contains("overrides: 0"))
        #expect(header.contains(SkinKitModule.webampCommit))
    }

    @Test func fontLookupMatchesWebamp() {
        #expect(FontLookup.cells.count == 69)
        #expect(FontLookup.cells["a"] == TextCell(0, 0))
        #expect(FontLookup.cells[" "] == TextCell(0, 30))
        #expect(FontLookup.cells["\u{2026}"] == TextCell(1, 10))
        for (open, close) in [("<", ">"), ("{", "}")] {
            #expect(FontLookup.cells[Character(open)] == FontLookup.cells["["])
            #expect(FontLookup.cells[Character(close)] == FontLookup.cells["]"])
        }
        for cell in FontLookup.cells.values {
            #expect(cell.column * 5 + 5 <= 155 && cell.row * 6 + 6 <= 18)
        }
    }
}

@Suite struct LayoutTests {
    static let windows: [WindowKind] = WindowKind.allCases

    @Test(arguments: windows)
    func controlsFitTheWindow(window: WindowKind) {
        let bounds = IntRect(origin: .zero, size: window.size)
        for (control, rect) in Layout.hitRects(window) {
            #expect(bounds.contains(rect), "\(control) \(rect) is outside \(window)")
        }
    }

    @Test(arguments: windows)
    func controlsDoNotOverlap(window: WindowKind) {
        // The title bar is the drag area behind its buttons, so it is allowed to contain them.
        let all = Layout.hitRects(window).filter { $0.0 != .titleBar }
        for (i, a) in all.enumerated() {
            for b in all[(i + 1)...] {
                #expect(!a.1.intersects(b.1), "\(a.0) overlaps \(b.0) in \(window)")
            }
        }
    }

    @Test(arguments: windows)
    func hitTestingFindsEveryControl(window: WindowKind) {
        for (control, rect) in Layout.hitRects(window) where control != .titleBar {
            #expect(Layout.hitTest(window, IntPoint(rect.x + rect.width / 2, rect.y + rect.height / 2)) == control)
            #expect(Layout.hitTest(window, rect.origin) == control, "\(control) top-left")
        }
    }

    @Test func mainWindowSpotChecks() {
        #expect(Layout.hitTest(.main, IntPoint(150, 7)) == .titleBar)  // dragging area
        #expect(Layout.hitTest(.main, IntPoint(264, 3)) == .close)
        #expect(Layout.hitTest(.main, IntPoint(273, 3)) == .titleBar)
        #expect(Layout.hitTest(.main, IntPoint(209, 95)) == .shuffle)  // shuffle's 46th column
        #expect(Layout.hitTest(.main, IntPoint(210, 95)) == .repeat)
        #expect(Layout.hitTest(.main, IntPoint(129, 95)) == .next)
        #expect(Layout.hitTest(.main, IntPoint(130, 95)) == nil)  // between next and eject
        #expect(Layout.hitTest(.main, IntPoint(190, 45)) == nil)  // empty panel
        #expect(Layout.hitTest(.main, IntPoint(275, 50)) == nil)  // outside
    }

    @Test func shadeTransportMatchesWebamp() {
        // Webamp css: previous at 169 (Bitamp has 168), eject 215 10 wide.
        #expect(Layout.rect(of: .previous, in: .shade) == IntRect(169, 2, 7, 10))
        #expect(Layout.rect(of: .eject, in: .shade) == IntRect(215, 2, 10, 10))
        #expect(Layout.hitTest(.shade, IntPoint(258, 7)) == .shade)
        #expect(Layout.hitTest(.shade, IntPoint(230, 7)) == .position)
        #expect(Layout.hitTest(.shade, IntPoint(90, 7)) == .visualizer)
        #expect(Layout.hitTest(.shade, IntPoint(140, 7)) == .time)
        #expect(Layout.hitTest(.shade, IntPoint(40, 7)) == .titleBar)
    }

    @Test func eqBandsAreEighteenApart() {
        for i in 0..<10 {
            #expect(EQLayout.band(i) == IntRect(78 + 18 * i, 38, 14, 63))
            #expect(Layout.hitTest(.eq, IntPoint(80 + 18 * i, 60)) == Control.bands[i])
        }
        #expect(Layout.hitTest(.eq, IntPoint(25, 60)) == .preamp)
    }

    @Test func playlistGeometryAddsUp() {
        let top = [PlaylistLayout.topLeft, PlaylistLayout.leftSpacer, PlaylistLayout.leftFill, PlaylistLayout.title,
                   PlaylistLayout.rightSpacer, PlaylistLayout.rightFill, PlaylistLayout.topRight]
        #expect(top.map(\.width).reduce(0, +) == 275)
        for (a, b) in zip(top, top.dropFirst()) { #expect(a.maxX == b.x) }
        #expect(PlaylistLayout.bottomLeft.width + PlaylistLayout.bottomRight.width == 275)
        #expect(PlaylistLayout.list.height == 6 * PlaylistLayout.tileHeight)
        #expect(PlaylistLayout.scrollTrack.height - PlaylistLayout.scrollThumb.height == PlaylistLayout.scrollTravel)
    }
}

@Suite struct SliderGeometryTests {
    // Webamp Band.test.js
    @Test func spriteNumbers() {
        #expect(EQSliderGeometry.frame(for: 0) == 0)
        #expect(EQSliderGeometry.frame(for: 50) == 14)
        #expect(EQSliderGeometry.frame(for: 100) == 27)
        #expect(EQSliderGeometry.frameOffset(0) == IntPoint(0, 0))
        #expect(EQSliderGeometry.frameOffset(14) == IntPoint(0, 65))
        #expect(EQSliderGeometry.frameOffset(27) == IntPoint(13 * 15, 65))
    }

    // 51 px of travel (Webamp), not Bitamp's 52.
    @Test func thumbTravelIs51() {
        #expect(EQSliderGeometry.thumbOffset(for: 100) == 0)
        #expect(EQSliderGeometry.thumbOffset(for: 0) == 51)
        #expect(EQSliderGeometry.thumbOffset(for: 50) == 25)
        #expect(EQLayout.sliderSize.height - 1 - EQLayout.thumb.height == EQSliderGeometry.travel)
    }

    // Bitamp sliderEnds / middleSnapsToFlat, in 0...100 values.
    @Test func endsAndSnap() {
        #expect(EQSliderGeometry.decibels(for: 100) == 12)
        #expect(EQSliderGeometry.decibels(for: 0) == -12)
        #expect(EQSliderGeometry.value(forThumbOffset: 0) == 100)
        #expect(EQSliderGeometry.value(forThumbOffset: 51) == 0)
        #expect(EQSliderGeometry.decibels(for: EQSliderGeometry.value(forDecibels: 0.4)) == 0)
        for offset in 0...51 {
            #expect(EQSliderGeometry.thumbOffset(for: EQSliderGeometry.value(forThumbOffset: offset)) == offset)
        }
    }

    @Test func mainSlidersStayInTheirTracks() {
        #expect(MainLayout.volume.x + MainLayout.volumeTravel + MainLayout.sliderThumb.width == MainLayout.volume.maxX - 3)
        #expect(MainLayout.balance.x + MainLayout.balanceTravel + MainLayout.sliderThumb.width == MainLayout.balance.maxX)
        #expect(MainLayout.position.x + MainLayout.positionTravel + MainLayout.positionThumb.width == MainLayout.position.maxX)
    }
}
