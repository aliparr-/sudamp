// SPDX-License-Identifier: GPL-3.0-or-later
// A 1x RGBA8 pixel buffer (straight alpha, sRGB, top-left origin). Every sheet is normalised into one, and the
// composer, rasteriser and generator only ever copy integer pixels, so output is byte-identical on every machine.

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// An sRGB colour with straight (non-premultiplied) alpha.
public struct RGBA: Hashable, Sendable, Codable, CustomStringConvertible {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// `0xRRGGBB`, opaque.
    public init(hex: UInt32) {
        self.init(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }

    public static let clear = RGBA(0, 0, 0, 0)
    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(255, 255, 255)

    /// `#RRGGBB` (alpha dropped).
    public var hexString: String {
        let digits = Array("0123456789ABCDEF")
        return "#" + String([r >> 4, r & 15, g >> 4, g & 15, b >> 4, b & 15].map { digits[Int($0)] })
    }

    public var description: String { a == 255 ? hexString : "\(hexString)@\(a)" }

    /// Linear blend from `self` (t = 0) to `other` (t = 1), rounded half up, alpha from `self`.
    public func mixed(with other: RGBA, _ t: Double) -> RGBA {
        let t = min(max(t, 0), 1)
        func lerp(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded(.toNearestOrAwayFromZero))
        }
        return RGBA(lerp(r, other.r), lerp(g, other.g), lerp(b, other.b), a)
    }

    public func withAlpha(_ alpha: UInt8) -> RGBA { RGBA(r, g, b, alpha) }
}

