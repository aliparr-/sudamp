// SPDX-License-Identifier: GPL-3.0-or-later
// 16-bit BMP sheets (BI_RGB 5-5-5 and BI_BITFIELDS, e.g. 5-6-5), decoded here instead of by ImageIO.
//
// ImageIO widens a 5-bit channel with a plain shift (v << 3), so full intensity 31 becomes 248: whites turn grey
// and every colour darkens by up to 7 levels. Browsers, and so Webamp and every Skin Museum screenshot, scale to the
// full range instead: round(v * 255 / (2^bits - 1)), 31 -> 255, 3 -> 25 (Skia's SkMasks lookup tables, matched
// against museum screenshots in docs/spikes/golden.md). About 5% of the golden corpus ships 16-bit sheets; before
// this decoder their windows differed from the screenshots in up to 92% of pixels.
//
// Only the common, well-formed cases are handled: a BITMAPINFOHEADER or later (40+ bytes), 16 bits per pixel,
// BI_RGB or BI_BITFIELDS (masks after a 40-byte header or inside a V2+ header), bottom-up or top-down rows, and pixel
// data that is all there. Anything else returns nil and ImageIO decodes it as before. Alpha is ignored, as for every
// sheet (SheetDecoder makes sheets opaque).

import Foundation

enum BMP16Decoder {
    struct Header: Equatable {
        var width: Int
        var height: Int
        var topDown: Bool
        var pixelOffset: Int
        var redMask: UInt32
        var greenMask: UInt32
        var blueMask: UInt32

        /// Bytes per row, padded to 4.
        var stride: Int { (width * 2 + 3) / 4 * 4 }
    }

    static let biRGB: UInt32 = 0
    static let biBitfields: UInt32 = 3
    static let biAlphaBitfields: UInt32 = 6

    /// Parses `data` as a 16-bit BMP; nil when it is anything else (the caller then uses ImageIO).
    static func header(_ data: Data) -> Header? {
        let bytes = [UInt8](data.prefix(14 + 124))
        func u16(_ o: Int) -> UInt32? { o + 2 <= bytes.count ? UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> UInt32? {
            guard o + 4 <= bytes.count else { return nil }
            return UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        guard bytes.count >= 54, bytes[0] == 0x42, bytes[1] == 0x4D,  // "BM"
              let offset = u32(10), let headerSize = u32(14), headerSize >= 40,
              let rawWidth = u32(18), let rawHeight = u32(22), u16(26) == 1, u16(28) == 16,
              let compression = u32(30)
        else { return nil }
        let width = Int(Int32(bitPattern: rawWidth)), signedHeight = Int(Int32(bitPattern: rawHeight))
        guard width > 0, signedHeight != 0, signedHeight != Int(Int32.min) else { return nil }

        let masks: (UInt32, UInt32, UInt32)
        switch compression {
        case biRGB:
            masks = (0x7C00, 0x03E0, 0x001F)
        case biBitfields, biAlphaBitfields:
            // After a plain BITMAPINFOHEADER the three masks follow it; V2 (52) and later headers hold them inside.
            guard let r = u32(54), let g = u32(58), let b = u32(62) else { return nil }
            masks = (r, g, b)
        default:
            return nil
        }
        for mask in [masks.0, masks.1, masks.2] where mask > 0xFFFF || !isContiguous(mask) { return nil }
        guard Int(offset) >= 14 + Int(headerSize) else { return nil }
        return Header(width: width, height: abs(signedHeight), topDown: signedHeight < 0, pixelOffset: Int(offset),
                      redMask: masks.0, greenMask: masks.1, blueMask: masks.2)
    }

    /// Decodes the pixels of a parsed 16-bit BMP into an opaque bitmap; nil if the pixel data is short.
    static func decode(_ data: Data, header h: Header) -> Bitmap? {
        guard h.width <= SheetDecoder.maxDimension, h.height <= SheetDecoder.maxDimension else { return nil }
        // The last byte read is at needed - 1, so every raw[s] and raw[s + 1] below is in bounds.
        let needed = h.pixelOffset + h.stride * (h.height - 1) + h.width * 2
        guard data.count >= needed else { return nil }
        let red = Channel(h.redMask), green = Channel(h.greenMask), blue = Channel(h.blueMask)
        var pixels = [UInt8](repeating: 255, count: h.width * h.height * 4)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            pixels.withUnsafeMutableBufferPointer { out in
                for y in 0..<h.height {
                    let sourceRow = h.topDown ? y : h.height - 1 - y
                    var s = h.pixelOffset + sourceRow * h.stride
                    var d = y * h.width * 4
                    for _ in 0..<h.width {
                        let v = UInt32(raw[s]) | UInt32(raw[s + 1]) << 8
                        out[d] = red.expand(v)
                        out[d + 1] = green.expand(v)
                        out[d + 2] = blue.expand(v)
                        s += 2
                        d += 4
                    }
                }
            }
        }
        return Bitmap(width: h.width, height: h.height, pixels: pixels)
    }

    /// One colour channel of a bit mask, widened to 8 bits as browsers do.
    struct Channel {
        /// Where the kept bits start in the pixel.
        let shift: UInt32
        /// Kept bits, 0...8 (a wider mask keeps its top 8, as Skia does).
        let bits: UInt32
        /// Kept value -> 8-bit level: round(v * 255 / (2^bits - 1)).
        let table: [UInt8]

        init(_ mask: UInt32) {
            let width = UInt32(mask.nonzeroBitCount)
            let kept = min(width, 8)
            shift = mask == 0 ? 0 : UInt32(mask.trailingZeroBitCount) + (width - kept)
            bits = kept
            if kept == 0 {
                table = [0]
            } else {
                let maxValue = (UInt32(1) << kept) - 1
                table = (0...maxValue).map { UInt8((Double($0) * 255 / Double(maxValue)).rounded(.toNearestOrAwayFromZero)) }
            }
        }

        func expand(_ pixel: UInt32) -> UInt8 {
            bits == 0 ? 0 : table[Int((pixel >> shift) & ((UInt32(1) << bits) - 1))]
        }
    }

    static func isContiguous(_ mask: UInt32) -> Bool {
        guard mask != 0 else { return true }
        let shifted = mask >> UInt32(mask.trailingZeroBitCount)
        return shifted & (shifted + 1) == 0
    }
}
