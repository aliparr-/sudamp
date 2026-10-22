// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S1: the 1-bit coverage mask the region rasteriser produces.

/// A row-major 1-bit coverage mask in skin pixels. Row 0 is the top of the window.
public struct Mask: Equatable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int
    /// 1 = inside the region (drawn opaque), 0 = outside (alpha 0).
    public private(set) var bits: [UInt8]

    public init(width: Int, height: Int) {
        precondition(width >= 0 && height >= 0, "negative mask size")
        self.width = width
        self.height = height
        bits = [UInt8](repeating: 0, count: width * height)
    }

    /// Builds a mask from ASCII art (`#` inside, anything else outside). Rows must have equal length.
    public init(ascii rows: [String]) {
        let w = rows.first?.count ?? 0
        self.init(width: w, height: rows.count)
        for (y, row) in rows.enumerated() {
            precondition(row.count == w, "ragged ASCII mask row \(y)")
            for (x, c) in row.enumerated() where c == "#" { bits[y * w + x] = 1 }
        }
    }

    /// Out-of-range reads are `false`, so callers can probe around the edges.
    public subscript(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return bits[y * width + x] != 0
    }

    /// Number of covered pixels.
    public var count: Int { bits.reduce(0) { $0 + Int($1) } }

    public var ascii: [String] {
        (0..<height).map { y in String((0..<width).map { self[$0, y] ? "#" : "." }) }
    }

    public var description: String { ascii.joined(separator: "\n") }

    /// Sets the half-open span `[x0, x1)` on row `y`, clipped to the mask.
    mutating func fillSpan(y: Int, from x0: Int, to x1: Int) {
        guard y >= 0, y < height else { return }
        let lo = max(0, x0), hi = min(width, x1)
        guard lo < hi else { return }
        let row = y * width
        for x in lo..<hi { bits[row + x] = 1 }
    }

    public mutating func formUnion(_ other: Mask) {
        precondition(width == other.width && height == other.height, "mask size mismatch")
        for i in bits.indices where other.bits[i] != 0 { bits[i] = 1 }
    }

    public func intersection(_ other: Mask) -> Mask {
        precondition(width == other.width && height == other.height, "mask size mismatch")
        var result = Mask(width: width, height: height)
        for i in bits.indices where bits[i] != 0 && other.bits[i] != 0 { result.bits[i] = 1 }
        return result
    }
}
