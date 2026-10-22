// SPDX-License-Identifier: GPL-3.0-or-later
// Parser tests against Webamp's fixtures (Fixtures/skins/webamp-fixtures, MIT © 2015 Jordan Eldredge): the
// expectations are Webamp's own, from utils.test.ts and __snapshots__/regionParser.test.js.snap @ 7734cd3.
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

private let fixtures = "Fixtures/skins/webamp-fixtures/"

private func fixture(_ name: String) throws -> String {
    SkinTextDecoding.decode(try Repo.data(fixtures + name))
}

private func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> RGBA { RGBA(r, g, b) }

@Suite struct IniParserTests {
    @Test func defaultPledit() throws {
        #expect(IniParser.parse(try fixture("PLEDIT.TXT")) == [
            "text": ["normal": "#00FF00", "current": "#FFFFFF", "normalbg": "#000000", "selectedbg": "#0000FF", "font": "Arial"],
        ])
    }

    @Test func topazPledit() throws {
        #expect(IniParser.parse(try fixture("PLEDIT_TOPAZ.TXT")) == [
            "text": ["normal": "#319593", "current": "#89D8D1", "normalbg": "#000000", "selectedbg": "#2B4242",
                     "font": "Arial", "mbbg": "#000000", "mbfg": "#89D8D1"],
        ])
    }

    @Test func spaceAroundEquals() {
        #expect(IniParser.parse("\n[foo]\nbar = baz\n") == ["foo": ["bar": "baz"]])
    }

    @Test func quotedPledit() throws {
        #expect(IniParser.parse(try fixture("PLEDIT_WITH_QUOTES.TXT")) == [
            "text": ["normal": "#00FF00", "current": "#FFFFFF", "normalbg": "#000000", "selectedbg": "#0000FF",
                     "font": "Ricky's cool font!"],
        ])
    }

    @Test func equalsMarksComments() throws {
        #expect(IniParser.parse(try fixture("PLEDIT_WITH_EQUALS.TXT")) == [
            "text": ["normal": "#000000", "mbfg": "#000000", "current": "#606060", "normalbg": "#7897B7",
                     "selectedbg": "#6685A5", "mbbg": "#7897B7", "font": "Ariel"],
        ])
    }

    @Test func quotesAroundValues() {
        #expect(IniParser.parse("\n[foo]\nbar = \"baz\"\n  ") == ["foo": ["bar": "baz"]])
    }

    @Test func linesBeforeAnySectionAreIgnored() {
        #expect(IniParser.parse("a=1\r\n[S]\r\nb=2\r\n;c=3") == ["s": ["b": "2"]])
    }
}

@Suite struct PleditParserTests {
    let defaults = PlaylistStyle(normal: rgb(1, 1, 1), current: rgb(2, 2, 2), normalBackground: rgb(3, 3, 3),
                                 selectedBackground: rgb(4, 4, 4), font: "Default")

    @Test(arguments: [
        ("PLEDIT.TXT", PlaylistStyle(normal: RGBA(hex: 0x00FF00), current: RGBA(hex: 0xFFFFFF),
                                     normalBackground: RGBA(hex: 0x000000), selectedBackground: RGBA(hex: 0x0000FF), font: "Arial")),
        ("PLEDIT_TOPAZ.TXT", PlaylistStyle(normal: RGBA(hex: 0x319593), current: RGBA(hex: 0x89D8D1),
                                           normalBackground: RGBA(hex: 0x000000), selectedBackground: RGBA(hex: 0x2B4242), font: "Arial")),
        ("PLEDIT_WITH_QUOTES.TXT", PlaylistStyle(normal: RGBA(hex: 0x00FF00), current: RGBA(hex: 0xFFFFFF),
                                                 normalBackground: RGBA(hex: 0x000000), selectedBackground: RGBA(hex: 0x0000FF),
                                                 font: "Ricky's cool font!")),
        ("PLEDIT_WITH_EQUALS.TXT", PlaylistStyle(normal: RGBA(hex: 0x000000), current: RGBA(hex: 0x606060),
                                                 normalBackground: RGBA(hex: 0x7897B7), selectedBackground: RGBA(hex: 0x6685A5), font: "Ariel")),
    ])
    func webampFixtures(name: String, expected: PlaylistStyle) throws {
        #expect(PleditParser.parse(try fixture(name), defaults: defaults) == expected)
    }

