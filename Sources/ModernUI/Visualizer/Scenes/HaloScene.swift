// SPDX-License-Identifier: GPL-3.0-or-later
// Halo: the spectrum as spokes around a ring, the lows at the foot and the highs at the crown, mirrored left and
// right, the whole figure turning slowly. The ring breathes with the bass over a soft glow, a peak dot rides out on
// each spoke, and every kick sends a shockwave rolling out from the ring.

import CoreGraphics
import Foundation

nonisolated final class HaloScene: VisualizerScene {
    /// Spokes on each side; the other side mirrors them.
    private static let half = 30
    private static let sides: [Double] = [1, -1]
    private static let waveLife = 0.75

    private var lengths = [Float](repeating: 0, count: half)
    private var targets = [Float](repeating: 0, count: half)
    private var caps = [Float](repeating: 0, count: half)
    private var capFalls = [Float](repeating: 0, count: half)
    private var angle: Double
    private let spin: Double
    private var bass: Float = 0
    private var level: Float = 0
    private var pulse: Float = 0
    /// The shockwaves rolling out, by age in seconds.
    private var waves: [Double] = []
    /// The colours for a style: the glow inside the ring, and the spokes' roots and tips.
    private var paints: (style: SceneStyle, disc: CGGradient?, root: RGB, tip: RGB)?
    /// Spoke segments, kept between frames.
    private var roots: [CGPoint] = []
    private var tips: [CGPoint] = []

    init(seed: UInt64) {
        var random = SceneRandom(seed: seed)
        angle = random.range(-0.4, 0.4)
        spin = random.chance(0.5) ? 1 : -1
    }

    var glow: Double { 0.8 }

    func update(_ input: VisualizerInput, dt: Double) {
        let rise = Float(1 - pow(0.35, dt * 60)), fall = Float(1 - pow(0.86, dt * 60))
        // Spoke 0 is at the crown with the highs; the lows are at the foot. Neighbours are blended a little so the
        // outline flows.
        for i in 0..<Self.half {
            let f = 1 - (Double(i) + 0.5) / Double(Self.half)
            let d = 0.5 / Double(Self.half)
            let raw = input.band(at: f) * 0.5 + (input.band(at: f - d) + input.band(at: f + d)) * 0.25
            targets[i] = min(max((raw + 0.08 * Float(f) - 0.14) / 0.82, 0), 1)
        }
        for i in 0..<Self.half {
            let v = targets[i]
            lengths[i] += (v - lengths[i]) * (v > lengths[i] ? rise : fall)
            if lengths[i] >= caps[i] {
                caps[i] = lengths[i]
                capFalls[i] = 0
            } else {
                capFalls[i] += Float(dt) * 1.6
                caps[i] = max(lengths[i], caps[i] - capFalls[i] * Float(dt))
            }
        }
        let follow = Float(1 - pow(0.8, dt * 60))
        bass += (input.bass - bass) * follow
        level += (input.level - level) * follow
        pulse = input.pulse
        // Turns faster when the music is loud, and stops in silence.
        angle += dt * spin * (0.05 + 0.3 * Double(level)) * Double(min(level * 12, 1))
        for i in waves.indices { waves[i] += dt }
        waves.removeAll { $0 >= Self.waveLife }
        if input.beat { waves.append(0) }
    }

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let u = size.width / 92
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        // 0 in silence, 1 once anything is sounding.
        let sounding = CGFloat(min(level * 8, 1))
        let ring = u * (13.5 + 3.5 * CGFloat(bass) + 1.6 * CGFloat(pulse))
        let inner = ring + 2.6 * u
        let reach = 21 * u
        if paints == nil || paints?.style != style {
            paints = (style, Self.disc(style), style.ink, style.isLight ? style.accent : style.spark(0).mixed(with: style.ink, 0.15))
        }
        guard let paints else { return }

        // The soft light inside the ring.
        if let disc = paints.disc, sounding > 0 {
            ctx.saveGState()
            ctx.setAlpha(Double(sounding) * (0.45 + 0.4 * Double(pulse)))
            ctx.drawRadialGradient(disc, startCenter: c, startRadius: 0, endCenter: c, endRadius: ring * 1.05, options: [])
            ctx.restoreGState()
        }

        // Spokes: a root in the ink and a wider tip in the artwork's colour, each side drawn in one go.
        roots.removeAll(keepingCapacity: true)
        tips.removeAll(keepingCapacity: true)
        let dots = CGMutablePath()
        let step = Double.pi / Double(Self.half)
        for i in 0..<Self.half {
            let len = CGFloat(lengths[i]) * reach
            let cap = CGFloat(caps[i]) * reach
            for side in Self.sides {
                let a = angle + side * (Double(i) + 0.5) * step
                let dx = CGFloat(sin(a)), dy = CGFloat(-cos(a))
                func point(_ r: CGFloat) -> CGPoint { CGPoint(x: c.x + dx * r, y: c.y + dy * r) }
                if len > 0.6 * u {
                    let knee = inner + len * 0.58
                    roots.append(point(inner))
                    roots.append(point(knee))
                    tips.append(point(knee))
                    tips.append(point(inner + len))
                }
                if cap > len + 1.5 * u {
                    let p = point(inner + cap + 1.3 * u)
                    dots.addEllipse(in: CGRect(x: p.x - 0.85 * u, y: p.y - 0.85 * u, width: 1.7 * u, height: 1.7 * u))
                }
            }
        }
        if !roots.isEmpty {
            ctx.saveGState()
            ctx.setLineCap(.butt)
            ctx.setStroke(paints.root, 0.92)
            ctx.setLineWidth(1.1 * u)
            ctx.strokeLineSegments(between: roots)
            ctx.setStroke(paints.tip, 0.9)
            ctx.setLineWidth(1.5 * u)
            ctx.strokeLineSegments(between: tips)
            ctx.restoreGState()
        }
        if !dots.isEmpty {
            ctx.addPath(dots)
            ctx.setFill(style.isLight ? style.ink : style.accent.mixed(with: .white, 0.4), 0.9)
            ctx.fillPath()
        }

        // Shockwaves: a ring rolling out from each kick, thinning as it fades.
        for age in waves {
            let t = age / Self.waveLife
            let ease = 1 - pow(1 - t, 3)
            let r = ring + (inner + reach + 4 * u - ring) * CGFloat(ease)
            ctx.setStroke(style.isLight ? style.ink : style.accent.mixed(with: .white, 0.3), 0.75 * pow(1 - t, 1.6))
            ctx.setLineWidth(u * CGFloat(2.4 - 1.4 * t))
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }

        // The ring itself: thin and calm in silence, bolder on a kick.
        ctx.setStroke(style.ink, 0.55 + 0.4 * Double(sounding))
        ctx.setLineWidth(u * (1.1 + 0.7 * sounding + 1.0 * CGFloat(pulse)))
        ctx.strokeEllipse(in: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2))
    }

    /// The soft light inside the ring.
    private static func disc(_ style: SceneStyle) -> CGGradient? {
        let light = style.isLight ? style.accent : style.accent.mixed(with: .white, 0.3)
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [light.cgColor(alpha: style.isLight ? 0.22 : 0.5), light.cgColor(alpha: style.isLight ? 0.1 : 0.2),
                                   light.cgColor(alpha: 0)] as CFArray, locations: [0, 0.6, 1])
    }
}
