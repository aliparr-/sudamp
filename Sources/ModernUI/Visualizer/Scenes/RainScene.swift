// SPDX-License-Identifier: GPL-3.0-or-later
// Rain: rain on a pond, seen from above. Each drop that lands sends out two or three rings that spread and fade,
// crossing each other where they meet, and a few lily pads float on the water, bobbing and rocking as the rings pass
// under them. The treble sets the drizzle (how often small drops land), and every kick drops a big drop with wider,
// longer rings and a splash of droplets. Through a breakdown it settles to a light, gentle rain; the drop brings a
// short burst of many drops. In silence the rain stops and the last rings fade: a still pond with its pads and one
// faint ring. A seed places the pads (two or three, one perhaps in flower) and the rain.

import CoreGraphics
import Foundation

nonisolated final class RainScene: VisualizerScene {
    /// A drop's rings spreading on the water. Positions and sizes are shares of the width (y down).
    private struct Ripple {
        var x: Double
        var y: Double
        var age = 0.0
        /// Seconds until the rings have faded out.
        var life: Double
        /// How far the outer ring spreads.
        var reach: Double
        /// Rings in the train, and the gap between them.
        var rings: Int
        var spacing: Double
        /// Opacity as it lands, 0...1.
        var strength: Double
        /// Line width in points (at 92 points across).
        var width: Double
        /// A kick's big drop: it throws a crown of droplets as it lands.
        var big: Bool
        /// Which way the droplets fly, radians.
        var turn: Double
        /// 1 while the music plays; falls quickly in silence so the last rings fade out.
        var hush = 1.0
    }

    /// A lily pad: a disc with a notch, floating. Bobbing lifts it (seen from above: it grows a little), rocks it
    /// round and nudges it away from the drop that made the ring.
    private struct Pad {
        var x: Double
        var y: Double
        var radius: Double
        /// Where the notch points, radians.
        var notch: Double
        /// How wide the notch opens, radians.
        var gap: Double
        var flower: Bool
        /// A little light or shade, so the pads are not all one green.
        var tone: Double
        var lift = Spring(), rock = Spring(), dx = Spring(), dy = Spring()
    }

    /// A damped spring about 0.
    private struct Spring {
        var value = 0.0
        var velocity = 0.0

        mutating func step(_ dt: Double, omega: Double, damping: Double) {
            velocity += (-omega * omega * value - 2 * damping * omega * velocity) * dt
            value += velocity * dt
        }
    }

    /// A ring to draw this frame: its centre, radius and width in points, and its opacity.
    private struct Ring {
        var x: CGFloat
        var y: CGFloat
        var radius: CGFloat
        var width: CGFloat
        var alpha: Float
    }

    /// The colours the pond's pictures are made from. The artwork's colours can turn slowly and without end, so the
    /// pictures are made again only once these have moved visibly (one picture a frame).
    private struct Look {
        var water: RGB
        var leaf: RGB
        var petal: RGB
        var isLight: Bool

        init(_ style: SceneStyle) {
            water = style.deep
            leaf = RGB(0.27, 0.55, 0.3).mixed(with: style.mid, 0.2)
            petal = style.isLight ? style.spark(0).mixed(with: .white, 0.2) : style.spark(1).mixed(with: .white, 0.45)
            isLight = style.isLight
        }

        private static func close(_ a: RGB, _ b: RGB, _ within: Double) -> Bool {
            max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) < within
        }

        /// The water shows its colour at a third or less, so it may drift further before it shows.
        func sameWater(as other: Look) -> Bool { isLight == other.isLight && Self.close(water, other.water, 0.03) }

        func samePads(as other: Look) -> Bool {
            isLight == other.isLight && Self.close(leaf, other.leaf, 0.012) && Self.close(petal, other.petal, 0.015)
        }
    }

    /// A splash's fleck or droplet to draw this frame, in points.
    private struct Dot {
        var x: CGFloat
        var y: CGFloat
        var radius: CGFloat
        var alpha: Float
    }

    private static let maxRipples = 40

    private var ripples: [Ripple] = []
    private var pads: [Pad] = []
    private var random: SceneRandom
    /// 0 in silence, 1 while music plays.
    private var activity = 0.0
    private var treble = 0.0
    /// Counts up to the next small drop.
    private var drizzle = 0.0
    private var nextDrizzle = 1.0
    /// Drops left in a drop's burst, and the clock between them.
    private var burst = 0
    private var burstClock = 0.0
    /// Where the last big drop fell, so the next lands elsewhere.
    private var lastBig = (x: 0.5, y: 0.5)
    /// The faint ring left on the still pond, and how much of it shows.
    private let restRing: (x: Double, y: Double, radius: Double)
    private var rest = 1.0

    /// Made once for a look and a size: the pond's shading, as pixels, and each pad's picture (drawn upright, then
    /// turned and lifted as it bobs).
    private var water: (look: Look, pixels: Int, image: [UInt32])?
    private var padPictures: (look: Look, pixels: Int, images: [CGImage?])?
    // Scratch space for drawing, kept between frames: the frame's pixels, rings and splashes.
    private var canvas: [UInt32] = []
    private var rings: [Ring] = []
    private var dots: [Dot] = []

    var glow: Double { 0 }

    init(seed: UInt64) {
        random = SceneRandom(seed: seed)
        pads = Self.makePads(&random)
        // The still pond's ring: open water, clear of the pads.
        var spot = (x: 0.55, y: 0.45, radius: 0.12)
        for _ in 0..<40 {
            let candidate = (x: random.range(0.3, 0.7), y: random.range(0.3, 0.68), radius: random.range(0.1, 0.14))
            let room = pads.map { hypot($0.x - candidate.x, $0.y - candidate.y) - $0.radius }.min() ?? 1
            if room > candidate.radius + 0.04 {
                spot = candidate
                break
            }
        }
        restRing = spot
        ripples.reserveCapacity(Self.maxRipples)
        rings.reserveCapacity(Self.maxRipples * 6 + 4)
        dots.reserveCapacity(Self.maxRipples * 6)
    }

    /// Two or three pads in a loose group, clear of the window's buttons at the top left and of each other.
    private static func makePads(_ random: inout SceneRandom) -> [Pad] {
        let count = random.chance(0.5) ? 3 : 2
        let sizes = [random.range(0.12, 0.145), random.range(0.085, 0.105), random.range(0.06, 0.075)]
        var pads: [Pad] = []
        let flowerOn = random.int(count)
        // The group gathers about one side of the pond.
        let anchors = [(0.26, 0.72), (0.74, 0.74), (0.76, 0.34), (0.3, 0.6)]
        let anchor = anchors[random.int(anchors.count)]
        for i in 0..<count {
            let r = sizes[i]
            var best = (x: anchor.0, y: anchor.1)
            for attempt in 0..<60 {
                let spread = i == 0 ? 0.05 : 0.2 + Double(attempt) * 0.004
                let x = min(max(anchor.0 + random.range(-spread, spread), 0.14), 0.86)
                let y = min(max(anchor.1 + random.range(-spread, spread), 0.2), 0.86)
                if x < 0.36, y < 0.3 { continue }
                if pads.allSatisfy({ hypot($0.x - x, $0.y - y) > $0.radius + r + 0.02 }) {
                    best = (x, y)
                    break
                }
            }
            pads.append(Pad(x: best.x, y: best.y, radius: r, notch: random.range(0, 2 * .pi),
                            gap: random.range(0.32, 0.5), flower: i == flowerOn && random.chance(0.7),
                            tone: random.range(-0.08, 0.08)))
        }
        return pads
    }

    // MARK: Update

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let level = Double(input.level), bass = Double(input.bass)
        let breakdown = Double(input.breakdown)
        let target = smoothstep(0.02, 0.1, level)
        activity += (target - activity) * (1 - exp(-dt / (target > activity ? 0.1 : 0.06)))
        treble += (Double(input.treble) - treble) * (1 - exp(-dt / 0.15))
        rest += ((activity < 0.3 ? 1 : 0) - rest) * (1 - exp(-dt / 0.12))
        let raining = activity > 0.3

        if raining {
            // The drizzle: a few drops a second on quiet hats, a steady patter on bright ones; lighter in a breakdown.
            let rate = (0.6 + 7 * treble * treble) * (1 - 0.3 * breakdown) * activity
            drizzle += rate * dt
            while drizzle >= nextDrizzle {
                drizzle -= nextDrizzle
                nextDrizzle = random.range(0.5, 1.5)
                addDrop(big: false, strength: 0.5 + 0.25 * treble)
            }
            if input.drop {
                burst = 12
                burstClock = 0
                addDrop(big: true, strength: 1, central: true)
            } else if input.beat {
                // A kick's big drop; in a breakdown the bassline's hits fall as gentle middling drops instead.
                if breakdown > 0.5 {
                    addDrop(big: false, strength: 0.6, wide: true)
                } else {
                    addDrop(big: true, strength: (0.55 + 0.45 * bass) * (1 - 0.6 * breakdown))
                }
            }
            if burst > 0 {
                burstClock += dt
                while burst > 0, burstClock >= 0.04 {
                    burstClock -= 0.04
                    burst -= 1
                    addDrop(big: false, strength: random.range(0.55, 0.85), wide: random.chance(0.35))
                }
            }
        } else {
            burst = 0
        }

        let hush = raining ? 1 : exp(-dt / 0.09)
        var i = 0
        while i < ripples.count {
            var r = ripples[i]
            let before = Self.radius(r, age: r.age)
            r.age += dt
            r.hush *= hush
            if r.age >= r.life || r.hush < 0.01 {
                ripples.remove(at: i)
                continue
            }
            nudgePads(by: r, from: before, to: Self.radius(r, age: r.age))
            ripples[i] = r
            i += 1
        }

        // The pads ride the rings and settle; in silence they settle quickly.
        let damping = raining ? 1.0 : 2.4
        let steps = max(1, Int((dt / (1.0 / 120)).rounded(.up)))
        let h = dt / Double(steps)
        for p in pads.indices {
            for _ in 0..<steps {
                pads[p].lift.step(h, omega: 2 * .pi * 1.5, damping: 0.3 * damping)
                pads[p].rock.step(h, omega: 2 * .pi * 0.9, damping: 0.28 * damping)
                pads[p].dx.step(h, omega: 2 * .pi * 0.7, damping: 0.5 * damping)
                pads[p].dy.step(h, omega: 2 * .pi * 0.7, damping: 0.5 * damping)
            }
        }
    }

    /// A new drop: somewhere on open water (not on a pad), big ones away from the last big one; `central` (the
    /// drop's first) near the middle.
    private func addDrop(big: Bool, strength: Double, wide: Bool = false, central: Bool = false) {
        var x = 0.5, y = 0.5
        for attempt in 0..<8 {
            let spread = central && attempt < 4 ? 0.12 : 0.42
            x = 0.5 + random.range(-spread, spread)
            y = 0.5 + random.range(-spread, spread)
            let onPad = pads.contains { hypot($0.x - x, $0.y - y) < $0.radius + 0.015 }
            let crowded = big && !central && hypot(x - lastBig.x, y - lastBig.y) < 0.3
            if !onPad, !crowded { break }
        }
        if big { lastBig = (x, y) }
        if ripples.count >= Self.maxRipples {
            // Full: the one furthest through its life gives way.
            func spent(_ i: Int) -> Double { ripples[i].age / ripples[i].life }
            guard let oldest = ripples.indices.max(by: { spent($0) < spent($1) }) else { return }
            ripples.remove(at: oldest)
        }
        let ripple: Ripple
        if big {
            ripple = Ripple(x: x, y: y, life: random.range(1.7, 2.0), reach: random.range(0.25, 0.29), rings: 3,
                            spacing: 0.042, strength: strength, width: 1.5, big: true, turn: random.range(0, 2 * .pi))
        } else if wide {
            ripple = Ripple(x: x, y: y, life: random.range(1.4, 1.7), reach: random.range(0.17, 0.22), rings: 2,
                            spacing: 0.04, strength: strength, width: 1.25, big: false, turn: 0)
        } else {
            ripple = Ripple(x: x, y: y, life: random.range(1.0, 1.3), reach: random.range(0.1, 0.15), rings: 2,
                            spacing: 0.032, strength: strength, width: 1.1, big: false, turn: 0)
        }
        ripples.append(ripple)
    }

    /// The outer ring's radius at `age`: quick at first, slowing as it spreads.
    private static func radius(_ r: Ripple, age: Double) -> Double {
        let u = min(max(age / r.life, 0), 1)
        return r.reach * (1 - pow(1 - u, 1.8))
    }

    /// The ring's opacity at its age: full as it lands, fading as it grows.
    private static func opacity(_ r: Ripple) -> Double {
        let u = min(max(r.age / r.life, 0), 1)
        return r.strength * pow(1 - u, 1.7) * min(1, r.age / 0.05) * r.hush
    }

    /// A ring passing under a pad lifts it, rocks it and pushes it gently away.
    private func nudgePads(by r: Ripple, from before: Double, to now: Double) {
        guard now > before else { return }
        for p in pads.indices {
            let ddx = pads[p].x - r.x, ddy = pads[p].y - r.y
            let d = hypot(ddx, ddy)
            guard d > before, d <= now, d > 1e-4 else { continue }
            let push = Self.opacity(r) * (r.big ? 1 : 0.45) * (0.1 / (pads[p].radius + 0.02))
            pads[p].lift.velocity += 1.4 * push
            // Rock one way or the other depending on which side the ring comes from.
            let side = sin(atan2(ddy, ddx) - pads[p].notch) >= 0 ? 1.0 : -1.0
            pads[p].rock.velocity += 3 * push * side
            pads[p].dx.velocity += 0.25 * push * ddx / d
            pads[p].dy.velocity += 0.25 * push * ddy / d
        }
    }

    // MARK: Draw

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let w = size.width
        guard w >= 1 else { return }
        let unit = w / 92
        let scale = min(max(abs(ctx.userSpaceToDeviceSpaceTransform.a), 1), 3)
        let n = Int((w * scale).rounded())
        guard n > 0, n <= 2048 else { return }
        let look = Look(style)
        let resized = water?.pixels != n || padPictures?.pixels != n
        var made = false
        if resized || water?.look.sameWater(as: look) != true {
            water = (look, n, Self.waterPixels(look, pixels: n))
            made = true
        }
        if resized || (!made && padPictures?.look.samePads(as: look) != true) {
            padPictures = (look, n, pads.map { Self.padImage($0, look: look, width: w, scale: scale) })
        }
        if canvas.count != n * n { canvas = [UInt32](repeating: 0, count: n * n) }
        guard let water, let padPictures, water.image.count == n * n, canvas.count == n * n else { return }

        // The pond (the artwork deepened towards its banks, so the rings and pads stand out on it), then the rings
        // and splashes over it, drawn into pixels: only the pixels along each ring are touched, which costs far less
        // than having Core Graphics fill or stroke them.
        collectRings(w: w, unit: unit)
        let k = Double(scale)
        let ink = Self.paint(style.ink)
        let trough = Self.paint(style.deep.scaled(0.3))
        canvas.withUnsafeMutableBufferPointer { out in
            water.image.withUnsafeBufferPointer { pond in
                guard let to = out.baseAddress, let from = pond.baseAddress else { return }
                to.update(from: from, count: n * n)
            }
            for ring in rings {
                let half = Double(ring.width) * k / 2
                let radius = Double(ring.radius) * k
                // Each ring is a bright crest with a darker trough just inside it (on dark artwork: on light, the
                // crest alone, drawn dark).
                if !style.isLight {
                    Self.band(out, n: n, cx: Double(ring.x) * k, cy: Double(ring.y) * k,
                              radius: radius - 2.2 * half, half: half, paint: trough, alpha: ring.alpha * 0.45)
                }
                Self.band(out, n: n, cx: Double(ring.x) * k, cy: Double(ring.y) * k, radius: radius, half: half,
                          paint: ink, alpha: ring.alpha)
            }
            for dot in dots {
                Self.disc(out, n: n, cx: Double(dot.x) * k, cy: Double(dot.y) * k, radius: Double(dot.radius) * k,
                          paint: ink, alpha: dot.alpha)
            }
        }
        if let image = Self.image(canvas, n: n) {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: 0, y: w)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: w))
            ctx.restoreGState()
        }

        for (pad, image) in zip(pads, padPictures.images) {
            guard let image else { continue }
            drawPad(pad, image: image, ctx: ctx, w: w, scale: scale)
        }
    }

    /// This frame's rings and splashes, in points.
    private func collectRings(w: CGFloat, unit: CGFloat) {
        rings.removeAll(keepingCapacity: true)
        dots.removeAll(keepingCapacity: true)
        let fadeShares = [1.0, 0.68, 0.42]
        for r in ripples {
            let a = Self.opacity(r)
            guard a > 0.01 else { continue }
            let u = min(r.age / r.life, 1)
            let outer = Self.radius(r, age: r.age)
            for k in 0..<r.rings {
                let radius = (outer - Double(k) * r.spacing * (0.55 + 0.6 * u)) * w
                let alpha = a * fadeShares[min(k, 2)]
                guard radius > 0.8 * unit, alpha > 0.02 else { continue }
                rings.append(Ring(x: r.x * w, y: r.y * w, radius: radius, width: r.width * unit, alpha: Float(alpha)))
            }
            // The splash as it lands: a bright fleck, and for a big drop a crown of droplets flung out.
            guard r.age < 0.24 else { continue }
            let t = r.age / 0.24
            let fleck = (r.big ? 1.7 : 1.1) * (1 - t) * unit
            if fleck > 0.3 * unit {
                dots.append(Dot(x: r.x * w, y: r.y * w, radius: fleck, alpha: Float(r.strength * r.hush * (1 - t))))
            }
            guard r.big else { continue }
            let drop = 0.8 * unit * (1 - 0.4 * t)
            for k in 0..<5 {
                // Irregular: each droplet flies its own way and distance.
                let angle = r.turn + Double(k) * 1.257 + 0.35 * sin(r.turn * 3 + Double(k) * 2.1)
                let reach = (0.02 + (0.04 + 0.025 * sin(r.turn * 5 + Double(k) * 1.7)) * pow(t, 0.6)) * w
                dots.append(Dot(x: r.x * w + cos(angle) * reach, y: r.y * w + sin(angle) * reach, radius: drop,
                                alpha: Float(0.85 * r.strength * r.hush * (1 - t * t))))
            }
        }
        // The still pond's ring.
        if rest > 0.01 {
            for (k, share) in [1.0, 0.68].enumerated() {
                rings.append(Ring(x: restRing.x * w, y: restRing.y * w, radius: restRing.radius * share * w,
                                  width: 1.1 * unit, alpha: Float(0.32 * rest * (k == 0 ? 1 : 0.7))))
            }
        }
    }

    /// A pad's picture, turned by its rock, grown by its lift and moved by its drift. At rest it lands on whole
    /// pixels, so it stays crisp.
    private func drawPad(_ pad: Pad, image: CGImage, ctx: CGContext, w: CGFloat, scale: CGFloat) {
        let side = CGFloat(image.width) / scale
        let cx = (pad.x * w * scale).rounded() / scale + pad.dx.value * w
        let cy = (pad.y * w * scale).rounded() / scale + pad.dy.value * w
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        if abs(pad.rock.value) > 1e-4 { ctx.rotate(by: pad.rock.value) }
        if abs(pad.lift.value) > 1e-4 { ctx.scaleBy(x: 1 + pad.lift.value, y: 1 + pad.lift.value) }
        // Bitmaps draw bottom-up in this top-left-origin context: flip about the pad's centre.
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
        ctx.restoreGState()
    }
}

