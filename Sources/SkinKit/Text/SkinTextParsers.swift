// SPDX-License-Identifier: GPL-3.0-or-later
//
// Parsers for a skin's text files: an INI reader, viscolor.txt, pledit.txt and region.txt.
//
// Semantics are Webamp's (packages/webamp/js/utils.ts parseIni/parseViscolors, skinParserUtils.ts
// getPlaylistStyle, regionParser.ts @ 7734cd3) and are tested against Webamp's own fixtures and snapshot in
// Fixtures/skins/webamp-fixtures/. The Swift structure follows wishval/wamp's IniParser, ViscolorsParser and
// PlaylistStyleParser (@ eea516db), whose CRLF and quote handling it keeps, with Webamp's "ignore anything after
// a second =" rule added (wamp kept trailing "= comment" text). For region.txt, andrehickmann/macamp's
// parseRegions (@ 03da76a3) was evaluated; Webamp's behaviour (partial polygons kept, continuation lines
// ignored, as Winamp's single-line profile reads do) won, so no macamp code is used.
//
// Notices for the sources above:
//
// Webamp — The MIT License (MIT), Copyright (c) [2015] [Jordan Eldredge]
// wamp — MIT License, Copyright (c) 2026 Valerii Bakalenko
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

/// Decodes a skin text file: UTF-8 when valid (BOM stripped), else Windows-1252, which is what era skins used.
public enum SkinTextDecoding {
    public static func decode(_ data: Data) -> String {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return String(data: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }
}

/// Webamp's parseIni: `[section]` headers and `key = value` lines; keys and sections lower-cased; anything after
/// a second `=` dropped; one pair of surrounding quotes stripped; lines before the first section ignored.
public enum IniParser {
    private static let sectionRegex = try! NSRegularExpression(pattern: #"^\s*\[(.+?)\]\s*$"#)
    private static let propertyRegex = try! NSRegularExpression(pattern: #"^\s*([^;][^=]*)\s*=\s*(.*)\s*$"#)

    public static func parse(_ text: String) -> [String: [String: String]] {
        var data: [String: [String: String]] = [:]
        var section: String?
        // JS: text.split(/[\r\n]+/). Scalars, not Characters: Swift treats "\r\n" as one Character.
        let lines = text.unicodeScalars.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).map { String($0) }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let section, let m = propertyRegex.firstMatch(in: line, range: range),
               let k = Range(m.range(at: 1), in: line), let v = Range(m.range(at: 2), in: line) {
                let key = line[k].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                var value = String(line[v])
                if let eq = value.firstIndex(of: "=") { value = String(value[..<eq]) }  // ignore after a second "="
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                value = stripQuotes(value)
                data[section]?[key] = value
            } else if let m = sectionRegex.firstMatch(in: line, range: range), let s = Range(m.range(at: 1), in: line) {
                let name = line[s].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                section = name
                data[name] = [:]
            }
        }
        return data
    }

    /// JS `.replace(/(^")|("$)|(^')|('$)/g, "")`: drops one leading and one trailing quote of either kind.
    static func stripQuotes(_ value: String) -> String {
        var v = Substring(value)
        if v.first == "\"" || v.first == "'" { v = v.dropFirst() }
        if v.last == "\"" || v.last == "'" { v = v.dropLast() }
        return String(v)
    }
}

/// viscolor.txt: 24 colours (0 background, 1 grid dots, 2-17 spectrum top to bottom, 18-22 oscilloscope,
/// 23 peak dots). The n-th line matching `^\s*(\d+)\s*,?\s*(\d+)\s*,?\s*(\d+)` sets colour n; the rest keep
/// `defaults`. Lines past the 24th are ignored (Webamp grows its array but never reads them).
public enum ViscolorParser {
    private static let regex = try! NSRegularExpression(pattern: #"^\s*(\d+)\s*,?\s*(\d+)\s*,?\s*(\d+)"#)

    public static let count = 24

    public static func parse(_ text: String, defaults: [RGBA]) -> [RGBA] {
        precondition(defaults.count == count, "viscolor defaults need 24 colours")
        var colors = defaults
        var index = 0
        // JS: text.split("\n"); a trailing "\r" does not matter because the regex anchors only at the start.
        for line in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map({ String($0) }) {
            let range = NSRange(line.startIndex..., in: line)
            guard let m = regex.firstMatch(in: line, range: range) else { continue }
            let values = (1...3).map { i -> UInt8 in
                let r = Range(m.range(at: i), in: line)!
                // CSS clamps rgb() channels to 255, which is what Webamp ends up drawing.
                return UInt8(min(Int(line[r].prefix(4)) ?? 255, 255))
            }
            if index < count { colors[index] = RGBA(values[0], values[1], values[2]) }
            index += 1
        }
        return colors
    }
}

/// pledit.txt `[Text]`: playlist colours and font name.
public struct PlaylistStyle: Hashable, Sendable, Codable {
    public var normal: RGBA
    public var current: RGBA
    public var normalBackground: RGBA
    public var selectedBackground: RGBA
    public var font: String