public struct Bitmap: Hashable, Sendable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes, row-major, R G B A.
    public private(set) var pixels: [UInt8]

    public init(width: Int, height: Int, fill: RGBA = .clear) {
        precondition(width >= 0 && height >= 0, "negative bitmap size")
        self.width = width
        self.height = height
        if fill == .clear {
            pixels = [UInt8](repeating: 0, count: width * height * 4)
        } else {
            var row = [UInt8]()
            row.reserveCapacity(width * 4)
            for _ in 0..<width { row += [fill.r, fill.g, fill.b, fill.a] }
            pixels = Array([[UInt8]](repeating: row, count: height).joined())
        }
    }

    public init(_ size: IntSize, fill: RGBA = .clear) {
        self.init(width: size.width, height: size.height, fill: fill)
    }

    /// Wraps existing RGBA8 bytes; `pixels.count` must be `width * height * 4`.
    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "pixel count does not match size")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var size: IntSize { IntSize(width, height) }
    public var bounds: IntRect { IntRect(0, 0, width, height) }

    public subscript(x: Int, y: Int) -> RGBA {
        get {
            guard x >= 0, y >= 0, x < width, y < height else { return .clear }
            let i = (y * width + x) * 4
            return RGBA(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
        }
        set {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            let i = (y * width + x) * 4
            pixels[i] = newValue.r
            pixels[i + 1] = newValue.g
            pixels[i + 2] = newValue.b
            pixels[i + 3] = newValue.a
        }
    }

    /// Fills `rect` (clipped to the bitmap) with `color`, replacing what was there.
    public mutating func fill(_ rect: IntRect, _ color: RGBA) {
        let r = rect.intersection(bounds)
        guard !r.isEmpty else { return }
        let bytes = [color.r, color.g, color.b, color.a]
        pixels.withUnsafeMutableBufferPointer { p in
            for y in r.minY..<r.maxY {
                var i = (y * width + r.minX) * 4
                for _ in 0..<r.width {
                    p[i] = bytes[0]; p[i + 1] = bytes[1]; p[i + 2] = bytes[2]; p[i + 3] = bytes[3]
                    i += 4
                }
            }
        }
    }

    public mutating func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: RGBA) {
        fill(IntRect(x, y, w, h), color)
    }

    /// How `draw` combines source and destination pixels.
    public enum BlendMode: Sendable {
        /// Replace the destination with the source pixel, alpha included.
        case copy
        /// Source-over compositing with straight alpha; fully transparent source pixels leave the destination.
        case over
    }

    /// Draws `source[from]` with its top-left at `at`. Source pixels outside `source` are skipped, so a sprite
    /// that runs past the edge of its sheet shows whatever is underneath (Strider's "see-through" rule).
    public mutating func draw(_ source: Bitmap, from: IntRect? = nil, at: IntPoint, mode: BlendMode = .copy) {
        let src = (from ?? source.bounds).intersection(source.bounds)
        // Destination area, clipped to both bitmaps; offsets keep source and destination aligned.
        let shiftX = src.minX - (from ?? source.bounds).minX, shiftY = src.minY - (from ?? source.bounds).minY
        let dest = IntRect(at.x + shiftX, at.y + shiftY, src.width, src.height).intersection(bounds)
        guard !dest.isEmpty else { return }
        let sx0 = src.minX + (dest.minX - (at.x + shiftX)), sy0 = src.minY + (dest.minY - (at.y + shiftY))
        let sw = source.width, dw = width
        source.pixels.withUnsafeBufferPointer { s in
            pixels.withUnsafeMutableBufferPointer { d in
                for row in 0..<dest.height {
                    var si = ((sy0 + row) * sw + sx0) * 4
                    var di = ((dest.minY + row) * dw + dest.minX) * 4
                    for _ in 0..<dest.width {
                        switch mode {
                        case .copy:
                            d[di] = s[si]; d[di + 1] = s[si + 1]; d[di + 2] = s[si + 2]; d[di + 3] = s[si + 3]
                        case .over:
                            Self.blendOver(s, si, d, di)
                        }
                        si += 4
                        di += 4
                    }
                }
            }
        }
    }

    /// Straight-alpha source-over for one pixel, with integer rounding so results are reproducible.
    private static func blendOver(_ s: UnsafeBufferPointer<UInt8>, _ si: Int, _ d: UnsafeMutableBufferPointer<UInt8>, _ di: Int) {
        let sa = Int(s[si + 3])
        if sa == 0 { return }
        if sa == 255 {
            d[di] = s[si]; d[di + 1] = s[si + 1]; d[di + 2] = s[si + 2]; d[di + 3] = 255
            return
        }
        let da = Int(d[di + 3])
        // out_a = sa + da * (1 - sa); colours weighted by their alpha contribution.
        let outA255 = sa * 255 + da * (255 - sa)  // scaled by 255
        guard outA255 > 0 else { return }
        for k in 0..<3 {
            let num = Int(s[si + k]) * sa * 255 + Int(d[di + k]) * da * (255 - sa)
            d[di + k] = UInt8((num + outA255 / 2) / outA255)
        }
        d[di + 3] = UInt8((outA255 + 127) / 255)
    }

    /// A copy of `rect`; pixels outside the bitmap come back transparent.
    public func cropped(_ rect: IntRect) -> Bitmap {
        var out = Bitmap(width: max(0, rect.width), height: max(0, rect.height))
        out.draw(self, from: rect, at: .zero)
        return out
    }

    /// Sets every pixel's alpha from `mask` (one byte per pixel, same size); used by the region rasteriser.
    public mutating func applyAlphaMask(_ mask: [UInt8]) {
        precondition(mask.count == width * height, "mask size does not match bitmap")
        pixels.withUnsafeMutableBufferPointer { p in
            for i in 0..<(width * height) {
                p[i * 4 + 3] = mask[i]
            }
        }
    }

    /// Forces every pixel opaque, keeping its colour channels.
    public mutating func makeOpaque() {
        pixels.withUnsafeMutableBufferPointer { p in
            var i = 3
            while i < p.count {
                p[i] = 255
                i += 4
            }
        }
    }

    /// Lower-case hex SHA-256 of the raw RGBA8 bytes; render goldens compare this, not PNG bytes (DESIGN §9).
    public var sha256: String {
        SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()
    }

    /// Raw RGBA8 bytes, as written to `.rgba` files.
    public var rgbaData: Data { Data(pixels) }

    /// A CGImage view of the pixels (straight alpha, sRGB).
    public func cgImage() -> CGImage? {
        guard width > 0, height > 0, let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// PNG encoding via ImageIO. PNG bytes can differ between macOS versions; hash `pixels`, not this.
    public func pngData() -> Data? {
        guard let image = cgImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
