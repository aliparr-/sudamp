// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S1: pixel-exact tests for the region rasteriser. Every expected mask below was worked out by
// hand from the coverage rule (lattice point (x, y) inside; left/top boundaries in, right/bottom out).
import Testing
@testable import RegionRaster

private func pts(_ xy: Int...) -> [RegionPoint] {
    precondition(xy.count % 2 == 0)
    return stride(from: 0, to: xy.count, by: 2).map { RegionPoint(xy[$0], xy[$0 + 1]) }
}

private func raster(
    _ polygons: [[RegionPoint]], _ w: Int, _ h: Int,
    _ rule: FillRule = .evenOdd, _ combine: PolygonCombine = .polyPolygon
) -> [String] {
    RegionRasterizer.rasterize(polygons, width: w, height: h, rule: rule, combine: combine).ascii
}

@Suite("Edge exclusivity")
struct EdgeExclusivityTests {
    @Test("A rectangle covers its left/top edges and excludes its right/bottom edges")
    func rectangle() {
        // x = 1 is a left edge (in), x = 4 a right edge (out); y = 1 top (in), y = 3 bottom (out).
        #expect(raster([pts(1, 1, 4, 1, 4, 3, 1, 3)], 6, 5) == [
            "......",
            ".###..",
            ".###..",
            "......",
            "......",
        ])
    }

    @Test("Orientation doesn't matter for a simple polygon")
    func orientation() {
        let clockwise = raster([pts(1, 1, 4, 1, 4, 3, 1, 3)], 6, 5)
        let counterClockwise = raster([pts(1, 1, 1, 3, 4, 3, 4, 1)], 6, 5)
        #expect(clockwise == counterClockwise)
        #expect(raster([pts(1, 1, 1, 3, 4, 3, 4, 1)], 6, 5, .nonZero) == clockwise)
    }

    @Test("Diagonal right edge: lattice points on it are excluded")
    func diagonalRightEdge() {
        // (0,0) (4,0) (0,4): row y spans [0, 4 - y).
        #expect(raster([pts(0, 0, 4, 0, 0, 4)], 5, 5) == [
            "####.",
            "###..",
            "##...",
            "#....",
            ".....",
        ])
    }

    @Test("Diagonal left edge: lattice points on it are included")
    func diagonalLeftEdge() {
        // (0,0) (4,0) (4,4): row y spans [y, 4), so (1,1) (2,2) (3,3) are in.
        #expect(raster([pts(0, 0, 4, 0, 4, 4)], 5, 5) == [
            "####.",
            ".###.",
            "..##.",
            "...#.",
            ".....",
        ])
    }

    @Test("Shallow slopes: a non-integer crossing x starts or ends the span at ⌈x⌉")
    func nonIntegerCrossings() {
        // Right edge x = 5 - 5y/3: rows end at ⌈5⌉, ⌈3.33⌉ = 4, ⌈1.67⌉ = 2 (exclusive).
        #expect(raster([pts(0, 0, 5, 0, 0, 3)], 6, 4) == [
            "#####.",
            "####..",
            "##....",
            "......",
        ])
        // Left edge x = 5y/3: rows start at ⌈0⌉, ⌈1.67⌉ = 2, ⌈3.33⌉ = 4 (inclusive).
        #expect(raster([pts(0, 0, 5, 0, 5, 3)], 6, 4) == [
            "#####.",
            "..###.",
            "....#.",
            "......",
        ])
    }

    @Test("Polygons sharing an edge (straight or diagonal) tile with no seam and no overlap")
    func adjacentPolygonsTile() {
        let upper = [pts(0, 0, 4, 0, 4, 4)]  // right of the diagonal x = y
        let lower = [pts(0, 0, 4, 4, 0, 4)]  // left of it: row y spans [0, y)
        #expect(raster(lower, 5, 5) == [
            ".....",
            "#....",
            "##...",
            "###..",
            ".....",
        ])
        let a = RegionRasterizer.rasterize(upper, width: 5, height: 5)
        let b = RegionRasterizer.rasterize(lower, width: 5, height: 5)
        #expect(a.intersection(b).count == 0)
        var both = a
        both.formUnion(b)
        #expect(both == RegionRasterizer.rasterize([pts(0, 0, 4, 0, 4, 4, 0, 4)], width: 5, height: 5))
        #expect(both.count == 16)

        // Two rectangles meeting at x = 2: one poly-polygon has no seam and no double edge.
        #expect(raster([pts(0, 0, 2, 0, 2, 2, 0, 2), pts(2, 0, 4, 0, 4, 2, 2, 2)], 5, 3) == [
            "####.",
            "####.",
            ".....",
        ])
    }

    @Test("Degenerate polygons cover nothing")
    func degenerate() {
        let empty = Array(repeating: ".....", count: 5)
        #expect(raster([], 5, 5) == empty)
        #expect(raster([pts()], 5, 5) == empty)
        #expect(raster([pts(1, 1)], 5, 5) == empty)
        #expect(raster([pts(0, 2, 4, 2)], 5, 5) == empty)  // horizontal line
        #expect(raster([pts(2, 0, 2, 4)], 5, 5) == empty)  // vertical line: span [2, 2)
        #expect(raster([pts(0, 1, 2, 1, 4, 1)], 5, 5) == empty)  // collinear
        #expect(raster([pts(0, 0, 4, 0, 4, 4, 0, 4)], 0, 0) == [])
    }

    @Test("Vertices outside the window are clipped")
    func clipping() {
        #expect(raster([pts(-2, -2, 30, -2, 30, 30, -2, 30)], 4, 3) == ["####", "####", "####"])
        // A triangle poking out of the right edge: (2,0) (9,0) (2,7) spans [2, 9 - y), clipped to 6.
        #expect(raster([pts(2, 0, 9, 0, 2, 7)], 6, 5) == [
            "..####",
            "..####",
            "..####",
            "..####",
            "..###.",
        ])
    }
}

