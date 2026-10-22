// SPDX-License-Identifier: GPL-3.0-or-later
// Rasterises region.txt polygons into a window alpha mask without anti-aliasing (DESIGN §8.2). Each polygon is
// filled with the even-odd rule, sampling pixel centres, so integer vertices give GDI-style coverage: right and
// bottom edges are exclusive (a 0,0 275,0 275,116 0,116 rectangle covers exactly 275x116 pixels). The window shape
// is the union of its polygons, matching Webamp's SVG clipPath of separate <polygon>s (Satellite M-style files
// list overlapping rectangles, which a single even-odd pass would cancel out). No prior art did this part.

public enum RegionRasterizer {
    /// One byte per pixel, row-major: 255 inside the region, 0 outside. Polygons with fewer than three points
    /// cover nothing.
    public static func mask(_ polygons: [[RegionPoint]], size: IntSize) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: size.width * size.height)
        for polygon in polygons where polygon.count >= 3 {
            fill(polygon, size: size, into: &mask)
        }
        return mask
    }

    private static func fill(_ polygon: [RegionPoint], size: IntSize, into mask: inout [UInt8]) {
        let ys = polygon.map(\.y).filter(\.isFinite)
        guard let minY = ys.min(), let maxY = ys.max() else { return }
        // Clamp before converting: region.txt values are untrusted and Int(Double) traps out of range.
        let firstRow = max(0, Int((clamp(minY, size.height) - 0.5).rounded(.up)))
        let lastRow = min(size.height - 1, Int((clamp(maxY, size.height) - 0.5).rounded(.up)) - 1)
        guard firstRow <= lastRow else { return }
        var crossings: [Double] = []
        for row in firstRow...lastRow {
            let yc = Double(row) + 0.5
            crossings.removeAll(keepingCapacity: true)
            for i in 0..<polygon.count {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                guard a.y.isFinite, b.y.isFinite, a.x.isFinite, b.x.isFinite, a.y != b.y else { continue }
                // Half-open in y so a vertex shared by two edges is counted once.
                let (lo, hi) = a.y < b.y ? (a, b) : (b, a)
                guard yc >= lo.y, yc < hi.y else { continue }
                crossings.append(lo.x + (yc - lo.y) * (hi.x - lo.x) / (hi.y - lo.y))
            }
            crossings.sort()
            var k = 0
            while k + 1 < crossings.count {
                // Pixels whose centre x + 0.5 lies in [left, right).
                let start = max(0, Int((clamp(crossings[k], size.width) - 0.5).rounded(.up)))
                let end = min(size.width, Int((clamp(crossings[k + 1], size.width) - 0.5).rounded(.up)))
                if start < end {
                    let base = row * size.width
                    for x in start..<end { mask[base + x] = 255 }
                }
                k += 2
            }
        }
    }

    /// Keeps a coordinate within a pixel of the window so integer conversion is always safe.
    private static func clamp(_ value: Double, _ limit: Int) -> Double {
        min(max(value, -1), Double(limit) + 1)
    }

    /// Whether the pixel at `point` is inside the region (for hit-testing shaped windows).
    public static func contains(_ mask: [UInt8], size: IntSize, _ point: IntPoint) -> Bool {
        guard point.x >= 0, point.y >= 0, point.x < size.width, point.y < size.height else { return false }
        return mask[point.y * size.width + point.x] != 0
    }
}