    @Test func missingSectionAndBadColoursKeepDefaults() {
        #expect(PleditParser.parse("[other]\nnormal=#123456", defaults: defaults) == defaults)
        let style = PleditParser.parse("[Text]\nNormal=00ff00ff\nCurrent=#zzzzzz\nNormalBG=#abc", defaults: defaults)
        #expect(style.normal == RGBA(hex: 0x00FF00))  // "#" added, cut to 7 characters
        #expect(style.current == defaults.current)
        #expect(style.normalBackground == RGBA(hex: 0xAABBCC))  // CSS shorthand, as a browser reads it
        #expect(style.font == "Default")
    }
}

@Suite struct ViscolorParserTests {
    /// Magenta defaults make any line the parser failed to read stand out.
    let defaults = [RGBA](repeating: rgb(255, 0, 255), count: 24)

    @Test func defaultFile() throws {
        #expect(ViscolorParser.parse(try fixture("VISCOLOR.TXT"), defaults: defaults) == [
            rgb(0, 0, 0), rgb(24, 33, 41), rgb(239, 49, 16), rgb(206, 41, 16), rgb(214, 90, 0), rgb(214, 102, 0),
            rgb(214, 115, 0), rgb(198, 123, 8), rgb(222, 165, 24), rgb(214, 181, 33), rgb(189, 222, 41),
            rgb(148, 222, 33), rgb(41, 206, 16), rgb(50, 190, 16), rgb(57, 181, 16), rgb(49, 156, 8), rgb(41, 148, 0),
            rgb(24, 132, 8), rgb(255, 255, 255), rgb(214, 214, 222), rgb(181, 189, 189), rgb(160, 170, 175),
            rgb(148, 156, 165), rgb(150, 150, 150),
        ])
    }

    @Test func malformedFile() throws {
        // Webamp's snapshot has 26 entries; only the first 24 are colours.
        let blue = rgb(55, 55, 67)
        #expect(ViscolorParser.parse(try fixture("CENTRA_VISCOLOR.TXT"), defaults: defaults) ==
            [rgb(110, 150, 176), rgb(165, 165, 165)] + [RGBA](repeating: blue, count: 21) + [rgb(181, 189, 189)])
    }

    @Test func valuesWithoutCommas() throws {
        #expect(ViscolorParser.parse(try fixture("viscolor_valgaav.txt"), defaults: defaults) == [
            rgb(98, 111, 123), rgb(98, 111, 123), rgb(21, 21, 21), rgb(223, 176, 176), rgb(218, 168, 168),
            rgb(211, 158, 158), rgb(204, 147, 147), rgb(198, 137, 137), rgb(191, 127, 127), rgb(185, 117, 117),
            rgb(178, 107, 107), rgb(172, 97, 97), rgb(165, 86, 86), rgb(158, 76, 76), rgb(152, 66, 66),
            rgb(145, 56, 56), rgb(138, 46, 46), rgb(138, 46, 46), rgb(138, 46, 46), rgb(158, 76, 76),
            rgb(178, 107, 107), rgb(198, 137, 137), rgb(218, 168, 168), rgb(223, 176, 176),
        ])
    }

    @Test func trailingLines() throws {
        #expect(ViscolorParser.parse(try fixture("viscolor_green_dimension.txt"), defaults: defaults) == [
            rgb(0, 0, 0), rgb(0, 0, 0), rgb(0, 50, 0), rgb(0, 56, 0), rgb(0, 63, 0), rgb(0, 70, 0), rgb(0, 76, 0),
            rgb(0, 83, 0), rgb(0, 89, 0), rgb(0, 96, 0), rgb(0, 103, 0), rgb(0, 109, 0), rgb(0, 116, 0),
            rgb(0, 123, 0), rgb(0, 129, 0), rgb(0, 136, 0), rgb(0, 143, 0), rgb(0, 150, 0), rgb(0, 63, 0),
            rgb(0, 76, 0), rgb(0, 96, 0), rgb(0, 116, 0), rgb(0, 150, 0), rgb(0, 255, 0),
        ])
    }

    @Test func shortFilesKeepDefaultsAndChannelsClamp() {
        let colors = ViscolorParser.parse("1,2,3\r\nnot a colour\r\n300 400 5", defaults: defaults)
        #expect(colors[0] == rgb(1, 2, 3))
        #expect(colors[1] == rgb(255, 255, 5))
        #expect(colors[2...].allSatisfy { $0 == rgb(255, 0, 255) })
    }
}