    public init(normal: RGBA, current: RGBA, normalBackground: RGBA, selectedBackground: RGBA, font: String) {
        self.normal = normal
        self.current = current
        self.normalBackground = normalBackground
        self.selectedBackground = selectedBackground
        self.font = font
    }
}

public enum PleditParser {
    /// Webamp's getPlaylistStyle: no `[Text]` section means `defaults`; each colour missing or unparsable keeps
    /// its default. Colours get a leading "#" if missing and are cut to 7 characters ("#RRGGBB").
    public static func parse(_ text: String, defaults: PlaylistStyle) -> PlaylistStyle {
        guard let section = IniParser.parse(text)["text"] else { return defaults }
        var style = defaults
        func color(_ key: String) -> RGBA? { section[key].flatMap(parseColor) }
        style.normal = color("normal") ?? defaults.normal
        style.current = color("current") ?? defaults.current
        style.normalBackground = color("normalbg") ?? defaults.normalBackground
        style.selectedBackground = color("selectedbg") ?? defaults.selectedBackground
        if let font = section["font"], !font.isEmpty { style.font = font }
        return style
    }

    /// "#RRGGBB", "RRGGBB", "#RRGGBBxx…" (cut to 7) and CSS's 3-digit "#RGB", which a browser would accept.
    public static func parseColor(_ raw: String) -> RGBA? {
        var value = raw
        if !value.hasPrefix("#") { value = "#" + value }
        let hex = String(value.dropFirst().prefix(6))
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        switch hex.count {
        case 6:
            return UInt32(hex, radix: 16).map(RGBA.init(hex:))
        case 3:
            let doubled = hex.map { "\($0)\($0)" }.joined()
            return UInt32(doubled, radix: 16).map(RGBA.init(hex:))
        default:
            return nil
        }
    }
}

/// A point of a region polygon, in window pixels. Values may be fractional or negative in the wild.
public struct RegionPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// region.txt: polygons per section (`normal`, `windowshade`, `equalizer`, `equalizerws`).
public enum RegionParser {
    public static let windowSections = ["normal", "windowshade", "equalizer", "equalizerws"]

    /// Webamp's regionParser: `NumPoints` is a comma list of counts, `PointList` is x,y values separated by
    /// commas and/or spaces. Counts under 3 skip their points; a polygon with fewer points than declared is kept;
    /// one with no points left is dropped; a value with no partner is dropped (Webamp would emit "x,undefined",
    /// which its SVG then ignores). Sections without a usable polygon are omitted.
    public static func parse(_ text: String) -> [String: [[RegionPoint]]] {
        var result: [String: [[RegionPoint]]] = [:]
        for (section, values) in IniParser.parse(text) {
            guard let numPoints = values["numpoints"], !numPoints.isEmpty,
                  let pointList = values["pointlist"], !pointList.isEmpty
            else { continue }
            let counts = split(numPoints, separators: [","])
            let numbers = split(pointList, separators: [",", " "])
            var points: [RegionPoint?] = []
            var i = 0
            while i < numbers.count {
                let x = jsNumber(numbers[i]), y = i + 1 < numbers.count ? jsNumber(numbers[i + 1]) : nil
                points.append(x != nil && y != nil ? RegionPoint(x!, y!) : nil)
                i += 2
            }
            var index = 0
            var polygons: [[RegionPoint]] = []
            for countText in counts {
                // JS Number(): a non-numeric count is NaN, whose slice is empty, so it is skipped without
                // consuming points. Fractions truncate as JS slice() does; the index never goes below 0.
                guard let value = jsNumber(countText) else { continue }
                let count = Int(value)
                if count < 3 {
                    index = max(0, index + count)
                    continue
                }
                let slice = index < points.count ? Array(points[index..<min(points.count, index + count)]) : []
                guard !slice.isEmpty else { continue }  // more polygons declared than points given
                index += count
                let polygon = slice.compactMap { $0 }
                if !polygon.isEmpty { polygons.append(polygon) }
            }
            if !polygons.isEmpty { result[section] = polygons }
        }
        return result
    }

    /// JS `split(/\s*[sep]\s*/)` followed by `.filter(v => v !== "")`.
    private static func split(_ text: String, separators: Set<Character>) -> [String] {
        var parts: [String] = []
        var current = ""
        for c in text {
            if separators.contains(c) {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.filter { !$0.isEmpty }
    }

    /// JS Number() for the forms region files use: decimal integers or fractions with an optional sign. Values
    /// beyond ±1e9 are treated as invalid, so later integer conversions can never trap.
    private static func jsNumber(_ text: String) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-" || $0 == "+") }),
              let value = Double(text), value.isFinite, abs(value) <= 1e9
        else { return nil }
        return value
    }
}