@Suite("Concave and self-intersecting polygons")
struct ConcaveTests {
    @Test("U shape (axis-aligned concave)")
    func uShape() {
        #expect(raster([pts(0, 0, 2, 0, 2, 3, 4, 3, 4, 0, 6, 0, 6, 5, 0, 5)], 7, 6) == [
            "##..##.",
            "##..##.",
            "##..##.",
            "######.",
            "######.",
            ".......",
        ])
    }

    @Test("V notch with diagonal edges")
    func vNotch() {
        // (0,0) (3,3) (6,0) (6,5) (0,5). Row 0: crossings 0,0,6,6 → nothing (the lobes have zero width).
        // Row 1: 0,1,5,6 → [0,1) [5,6). Row 2: 0,2,4,6. Rows 3–4: 0,6.
        #expect(raster([pts(0, 0, 3, 3, 6, 0, 6, 5, 0, 5)], 7, 6) == [
            ".......",
            "#....#.",
            "##..##.",
            "######.",
            "######.",
            ".......",
        ])
    }

    @Test("Self-intersecting bow tie: both lobes, same result under both rules")
    func bowTie() {
        let bowTie = [pts(0, 0, 4, 4, 4, 0, 0, 4)]
        let expected = [
            ".....",
            "#..#.",
            "####.",
            "#..#.",
            ".....",
        ]
        #expect(raster(bowTie, 5, 5, .evenOdd) == expected)
        #expect(raster(bowTie, 5, 5, .nonZero) == expected)
    }
}

@Suite("Multiple polygons")
struct MultiPolygonTests {
    static let outer = pts(0, 0, 6, 0, 6, 6, 0, 6)
    static let innerSameOrientation = pts(2, 2, 4, 2, 4, 4, 2, 4)
    static let innerOpposite = pts(2, 2, 2, 4, 4, 4, 4, 2)
    static let ring = [
        "######.",
        "######.",
        "##..##.",
        "##..##.",
        "######.",
        "######.",
        ".......",
    ]
    static let full = Array(repeating: "######.", count: 6) + ["......."]

    @Test("Even-odd poly-polygon: an overlap becomes a hole whatever the orientation")
    func evenOddHole() {
        #expect(raster([Self.outer, Self.innerSameOrientation], 7, 7) == Self.ring)
        #expect(raster([Self.outer, Self.innerOpposite], 7, 7) == Self.ring)
    }

    @Test("Non-zero poly-polygon: overlap is filled unless the inner polygon runs the other way")
    func nonZero() {
        #expect(raster([Self.outer, Self.innerSameOrientation], 7, 7, .nonZero) == Self.full)
        #expect(raster([Self.outer, Self.innerOpposite], 7, 7, .nonZero) == Self.ring)
    }

    @Test("Union (Webamp clip-path semantics): an overlap stays filled")
    func union() {
        #expect(raster([Self.outer, Self.innerSameOrientation], 7, 7, .evenOdd, .union) == Self.full)
        #expect(raster([Self.outer, Self.innerOpposite], 7, 7, .evenOdd, .union) == Self.full)
    }
}

@Suite("Winamp-style region.txt")
struct WinampRegionTests {
    /// A 20×8 main window: bevelled top corners, a notch in the bottom edge, an inverted-triangle
    /// island inside the notch, and a degenerate (collinear) polygon that must contribute nothing.
    static let regionText = """
        ; sudamp S1 fixture (hand-written, not from a real skin)
        [Normal]
        NumPoints = 10, 3, 3
        PointList = 1,0, 19,0, 20,1, 20,8, 13,8, 13,5, 7,5, 7,8, 0,8, 0,1, 8,6, 12,6, 10,8, 2,2, 4,2, 6,2
        [WindowShade]
        NumPoints=4
        PointList=0,0, 20,0, 20,3, 0,3
        """

    static let expectedNormal = [
        ".##################.",  // the 45° corner cuts start at x = 1 and stop before x = 19
        "####################",
        "####################",
        "####################",
        "####################",
        "#######......#######",  // notch: x = 7…12 (x = 13 is the notch's right wall, a left edge → in)
        "#######.####.#######",  // island row 6: [8, 12)
        "#######..##..#######",  // island row 7: [9, 11)
    ]

