// SPDX-License-Identifier: GPL-3.0-or-later
// Starfield: flying through space. Stars stream out from a vanishing point that wanders and banks slowly, drawn as
// streaks that stretch with the speed; the speed rides the music's level and surges on every kick. Near stars are
// bigger and brighter, and a few are tinted with the artwork's spark colours. In silence the flight stops: a still,
// calm field of stars.

import CoreGraphics

nonisolated final class StarfieldScene: VisualizerScene {
    /// A star in space: `x` and `y` are where it sits across the view at depth 1 (the view spans -1...1 there), `z`
    /// how far away it is (1 the far end, 0 the eye).
    private struct Star {
        var x: Double
        var y: Double
        var z: Double
        /// -1 for the ink, otherwise a spark colour.
        var tint: Int
        /// Seconds since it appeared, for a fade-in.
        var age: Double
    }

    private static let count = 130
    private static let nearest = 0.045
    /// How far behind a star its streak starts, in seconds of flight.
    private static let streak = 0.085
    /// Shapes per fill: Core Graphics slows down sharply as one path gathers many shapes, so batches are filled in
    /// runs of this many.
    private static let chunk = 20

    private var stars: [Star] = []
    private var random: SceneRandom
    /// Depth flown per second.
    private var speed = 0.0
    /// Depth flown so far: the wander and the banking follow it, so they stop when the flight does.
    private var travel = 0.0
    /// 0 in silence, 1 while music plays.
    private var activity = 0.0
    private var flash = 0.0

    // Scratch space for drawing, kept between frames.
    private var order: [Int] = []
    private var keys: [Int] = []
    private var rects: [CGRect] = []

    var glow: Double { 0.85 }

    init(seed: UInt64) {
        random = SceneRandom(seed: seed)
        stars.reserveCapacity(Self.count)
        for _ in 0..<Self.count {
            // Spread through the whole depth at first, more of them far away.
            let u = random.next()
            stars.append(spawn(z: 1 - 0.9 * u * u, settled: true))
        }
        order = Array(0..<Self.count)
        keys = [Int](repeating: 0, count: Self.count)
    }

    /// Where the vanishing point is (0...1 across the view) and how far the view has banked, for the flight so far.
    private var view: (x: Double, y: Double, roll: Double) {
        let t = travel * 0.55
        let x = 0.5 + 0.12 * sin(t * 1.0 + 0.4) + 0.05 * sin(t * 2.3 + 1.0)
        let y = 0.5 + 0.10 * sin(t * 0.8 + 1.7) + 0.04 * sin(t * 1.9 + 0.5)
        return (x, y, 0.32 * sin(t * 0.45 + 0.9))
    }

    /// A new star somewhere across the view at depth `z`.
    private func spawn(z: Double, settled: Bool = false) -> Star {
        let v = view
        // Pick where it shows on screen, then put it at that depth behind that point.
        let dx = (random.range(-0.06, 1.06) - v.x) * 2 * z
        let dy = (random.range(-0.06, 1.06) - v.y) * 2 * z
        let c = cos(v.roll), s = sin(v.roll)
        let tint = random.chance(0.2) ? random.int(4) : -1
        return Star(x: dx * c + dy * s, y: -dx * s + dy * c, z: z, tint: tint, age: settled ? 10 : 0)
    }

    func update(_ input: VisualizerInput, dt: Double) {
        let level = Double(input.level), bass = Double(input.bass), pulse = Double(input.pulse)
        let target = smoothstep(0.02, 0.1, level)
        activity += (target - activity) * (1 - exp(-dt / (target > activity ? 0.1 : 0.08)))

        // Cruise on the level and bass; a kick kicks the speed up and it eases back over half a second.
        let cruise = 0.07 + 0.38 * level + 0.12 * bass
        let wanted = activity * (cruise + 1.5 * pulse * pulse * (0.5 + 0.5 * bass))
        let rate = wanted > speed ? 0.05 : (activity > 0.5 ? 0.28 : 0.09)
        speed += (wanted - speed) * (1 - exp(-dt / rate))
        if speed < 1e-4 { speed = 0 }
        flash = max(flash * exp(-dt * 6), input.beat ? 1 : 0) * activity
        travel += speed * dt

        let v = view
        let c = cos(v.roll), s = sin(v.roll)
        for i in stars.indices {
            stars[i].z -= speed * dt
            stars[i].age += dt
            let star = stars[i]
            // Off the edge or past the eye: a new one at the far end.
            let rx = star.x * c - star.y * s, ry = star.x * s + star.y * c
            let sx = v.x + rx / max(star.z, 1e-3) * 0.5, sy = v.y + ry / max(star.z, 1e-3) * 0.5
            if star.z < Self.nearest || sx < -0.1 || sx > 1.1 || sy < -0.1 || sy > 1.1 {
                stars[i] = spawn(z: random.range(0.8, 1))
            }
        }
    }

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let v = view
        let c = cos(v.roll), s = sin(v.roll)
        let w = size.width, h = size.height
        let unit = min(w, h) / 92
        let vp = CGPoint(x: v.x * w, y: v.y * h)

        // A faint light at the far end, brightening on the kicks (dark artwork only: no glare on light).
        if !style.isLight, activity > 0.01 {
            let alpha = (0.08 + 0.1 * flash) * activity
            ctx.fillGlow(at: vp, radius: w * (0.22 + 0.05 * flash), color: style.spark(0).mixed(with: .white, 0.5),
                         alpha: alpha)
        }

        // Colours: the ink and four tints; on light artwork a little deeper so they read on the pale ground.
        let tintMix = style.isLight ? 0.0 : 0.3
        func colour(_ tint: Int) -> RGB {
            if tint < 0 { return style.ink }
            let spark = style.spark(tint)
            return style.isLight ? spark.scaled(0.82) : spark.mixed(with: .white, tintMix)
        }

        // Sort the stars into batches of one colour and one brightness.
        let levels = 8
        let lag = speed * Self.streak
        for i in stars.indices {
            let star = stars[i]
            let alpha = starAlpha(star)
            let level = alpha <= 0.02 ? -1 : min(levels - 1, Int(alpha * Double(levels)))
            keys[i] = level < 0 ? -1 : (star.tint + 1) * levels + level
        }
        order.sort { keys[$0] < keys[$1] }

        var start = 0
        while start < order.count {
            let key = keys[order[start]]
            var end = start
            while end < order.count, keys[order[end]] == key { end += 1 }
            defer { start = end }
            guard key >= 0 else { continue }
            let tint = key / levels - 1, level = key % levels
            ctx.setFill(colour(tint), min(1, (Double(level) + 0.5) / Double(levels)))
            rects.removeAll(keepingCapacity: true)
            var shapes = 0
            for k in start..<end {
                let star = stars[order[k]]
                let near = 1 - star.z
                let r = CGFloat(0.62 + 1.05 * pow(near, 1.6)) * unit
                let head = project(star.x, star.y, star.z, c, s, vp, w, h)
                let tail = project(star.x, star.y, min(star.z + lag, 1.6), c, s, vp, w, h)
                let dx = head.x - tail.x, dy = head.y - tail.y
                let length = (dx * dx + dy * dy).squareRoot()
                if length > r * 0.8 {
                    addComet(ctx, head: head, tail: tail, length: length, radius: max(r * 0.82, 0.62 * unit))
                } else if r < 0.78 {
                    let side = r * 1.77
                    rects.append(CGRect(x: head.x - side / 2, y: head.y - side / 2, width: side, height: side))
                    continue
                } else {
                    addDot(ctx, head, r)
                }
                shapes += 1
                if shapes == Self.chunk {
                    ctx.fillPath()
                    shapes = 0
                }
            }
            if shapes > 0 { ctx.fillPath() }
            if !rects.isEmpty { ctx.fill(rects) }
        }
    }

    /// How bright a star shows: faint far off, full close by, fading in when new and lifted by a kick.
    private func starAlpha(_ star: Star) -> Double {
        let near = 1 - star.z
        let fade = min(1, star.age / 0.35)
        return min(1, fade * (0.36 + 0.64 * pow(max(near, 0), 1.2)) * (1 + 0.35 * flash))
    }

    private func project(_ x: Double, _ y: Double, _ z: Double, _ c: Double, _ s: Double, _ vp: CGPoint,
                         _ w: CGFloat, _ h: CGFloat) -> CGPoint {
        let k = 0.5 / max(z, 1e-3)
        return CGPoint(x: vp.x + CGFloat((x * c - y * s) * k) * w, y: vp.y + CGFloat((x * s + y * c) * k) * h)
    }
}

