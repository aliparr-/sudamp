// SPDX-License-Identifier: GPL-3.0-or-later
// Decodes skin bitmaps with ImageIO and normalises them to opaque sRGB RGBA8 (DESIGN §8.2). ImageIO on macOS 27
// decoded 2,029 real skin BMPs (1/4/8/16/24/32-bit, RLE4/RLE8) with no failures [measured], so there is no
// custom BMP decoder. Dimensions are checked from the header before any pixels are allocated.

import CoreGraphics
import Foundation
import ImageIO

public enum SheetDecodeError: Error, Equatable, Sendable, CustomStringConvertible {
    case undecodable
    case tooLarge(width: Int, height: Int)

    public var description: String {
        switch self {
        case .undecodable: return "not a decodable image"
        case .tooLarge(let w, let h): return "image too large (\(w)x\(h))"
        }
    }
}

public enum SheetDecoder {
    /// Largest sheet side accepted. Classic sheets are at most 344x433; generous room for oversized ones.
    public static let maxDimension = 2048

    /// Decodes `data` into an opaque sRGB bitmap. Transparent pixels (PNG, 32-bit BMP alpha) are composited over
    /// black, which is "alpha ignored" for the BMPs Winamp reads; Webamp likewise draws no colour key.
    public static func decode(_ data: Data) throws -> Bitmap {
        // 16-bit BMPs: ImageIO widens 5-bit channels by shifting (31 -> 248); browsers, hence Webamp and the museum
        // screenshots, scale to the full range. BMP16Decoder does that; anything it doesn't handle goes to ImageIO.
        if let header = BMP16Decoder.header(data) {
            guard header.width <= maxDimension, header.height <= maxDimension else {
                throw SheetDecodeError.tooLarge(width: header.width, height: header.height)
            }
            if let bitmap = BMP16Decoder.decode(data, header: header) { return bitmap }
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) > 0
        else { throw SheetDecodeError.undecodable }
        // Read the size from the header first: a tiny PNG or RLE file can claim an enormous canvas.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { throw SheetDecodeError.undecodable }
        guard width > 0, height > 0 else { throw SheetDecodeError.undecodable }
        guard width <= maxDimension, height <= maxDimension else {
            throw SheetDecodeError.tooLarge(width: width, height: height)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == width, image.height == height
        else { throw SheetDecodeError.undecodable }
        return try normalise(image)
    }

    /// Draws `image` into an sRGB RGBA8 context (premultiplied, over transparent black) and makes it opaque.
    static func normalise(_ image: CGImage) throws -> Bitmap {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw SheetDecodeError.undecodable }
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw SheetDecodeError.undecodable }
        // Premultiplied over black == straight colour composited on black; forcing alpha to 255 keeps that colour.
        var bitmap = Bitmap(width: width, height: height, pixels: pixels)
        bitmap.makeOpaque()
        return bitmap
    }
}
