// SPDX-License-Identifier: GPL-3.0-or-later
// Tunnel: rings set off from the far end of a tunnel on every beat and kick, and rush outwards past the viewer,
// faster and faster as they come close. Each ring keeps the shape of the spectrum from the moment it set off, bulging
// around its rim (treble at the top, bass at the bottom, mirrored left and right), so the music's recent past streams
// by. Rings are thicker for a heavy bass, brighter for a loud passage, and walk through the artwork's spark colours.
// The far end drifts gently. In silence the rings stop where they are and fade to a few faint outlines.

import CoreGraphics

nonisolated final class TunnelScene: VisualizerScene {
    private struct Ring {
        /// How far along the tunnel it is: 0 at the far end, 1 gone past the viewer.
        var travel: Double
        /// The spectrum when it set off, from the top of the ring (treble) to the bottom (bass), 0...1.
        var shape: [Double]
        /// Where it is along the walk through the spark colours.
        var hue: Double
        /// Thickness (from the bass) and brightness (from the level), 0...1.
        var weight: Double
        var bright: Double
        /// 1 for a ring a kick set off: brighter and bolder.
        var kick: Double
    }

    /// Samples around half a ring's rim, top to bottom.
    private static let shapeCount = 19
    /// Points around a whole ring, at most.
    private static let rimCount = 48
    private static let rim: [(cos: Double, sin: Double)] = (0..<rimCount).map { i in
        let angle = Double(i) / Double(rimCount) * 2 * Double.pi
        return (cos(angle), sin(angle))
    }

    private var rings: [Ring] = []
    private var activity = 0.0
    private var pulse = 0.0
    private var lastGroove = 0.0
    private var sinceRing = 10.0
    private var ringCount = 0
    /// The far end's wandering, in radians of its slow orbit.
    private var drift = 0.0
    /// How far along the spark colours each new ring steps (one way or the other, by the seed).
    private var hueStep: Double
    private var outer: [CGPoint] = []
    private var inner: [CGPoint] = []

    var glow: Double { 0.75 }

    init(seed: UInt64) {
        var random = SceneRandom(seed: seed)
        drift = random.range(0, 2 * Double.pi)
        hueStep = random.chance(0.5) ? 0.42 : -0.42
        ringCount = random.int(8)
        // A few rings waiting in the tunnel, so silence shows it.
        for travel in [0.2, 0.4, 0.58, 0.74, 0.88] {
            emit(shape: [Double](repeating: 0, count: Self.shapeCount), weight: 0.15, bright: 0.5, kick: 0, travel: travel)
        }
        outer.reserveCapacity(Self.rimCount)
        inner.reserveCapacity(Self.rimCount)
    }

    private func emit(shape: [Double], weight: Double, bright: Double, kick: Double, travel: Double = 0) {
        ringCount += 1
        rings.append(Ring(travel: travel, shape: shape, hue: Double(ringCount) * hueStep, weight: weight, bright: bright,
                          kick: kick))
        sinceRing = 0
    }

    /// The spectrum now, sampled down half a ring's rim and smoothed a little.
    private func shape(of input: VisualizerInput) -> [Double] {
        let raw = (0..<Self.shapeCount).map { i in
            Double(input.band(at: 1 - Double(i) / Double(Self.shapeCount - 1)))
        }
        return raw.indices.map { i in
            let a = raw[max(i - 1, 0)], b = raw[i], c = raw[min(i + 1, raw.count - 1)]
            return (a + 4 * b + c) / 6
        }
    }

    func update(_ input: VisualizerInput, dt: Double) {
        let level = Double(input.level), bass = Double(input.bass)
        let target = smoothstep(0.02, 0.1, level)
        activity += (target - activity) * (1 - exp(-dt / (target > activity ? 0.1 : 0.08)))
        pulse = Double(input.pulse) * activity
        sinceRing += dt

        // Each ring takes five or six beats to pass, a little quicker when loud, surging on a kick.
        let beat = min(max(input.beatInterval, 0.3), 1)
        let speed = activity / (5.5 * beat) * (0.8 + 0.4 * level) * (1 + 0.9 * pulse)
        for i in rings.indices { rings[i].travel += speed * dt }
        rings.removeAll { $0.travel >= 1 }
        drift += dt * (0.35 + 0.6 * level) * activity

        // A ring on every beat of the clock, one for each kick between them, and a fainter one on the off-beat.
        let groove = input.groove
        let downbeat = groove < lastGroove - 0.5
        let offbeat = lastGroove < 0.5 && groove >= 0.5
        lastGroove = groove
        guard activity > 0.5, rings.count < 16 else { return }
        if input.beat {
            if sinceRing < 0.15, !rings.isEmpty {
                // The kick landed with the beat's ring: that ring takes it.
                let last = rings.count - 1
                rings[last].kick = 1
                rings[last].weight = max(rings[last].weight, bass)
                rings[last].shape = shape(of: input)
            } else {
                emit(shape: shape(of: input), weight: bass, bright: 0.55 + 0.45 * level, kick: 1)
            }
        } else if downbeat, sinceRing > 0.2 {
            emit(shape: shape(of: input), weight: bass * 0.8, bright: 0.45 + 0.45 * level, kick: 0)
        } else if offbeat, sinceRing > 0.2, level > 0.25 {
            emit(shape: shape(of: input), weight: bass * 0.45, bright: 0.3 + 0.35 * level, kick: 0)
        }
    }

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let w = size.width, h = size.height
        let unit = min(w, h) / 92
        let centre = CGPoint(x: w / 2, y: h / 2)
        // The far end wanders round a small loop.
        let far = CGPoint(x: centre.x + CGFloat(0.11 * sin(drift) + 0.03 * sin(drift * 2.7 + 1)) * w,
                          y: centre.y + CGFloat(0.09 * sin(drift * 0.73 + 1.4) + 0.025 * sin(drift * 2.1)) * h)

        // Light at the end of the tunnel (on light artwork, a soft shade instead: no glare).
        if activity > 0.01 {
            if style.isLight {
                ctx.fillGlow(at: far, radius: w * 0.2, color: style.ink, alpha: (0.07 + 0.08 * pulse) * activity)
            } else {
                let colour = colourAt(Double(ringCount) * hueStep, style).mixed(with: .white, 0.5)
                ctx.fillGlow(at: far, radius: w * (0.2 + 0.06 * pulse), color: colour,
                             alpha: (0.14 + 0.26 * pulse) * activity)
            }
        }

        let maxRadius = 0.76 * Double(max(w, h))
        let fadeQuiet = 0.3 + 0.7 * activity
        for ring in rings {
            let u = ring.travel
            // Perspective, roughly: slow far away, rushing past up close.
            let r = (0.012 + 0.988 * pow(u, 2.3)) * maxRadius
            let along = pow(1 - u, 2)
            let c = CGPoint(x: centre.x + (far.x - centre.x) * along, y: centre.y + (far.y - centre.y) * along)
            // Every ring throbs a little on a kick.
            let heft = 0.45 + 2.6 * pow(ring.weight, 1.4) + 0.8 * ring.kick
            let width = max(1.0, heft * (0.25 + 1.25 * u) * (1 + 0.3 * pulse) * Double(unit))
            let fadeIn = smoothstep(0, 0.22, u), fadeOut = 1 - smoothstep(0.82, 1, u)
            let alpha = min(1, ring.bright * (1 + 0.25 * ring.kick + 0.35 * pulse) * fadeIn * fadeOut * fadeQuiet)
            guard alpha > 0.01, r > 0.5 else { continue }

            // Fewer points on small rings: they're too small to show the difference.
            let stride = r < 7 ? 2 : 1
            let n = Self.rimCount / stride
            outer.removeAll(keepingCapacity: true)
            inner.removeAll(keepingCapacity: true)
            // Bulging outwards where the ring's spectrum stood above its own average.
            let bulge = 0.5 * (0.4 + 0.6 * activity)
            let mean = ring.shape.reduce(0, +) / Double(ring.shape.count)
            for k in 0..<n {
                let j = k * stride
                let (cs, sn) = Self.rim[j]
                // j = 0 is the top of the ring; down either side to the bottom at the middle.
                let f = Double(j <= Self.rimCount / 2 ? j : Self.rimCount - j) / Double(Self.rimCount / 2)
                // Eased so the two mirrored halves meet level at the top and bottom, with no point.
                let rr = r * (0.94 + bulge * (sample(ring.shape, (1 - cos(Double.pi * f)) / 2) - 0.6 * mean))
                let x = Double(c.x) + sn * rr, y = Double(c.y) - cs * rr
                let hw = width / 2
                outer.append(CGPoint(x: x + sn * hw, y: y - cs * hw))
                inner.append(CGPoint(x: x - sn * hw, y: y + cs * hw))
            }
            var colour = colourAt(ring.hue, style)
            if !style.isLight { colour = colour.mixed(with: .white, 0.3 * ring.kick) }
            ctx.setFill(colour, alpha)
            ctx.addLines(between: outer)
            ctx.closePath()
            ctx.addLines(between: inner)
            ctx.closePath()
            ctx.fillPath(using: .evenOdd)
        }
    }

    /// The colour `hue` of the way along the sparks (wrapping), blending between neighbours.
    private func colourAt(_ hue: Double, _ style: SceneStyle) -> RGB {
        let base = hue.rounded(.down)
        let i = Int(base)
        let colour = style.spark(i).mixed(with: style.spark(i + 1), hue - base)
        return style.isLight ? colour.scaled(0.85) : colour
    }

    /// The shape's value `f` of the way from top to bottom, interpolated.
    private func sample(_ shape: [Double], _ f: Double) -> Double {
        let x = min(max(f, 0), 1) * Double(shape.count - 1)
        let i = min(Int(x), shape.count - 2)
        let t = x - Double(i)
        return shape[i] + (shape[i + 1] - shape[i]) * t
    }
}

/// 0 below `lo`, 1 above `hi`, smooth between.
nonisolated private func smoothstep(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
    let t = min(max((x - lo) / (hi - lo), 0), 1)
    return t * t * (3 - 2 * t)
}
