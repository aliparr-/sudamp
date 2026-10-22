// SPDX-License-Identifier: GPL-3.0-or-later
//
// A 1x RGBA drawing surface for pixel art, used by the sudamp Dark generator.
//
// Ported from Bitamp, Sources/BitampKit/Skin/Canvas.swift
// (https://github.com/ryanromanov/Bitamp @ 91952819c9cc0394dd03a961dd27a101a52ee6ef).
// sudamp changes: draws into a `Bitmap` with integer maths instead of a CGContext, so the generated skin is
// byte-identical on every macOS version; colours are `RGBA`; the gloss/halo/locked helpers used only by Bitamp's
// other themes are dropped.
//
// Original notice:
//
// MIT License
//
// Copyright (c) 2026 Ryan Romanosky and Bitamp contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

/// A 1x RGBA bitmap with a top-left origin and no antialiasing, for pixel art. Starts fully transparent.
final class Canvas {
    private(set) var bitmap: Bitmap
    var width: Int { bitmap.width }
    var height: Int { bitmap.height }

    init(_ width: Int, _ height: Int) {
        bitmap = Bitmap(width: width, height: height)
    }

    convenience init(_ size: IntSize) {
        self.init(size.width, size.height)
    }

    /// Fills a rect, compositing translucent colours over what is there.
    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: RGBA) {
        guard w > 0, h > 0 else { return }
        if color.a == 255 {
            bitmap.fill(IntRect(x, y, w, h), color)
        } else {
            bitmap.draw(Bitmap(width: w, height: h, fill: color), at: IntPoint(x, y), mode: .over)
        }
    }

    /// A 1px raised edge: `light` on the top and left, `dark` on the bottom and right.
    func bevel(_ x: Int, _ y: Int, _ w: Int, _ h: Int, light: RGBA, dark: RGBA) {
        fill(x, y, w, 1, light)
        fill(x, y, 1, h, light)
        fill(x, y + h - 1, w, 1, dark)
        fill(x + w - 1, y, 1, h, dark)
    }

    /// Draws `image` upright with its top-left corner at (x, y), source-over.
    func draw(_ image: Bitmap, _ x: Int, _ y: Int) {
        bitmap.draw(image, at: IntPoint(x, y), mode: .over)
    }

    func draw(_ image: Bitmap, at point: IntPoint) {
        draw(image, point.x, point.y)
    }

    func glyph(_ character: Character, _ x: Int, _ y: Int, _ color: RGBA) {
        for (row, bits) in PixelFont.rows(for: character).enumerated() {
            for (column, bit) in bits.enumerated() where bit == "#" {
                fill(x + column, y + row, 1, 1, color)
            }
        }
    }

    func text(_ text: String, _ x: Int, _ y: Int, _ color: RGBA) {
        for (index, character) in PixelFont.normalize(text).enumerated() {
            glyph(character, x + index * PixelFont.cellWidth, y, color)
        }
    }

    /// Text with 1px between each glyph's lit columns instead of fixed cells, for labels that need to fit a
    /// small button.
    func compactText(_ text: String, _ x: Int, _ y: Int, _ color: RGBA) {
        var x = x
        for character in PixelFont.normalize(text) {
            let rows = PixelFont.compactRows(for: character)
            for (row, bits) in rows.enumerated() {
                for (column, bit) in bits.enumerated() where bit == "#" {
                    fill(x + column, y + row, 1, 1, color)
                }
            }
            x += rows[0].count + 1
        }
    }

    func pixel(_ x: Int, _ y: Int) -> RGBA { bitmap[x, y] }

    func image() -> Bitmap { bitmap }
}

func rgb(_ hex: UInt32) -> RGBA { RGBA(hex: hex) }

/// Linear blend from `a` (t = 0) to `b` (t = 1) in sRGB, rounded to the nearest 8-bit value.
func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
    a.mixed(with: b, t).withAlpha(255)
}
