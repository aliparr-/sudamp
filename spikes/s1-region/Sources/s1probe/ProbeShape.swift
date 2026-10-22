// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S1: the probe's 275×116 "main window" region and the named spots the probe clicks or samples.
import AppKit
import RegionRaster

enum ProbeShape {
    static let width = 275
    static let height = 116
    /// Points per skin pixel. 2 matches DESIGN §8.1's Retina default and makes the notch easy to hit.
    static let scale: CGFloat = 2

    /// Bevelled top corners, a 85×76 px notch cut up from the bottom edge, and a diamond island in it.
    static let notchedRegion = """
        [Normal]
        NumPoints = 10, 4
        PointList = 3,0, 272,0, 275,3, 275,116, 180,116, 180,40, 95,40, 95,116, 0,116, 0,3, 137,62, 152,77, 137,92, 122,77
        """
    static let fullRegion = "[Normal]\nNumPoints=4\nPointList=0,0, 275,0, 275,116, 0,116\n"

    static func mask(_ regionText: String) -> Mask {
        RegionRasterizer.rasterize(RegionText.polygons(in: regionText), width: width, height: height)
    }

    /// A skin pixel the probe clicks or samples (its centre is at +0.5, +0.5).
    struct Spot: Sendable {
        let name: String
        let x: Int
        let y: Int
    }

    static let clickSpots = [
        Spot(name: "bodyOpaque", x: 40, y: 60),
        Spot(name: "notchTransparent", x: 110, y: 100),
        Spot(name: "notchTransparentHigh", x: 165, y: 50),
        Spot(name: "islandOpaque", x: 137, y: 77),
        Spot(name: "cornerTransparent", x: 0, y: 0),
    ]

    /// Skin-colour RGBA (premultiplied; alpha 0 outside the mask). A lighter "title bar" and a darker
    /// 1 px rim make the shape readable on screen; none of that affects coverage.
    static func image(for mask: Mask) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: mask.width * mask.height * 4)
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask[x, y] {
                let rim = !mask[x - 1, y] || !mask[x + 1, y] || !mask[x, y - 1] || !mask[x, y + 1]
                let rgb: (UInt8, UInt8, UInt8) = rim ? (10, 60, 60) : (y < 14 ? (60, 190, 180) : (28, 120, 116))
                let i = (y * mask.width + x) * 4
                pixels[i] = rgb.0
                pixels[i + 1] = rgb.1
                pixels[i + 2] = rgb.2
                pixels[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: mask.width, height: mask.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: mask.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}
