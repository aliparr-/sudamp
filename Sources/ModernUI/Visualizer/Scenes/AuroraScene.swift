// SPDX-License-Identifier: GPL-3.0-or-later
// Aurora: the northern lights over dark hills. Two curtains of light hang in a night sky, made of fine vertical
// rays, brightest along their lower edge and fading upwards, folding and drifting slowly over a ridge of pines, with
// stars twinkling behind. The mids ripple the curtains, the level brightens them, the treble shimmers the rays, and
// every kick sends a soft wave of brightness along the ribbon. Through a breakdown the aurora drifts slow and wide;
// the drop makes it flare, bloom and settle. In silence it fades to a faint glow under the stars. On light artwork it
// is dusk instead: a pale sky with deeper-tinted ribbons. A seed shapes the hills, places the trees and the stars,
// sometimes puts a cabin with a lit window on the ridge, and picks which colour leads.

import CoreGraphics
import Foundation

nonisolated final class AuroraScene: VisualizerScene {
    private struct Star {
        var x: Double
        var y: Double
        /// Radius in points (at 92 points across).
        var size: Double
        var bright: Double
        var phase: Double
    }

    /// A kick's wave of brightness running along the curtains.
    private struct Wave {
        var x: Double
        var direction: Double
        var strength: Double
        var age = 0.0
    }

    /// One curtain's shape and light: where its lower edge sits, how far its folds swing and its rays reach, and how
    /// bright it is, all as shares of the height.
    private struct Curtain {
        var base: Double
        var swing: Double
        var height: Double
        var brightness: Double
        /// Its own phases, so the two curtains don't move in step.
        var phase: Double
        var tilt: Double
        /// How far under its edge the light falls away, in points: the far curtain is hazier.
        var soft: Double
    }

    private struct Tree {
        var x: Double
        var height: Double
        var width: Double
    }

    /// The vertical light profile is looked up in a table of this many steps from the edge (0) to the top (1).
    private static let profileSteps = 128

    private var activity = 0.0
    private var level = 0.0
    private var mid = 0.0
    private var treble = 0.0
    private var breakdown = 0.0
    /// How far the folds have drifted, and the rays shimmered: they move only while music plays.
    private var drift: Double
    private var shimmer: Double
    private var twinkle = 0.0
    private var sinceDrop = 10.0
    private var waves: [Wave] = []
    private var kicks = 0

    /// The near curtain, then the far one (the drawing is written for these two).
    private let curtains: [Curtain]
    /// Which of the two aurora colours leads the near curtain's edge.
    private let swapped: Bool
    private let stars: [Star]
    private let farRidge: [Double]
    private let nearRidge: [Double]
    private let trees: [Tree]
    /// Where a cabin sits on the ridge, if there is one.
    private let cabin: Double?

    /// Colours for a style and a height in pixels: the sky down the rows, the aurora's colours and the hills'.
    private var paints: Paints?
    /// The hills for a size, made once: the far ridge's outline, and a picture of the near ridge with its pines (and
    /// the cabin, if there is one) in the colour it was made in, with the row it starts at. The artwork's colours can
    /// turn slowly and without end: the picture is made again only once its colour has moved visibly.
    private var hills: (colour: RGB, isLight: Bool, width: Int, far: CGPath, near: CGImage?, top: Int)?
    // Scratch space for drawing, kept between frames: the sky's pixels, and each curtain's columns of light (a point
    // apart, then a pixel apart).
    private var pixels: [UInt32] = []
    private var coarse: [Column] = []
    private var fine: [Column] = []
    private var starAlpha: [Double] = []

    private struct Paints {
        var style: SceneStyle
        var rows: Int
        /// The sky's colour on each row, 0...1, and as pixels.
        var sky: [Float]
        var skyPacked: [UInt32]
        /// Per curtain, per step up its height: red, green, blue, and how bright it is there.
        var table: [Float]
        /// How strongly the rays break the light up, per step up the height.
        var rayDepth: [Float]
        /// The bright lower edge's colour, per curtain: red, green, blue.
        var edge: [Float]
        var far: RGB
        var near: RGB
        var glowTint: RGB
    }

    /// One column's light this frame, for one curtain: its edge row, 1 / its height in rows, brightness and how
    /// much its rays dim it.
    private struct Column {
        var edge: Float
        var inverse: Float
        var light: Float
        var dip: Float
    }

    var glow: Double { 0 }

    init(seed: UInt64) {
        var random = SceneRandom(seed: seed)
        drift = random.range(0, 10)
        shimmer = random.range(0, 10)
        swapped = random.chance(0.5)
        curtains = [
            Curtain(base: random.range(0.5, 0.56), swing: 1, height: random.range(0.36, 0.42), brightness: 1,
                    phase: random.range(0, 2 * .pi), tilt: random.range(-0.04, 0.04), soft: 1.1),
            Curtain(base: random.range(0.33, 0.39), swing: 0.7, height: random.range(0.22, 0.27), brightness: 0.42,
                    phase: random.range(0, 2 * .pi), tilt: random.range(-0.05, 0.05), soft: 2.6),
        ]
        farRidge = (0..<4).map { _ in random.range(0, 2 * .pi) }
        nearRidge = (0..<4).map { _ in random.range(0, 2 * .pi) }
        var stars: [Star] = []
        while stars.count < 24 {
            let x = random.range(0.04, 0.96), y = random.range(0.03, 0.66)
            let big = stars.count < 3
            stars.append(Star(x: x, y: y, size: big ? random.range(0.85, 1.05) : random.range(0.55, 0.75),
                              bright: big ? random.range(0.75, 0.95) : random.range(0.3, 0.65),
                              phase: random.range(0, 2 * .pi)))
        }
        self.stars = stars
        // Pines in a few clumps along the near ridge, with gaps between.
        var trees: [Tree] = []
        var x = random.range(-0.04, 0.06)
        while x < 1.04 {
            let clump = 1 + random.int(4)
            for _ in 0..<clump where x < 1.04 {
                let height = random.range(0.07, 0.13)
                trees.append(Tree(x: x, height: height, width: height * random.range(0.5, 0.6)))
                x += random.range(0.03, 0.055)
            }
            x += random.range(0.08, 0.2)
        }
        if random.chance(0.5) {
            // A cabin in one of the gaps: as far from every tree as can be found.
            var best = 0.5, room = 0.0
            for _ in 0..<12 {
                let spot = random.range(0.2, 0.8)
                let clear = trees.map { abs($0.x - spot) }.min() ?? 1
                if clear > room { room = clear; best = spot }
            }
            cabin = room > 0.05 ? best : nil
            if let cabin { trees.removeAll { abs($0.x - cabin) < 0.05 } }
        } else {
            cabin = nil
        }
        self.trees = trees
    }

    // MARK: Update

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let target = smoothstep(0.02, 0.1, Double(input.level))
        activity += (target - activity) * (1 - exp(-dt / (target > activity ? 0.15 : 0.07)))
        func ease(_ value: inout Double, _ to: Float, _ seconds: Double) {
            value += (Double(to) - value) * (1 - exp(-dt / seconds))
        }
        ease(&level, input.level, 0.3)
        ease(&mid, input.mid, 0.25)
        ease(&treble, input.treble, 0.12)
        breakdown = Double(input.breakdown)

        // The folds drift slowly (slower still in a breakdown) and the rays shimmer with the treble.
        let slow = 1 - 0.55 * breakdown
        drift += dt * activity * (0.12 + 0.4 * mid) * slow
        shimmer += dt * activity * (0.3 + 3.5 * treble) * (1 - 0.4 * breakdown)
        twinkle += dt * activity * (0.8 + 2.5 * treble)
        sinceDrop = input.drop ? 0 : sinceDrop + dt

        // A kick sends a wave of light along the ribbon, each from the other end; not through a breakdown, whose
        // bassline would keep it rippling.
        if input.beat, activity > 0.3, breakdown < 0.5 {
            kicks += 1
            let direction: Double = kicks % 2 == 0 ? 1 : -1
            waves.append(Wave(x: direction > 0 ? -0.15 : 1.15, direction: direction,
                              strength: 0.45 + 0.4 * Double(input.bass)))
            if waves.count > 6 { waves.removeFirst() }
        }
        let fade = activity > 0.3 ? 1 : exp(-dt / 0.08)
        for i in waves.indices {
            waves[i].age += dt
            waves[i].x += waves[i].direction * dt * 0.85
            waves[i].strength *= fade
        }
        waves.removeAll { $0.age > 1.6 || $0.strength < 0.01 }
    }

    /// The drop's flare: blooms over a moment, then settles over a couple of seconds.
    private var flare: Double {
        let t = sinceDrop
        let f = t < 0.18 ? t / 0.18 : exp(-(t - 0.18) / 0.9)
        return f * activity
    }

    // MARK: Draw

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let w = size.width, h = size.height
        guard w >= 1, h >= 1 else { return }
        // The sky is worked out a pixel at a time and drawn one to one (scaling a picture up costs more than this).
        let scale = min(max(abs(ctx.userSpaceToDeviceSpaceTransform.a), 1), 3)
        let cols = Int((w * scale).rounded()), rows = Int((h * scale).rounded())
        guard cols > 0, rows > 0, cols <= 1024, rows <= 1024 else { return }
        if paints == nil || paints?.style != style || paints?.rows != rows {
            paints = Self.paints(style, rows: rows, swapped: swapped)
        }
        guard let paints else { return }
        let near = paints.near
        let stale = hills.map { old in
            let moved = max(abs(old.colour.r - near.r), abs(old.colour.g - near.g), abs(old.colour.b - near.b))
            return old.width != cols || old.isLight != style.isLight || moved >= 0.012
        } ?? true
        if stale { hills = makeHills(w: w, h: h, scale: scale, paints: paints) }
        guard let hills else { return }
        if pixels.count != cols * rows { pixels = [UInt32](repeating: 0, count: cols * rows) }

        let light = renderSky(cols: cols, rows: rows, points: max(8, min(256, Int(w.rounded()))), paints: paints)
        if let image = Self.image(pixels, width: cols, height: rows) {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: 0, y: h)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
        }
        drawStars(ctx, w: w, h: h, style: style, cols: cols, rows: rows)

        // The hills: the far ridge catches a little of the aurora's light; the near one, with its pines, is black.
        let catchLight = style.isLight ? 0 : min(0.25, 0.08 * light)
        ctx.addPath(hills.far)
        ctx.setFill(paints.far.mixed(with: paints.glowTint, catchLight))
        ctx.fillPath()
        if let near = hills.near {
            // Drawn a pixel to a pixel, below the row it starts at.
            let top = CGFloat(hills.top) / scale, height = CGFloat(near.height) / scale
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: 0, y: top + height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(near, in: CGRect(x: 0, y: 0, width: w, height: height))
            ctx.restoreGState()
        }
    }

    /// Fills the pixels with the sky and the curtains' light; returns how bright the aurora is overall. The curtains'
    /// shapes are worked out a point apart and eased between for each pixel.
    private func renderSky(cols: Int, rows: Int, points: Int, paints: Paints) -> Double {
        let flare = flare
        let bright = (0.2 + activity * (0.35 + 0.8 * level)) * (1 + 1.6 * flare)
        let count = curtains.count
        if coarse.count != points * count { coarse = [Column](repeating: Column(edge: 0, inverse: 0, light: 0, dip: 0),
                                                              count: points * count) }
        if fine.count != cols * count { fine = [Column](repeating: Column(edge: 0, inverse: 0, light: 0, dip: 0),
                                                        count: cols * count) }

        // Each column's edge, height, brightness and rays, per curtain, in rows.
        var top = rows, bottom = 0
        for (c, curtain) in curtains.enumerated() {
            let phase = curtain.phase + drift * (c == 0 ? 1 : -0.8)
            // The mids swing the folds further; a breakdown stretches them wide and slow.
            let swing = (0.035 + 0.085 * mid * activity + 0.03 * breakdown) * curtain.swing
            let k1 = 2 * Double.pi * (0.85 - 0.3 * breakdown), k2 = 2 * Double.pi * (2.1 - 0.6 * breakdown)
            let k3 = 2 * Double.pi * 3.7
            let p2 = -1.3 * phase + curtain.phase * 2, p3 = 0.7 * phase + curtain.phase * 5
            for x in 0..<points {
                let u = (Double(x) + 0.5) / Double(points)
                let edge = curtain.base + curtain.tilt * (u - 0.5) * 2
                    + swing * (0.6 * sin(k1 * u + phase) + 0.3 * sin(k2 * u + p2) + 0.1 * sin(k3 * u + p3))
                // Where the ribbon folds (its edge runs steepest) we look along the sheet: brighter there.
                let slope = abs(swing * (0.6 * k1 * cos(k1 * u + phase) + 0.3 * k2 * cos(k2 * u + p2)))
                let fold = 1 + min(0.8, slope * 3)
                // Patches along the ribbon glow brighter than others, drifting with it.
                let patch = 0.74 + 0.26 * sin(2 * .pi * 1.15 * u + phase * 0.6 + curtain.phase * 3)
                let height = curtain.height * (0.78 + 0.22 * sin(2 * .pi * 1.7 * u + phase * 0.7 + 1))
                    * (1 + 0.45 * flare + 0.15 * breakdown)
                var wave = 0.0
                for wv in waves {
                    let d = (u - wv.x) / 0.15
                    wave += wv.strength * exp(-d * d) * max(0, 1 - wv.age / 1.6)
                }
                // The rays: fine streaks that slide and flicker with the treble.
                let ray = 0.5 + 0.22 * sin(2 * .pi * 9 * u + shimmer * 1.3 + curtain.phase)
                    + 0.17 * sin(2 * .pi * 19 * u - shimmer * 2.1) + 0.11 * sin(2 * .pi * 33 * u + shimmer * 3.3 + 2)
                let edgeRow = edge * Double(rows)
                let heightRows = max(height * Double(rows), 2)
                let shine = bright * curtain.brightness * fold * patch * (1 + 1.2 * wave)
                coarse[c * points + x] = Column(edge: Float(edgeRow), inverse: Float(1 / heightRows),
                                                light: Float(shine), dip: Float(0.75 * (1 - min(max(ray, 0), 1))))
                top = min(top, Int(edgeRow - heightRows) - 1)
                bottom = max(bottom, Int(edgeRow + 3 * curtain.soft * Double(rows) / 92) + 1)
            }
        }
        top = max(top, 0)
        bottom = min(bottom, rows - 1)
        for c in 0..<count {
            for x in 0..<cols {
                let p = (Double(x) + 0.5) / Double(cols) * Double(points) - 0.5
                let i = min(max(Int(p.rounded(.down)), 0), points - 1), j = min(i + 1, points - 1)
                let f = Float(min(max(p - Double(i), 0), 1))
                let a = coarse[c * points + i], b = coarse[c * points + j]
                fine[c * cols + x] = Column(edge: a.edge + (b.edge - a.edge) * f,
                                            inverse: a.inverse + (b.inverse - a.inverse) * f,
                                            light: a.light + (b.light - a.light) * f, dip: a.dip + (b.dip - a.dip) * f)
            }
        }

        // The sky row by row, the curtains' light added in (on light artwork: laid over, as ink).
        let steps = Self.profileSteps
        let light = paints.style.isLight
        // The two curtains, near then far (the loop below is written out for two).
        let soft0 = Float(92 / (curtains[0].soft * Double(rows))), soft1 = Float(92 / (curtains[1].soft * Double(rows)))
        let edge0 = (paints.edge[0], paints.edge[1], paints.edge[2])
        let edge1 = (paints.edge[3], paints.edge[4], paints.edge[5])
        let glow = light ? 0 : Float(0.12 * flare + 0.05 * bright)
        let tint = (Float(paints.glowTint.r), Float(paints.glowTint.g), Float(paints.glowTint.b))
        pixels.withUnsafeMutableBufferPointer { out in
            fine.withUnsafeBufferPointer { column in
                paints.table.withUnsafeBufferPointer { table in
                    paints.rayDepth.withUnsafeBufferPointer { rayDepth in
                        paints.sky.withUnsafeBufferPointer { sky in
                            for y in 0..<rows {
                                let row = y * cols
                                // The aurora lights the sky a little towards the horizon; the flare lights it more.
                                let lift = glow * Float(y) / Float(rows)
                                let s0 = sky[y * 3] + lift * tint.0, s1 = sky[y * 3 + 1] + lift * tint.1
                                let s2 = sky[y * 3 + 2] + lift * tint.2
                                guard y >= top, y <= bottom else {
                                    let packed = lift > 0.002 ? Self.pack(s0, s1, s2) : paints.skyPacked[y]
                                    for x in 0..<cols { out[row + x] = packed }
                                    continue
                                }
                                let fy = Float(y) + 0.5
                                for x in 0..<cols {
                                    // The aurora's light here, gathered from both curtains.
                                    let near = Self.light(column[x], fy: fy, base: 0, soft: soft0, edge: edge0,
                                                          table: table, rayDepth: rayDepth)
                                    let far = Self.light(column[cols + x], fy: fy, base: steps * 4, soft: soft1,
                                                         edge: edge1, table: table, rayDepth: rayDepth)
                                    let cover = near.3 + far.3
                                    guard cover > 0.002 else {
                                        out[row + x] = Self.pack(s0, s1, s2)
                                        continue
                                    }
                                    let r = near.0 + far.0, g = near.1 + far.1, b = near.2 + far.2
                                    if light {
                                        // Laid over as ink, at most most of the way.
                                        let a = min(0.85, cover * 0.8 / (1 + cover * 0.6))
                                        let k = a / cover
                                        out[row + x] = Self.pack(s0 + r * k - s0 * a, s1 + g * k - s1 * a,
                                                                 s2 + b * k - s2 * a)
                                    } else {
                                        // Added as light, eased off as it gathers so the brightest stays coloured
                                        // (1 - e^-x, near enough).
                                        let x2 = 1.6 * cover
                                        let k = (1 - 1 / (1 + x2 + 0.5 * x2 * x2)) / cover
                                        out[row + x] = Self.pack(s0 + r * k, s1 + g * k, s2 + b * k)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return bright
    }

    /// One curtain's light at a pixel in row `fy` of a column, as red, green and blue amounts and how much in all:
    /// up its height from the table, fading fast under its edge.
    @inline(__always)
    private static func light(_ col: Column, fy: Float, base: Int, soft: Float, edge: (Float, Float, Float),
                              table: UnsafeBufferPointer<Float>, rayDepth: UnsafeBufferPointer<Float>)
        -> (Float, Float, Float, Float) {
        let above = (col.edge - fy) * col.inverse
        if above >= 0 {
            guard above < 1 else { return (0, 0, 0, 0) }
            let i = Int(above * Float(profileSteps))
            let t = base + i * 4
            let amount = table[t + 3] * col.light * (1 - col.dip * rayDepth[i])
            return (table[t] * amount, table[t + 1] * amount, table[t + 2] * amount, amount)
        }
        // Under the edge the light falls away within a pixel or two (more on the far curtain).
        let below = (fy - col.edge) * soft
        guard below < 2.5 else { return (0, 0, 0, 0) }
        let b2 = below * below
        let amount = col.light * table[base + 3] / (1 + b2 * (1 + b2))
        return (edge.0 * amount, edge.1 * amount, edge.2 * amount, amount)
    }

    /// The stars, twinkling and dimmed where the aurora shines in front of them, in a few batches of brightness (none
    /// in the light artwork's dusk).
    private func drawStars(_ ctx: CGContext, w: CGFloat, h: CGFloat, style: SceneStyle, cols: Int, rows: Int) {
        guard !style.isLight else { return }
        let unit = w / 92
        let levels = 6
        let colour = RGB(1, 1, 1).mixed(with: style.accent, 0.15)
        starAlpha.removeAll(keepingCapacity: true)
        for (i, star) in stars.enumerated() {
            let col = min(max(Int(star.x * Double(cols)), 0), cols - 1)
            var veil = 0.0
            for c in curtains.indices where fine.count == cols * curtains.count {
                let column = fine[c * cols + col]
                let above = Double((column.edge - Float(star.y * Double(rows))) * column.inverse)
                if above >= 0, above < 1 { veil += Double(column.light) * (1 - above) }
            }
            let flicker = 0.75 + 0.25 * sin(star.phase + twinkle * (0.8 + Double(i % 5) * 0.15))
            starAlpha.append(star.bright * flicker * max(0.15, 1 - 0.8 * veil))
        }
        for level in 0..<levels {
            var any = false
            for (star, alpha) in zip(stars, starAlpha) where min(levels - 1, Int(alpha * Double(levels))) == level {
                let r = star.size * unit
                ctx.addEllipse(in: CGRect(x: star.x * w - r, y: star.y * h - r, width: r * 2, height: r * 2))
                any = true
            }
            if any {
                ctx.setFill(colour, (Double(level) + 0.5) / Double(levels))
                ctx.fillPath()
            }
        }
    }

    /// The far ridge's outline, and the near ridge with its pines (and perhaps a cabin) drawn into a picture, for a
    /// size and style.
    private func makeHills(w: CGFloat, h: CGFloat, scale: CGFloat, paints: Paints)
        -> (colour: RGB, isLight: Bool, width: Int, far: CGPath, near: CGImage?, top: Int) {
        func ridge(_ x: Double, _ p: [Double], base: Double, a: Double, b: Double) -> Double {
            base + a * sin(2 * .pi * 0.8 * x + p[0]) + b * sin(2 * .pi * 1.9 * x + p[1])
                + b * 0.4 * sin(2 * .pi * 4.3 * x + p[2])
        }
        func nearRidge(_ x: Double) -> Double { ridge(x, self.nearRidge, base: 0.875, a: 0.025, b: 0.015) }
        let far = CGMutablePath(), near = CGMutablePath()
        let steps = 46
        far.move(to: CGPoint(x: 0, y: h))
        near.move(to: CGPoint(x: 0, y: h))
        var highest = h
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            far.addLine(to: CGPoint(x: u * w, y: ridge(u, farRidge, base: 0.77, a: 0.035, b: 0.02) * h))
            near.addLine(to: CGPoint(x: u * w, y: nearRidge(u) * h))
            highest = min(highest, nearRidge(u) * h)
        }
        far.addLine(to: CGPoint(x: w, y: h))
        near.addLine(to: CGPoint(x: w, y: h))
        far.closeSubpath()
        near.closeSubpath()
        // Pines: two tiers each, standing on the ridge.
        for tree in trees {
            let foot = nearRidge(tree.x) + 0.015
            let x = tree.x * w, base = foot * h, top = (foot - tree.height) * h, half = tree.width * w / 2
            let tier = top + (base - top) * 0.45
            near.move(to: CGPoint(x: x, y: top))
            near.addLine(to: CGPoint(x: x + half * 0.7, y: tier + (base - top) * 0.12))
            near.addLine(to: CGPoint(x: x + half * 0.38, y: tier + (base - top) * 0.1))
            near.addLine(to: CGPoint(x: x + half, y: base))
            near.addLine(to: CGPoint(x: x - half, y: base))
            near.addLine(to: CGPoint(x: x - half * 0.38, y: tier + (base - top) * 0.1))
            near.addLine(to: CGPoint(x: x - half * 0.7, y: tier + (base - top) * 0.12))
            near.closeSubpath()
            highest = min(highest, top)
        }
        var window: CGRect?
        if let cabin {
            let unit = w / 92
            let foot = (nearRidge(cabin) + 0.012) * h
            let x = cabin * w, half = 4 * unit, wall = 4.5 * unit
            near.move(to: CGPoint(x: x - half, y: foot))
            near.addLine(to: CGPoint(x: x - half, y: foot - wall))
            near.addLine(to: CGPoint(x: x, y: foot - wall - 3.5 * unit))
            near.addLine(to: CGPoint(x: x + half, y: foot - wall))
            near.addLine(to: CGPoint(x: x + half, y: foot))
            near.closeSubpath()
            highest = min(highest, foot - wall - 3.5 * unit)
            // On whole pixels, so the lit window stays a crisp square.
            window = CGRect(x: ((x - unit) * scale).rounded() / scale,
                            y: ((foot - 3.5 * unit) * scale).rounded() / scale, width: 2 * unit, height: 2 * unit)
        }

        // The picture covers the rows from just above the highest tree to the foot.
        let cols = Int((w * scale).rounded()), rows = Int((h * scale).rounded())
        let top = max(0, Int((highest * scale).rounded(.down)) - 1)
        var image: CGImage?
        if rows - top > 0,
           let ctx = CGContext(data: nil, width: cols, height: rows - top, bitsPerComponent: 8, bytesPerRow: 0,
                               space: sceneColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            // Points, from the top left of the whole artwork.
            ctx.translateBy(x: 0, y: CGFloat(rows - top))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: 0, y: -CGFloat(top) / scale)
            ctx.addPath(near)
            ctx.setFill(paints.near)
            ctx.fillPath()
            if let window {
                ctx.setFill(RGB(1, 0.78, 0.42), paints.style.isLight ? 0.9 : 1)
                ctx.fill(window)
            }
            image = ctx.makeImage()
        }
        return (paints.near, paints.style.isLight, cols, far, image, top)
    }

    // MARK: Colours

    /// The sky down the buffer's rows, the aurora's colours up its height, and the hills'.
    private static func paints(_ style: SceneStyle, rows: Int, swapped: Bool) -> Paints {
        let steps = profileSteps
        let light = style.isLight
        // The two aurora colours: on dark artwork, its brightest sparks (one leads each curtain's lower edge, the
        // other tints its top); on light, deeper tints of its accent and sparks.
        var first: RGB, second: RGB
        if light {
            first = style.accent.adjusted(saturation: 1.2, brightness: 0.85)
            second = style.spark(3).adjusted(saturation: 1.1, brightness: 0.8).mixed(with: style.ink, 0.15)
        } else {
            first = style.spark(0).adjusted(saturation: 1.15)
            second = style.spark(2).adjusted(saturation: 1.2)
        }
        if swapped { swap(&first, &second) }
        let skyTop: RGB, skyLow: RGB, far: RGB, near: RGB
        if light {
            skyTop = style.mid.mixed(with: style.accent, 0.15)
            skyLow = style.deep.mixed(with: RGB(1, 0.9, 0.8), 0.35)
            far = style.ink.mixed(with: skyLow, 0.55)
            near = style.ink.scaled(0.8)
        } else {
            skyTop = style.deep.scaled(0.32)
            skyLow = style.deep.mixed(with: style.mid, 0.2).scaled(0.42)
            near = style.deep.scaled(0.1)
            far = near.mixed(with: skyLow, 0.65).mixed(with: first, 0.08)
        }
        var sky: [Float] = []
        var packed: [UInt32] = []
        for y in 0..<rows {
            // Darkest overhead, lightening towards the horizon at about four fifths of the way down.
            let t = min(1, Double(y) / Double(rows) / 0.8)
            let c = skyTop.mixed(with: skyLow, t * t)
            sky += [Float(c.r), Float(c.g), Float(c.b)]
            packed.append(pack(Float(c.r), Float(c.g), Float(c.b)))
        }
        var table = [Float](repeating: 0, count: 2 * steps * 4), rayDepth: [Float] = []
        for i in 0..<steps {
            let v = (Double(i) + 0.5) / Double(steps)
            rayDepth.append(Float(min(1, 0.25 + 1.1 * v.squareRoot())))
            let up = pow(v, 0.8)
            for (c, colours) in [(first, second), (second, first)].enumerated() {
                // Whiter just above the near curtain's edge, the lead colour through the body, the other at the top.
                var tint = colours.0.mixed(with: colours.1, up)
                if !light, c == 0 { tint = tint.mixed(with: .white, 0.22 * max(0, 1 - v / 0.1)) }
                // Bright at the lower edge, a long glow above it, fading out at the top; the far curtain is a softer
                // glow, less sharply lit at its edge.
                let profile = c == 0 ? pow(1 - v, 1.4) * (0.32 + 0.68 * exp(-v * 5))
                    : pow(1 - v, 1.2) * (0.5 + 0.5 * exp(-v * 3))
                let t = (c * steps + i) * 4
                table[t] = Float(tint.r)
                table[t + 1] = Float(tint.g)
                table[t + 2] = Float(tint.b)
                table[t + 3] = Float(profile)
            }
        }
        let lower = light ? first : first.mixed(with: .white, 0.2)
        let edge = [lower, second].flatMap { [Float($0.r), Float($0.g), Float($0.b)] }
        return Paints(style: style, rows: rows, sky: sky, skyPacked: packed, table: table, rayDepth: rayDepth,
                      edge: edge, far: far, near: near, glowTint: first)
    }

    // MARK: Pixels

    /// An opaque pixel from components 0...1 (bytes R, G, B, A in memory).
    private static func pack(_ r: Float, _ g: Float, _ b: Float) -> UInt32 {
        func byte(_ v: Float) -> UInt32 { UInt32(min(max(v, 0), 1) * 255 + 0.5) }
        return byte(r) | byte(g) << 8 | byte(b) << 16 | 0xFF00_0000
    }

    private static func image(_ pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: sceneColorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// 0 below `lo`, 1 above `hi`, smooth between.
nonisolated private func smoothstep(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
    let t = min(max((x - lo) / (hi - lo), 0), 1)
    return t * t * (3 - 2 * t)
}