@Suite struct RegionParserTests {
    /// Webamp's snapshot: test name -> section -> polygon strings ("x,y x,y …").
    static func snapshot() throws -> [String: [String: [String]]] {
        let text = try Repo.text(fixtures + "regionParser.test.js.snap")
        var result: [String: [String: [String]]] = [:]
        var test: String?, section: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("exports[`regionParser > "), let end = line.range(of: " 1`]") {
                test = String(line[line.index(line.startIndex, offsetBy: 24)..<end.lowerBound])
                result[test!] = [:]
            } else if let t = test, line.hasPrefix("  \""), line.hasSuffix("\": [") {
                section = String(line.dropFirst(3).dropLast(4))
                result[t]?[section!] = []
            } else if let t = test, let s = section, line.hasPrefix("    \"") {
                result[t]?[s]?.append(String(line.dropFirst(5).dropLast(2)))
            } else if line.hasPrefix("`;") {
                test = nil
                section = nil
            }
        }
        return result
    }

    static func render(_ parsed: [String: [[RegionPoint]]]) -> [String: [String]] {
        func number(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        return parsed.mapValues { polygons in
            polygons.map { $0.map { "\(number($0.x)),\(number($0.y))" }.joined(separator: " ") }
        }
    }

    @Test(arguments: [
        ("parses a complex file", "region1.txt"),
        ("parses a file with section headers but no info", "region_empty_sections.txt"),
        ("parses the EVAunit region.txt", "region_eva.txt"),
        ("parses the iTuned region.txt", "region_ituned.txt"),
        ("parses a region.txt where the points have leading commas", "region_leading_comma.txt"),
        ("parses Satellite M's region.txt", "region_satellite.txt"),
    ])
    func matchesWebampSnapshot(test: String, file: String) throws {
        let expected = try #require(try Self.snapshot()[test], "snapshot has no entry for \(test)")
        #expect(!expected.isEmpty)
        #expect(Self.render(RegionParser.parse(try fixture(file))) == expected)
    }

    @Test func defaultFileIsEmpty() throws {
        #expect(RegionParser.parse(try fixture("region.txt")).isEmpty)
    }

    @Test func snapshotCoversSixFixtures() throws {
        #expect(try Self.snapshot().count == 6)
    }

    @Test func partialPolygonsAndShortCounts() {
        let parsed = RegionParser.parse("[Normal]\nNumPoints=2,4,3\nPointList=9,9 9,9 0,0 10,0 10,10 0,10 1,1")
        // The count of 2 skips two points; 4 takes the square; 3 finds one point left and keeps it.
        #expect(Self.render(parsed) == ["normal": ["0,0 10,0 10,10 0,10", "1,1"]])
        #expect(RegionParser.parse("[Normal]\nNumPoints=x,4\nPointList=0,0 1,0 1,1 0,1").count == 1)
        #expect(RegionParser.parse("[Normal]\nNumPoints=4\nPointList=").isEmpty)
    }
}
