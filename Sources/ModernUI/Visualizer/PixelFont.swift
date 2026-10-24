// SPDX-License-Identifier: GPL-3.0-or-later
// A tiny 3×5 pixel font for scenes that write a little: scores, a BPM readout, a dial's legend. Digits, capitals and a
// few marks; letters are upper-cased and anything else is left as a space. Drawn into a `PixelCanvas` (pixel-art
// scenes) or as squares of any size into a Core Graphics context (vector scenes).

import CoreGraphics
import Foundation

nonisolated enum PixelFont {
    static let glyphWidth = 3
    static let glyphHeight = 5

    /// The rows of `c`'s glyph, top first, each 3 bits with the left column highest; nil for a character it lacks.
    static func glyph(_ c: Character) -> [UInt8]? {
        // Some letters upper-case to two ("ß" to "SS"): those have no glyph.
        let upper = c.uppercased()
        guard upper.count == 1, let key = upper.first else { return nil }
        return glyphs[key]
    }

    /// The width of `text` in pixels, `spacing` pixels between glyphs.
    static func width(_ text: String, spacing: Int = 1) -> Int {
        let n = text.count
        return n == 0 ? 0 : n * glyphWidth + (n - 1) * spacing
    }

    /// Draws `text` into `canvas` with its top-left at (x, y).
    static func draw(_ text: String, into canvas: inout PixelCanvas, x: Int, y: Int, color: RGB, alpha: Double = 1,
                     spacing: Int = 1) {
        var left = x
        for c in text {
            if let rows = glyph(c) {
                for (row, bits) in rows.enumerated() {
                    for col in 0..<glyphWidth where bits & (0b100 >> UInt8(col)) != 0 {
                        canvas.set(left + col, y + row, color, alpha)
                    }
                }
            }
            left += glyphWidth + spacing
        }
    }

    /// Fills `text` as squares `pixel` points across, its top-left at `origin` (a top-left-origin context), in the
    /// context's current fill colour. One path, one fill.
    static func fill(_ text: String, in ctx: CGContext, at origin: CGPoint, pixel: CGFloat, spacing: Int = 1) {
        let path = CGMutablePath()
        var left = 0
        for c in text {
            if let rows = glyph(c) {
                for (row, bits) in rows.enumerated() {
                    for col in 0..<glyphWidth where bits & (0b100 >> UInt8(col)) != 0 {
                        path.addRect(CGRect(x: origin.x + CGFloat(left + col) * pixel, y: origin.y + CGFloat(row) * pixel,
                                            width: pixel, height: pixel))
                    }
                }
            }
            left += glyphWidth + spacing
        }
        ctx.addPath(path)
        ctx.fillPath()
    }

    private static let glyphs: [Character: [UInt8]] = [
        "0": [0b111, 0b101, 0b101, 0b101, 0b111], "1": [0b010, 0b110, 0b010, 0b010, 0b111],
        "2": [0b111, 0b001, 0b111, 0b100, 0b111], "3": [0b111, 0b001, 0b111, 0b001, 0b111],
        "4": [0b101, 0b101, 0b111, 0b001, 0b001], "5": [0b111, 0b100, 0b111, 0b001, 0b111],
        "6": [0b111, 0b100, 0b111, 0b101, 0b111], "7": [0b111, 0b001, 0b010, 0b010, 0b010],
        "8": [0b111, 0b101, 0b111, 0b101, 0b111], "9": [0b111, 0b101, 0b111, 0b001, 0b111],
        "A": [0b010, 0b101, 0b111, 0b101, 0b101], "B": [0b110, 0b101, 0b110, 0b101, 0b110],
        "C": [0b011, 0b100, 0b100, 0b100, 0b011], "D": [0b110, 0b101, 0b101, 0b101, 0b110],
        "E": [0b111, 0b100, 0b110, 0b100, 0b111], "F": [0b111, 0b100, 0b110, 0b100, 0b100],
        "G": [0b011, 0b100, 0b101, 0b101, 0b011], "H": [0b101, 0b101, 0b111, 0b101, 0b101],
        "I": [0b111, 0b010, 0b010, 0b010, 0b111], "J": [0b001, 0b001, 0b001, 0b101, 0b010],
        "K": [0b101, 0b101, 0b110, 0b101, 0b101], "L": [0b100, 0b100, 0b100, 0b100, 0b111],
        "M": [0b101, 0b111, 0b111, 0b101, 0b101], "N": [0b110, 0b101, 0b101, 0b101, 0b101],
        "O": [0b010, 0b101, 0b101, 0b101, 0b010], "P": [0b110, 0b101, 0b110, 0b100, 0b100],
        "Q": [0b010, 0b101, 0b101, 0b110, 0b011], "R": [0b110, 0b101, 0b110, 0b101, 0b101],
        "S": [0b011, 0b100, 0b010, 0b001, 0b110], "T": [0b111, 0b010, 0b010, 0b010, 0b010],
        "U": [0b101, 0b101, 0b101, 0b101, 0b111], "V": [0b101, 0b101, 0b101, 0b101, 0b010],
        "W": [0b101, 0b101, 0b111, 0b111, 0b101], "X": [0b101, 0b101, 0b010, 0b101, 0b101],
        "Y": [0b101, 0b101, 0b010, 0b010, 0b010], "Z": [0b111, 0b001, 0b010, 0b100, 0b111],
        " ": [0, 0, 0, 0, 0], "-": [0, 0, 0b111, 0, 0], ".": [0, 0, 0, 0, 0b010], ",": [0, 0, 0, 0b010, 0b100],
        ":": [0, 0b010, 0, 0b010, 0], "!": [0b010, 0b010, 0b010, 0, 0b010], "?": [0b111, 0b001, 0b010, 0, 0b010],
        "/": [0b001, 0b001, 0b010, 0b100, 0b100], "'": [0b010, 0b010, 0, 0, 0], "+": [0, 0b010, 0b111, 0b010, 0],
        "=": [0, 0b111, 0, 0b111, 0], "(": [0b001, 0b010, 0b010, 0b010, 0b001], ")": [0b100, 0b010, 0b010, 0b010, 0b100],
        "&": [0b010, 0b101, 0b010, 0b101, 0b011], "#": [0b101, 0b111, 0b101, 0b111, 0b101],
        "%": [0b101, 0b001, 0b010, 0b100, 0b101], "<": [0b001, 0b010, 0b100, 0b010, 0b001],
        ">": [0b100, 0b010, 0b001, 0b010, 0b100], "*": [0, 0b101, 0b010, 0b101, 0],
    ]
}
