// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S1: just enough region.txt reading to feed the rasteriser and the probe.

/// Reads one section's `NumPoints` / `PointList` from region.txt text. Numbers are split on anything
/// that isn't a digit or '-', and an incomplete trailing polygon is dropped.
///
/// This is deliberately minimal. M4 ports macamp's tolerant parser with Webamp's semantics
/// (continuation lines, partial polygons, all four sections) and tests it against Webamp's fixtures.
public enum RegionText {
    public static func polygons(in text: String, section: String = "Normal") -> [[RegionPoint]] {
        let wanted = section.lowercased()
        var current = ""
        var counts: [Int] = []
        var values: [Int] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = trimmed(rawLine)
            if line.hasPrefix(";") || line.isEmpty { continue }
            if line.hasPrefix("[") {
                current = String(line.dropFirst().prefix { $0 != "]" }).lowercased()
                continue
            }
            guard current == wanted, let eq = line.firstIndex(of: "=") else { continue }
            let key = trimmed(line[..<eq]).lowercased()
            let value = line[line.index(after: eq)...]
            if key == "numpoints" { counts = integers(in: value) }
            if key == "pointlist" { values = integers(in: value) }
        }
        var polygons: [[RegionPoint]] = []
        var cursor = 0
        for count in counts where count > 0 {
            guard cursor + 2 * count <= values.count else { break }
            polygons.append((0..<count).map { RegionPoint(values[cursor + 2 * $0], values[cursor + 2 * $0 + 1]) })
            cursor += 2 * count
        }
        return polygons
    }

    static func integers(in text: Substring) -> [Int] {
        text.split { !($0.isNumber || $0 == "-") }.compactMap { Int($0) }
    }

    static func trimmed(_ s: Substring) -> Substring {
        let isText: (Character) -> Bool = { $0 != " " && $0 != "\t" }
        guard let first = s.firstIndex(where: isText), let last = s.lastIndex(where: isText) else { return "" }
        return s[first...last]
    }
}
