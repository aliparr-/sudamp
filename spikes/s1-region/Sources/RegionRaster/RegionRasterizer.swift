// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S1: a non-anti-aliased, GDI-style polygon rasteriser for skin region.txt masks (DESIGN §8.2).

/// A region.txt vertex in skin pixels: origin at the window's top-left, y grows downwards.
public struct RegionPoint: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }
}

/// How crossings on one scanline become coverage.
public enum FillRule: Sendable {
    /// GDI `ALTERNATE`: inside if an odd number of edges lie at or left of the point. DESIGN's default.
    case evenOdd
    /// GDI `WINDING`: inside if the signed edge count is non-zero (depends on polygon orientation).
    case nonZero
}

/// How several region.txt polygons combine.
public enum PolygonCombine: Sendable {
    /// All polygons form one poly-polygon, as GDI's `CreatePolyPolygonRgn` would: where polygons
    /// overlap, the fill rule applies across them (under even-odd an overlap becomes a hole).
    case polyPolygon
    /// Each polygon is filled on its own and the results are OR-ed (Webamp's SVG clip-path union).
    case union
}

/// Rasterises polygons into a 1-bit mask with no anti-aliasing.
///
/// Coverage convention (the X11 `mi` edge-table scan converter that Wine's `CreatePolyPolygonRgn`
/// is built on): pixel `(x, y)` is covered if the lattice point `(x, y)`, the pixel's top-left corner,
/// is inside the polygon. A point on a left or top boundary counts as inside; a point on a right or
/// bottom boundary counts as outside. So `0,0 4,0 4,3 0,3` covers exactly columns 0…3 and rows 0…2,
/// and polygons that share an edge tile with no gap and no double coverage.
/// All arithmetic is exact integer arithmetic; vertices may lie outside the mask (they are clipped).
public enum RegionRasterizer {
    public static func rasterize(
        _ polygons: [[RegionPoint]],
        width: Int,
        height: Int,
        rule: FillRule = .evenOdd,
        combine: PolygonCombine = .polyPolygon
    ) -> Mask {
        switch combine {
        case .polyPolygon:
            return scan(edges(of: polygons), width: width, height: height, rule: rule)
        case .union:
            var mask = Mask(width: width, height: height)
            for polygon in polygons {
                mask.formUnion(scan(edges(of: [polygon]), width: width, height: height, rule: rule))
            }
            return mask
        }
    }

    /// A non-horizontal edge, stored top to bottom. It is active on scanlines `top.y ..< bottom.y`,
    /// which makes vertices count exactly once and bottom boundaries exclusive.
    struct Edge {
        let top: RegionPoint
        let bottom: RegionPoint
        /// +1 if the polygon runs downwards along this edge, -1 if upwards (only `nonZero` uses it).
        let winding: Int

        /// The first pixel column at or right of the exact crossing on scanline `y`: ⌈x⌉.
        func crossing(atScanline y: Int) -> Int {
            let dy = bottom.y - top.y
            return ceilDiv(top.x * dy + (y - top.y) * (bottom.x - top.x), dy)
        }
    }

    static func edges(of polygons: [[RegionPoint]]) -> [Edge] {
        var result: [Edge] = []
        for polygon in polygons where polygon.count >= 2 {
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                if a.y == b.y { continue }  // horizontal edges never cross a scanline
                result.append(a.y < b.y ? Edge(top: a, bottom: b, winding: 1) : Edge(top: b, bottom: a, winding: -1))
            }
        }
        return result
    }

    static func scan(_ edges: [Edge], width: Int, height: Int, rule: FillRule) -> Mask {
        var mask = Mask(width: width, height: height)
        guard width > 0, height > 0,
              let firstRow = edges.map(\.top.y).min(), let endRow = edges.map(\.bottom.y).max() else { return mask }
        let rows = max(0, firstRow)..<max(max(0, firstRow), min(height, endRow))
        var crossings: [(x: Int, winding: Int)] = []
        for y in rows {
            crossings.removeAll(keepingCapacity: true)
            for edge in edges where edge.top.y <= y && y < edge.bottom.y {
                crossings.append((edge.crossing(atScanline: y), edge.winding))
            }
            crossings.sort { $0.x < $1.x }
            switch rule {
            case .evenOdd:
                // Closed polygons always give an even number of crossings per scanline.
                var i = 0
                while i + 1 < crossings.count {
                    mask.fillSpan(y: y, from: crossings[i].x, to: crossings[i + 1].x)
                    i += 2
                }
            case .nonZero:
                var winding = 0, spanStart = 0
                for crossing in crossings {
                    let before = winding
                    winding += crossing.winding
                    if before == 0, winding != 0 {
                        spanStart = crossing.x
                    } else if before != 0, winding == 0 {
                        mask.fillSpan(y: y, from: spanStart, to: crossing.x)
                    }
                }
            }
        }
        return mask
    }
}

/// ⌈a / b⌉ for b > 0. Swift's `/` truncates toward zero, so negative numerators need care.
func ceilDiv(_ a: Int, _ b: Int) -> Int {
    precondition(b > 0)
    return a >= 0 ? (a + b - 1) / b : -((-a) / b)
}