// MARK: - Pixels

nonisolated extension RainScene {
    /// A colour ready to blend: its channels as 0...255.
    private typealias Paint = (r: Float, g: Float, b: Float)

    private static func paint(_ c: RGB) -> Paint { (Float(c.r) * 255, Float(c.g) * 255, Float(c.b) * 255) }

    /// `paint` at `alpha` over the premultiplied pixel `p` (bytes R, G, B, A in memory).
    @inline(__always)
    private static func blend(_ p: inout UInt32, _ paint: Paint, _ alpha: Float) {
        let keep = 1 - alpha
        let r = paint.r * alpha + Float(p & 0xFF) * keep
        let g = paint.g * alpha + Float((p >> 8) & 0xFF) * keep
        let b = paint.b * alpha + Float((p >> 16) & 0xFF) * keep
        let a = 255 * alpha + Float(p >> 24) * keep
        p = UInt32(min(r, 255) + 0.5) | UInt32(min(g, 255) + 0.5) << 8 | UInt32(min(b, 255) + 0.5) << 16
            | UInt32(min(a, 255) + 0.5) << 24
    }

    /// A ring `half` pixels either side of `radius` about (cx, cy), in pixels, softened to a pixel at its edges. Only
    /// the rows and runs the band crosses are visited.
    private static func band(_ out: UnsafeMutableBufferPointer<UInt32>, n: Int, cx: Double, cy: Double, radius: Double,
                             half: Double, paint: Paint, alpha: Float) {
        guard radius > 0.5, alpha > 0.004 else { return }
        let outer = radius + half + 1, inner = max(radius - half - 1, 0)
        let o2 = outer * outer, i2 = inner * inner
        let y0 = max(0, Int((cy - outer).rounded(.down))), y1 = min(n - 1, Int((cy + outer).rounded(.up)))
        guard y0 <= y1 else { return }
        let thin = min(2 * half, 1)
        for y in y0...y1 {
            let dy = Double(y) + 0.5 - cy
            let dy2 = dy * dy
            guard dy2 < o2 else { continue }
            let xo = (o2 - dy2).squareRoot()
            let xi = dy2 < i2 ? (i2 - dy2).squareRoot() : -1
            let row = y * n
            // The left and right runs (one run across the top and bottom, where the band has no hole).
            for side in 0..<(xi < 0 ? 1 : 2) {
                let lo = xi < 0 ? cx - xo : side == 0 ? cx - xo : cx + xi
                let hi = xi < 0 ? cx + xo : side == 0 ? cx - xi : cx + xo
                let x0 = max(0, Int(lo.rounded(.down))), x1 = min(n - 1, Int(hi.rounded(.up)))
                guard x0 <= x1 else { continue }
                for x in x0...x1 {
                    let dx = Double(x) + 0.5 - cx
                    let d = (dx * dx + dy2).squareRoot()
                    let cover = min(half + 0.5 - abs(d - radius), thin)
                    guard cover > 0 else { continue }
                    blend(&out[row + x], paint, alpha * Float(cover))
                }
            }
        }
    }

    /// A filled round dot, in pixels.
    private static func disc(_ out: UnsafeMutableBufferPointer<UInt32>, n: Int, cx: Double, cy: Double, radius: Double,
                             paint: Paint, alpha: Float) {
        guard radius > 0.2, alpha > 0.004 else { return }
        let reach = radius + 1
        let x0 = max(0, Int((cx - reach).rounded(.down))), x1 = min(n - 1, Int((cx + reach).rounded(.up)))
        let y0 = max(0, Int((cy - reach).rounded(.down))), y1 = min(n - 1, Int((cy + reach).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }
        let full = min(2 * radius, 1)
        for y in y0...y1 {
            let dy = Double(y) + 0.5 - cy
            for x in x0...x1 {
                let dx = Double(x) + 0.5 - cx
                let cover = min(radius + 0.5 - (dx * dx + dy * dy).squareRoot(), full)
                guard cover > 0 else { continue }
                blend(&out[y * n + x], paint, alpha * Float(cover))
            }
        }
    }

    private static func image(_ pixels: [UInt32], n: Int) -> CGImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: sceneColorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - Pictures

nonisolated extension RainScene {
    /// A bitmap context `pixels` across, drawing in points (`scale` pixels each) from the top left.
    private static func bitmap(pixels: Int, scale: CGFloat) -> CGContext? {
        guard pixels > 0, pixels <= 4096,
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sceneColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: scale, y: -scale)
        return ctx
    }

    /// Deeper water towards the banks: the artwork's own deep colour over it (only a whisper on light artwork), as
    /// premultiplied pixels `pixels` square.
    private static func waterPixels(_ look: Look, pixels n: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: n * n)
        let deep = look.water.scaled(look.isLight ? 1 : 0.55)
        let edge = look.isLight ? 0.12 : 0.55, middle = look.isLight ? 0.0 : 0.16
        let colors = [deep.cgColor(alpha: middle), deep.cgColor(alpha: (middle + edge) / 2), deep.cgColor(alpha: edge)]
        guard let gradient = CGGradient(colorsSpace: sceneColorSpace, colors: colors as CFArray, locations: [0, 0.6, 1])
        else { return out }
        out.withUnsafeMutableBytes { bytes in
            guard let ctx = CGContext(data: bytes.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: sceneColorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            // Rows in memory run top to bottom, as the pond's picture does; the gradient is drawn bottom-up.
            let w = CGFloat(n)
            let c = CGPoint(x: w * 0.5, y: w * (1 - 0.42))
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: w * 0.78,
                                   options: [.drawsAfterEndLocation])
        }
        return out
    }

    /// A pad at rest, centred in a square picture with room for its shadow: its shadow on the water, the leaf with a
    /// lighter heart, a darker rim and veins, and perhaps a water lily.
    private static func padImage(_ pad: Pad, look: Look, width w: CGFloat, scale: CGFloat) -> CGImage? {
        let unit = w / 92
        let r = pad.radius * w
        // An even number of pixels, so the centre falls on a pixel corner.
        let pixels = Int(((r * 1.3 + 3 * unit) * scale).rounded(.up)) * 2
        guard let ctx = bitmap(pixels: pixels, scale: scale) else { return nil }
        let half = CGFloat(pixels) / scale / 2
        let cx = half, cy = half
        let notch = pad.notch
        let leaf = pad.tone >= 0 ? look.leaf.mixed(with: .white, pad.tone) : look.leaf.scaled(1 + pad.tone)

        func padPath(_ ox: CGFloat, _ oy: CGFloat, _ radius: CGFloat) -> CGPath {
            let path = CGMutablePath()
            let c = CGPoint(x: cx + ox, y: cy + oy)
            path.move(to: c)
            path.addArc(center: c, radius: radius, startAngle: notch + pad.gap / 2,
                        endAngle: notch - pad.gap / 2 + 2 * .pi, clockwise: false)
            path.closeSubpath()
            return path
        }
        ctx.setLineCap(.round)
        ctx.addPath(padPath(0.9 * unit, 1.3 * unit, r))
        ctx.setFill(.black, look.isLight ? 0.14 : 0.28)
        ctx.fillPath()
        let body = padPath(0, 0, r)
        ctx.addPath(body)
        ctx.setFill(leaf)
        ctx.fillPath()
        ctx.addPath(padPath(-0.12 * r, -0.12 * r, r * 0.62))
        ctx.setFill(leaf.mixed(with: .white, 0.14), 0.7)
        ctx.fillPath()
        ctx.addPath(body)
        ctx.setLineWidth(0.9 * unit)
        ctx.setStroke(leaf.scaled(0.62))
        ctx.strokePath()
        // Veins from the heart, opposite the notch.
        ctx.setLineWidth(0.7 * unit)
        ctx.setStroke(leaf.scaled(0.72), 0.8)
        for k in [-1.0, 0.0, 1.0] {
            let angle = notch + .pi + k * 0.75
            ctx.move(to: CGPoint(x: cx, y: cy))
            ctx.addLine(to: CGPoint(x: cx + cos(angle) * r * 0.78, y: cy + sin(angle) * r * 0.78))
        }
        ctx.strokePath()

        if pad.flower {
            // A water lily: petals round a golden heart.
            let fx = cx + cos(notch + .pi * 0.7) * r * 0.25, fy = cy + sin(notch + .pi * 0.7) * r * 0.25
            let pr = max(r * 0.42, 3.2 * unit)
            ctx.setFill(look.petal)
            for k in 0..<6 {
                let a = notch + Double(k) * .pi / 3
                let px = fx + cos(a) * pr * 0.55, py = fy + sin(a) * pr * 0.55
                ctx.addEllipse(in: CGRect(x: px - pr * 0.42, y: py - pr * 0.42, width: pr * 0.84, height: pr * 0.84))
            }
            ctx.fillPath()
            ctx.setFill(RGB(1, 0.84, 0.36))
            ctx.fillEllipse(in: CGRect(x: fx - pr * 0.3, y: fy - pr * 0.3, width: pr * 0.6, height: pr * 0.6))
        }
        return ctx.makeImage()
    }
}

/// 0 below `lo`, 1 above `hi`, smooth between.
nonisolated private func smoothstep(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
    let t = min(max((x - lo) / (hi - lo), 0), 1)
    return t * t * (3 - 2 * t)
}