    @Test("Parses both sections")
    func parse() {
        let normal = RegionText.polygons(in: Self.regionText)
        #expect(normal.map(\.count) == [10, 3, 3])
        #expect(normal[1] == pts(8, 6, 12, 6, 10, 8))
        #expect(RegionText.polygons(in: Self.regionText, section: "windowshade") == [pts(0, 0, 20, 0, 20, 3, 0, 3)])
        #expect(RegionText.polygons(in: Self.regionText, section: "Equalizer").isEmpty)
    }

    @Test("Normal section rasterises pixel-exactly (both combine modes agree: no overlaps)")
    func normal() {
        let polygons = RegionText.polygons(in: Self.regionText)
        #expect(raster(polygons, 20, 8) == Self.expectedNormal)
        #expect(raster(polygons, 20, 8, .evenOdd, .union) == Self.expectedNormal)
        #expect(raster(polygons, 20, 8, .nonZero) == Self.expectedNormal)
    }

    @Test("Full-size 275×116 main window with single-pixel corner cuts")
    func fullSize() {
        // A common pattern in real skins: knock out the two top corner pixels.
        let text = """
            [Normal]
            NumPoints=8
            PointList=0,1, 1,1, 1,0, 274,0, 274,1, 275,1, 275,116, 0,116
            """
        let mask = RegionRasterizer.rasterize(RegionText.polygons(in: text), width: 275, height: 116)
        #expect(mask.count == 275 * 116 - 2)
        #expect(!mask[0, 0] && !mask[274, 0])
        #expect(mask[1, 0] && mask[273, 0] && mask[0, 1] && mask[274, 1] && mask[0, 115] && mask[274, 115])
    }

    @Test("Incomplete trailing polygon is dropped")
    func partial() {
        let text = "[Normal]\nNumPoints=4,4\nPointList=0,0 4,0 4,4 0,4 9,9 9,9\n"
        #expect(RegionText.polygons(in: text) == [pts(0, 0, 4, 0, 4, 4, 0, 4)])
    }
}

@Suite("Reference cross-check")
struct ReferenceTests {
    /// Per-pixel crossing test, written independently of the span filler: count the edges active on
    /// row `py` whose exact crossing is at or left of `px` (x_exact <= px, compared without division).
    static func referenceInside(_ polygon: [RegionPoint], _ px: Int, _ py: Int, _ rule: FillRule) -> Bool {
        var crossings = 0, winding = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            guard a.y != b.y else { continue }
            let (top, bottom, w) = a.y < b.y ? (a, b, 1) : (b, a, -1)
            guard top.y <= py, py < bottom.y else { continue }
            let dy = bottom.y - top.y
            if top.x * dy + (py - top.y) * (bottom.x - top.x) <= px * dy {
                crossings += 1
                winding += w
            }
        }
        return rule == .evenOdd ? crossings % 2 == 1 : winding != 0
    }

    /// SplitMix64, so the "random" polygons are the same on every run.
    struct SplitMix64 {
        var state: UInt64
        mutating func next(_ range: ClosedRange<Int>) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return range.lowerBound + Int(z % UInt64(range.count))
        }
    }

    @Test("Matches a brute-force per-pixel reference on 400 seeded random polygons", arguments: [FillRule.evenOdd, .nonZero])
    func randomPolygons(rule: FillRule) {
        var rng = SplitMix64(state: 0x5_1D_A3)
        let w = 20, h = 16
        var mismatches = 0
        for _ in 0..<400 {
            let polygon = (0..<rng.next(3...9)).map { _ in RegionPoint(rng.next(-4...24), rng.next(-4...20)) }
            let mask = RegionRasterizer.rasterize([polygon], width: w, height: h, rule: rule)
            for y in 0..<h {
                for x in 0..<w where mask[x, y] != Self.referenceInside(polygon, x, y, rule) {
                    mismatches += 1
                }
            }
        }
        #expect(mismatches == 0)
    }

    @Test("Union equals OR of single-polygon masks; poly-polygon even-odd equals XOR")
    func combineModes() {
        var rng = SplitMix64(state: 42)
        for _ in 0..<100 {
            let polygons = (0..<rng.next(2...3)).map { _ in
                (0..<rng.next(3...6)).map { _ in RegionPoint(rng.next(-2...18), rng.next(-2...14)) }
            }
            let singles = polygons.map { RegionRasterizer.rasterize([$0], width: 16, height: 12) }
            let union = RegionRasterizer.rasterize(polygons, width: 16, height: 12, combine: .union)
            let poly = RegionRasterizer.rasterize(polygons, width: 16, height: 12, combine: .polyPolygon)
            for y in 0..<12 {
                for x in 0..<16 {
                    let inside = singles.map { $0[x, y] }
                    #expect(union[x, y] == inside.contains(true))
                    #expect(poly[x, y] == (inside.filter { $0 }.count % 2 == 1))
                }
            }
        }
    }
}
