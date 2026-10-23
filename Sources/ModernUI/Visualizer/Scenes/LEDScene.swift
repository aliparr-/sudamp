// SPDX-License-Identifier: GPL-3.0-or-later
// Retro LEDs: a hi-fi meter's columns of segmented LEDs lit by the spectrum, green at the foot, then amber, then red
// at the top. Each column holds its peak segment for a moment before it drops back, segments that go out fade like
// real LEDs, and the unlit ones stay faintly visible behind the plastic.

import CoreGraphics
import Foundation

nonisolated final class LEDScene: VisualizerScene {
    static let columns = 12
    static let rows = 14
    /// How bright the fading segments are drawn, in three steps.
    private static let fadeSteps = [0.2, 0.45, 0.75]

    /// Each segment's light, 0...1, column by column from the bottom.
    private var light = [Float](repeating: 0, count: columns * rows)
    /// The held peak per column, in segments, and how long it still holds and how fast it is falling.
    private var peaks = [Float](repeating: 0, count: columns)
    private var holds = [Double](repeating: 0, count: columns)
    private var falls = [Float](repeating: 0, count: columns)
    private var art: LEDArt?
    /// Clip rectangles, kept between frames: the fully lit runs, and the fading segments in three steps.
    private var lit: [CGRect] = []
    private var fading: [[CGRect]] = [[], [], []]

    var glow: Double { 0.4 }

    func update(_ input: VisualizerInput, dt: Double) {
        let rows = Self.rows
        // An LED goes out in a few frames.
        let fade = Float(exp(-dt / 0.035))
        for c in 0..<Self.columns {
            let f = (Double(c) + 0.5) / Double(Self.columns)
            // The meter's scale: the analyser's quiet floor is cut off, and the highs get a gentle lift, so every
            // column moves through most of its height.
            let v = min(max((input.band(at: f) + 0.1 * Float(f) - 0.2) / 0.76, 0), 1)
            let count = Int((v * Float(rows)).rounded())
            for r in 0..<rows {
                let i = c * rows + r
                light[i] = r < count ? 1 : light[i] * fade
            }
            if Float(count) >= peaks[c] {
                peaks[c] = Float(count)
                holds[c] = 0.45
                falls[c] = 0
            } else if holds[c] > 0 {
                holds[c] -= dt
            } else {
                // Drops back with a little gravity, a segment at a time.
                falls[c] += Float(dt) * 40
                peaks[c] = max(Float(count), peaks[c] - falls[c] * Float(dt))
            }
        }
    }

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let scale = max(1, abs(ctx.userSpaceToDeviceSpaceTransform.a))
        if art?.matches(style, size, scale) != true { art = LEDArt(style: style, size: size, scale: scale) }
        guard let art else { return }
        let rows = Self.rows
        lit.removeAll(keepingCapacity: true)
        for i in fading.indices { fading[i].removeAll(keepingCapacity: true) }
        for c in 0..<Self.columns {
            var run = 0
            while run < rows, light[c * rows + run] >= 1 { run += 1 }
            if run > 0 { lit.append(art.layout.run(c, 0, run)) }
            for r in run..<rows {
                let b = light[c * rows + r]
                guard b > 0.05 else { continue }
                fading[b > 0.6 ? 2 : b > 0.3 ? 1 : 0].append(art.layout.run(c, r, r + 1))
            }
            let top = Int(peaks[c].rounded(.up)) - 1
            if top >= run, top < rows, peaks[c] > 0.5 { lit.append(art.layout.run(c, top, top + 1)) }
        }
        art.drawUnlit(in: ctx, size: size)
        art.drawLit(in: ctx, size: size, clip: lit, alpha: 1)
        for (i, rects) in fading.enumerated() where !rects.isEmpty {
            art.drawLit(in: ctx, size: size, clip: rects, alpha: Self.fadeSteps[i])
        }
    }
}

/// Where the segments sit, in whole points so they stay crisp at 1x.
private nonisolated struct LEDLayout {
    var origin: CGPoint
    var pitch: CGSize
    var led: CGSize

    init(size: CGSize) {
        let u = size.width / 92
        pitch = CGSize(width: max(3, (6 * u).rounded()), height: max(2, (4 * u).rounded()))
        led = CGSize(width: max(2, (4 * u).rounded()), height: max(1.5, (3 * u).rounded()))
        let w = pitch.width * CGFloat(LEDScene.columns - 1) + led.width
        let h = pitch.height * CGFloat(LEDScene.rows - 1) + led.height
        origin = CGPoint(x: ((size.width - w) / 2).rounded(), y: (size.height - h - 10 * u).rounded())
    }

    /// Segment `r` (from the bottom) of column `c`.
    func segment(_ c: Int, _ r: Int) -> CGRect {
        CGRect(x: origin.x + CGFloat(c) * pitch.width, y: origin.y + CGFloat(LEDScene.rows - 1 - r) * pitch.height,
               width: led.width, height: led.height)
    }

    /// Segments `from..<to` of column `c` with the gaps around them, for clipping (room for the bloom).
    func run(_ c: Int, _ from: Int, _ to: Int) -> CGRect {
        let top = segment(c, to - 1), bottom = segment(c, from)
        let gx = (pitch.width - led.width) / 2, gy = (pitch.height - led.height) / 2
        return CGRect(x: top.minX - gx, y: top.minY - gy, width: led.width + gx * 2, height: bottom.maxY - top.minY + gy * 2)
    }
}