/// 0 below `lo`, 1 above `hi`, smooth between.
nonisolated private func smoothstep(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
    let t = min(max((x - lo) / (hi - lo), 0), 1)
    return t * t * (3 - 2 * t)
}

/// A streak: a sharp tail widening to a round head, added to the context's path.
nonisolated private func addComet(_ ctx: CGContext, head: CGPoint, tail: CGPoint, length: CGFloat, radius r: CGFloat) {
    let ux = (head.x - tail.x) / length, uy = (head.y - tail.y) / length
    let nx = -uy * r, ny = ux * r
    let d = 0.7071 as CGFloat
    ctx.move(to: tail)
    ctx.addLine(to: CGPoint(x: head.x + nx, y: head.y + ny))
    ctx.addLine(to: CGPoint(x: head.x + (nx + ux * r) * d, y: head.y + (ny + uy * r) * d))
    ctx.addLine(to: CGPoint(x: head.x + ux * r, y: head.y + uy * r))
    ctx.addLine(to: CGPoint(x: head.x + (ux * r - nx) * d, y: head.y + (uy * r - ny) * d))
    ctx.addLine(to: CGPoint(x: head.x - nx, y: head.y - ny))
    ctx.closePath()
}

/// A round dot (an octagon: round enough at this size, and cheap), added to the context's path.
nonisolated private func addDot(_ ctx: CGContext, _ p: CGPoint, _ r: CGFloat) {
    let a = r * 0.9239, b = r * 0.3827
    ctx.move(to: CGPoint(x: p.x + a, y: p.y + b))
    ctx.addLine(to: CGPoint(x: p.x + b, y: p.y + a))
    ctx.addLine(to: CGPoint(x: p.x - b, y: p.y + a))
    ctx.addLine(to: CGPoint(x: p.x - a, y: p.y + b))
    ctx.addLine(to: CGPoint(x: p.x - a, y: p.y - b))
    ctx.addLine(to: CGPoint(x: p.x - b, y: p.y - a))
    ctx.addLine(to: CGPoint(x: p.x + b, y: p.y - a))
    ctx.addLine(to: CGPoint(x: p.x + a, y: p.y - b))
    ctx.closePath()
}
