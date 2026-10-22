// SPDX-License-Identifier: GPL-3.0-or-later
// Integer geometry in skin pixels: origin top-left, y grows down, rects are half-open (maxX/maxY exclusive).

public struct IntPoint: Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: Int
    public var y: Int

    public init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    public init(x: Int, y: Int) {
        self.init(x, y)
    }

    public static let zero = IntPoint(0, 0)
    public var description: String { "(\(x),\(y))" }
}

public struct IntSize: Hashable, Sendable, Codable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }

    public init(width: Int, height: Int) {
        self.init(width, height)
    }

    public var description: String { "\(width)x\(height)" }
}

public struct IntRect: Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.init(x, y, width, height)
    }

    public init(origin: IntPoint, size: IntSize) {
        self.init(origin.x, origin.y, size.width, size.height)
    }

    public var origin: IntPoint { IntPoint(x, y) }
    public var size: IntSize { IntSize(width, height) }
    public var minX: Int { x }
    public var minY: Int { y }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var description: String { "\(x),\(y) \(width)x\(height)" }

    public func contains(_ p: IntPoint) -> Bool {
        p.x >= x && p.y >= y && p.x < maxX && p.y < maxY
    }

    public func contains(_ r: IntRect) -> Bool {
        r.x >= x && r.y >= y && r.maxX <= maxX && r.maxY <= maxY
    }

    public func intersects(_ r: IntRect) -> Bool {
        !intersection(r).isEmpty
    }

    public func intersection(_ r: IntRect) -> IntRect {
        let x0 = max(x, r.x), y0 = max(y, r.y)
        let x1 = min(maxX, r.maxX), y1 = min(maxY, r.maxY)
        return IntRect(x0, y0, max(0, x1 - x0), max(0, y1 - y0))
    }

    public func offsetBy(_ dx: Int, _ dy: Int) -> IntRect {
        IntRect(x + dx, y + dy, width, height)
    }

    /// A rect with the same origin, `width`/`height` replaced where given.
    public func with(width: Int? = nil, height: Int? = nil) -> IntRect {
        IntRect(x, y, width ?? self.width, height ?? self.height)
    }
}

/// Clamps to [lower, upper]; NaN becomes `lower`. State values feed Int conversions, which trap on NaN/inf.
func clamped(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    value.isNaN ? lower : min(max(value, lower), upper)
}