/// The meter drawn once for a style, size and scale: every segment unlit, and every segment lit.
private nonisolated final class LEDArt {
    let style: SceneStyle
    let size: CGSize
    let scale: CGFloat
    let layout: LEDLayout
    private var unlit: CGImage?
    private var lit: CGImage?

    init(style: SceneStyle, size: CGSize, scale: CGFloat) {
        self.style = style
        self.size = size
        self.scale = scale
        layout = LEDLayout(size: size)
        let rows = LEDScene.rows
        let warm = Self.isWarm(style)
        let colors = (0..<rows).map { Self.color(row: $0, of: rows, light: style.isLight, warm: warm) }
        let radius = min(layout.led.width, layout.led.height) * 0.34
        func shape(_ rect: CGRect) -> CGPath { CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil) }
        func paths(row r: Int) -> CGMutablePath {
            let path = CGMutablePath()
            for c in 0..<LEDScene.columns { path.addPath(shape(layout.segment(c, r))) }
            return path
        }

        unlit = Self.render(size: size, scale: scale) { ctx in
            for r in 0..<rows {
                ctx.addPath(paths(row: r))
                ctx.setFill(colors[r].mixed(with: style.ink, style.isLight ? 0.2 : 0.35), style.isLight ? 0.13 : 0.15)
                ctx.fillPath()
            }
        }
        lit = Self.render(size: size, scale: scale) { ctx in
            for r in 0..<rows {
                let color = colors[r]
                let path = paths(row: r)
                ctx.saveGState()
                if !style.isLight {
                    // The bloom of a lit LED into the gaps around it.
                    ctx.setShadow(offset: .zero, blur: 2.2 * scale, color: color.cgColor(alpha: 0.9))
                }
                ctx.addPath(path)
                ctx.setFill(color)
                ctx.fillPath()
                ctx.restoreGState()
                // A brighter lens at the top of each segment.
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                let lens = (0..<LEDScene.columns).map { c -> CGRect in
                    let s = layout.segment(c, r)
                    return CGRect(x: s.minX, y: s.minY, width: s.width, height: s.height * 0.4)
                }
                ctx.setFill(color.mixed(with: .white, style.isLight ? 0.25 : 0.55))
                ctx.fill(lens)
                ctx.restoreGState()
            }
        }
    }

    func matches(_ style: SceneStyle, _ size: CGSize, _ scale: CGFloat) -> Bool {
        self.size == size && self.scale == scale && self.style == style
    }

    /// Whether the artwork is pink, red or orange, where the meter's green would fight it.
    static func isWarm(_ style: SceneStyle) -> Bool {
        let c = style.deep.hsb
        return !style.isLight && c.saturation > 0.3 && (c.hue > 0.74 || c.hue < 0.12)
    }

    /// The meter's colour for row `r` of `rows`: green (aqua on warm artwork), amber, red. Darker on light artwork.
    static func color(row r: Int, of rows: Int, light: Bool, warm: Bool) -> RGB {
        let f = Double(r) / Double(max(rows - 1, 1))
        let hue: Double
        if f < 0.56 {
            hue = warm ? 0.53 - 0.04 * f / 0.56 : 0.36 - 0.05 * f / 0.56
        } else if f < 0.84 {
            hue = 0.14 - 0.03 * (f - 0.56) / 0.28
        } else {
            hue = 0.995
        }
        return light ? RGB(hue: hue, saturation: 0.95, brightness: hue > 0.2 ? 0.55 : 0.72)
            : RGB(hue: hue, saturation: 0.78, brightness: 1)
    }

    func drawUnlit(in ctx: CGContext, size: CGSize) {
        guard let unlit else { return }
        ctx.saveGState()
        Self.drawUpright(unlit, in: ctx, size: size)
        ctx.restoreGState()
    }

    func drawLit(in ctx: CGContext, size: CGSize, clip: [CGRect], alpha: Double) {
        guard let lit, !clip.isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: clip)
        ctx.setAlpha(alpha)
        Self.drawUpright(lit, in: ctx, size: size)
        ctx.restoreGState()
    }

    /// Draws a bitmap made by `render` the right way up into a top-left-origin context.
    private static func drawUpright(_ image: CGImage, in ctx: CGContext, size: CGSize) {
        ctx.interpolationQuality = .none
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
    }

    /// A bitmap `size` points across at `scale`, drawn by `body` in points with a top-left origin.
    private static func render(size: CGSize, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(w) / size.width, y: -CGFloat(h) / size.height)
        body(ctx)
        return ctx.makeImage()
    }
}
