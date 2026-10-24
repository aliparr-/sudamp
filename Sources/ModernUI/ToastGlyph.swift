// SPDX-License-Identifier: GPL-3.0-or-later
// The Dancing Toast, sudamp's mascot (DESIGN §8.3), as the status item's glyph in the menu bar: the slice's outline
// with a face and legs, a template image like the system's own (SF Symbols has no toast).

import AppKit

/// The menu bar's toast, a 16-point template image. At 1x its pixels are placed by hand, as curves blur there; on
/// Retina it is ToastScene's slice outline, drawn smooth at the system symbols' line weight.
public enum ToastGlyph {
    public static let menuBar: NSImage = {
        let image = NSImage(size: NSSize(width: side, height: side))
        for rep in [pixelRep(), drawnRep(scale: 2)] {
            if let rep { image.addRepresentation(rep) }
        }
        image.isTemplate = true
        image.accessibilityDescription = "sudamp"
        return image
    }()

    static let side = 16

    /// The 1x glyph, top row first: the crown, eyes, a smile, legs and feet turned out.
    static let pixelMap = [
        "....########....",
        "..##........##..",
        ".#............#.",
        "#..............#",
        "##............##",
        "..#..........#..",
        "..#..#....#..#..",
        "..#..#....#..#..",
        "..#..........#..",
        "..#..#....#..#..",
        "..#...####...#..",
        "..#..........#..",
        "...##########...",
        ".....#....#.....",
        ".....#....#.....",
        "....##....##....",
    ]

    private static func pixelRep() -> NSBitmapImageRep? {
        rep(scale: 1) { ctx in
            for (row, line) in pixelMap.enumerated() {
                for (col, cell) in line.enumerated() where cell == "#" {
                    ctx.fill(CGRect(x: col, y: row, width: 1, height: 1))
                }
            }
        }
    }

    /// The same toast in points: the slice's outline standing on the 1x glyph's bottom row, its crown just inside the
    /// square, then eyes, a smile, and legs with feet turned out.
    private static func drawnRep(scale: CGFloat) -> NSBitmapImageRep? {
        rep(scale: scale) { ctx in
            ctx.setLineWidth(1.3)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let k: CGFloat = 0.44
            var place = CGAffineTransform(translationX: 8, y: 12.5).scaledBy(x: k, y: k)
            if let slice = ToastScene.slice(width: 24, height: 26).copy(using: &place) {
                ctx.addPath(slice)
                ctx.strokePath()
            }
            for x: CGFloat in [5.2, 10.8] {
                ctx.fillEllipse(in: CGRect(x: x - 0.7, y: 6, width: 1.4, height: 2))
            }
            ctx.move(to: CGPoint(x: 5.3, y: 9.3))
            ctx.addQuadCurve(to: CGPoint(x: 10.7, y: 9.3), control: CGPoint(x: 8, y: 11.7))
            ctx.strokePath()
            for (x, out): (CGFloat, CGFloat) in [(5.6, -1), (10.4, 1)] {
                ctx.move(to: CGPoint(x: x, y: 13.2))
                ctx.addLine(to: CGPoint(x: x, y: 15.2))
                ctx.addLine(to: CGPoint(x: x + out * 1.2, y: 15.2))
                ctx.strokePath()
            }
        }
    }

    /// A `side`-point square at `scale` pixels a point, black on clear; `draw` works in points with y down.
    private static func rep(scale: CGFloat, _ draw: (CGContext) -> Void) -> NSBitmapImageRep? {
        let pixels = Int(CGFloat(side) * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        draw(ctx)
        guard let image = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: side, height: side)
        return rep
    }
}
