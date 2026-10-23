// SPDX-License-Identifier: GPL-3.0-or-later
// Lava: a lava lamp. Blobs of warm wax heat up in the pool at the foot of the artwork, rise, cool near the top and
// sink back, merging and splitting as they pass; the music is the lamp's heat, so they climb faster when it is loud
// and hang still in silence. Every kick sets them wobbling. The wax glows hottest low down and deepens as it cools.

import CoreGraphics
import Foundation

nonisolated final class LavaScene: VisualizerScene {
    private struct Blob {
        /// Where it sways about, and its centre, as shares of the artwork (y down).
        var home: Double
        var x: Double
        var y: Double
        var vy: Double = 0
        /// 0 cold, 1 hot: hot wax rises, cold wax sinks.
        var heat: Double
        /// Each blob's own nature, so they drift out of step: how strongly heat lifts it, how fast it takes and loses
        /// heat, and the heights where it cools and warms.
        var lift = 0.75
        var exchange = 1.0
        var cools = 0.34
        var warms = 0.76
        /// The visible radius on its own, as a share of the width, and how tall it is for its width.
        var radius: Double
        var squash: Double = 1
        var sway: Double
        var swaySpeed: Double
        /// A kick's squash and stretch, and its phase.
        var wobble: Double = 0
        var wobblePhase: Double
    }

    /// Where the field's surface is: the kernel (1 - d²/R²)³ crosses it at `edge` of R.
    private static let threshold: Float = 0.25
    private static let edge = 0.608

    private var blobs: [Blob]
    /// The pool at the foot: a wide, flat blob that wobbles too.
    private var pool = Blob(home: 0.5, x: 0.5, y: 1.04, heat: 1, radius: 0.36, squash: 0.36, sway: 0, swaySpeed: 0.35,
                            wobblePhase: 0)
    /// How much heat the music gives the lamp, smoothed.
    private var energy: Double = 0
    private var field: [Float] = []
    private var pixels: [UInt32] = []
    /// The last frame, kept while the lamp is still (in silence), with what it was drawn for.
    private var still: (image: CGImage?, style: SceneStyle, width: Int, height: Int)?
    private var moved = true
    private var paints: (style: SceneStyle, rim: (RGB, RGB), core: (RGB, RGB), shine: RGB, opacity: Float)?

    init(seed: UInt64) {
        var random = SceneRandom(seed: seed)
        let count = 6
        // Homes spread across the lamp in a shuffled order, so neighbours in height are not neighbours across.
        var slots = Array(0..<count)
        for i in stride(from: count - 1, to: 0, by: -1) { slots.swapAt(i, random.int(i + 1)) }
        blobs = slots.map { slot in
            let home = 0.16 + 0.68 * (Double(slot) + random.range(0.3, 0.7)) / Double(count)
            let heat = random.next()
            return Blob(home: home, x: home, y: random.range(0.25, 0.85), heat: heat, lift: random.range(0.5, 0.95),
                        exchange: random.range(0.6, 1.5), cools: random.range(0.26, 0.42), warms: random.range(0.7, 0.84),
                        radius: random.range(0.075, 0.115), sway: random.range(0, 2 * .pi), swaySpeed: random.range(0.5, 1.1),
                        wobblePhase: random.range(0, 2 * .pi))
        }
    }

    var glow: Double { 0.2 }

    func update(_ input: VisualizerInput, dt: Double) {
        let target = min(1.4, Double(input.level) * 1.1 + Double(input.bass) * 0.5)
        energy += (target - energy) * (1 - exp(-dt / 0.6))
        let e = energy
        for i in blobs.indices {
            var b = blobs[i]
            // Heated in the pool at the foot, cooled near the top; in between it keeps what it has.
            let warmth = b.y > b.warms ? 1.0 : b.y < b.cools ? 0.0 : b.heat
            b.heat += (warmth - b.heat) * (1 - exp(-dt * 1.1 * b.exchange * e))
            // Hot wax rises and cool wax sinks, as fast as the music allows; in silence it slows to a stop.
            b.vy -= (b.heat - 0.5) * b.lift * e * dt
            b.vy *= exp(-dt * (1.5 + 4 * max(0, 0.35 - e)))
            b.y += b.vy * dt
            if b.y < 0.16 { b.y = 0.16; b.vy = max(b.vy, 0) }
            if b.y > 0.95 { b.y = 0.95; b.vy = min(b.vy, 0) }
            b.sway += dt * b.swaySpeed * 0.7 * e
            b.x = b.home + 0.06 * sin(b.sway)
            if abs(b.y - blobs[i].y) + abs(b.x - blobs[i].x) > 1e-6 { moved = true }
            blobs[i] = b
        }
        let poolX = pool.x
        pool.sway += dt * pool.swaySpeed * 0.7 * e
        pool.x = 0.5 + 0.05 * sin(pool.sway)
        // Kicks set the wax wobbling: a quick squash and stretch that rings down.
        for i in blobs.indices { Self.ring(&blobs[i], kick: input.beat, dt: dt) }
        Self.ring(&pool, kick: input.beat, dt: dt)
        if pool.wobble > 1e-4 || abs(pool.x - poolX) > 1e-6 || blobs.contains(where: { $0.wobble > 1e-4 }) { moved = true }
    }

    private static func ring(_ b: inout Blob, kick: Bool, dt: Double) {
        if kick { b.wobble = min(b.wobble + 0.11, 0.18) }
        b.wobble *= exp(-dt * 3.5)
        b.wobblePhase += dt * 2 * .pi * 3.2
    }

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        if paints == nil || paints?.style != style { paints = Self.paints(style) }
        guard let paints, size.width >= 1, size.height >= 1 else { return }
        let scale = min(max(abs(ctx.userSpaceToDeviceSpaceTransform.a), 1), 3)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        if !moved, let still, still.style == style, still.width == width, still.height == height {
            if let image = still.image { Self.drawUpright(image, in: ctx, size: size) }
            return
        }
        moved = false
        let count = width * height
        if field.count != count {
            field = [Float](repeating: 0, count: count)
            pixels = [UInt32](repeating: 0, count: count)
        }
        let w = Double(width), h = Double(height)
        // The field: each blob adds its kernel over the box it reaches.
        field.withUnsafeMutableBufferPointer { f in
            f.update(repeating: 0)
            for k in 0...blobs.count {
                let b = k < blobs.count ? blobs[k] : pool
                let s = b.wobble * sin(b.wobblePhase)
                let rx = b.radius * w / Self.edge * (1 + s), ry = b.radius * w / Self.edge * (1 - s) * b.squash
                let cx = b.x * w, cy = b.y * h
                let x0 = max(0, Int(cx - rx)), x1 = min(width - 1, Int(cx + rx) + 1)
                let y0 = max(0, Int(cy - ry)), y1 = min(height - 1, Int(cy + ry) + 1)
                guard x0 <= x1, y0 <= y1 else { continue }
                let ix = Float(1 / (rx * rx)), iy = Float(1 / (ry * ry))
                for y in y0...y1 {
                    let dy = Float(Double(y) + 0.5 - cy)
                    let qy = dy * dy * iy
                    guard qy < 1 else { continue }
                    let row = y * width
                    for x in x0...x1 {
                        let dx = Float(Double(x) + 0.5 - cx)
                        let q = qy + dx * dx * ix
                        if q < 1 {
                            let t = 1 - q
                            f[row + x] += t * t * t
                        }
                    }
                }
            }
        }

        // The wax: soft-edged to a pixel, its rim and core shading from hot at the foot to cooled at the top, with a
        // shine where its surface faces the light (up and to the left).
        let threshold = Self.threshold
        let lx: Float = -0.55, ly: Float = -0.83
        // The field's slope across a lone blob's edge, per pixel: the shine fades out where the surface is flatter
        // than that (where blobs meet), so it doesn't streak along the seams.
        let rimSlope = Float(1.45 * Self.edge / (0.095 * w))
        let opacity = paints.opacity
        let haloFrom = threshold * 0.2, haloAlpha: Float = style.isLight ? 0 : 0.4
        var anything = false
        field.withUnsafeBufferPointer { f in
            pixels.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let row = y * width
                    let cool = Float(min(max((Double(y) / h - 0.25) / 0.65, 0), 1))
                    let rim = Self.mix(paints.rim.0, paints.rim.1, cool), core = Self.mix(paints.core.0, paints.core.1, cool)
                    let up = y > 0 ? row - width : row, down = y < height - 1 ? row + width : row
                    for x in 0..<width {
                        let i = row + x
                        let v = f[i]
                        guard v > haloFrom else {
                            out[i] = 0
                            continue
                        }
                        // A faint glow in the liquid around the wax.
                        let near = min((v - haloFrom) / (threshold - haloFrom), 1)
                        let halo = near * near.squareRoot() * haloAlpha
                        let gx = (f[x < width - 1 ? i + 1 : i] - f[x > 0 ? i - 1 : i]) * 0.5
                        let gy = (f[down + x] - f[up + x]) * 0.5
                        let slope = (gx * gx + gy * gy).squareRoot()
                        // Coverage: how far inside the surface, in pixels.
                        let a = min(max(0.5 + (v - threshold) / max(slope, 0.004), 0), 1)
                        guard a > 0.003 else {
                            if halo > 0.004 {
                                out[i] = Self.pack(rim.0 * halo, rim.1 * halo, rim.2 * halo, halo)
                                anything = true
                            } else {
                                out[i] = 0
                            }
                            continue
                        }
                        let depth = min(max((v - threshold) / 0.8, 0), 1)
                        let k = depth.squareRoot()
                        var r = rim.0 + (core.0 - rim.0) * k
                        var g = rim.1 + (core.1 - rim.1) * k
                        var b = rim.2 + (core.2 - rim.2) * k
                        if slope > rimSlope * 0.25 {
                            // The outward normal is down the slope.
                            let facing = max(0, -(gx * lx + gy * ly) / slope)
                            let firm = min(1, (slope / rimSlope - 0.25) * 1.5)
                            let shine = facing * facing * facing * facing * (1 - depth) * firm * 0.8
                            r += (Float(paints.shine.r) - r) * shine
                            g += (Float(paints.shine.g) - g) * shine
                            b += (Float(paints.shine.b) - b) * shine
                        }
                        let alpha = a * opacity, under = halo * (1 - alpha)
                        out[i] = Self.pack(r * alpha + rim.0 * under, g * alpha + rim.1 * under, b * alpha + rim.2 * under,
                                           alpha + under)
                        anything = true
                    }
                }
            }
        }
        let image = anything ? image(width: width, height: height) : nil
        still = (image, style, width, height)
        if let image { Self.drawUpright(image, in: ctx, size: size) }
    }

    /// Draws a bitmap of the artwork's pixels into the top-left-origin context (bitmaps draw bottom-up).
    private static func drawUpright(_ image: CGImage, in ctx: CGContext, size: CGSize) {
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }

    private func image(width: Int, height: Int) -> CGImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func mix(_ a: RGB, _ b: RGB, _ t: Float) -> (Float, Float, Float) {
        (Float(a.r) + Float(b.r - a.r) * t, Float(a.g) + Float(b.g - a.g) * t, Float(a.b) + Float(b.b - a.b) * t)
    }

    /// Premultiplied components, 0...1, as bytes R, G, B, A in memory.
    private static func pack(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> UInt32 {
        func byte(_ v: Float) -> UInt32 { UInt32(min(max(v, 0), 1) * 255 + 0.5) }
        return byte(r) | byte(g) << 8 | byte(b) << 16 | byte(a) << 24
    }

    /// The wax's colours: rim and core, hot (low in the lamp) then cooled (high up), and its shine. Warm wax from the
    /// artwork's warmest spark; on light artwork, its accent and deep ink, with no white.
    private static func paints(_ style: SceneStyle)
        -> (style: SceneStyle, rim: (RGB, RGB), core: (RGB, RGB), shine: RGB, opacity: Float) {
        if style.isLight {
            let wax = style.accent
            return (style, (wax, wax.mixed(with: style.ink, 0.5)), (wax.mixed(with: .white, 0.25), wax),
                    wax.mixed(with: .white, 0.55), 0.92)
        }
        func warmth(_ c: RGB) -> Double { c.r - c.b + (c.g - c.b) * 0.3 }
        let warmest = style.sparks.max { warmth($0) < warmth($1) } ?? style.spark(0)
        let wax = warmth(warmest) > 0.2 ? warmest : style.spark(0)
        let hotRim = wax.adjusted(saturation: 1.3, brightness: 0.85)
        let coolRim = wax.adjusted(hue: -0.03, saturation: 1.4, brightness: 0.55)
        let hotCore = wax.mixed(with: .white, 0.5), coolCore = wax.mixed(with: .white, 0.12)
        return (style, (hotRim, coolRim), (hotCore, coolCore), .white, 0.97)
    }
}
