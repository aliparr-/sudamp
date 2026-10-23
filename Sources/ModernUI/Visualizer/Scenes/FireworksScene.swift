// SPDX-License-Identifier: GPL-3.0-or-later
// Fireworks: a rocket climbs from the bottom on every kick and bursts on the next beat into a shell of sparks in one
// of the artwork's colours (a peony, a ring or a drooping willow), which fall and fade with fading trails and crackle
// with the treble. When the bass comes back after a quiet stretch, the drop gets a salvo of big shells. Without kicks
// a smaller rocket goes up every other beat, and in silence the sky calms to a night of faint stars and embers.

import CoreGraphics

nonisolated final class FireworksScene: VisualizerScene {
    /// A spark, in the unit square (y down).
    private struct Particle {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        /// The trail's far end, following the spark.
        var lagX: Double
        var lagY: Double
        var age = 0.0
        var life: Double
        /// A spark colour, or -1 for the ink.
        var colour: Int
        /// Radius in points (at 92 points across).
        var size: Double
        var drag: Double
        var gravity: Double
        /// How long the trail takes to catch up, in seconds.
        var trail: Double
        /// This frame's crackle, 0...1.
        var twinkle = 1.0
        /// An ember of the calm night: lives on in silence.
        var ember = false
    }

    private struct Rocket {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var gravity: Double
        var lagX: Double
        var lagY: Double
        var age = 0.0
        var flight: Double
        var colour: Int
        var big: Bool
        var shed = 0.0
    }

    private struct Flash {
        var x: Double
        var y: Double
        var colour: Int
        var size: Double
        var age = 0.0
    }

    private struct SkyStar {
        var x: Double
        var y: Double
        var size: Double
        var bright: Double
        var phase: Double
        /// One of the few bright ones, with a little four-pointed sparkle.
        var sparkle: Bool
    }

    /// What gets drawn this frame: a spark's head, the end of its trail, its radius and its batch.
    private struct Sprite {
        var head: CGPoint
        var tail: CGPoint
        var radius: CGFloat
        var key: Int
        /// Drawn as a plain square: a fresh spark still bunched with the rest of its shell, where a pile of
        /// overlapping round shapes would cost far more to fill.
        var square = false
    }

    private static let maxParticles = 300
    private static let embers = 10
    private static let levels = 8
    /// Colour slots: the ink, four spark colours, then the same four paler for embers.
    private static let slots = 9
    /// Shapes per fill: Core Graphics slows down sharply as one path gathers many shapes, so batches are filled in
    /// runs of this many (300 sparks in one fill cost four times as much as in runs of 20).
    private static let chunk = 20

    private var particles: [Particle] = []
    private var rockets: [Rocket] = []
    private var flashes: [Flash] = []
    private var sky: [SkyStar] = []
    /// Where the calm night's embers drift, like the last of two shells.
    private var clusters: [(x: Double, y: Double)] = []
    private var random: SceneRandom
    private var activity = 0.0
    private var treble = 0.0
    private var lastGroove = 0.0
    private var beatCount = 0
    private var sinceKick = 10.0
    private var sinceLaunch = 10.0
    private var lastSide = 0.5
    private var nextColour: Int
    /// The bass's floor over the last half second (the lowest it dipped), in five bins of a tenth of a second.
    private var floorBins = [Double](repeating: 0, count: 5)
    private var floorBin = 1.0
    private var floorClock = 0.0
    private var floorIndex = 0
    /// The floor the music usually keeps, falling slowly.
    private var heldFloor = 0.0
    /// Seconds the bass has stayed well under its usual floor.
    private var lull = 0.0
    /// Seconds left of a drop's finale: shells burst big.
    private var finale = 0.0

    private var sprites: [Sprite] = []
    private var sorted: [Sprite] = []
    private var counts: [Int] = []
    private var rects: [CGRect] = []

    var glow: Double { 1 }

    init(seed: UInt64) {
        random = SceneRandom(seed: seed)
        nextColour = random.int(4)
        while sky.count < 18 {
            let x = random.range(0.05, 0.95), y = random.range(0.04, 0.62)
            // Clear of the window's buttons at the top left.
            if x < 0.32, y < 0.18 { continue }
            let sparkle = sky.count < 2
            let bright = sparkle ? random.range(0.6, 0.75) : random.range(0.2, 0.42)
            let phase = random.range(0, 2 * Double.pi)
            sky.append(SkyStar(x: x, y: y, size: random.range(0.6, 0.78), bright: bright, phase: phase, sparkle: sparkle))
        }
        let left = random.chance(0.5)
        clusters = [(left ? 0.34 : 0.66, random.range(0.42, 0.5)), (left ? 0.64 : 0.36, random.range(0.58, 0.66))]
        particles.reserveCapacity(Self.maxParticles)
        sprites.reserveCapacity(Self.maxParticles + 8)
        sorted.reserveCapacity(Self.maxParticles + 8)
        counts = [Int](repeating: 0, count: Self.slots * Self.levels + 1)
        for _ in 0..<Self.embers { addEmber(settled: true) }
    }

    // MARK: Update

    func update(_ input: VisualizerInput, dt: Double) {
        let level = Double(input.level), bass = Double(input.bass)
        let target = smoothstep(0.02, 0.1, level)
        activity += (target - activity) * (1 - exp(-dt / (target > activity ? 0.1 : 0.08)))
        treble += (Double(input.treble) - treble) * (1 - exp(-dt / 0.08))
        let calm = activity < 0.3
        sinceKick = input.beat ? 0 : sinceKick + dt
        sinceLaunch += dt
        finale = max(0, finale - dt)

        // A drop: the bass floor comes back up after staying well below its usual level for a while.
        trackFloor(bass, dt: dt)
        let floor = min(floorBins.min() ?? 0, floorBin)
        heldFloor = max(floor, heldFloor - dt * 0.01)
        var drop = false
        if floor < heldFloor * 0.8 {
            lull += dt
        } else if lull > 0, floor >= heldFloor * 0.9 {
            drop = lull > 1.5 && activity > 0.5
            lull = 0
        }

        // Rockets: one on each kick; through a stretch without kicks, a smaller one every other beat.
        let groove = input.groove
        let downbeat = groove < lastGroove - 0.5
        lastGroove = groove
        if downbeat { beatCount += 1 }
        let untilBeat = (1 - groove) * input.beatInterval
        if !calm {
            if drop {
                finale = 1.6
                for x in [0.24, 0.5, 0.76] {
                    let place = x + random.range(-0.04, 0.04)
                    launch(untilBeat: untilBeat, beat: input.beatInterval, big: true, bass: bass, at: place)
                }
            } else if input.beat, sinceLaunch > 0.2 {
                launch(untilBeat: untilBeat, beat: input.beatInterval, big: finale > 0, bass: bass)
            } else if downbeat, sinceKick > 1.5, beatCount % 2 == 0, level > 0.12 {
                launch(untilBeat: input.beatInterval, beat: input.beatInterval, big: false, bass: bass * 0.6)
            }
        }

        updateRockets(dt: dt, calm: calm, bass: bass)
        updateParticles(dt: dt, calm: calm)
        for i in flashes.indices { flashes[i].age += dt }
        flashes.removeAll { $0.age > 0.35 }

        // The calm night keeps a few embers drifting down.
        if calm {
            var embers = 0
            for p in particles where p.ember { embers += 1 }
            if embers < Self.embers { addEmber(settled: false) }
        }
        // Stars twinkle faster with the treble (and hold still in silence).
        let rate = (0.8 + 7 * treble) * activity
        for i in sky.indices { sky[i].phase += dt * rate * (0.7 + 0.6 * Double(i % 5) / 4) }
    }

    private func trackFloor(_ bass: Double, dt: Double) {
        floorBin = min(floorBin, bass)
        floorClock += dt
        if floorClock >= 0.1 {
            floorBins[floorIndex] = floorBin
            floorIndex = (floorIndex + 1) % floorBins.count
            floorBin = 1
            floorClock = 0
        }
    }

    /// Sends up a rocket to burst on a beat: the next one if there's time to climb, else the one after.
    private func launch(untilBeat: Double, beat: Double, big: Bool, bass: Double, at place: Double? = nil) {
        sinceLaunch = 0
        var flight = untilBeat
        while flight < 0.38 { flight += max(beat, 0.3) }
        flight = min(flight, 1.1) + random.range(-0.02, 0.02)
        // Bursts alternate sides, kept clear of the window's buttons at the top left.
        let x = place ?? (lastSide < 0.5 ? random.range(0.52, 0.8) : random.range(0.2, 0.48))
        lastSide = x
        var y = random.range(big ? 0.2 : 0.17, big ? 0.42 : 0.5)
        if x < 0.4 { y = max(y, 0.3) }
        let x0 = x + random.range(-0.1, 0.1), y0 = 1.04
        let rise = y0 - y
        nextColour = (nextColour + 1 + random.int(2)) % 4
        // Thrown up to come to rest at the burst just as the beat lands.
        rockets.append(Rocket(x: x0, y: y0, vx: (x - x0) / flight, vy: -2 * rise / flight,
                              gravity: 2 * rise / (flight * flight), lagX: x0, lagY: y0, flight: flight, colour: nextColour,
                              big: big || bass > 0.92))
    }

    private func updateRockets(dt: Double, calm: Bool, bass: Double) {
        var i = 0
        while i < rockets.count {
            var r = rockets[i]
            r.age += dt
            r.vy += r.gravity * dt
            r.x += r.vx * dt
            r.y += r.vy * dt
            let follow = 1 - exp(-dt / 0.07)
            r.lagX += (r.x - r.lagX) * follow
            r.lagY += (r.y - r.lagY) * follow
            // A fizz of dim sparks falls from it as it climbs.
            r.shed += dt
            while r.shed > 0.05, particles.count < Self.maxParticles {
                r.shed -= 0.05
                let x = r.x + random.range(-0.008, 0.008), y = r.y + random.range(0, 0.02)
                var fizz = Particle(x: x, y: y, vx: random.range(-0.05, 0.05), vy: random.range(0.02, 0.1), lagX: x,
                                    lagY: y, life: random.range(0.3, 0.5), colour: -1, size: 0.62, drag: 3, gravity: 0.3,
                                    trail: 0)
                fizz.twinkle = 0.55
                particles.append(fizz)
            }
            if calm {
                // Silence: it fizzles out as an ember.
                addEmber(at: (r.x, r.y), settled: false)
                rockets.remove(at: i)
                continue
            }
            if r.age >= r.flight {
                burst(r, bass: bass)
                rockets.remove(at: i)
                continue
            }
            rockets[i] = r
            i += 1
        }
    }

    private func burst(_ rocket: Rocket, bass: Double) {
        let big = rocket.big
        let wanted = big ? 70 : Int(34 + 24 * bass)
        makeRoom(for: wanted)
        let count = min(Self.maxParticles - particles.count, wanted)
        guard count > 0 else { return }
        let roll = random.next()
        let kind = big ? (roll < 0.6 ? 0 : 1) : (roll < 0.5 ? 0 : roll < 0.75 ? 1 : 2) // peony, ring, willow
        let speed = (0.52 + 0.24 * bass) * (big ? 1.35 : 1)
        // Some shells carry a second colour in their heart.
        let second = random.chance(0.35) ? (rocket.colour + 2) % 4 : rocket.colour
        let turn = random.range(0, 2 * Double.pi)
        for k in 0..<count {
            let angle = turn + 2 * Double.pi * (Double(k) + random.range(-0.3, 0.3)) / Double(count)
            var v: Double, life: Double, drag: Double, gravity: Double, trail: Double
            switch kind {
            case 1:
                v = speed * random.range(0.9, 1)
                life = random.range(1.1, 1.45); drag = 2.1; gravity = 0.26; trail = 0.08
            case 2:
                v = speed * 0.8 * (0.45 + 0.55 * random.next().squareRoot())
                life = random.range(1.8, 2.4); drag = 1.7; gravity = 0.45; trail = 0.28
            default:
                v = speed * (0.3 + 0.7 * random.next().squareRoot())
                life = random.range(1.15, 1.6); drag = 2.1; gravity = 0.28; trail = 0.1
            }
            if big { life *= 1.15 }
            let colour = kind == 2 ? (rocket.colour + 1) % 4 : (v < speed * 0.6 ? second : rocket.colour)
            particles.append(Particle(x: rocket.x, y: rocket.y, vx: cos(angle) * v, vy: sin(angle) * v,
                                      lagX: rocket.x, lagY: rocket.y, life: life, colour: colour,
                                      size: big ? 0.95 : 0.85, drag: drag, gravity: gravity, trail: trail))
        }
        if flashes.count < 3 {
            flashes.append(Flash(x: rocket.x, y: rocket.y, colour: rocket.colour, size: big ? 0.26 : 0.17))
        }
    }

    private func updateParticles(dt: Double, calm: Bool) {
        let crackle = 0.12 + 0.55 * treble
        for i in particles.indices {
            var p = particles[i]
            // In silence the show winds down quickly; embers keep their own pace.
            p.age += p.ember ? dt : dt * (calm ? 3 : 1)
            let slow = exp(-p.drag * dt)
            p.vx *= slow
            p.vy = p.vy * slow + p.gravity * dt
            p.x += p.vx * dt
            p.y += p.vy * dt
            if p.trail > 0 {
                // Trails stretch out as the sparks slow and fall.
                let follow = 1 - exp(-dt / (p.ember ? p.trail : p.trail * (1 + 1.8 * p.age / p.life)))
                p.lagX += (p.x - p.lagX) * follow
                p.lagY += (p.y - p.lagY) * follow
            } else {
                p.lagX = p.x
                p.lagY = p.y
            }
            // Ageing sparks crackle: more of them flicker when the treble is bright.
            if p.ember {
                p.twinkle = 0.75 + 0.25 * random.next()
            } else if p.age > p.life * 0.4, p.trail > 0 {
                p.twinkle = random.chance(crackle) ? random.range(0.15, 0.5) : 1
            }
            particles[i] = p
        }
        particles.removeAll { $0.age >= $0.life || $0.y > 1.1 || $0.x < -0.1 || $0.x > 1.1 }
    }

    /// An ember drifting down through the calm night, around one of the clusters (or at `at`).
    private func addEmber(at point: (Double, Double)? = nil, settled: Bool = true) {
        guard particles.count < Self.maxParticles else { return }
        let cluster = clusters[random.int(clusters.count)]
        let x = point?.0 ?? cluster.x + random.range(-0.14, 0.14), y = point?.1 ?? cluster.y + random.range(-0.1, 0.12)
        let life = random.range(4, 7)
        let vx = random.range(-0.015, 0.015), vy = random.range(0.02, 0.04)
        var ember = Particle(x: x, y: y, vx: vx, vy: vy, lagX: x - vx * 0.45, lagY: y - vy * 0.45, life: life,
                             colour: random.int(4), size: random.range(0.8, 1.0), drag: 0, gravity: 0, trail: 0.45)
        ember.ember = true
        ember.age = settled ? random.range(0.6, life * 0.5) : 0
        particles.append(ember)
    }

    /// Makes room for `count` more sparks by retiring the ones furthest through their lives (nearly faded anyway).
    private func makeRoom(for count: Int) {
        let excess = particles.count + count - Self.maxParticles
        guard excess > 0 else { return }
        let ages = particles.map { $0.ember ? 0 : $0.age / $0.life }.sorted(by: >)
        let cutoff = ages[min(excess, ages.count) - 1]
        particles.removeAll { !$0.ember && $0.age / $0.life >= cutoff }
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let w = size.width, h = size.height
        let unit = min(w, h) / 92
        let levels = Self.levels

        // The night sky: a few faint stars.
        for band in 0..<3 {
            rects.removeAll(keepingCapacity: true)
            for star in sky where !star.sparkle {
                let bright = star.bright * (0.8 + 0.2 * sin(star.phase))
                guard min(2, max(0, Int((bright - 0.16) / 0.1))) == band else { continue }
                let side = CGFloat(star.size) * 1.77 * unit
                rects.append(CGRect(x: CGFloat(star.x) * w - side / 2, y: CGFloat(star.y) * h - side / 2, width: side,
                                    height: side))
            }
            if !rects.isEmpty {
                ctx.setFill(style.ink, (0.2 + 0.11 * Double(band)) * (style.isLight ? 0.75 : 1))
                ctx.fill(rects)
            }
        }
        for star in sky where star.sparkle {
            let twinkle = 0.75 + 0.25 * sin(star.phase)
            ctx.setFill(style.ink, star.bright * twinkle * (style.isLight ? 0.75 : 1))
            addSparkle(ctx, CGPoint(x: CGFloat(star.x) * w, y: CGFloat(star.y) * h),
                       arm: CGFloat(2.1 + 0.6 * twinkle) * unit, waist: 0.42 * unit)
            ctx.fillPath()
        }

        // A burst lights up the sky around it (dark artwork only: no glare on light).
        if !style.isLight {
            for flash in flashes {
                let t = flash.age / 0.35
                let alpha = 0.5 * (1 - t) * (1 - t)
                ctx.fillGlow(at: CGPoint(x: CGFloat(flash.x) * w, y: CGFloat(flash.y) * h),
                             radius: CGFloat(flash.size * (0.7 + 0.5 * t)) * w,
                             color: style.spark(flash.colour).mixed(with: .white, 0.4), alpha: alpha)
            }
        }

        // Each ember glows softly: in its own colour, faintly, on light artwork (a tint, not a glare).
        for p in particles where p.ember {
            let t = p.age / p.life
            let alpha = (style.isLight ? 0.22 : 0.5) * min(1, p.age / 0.5) * min(1, (1 - t) / 0.3)
            ctx.fillGlow(at: CGPoint(x: CGFloat(p.x) * w, y: CGFloat(p.y) * h), radius: 5.5 * unit,
                         color: style.spark(p.colour), alpha: alpha)
        }

        // Sparks and rockets, each into a batch of one colour and brightness.
        sprites.removeAll(keepingCapacity: true)
        func add(_ x: Double, _ y: Double, _ lagX: Double, _ lagY: Double, radius: Double, slot: Int, alpha: Double,
                 square: Bool = false) {
            guard alpha > 0.02 else { return }
            let level = min(levels - 1, Int(alpha * Double(levels)))
            sprites.append(Sprite(head: CGPoint(x: CGFloat(x) * w, y: CGFloat(y) * h),
                                  tail: CGPoint(x: CGFloat(lagX) * w, y: CGFloat(lagY) * h),
                                  radius: max(0.62, CGFloat(radius)) * unit, key: slot * levels + level, square: square))
        }
        for p in particles {
            let t = p.age / p.life
            var alpha: Double
            if p.ember {
                alpha = 0.9 * min(1, p.age / 0.5) * min(1, (1 - t) / 0.3) * p.twinkle
            } else {
                // Full for the first part of the flight, then fading out.
                alpha = (t < 0.3 ? 1 : pow(max(1 - (t - 0.3) / 0.7, 0), 1.2)) * p.twinkle
            }
            // Fresh sparks burn white-hot over dark artwork before taking their colour.
            let hot = !style.isLight && !p.ember && p.age < 0.1
            let slot = p.colour < 0 || hot ? 0 : p.colour + (p.ember ? 5 : 1)
            add(p.x, p.y, p.lagX, p.lagY, radius: p.size * (1 - 0.35 * t), slot: slot, alpha: alpha,
                square: !p.ember && p.age < 0.07)
        }
        for r in rockets {
            add(r.x, r.y, r.lagX, r.lagY, radius: 0.85, slot: 0, alpha: 0.95)
        }
        guard !sprites.isEmpty else { return }

        // Counting sort into batches.
        for k in counts.indices { counts[k] = 0 }
        for s in sprites { counts[s.key + 1] += 1 }
        for k in 1..<counts.count { counts[k] += counts[k - 1] }
        sorted.removeAll(keepingCapacity: true)
        sorted.append(contentsOf: sprites)
        for s in sprites {
            sorted[counts[s.key]] = s
            counts[s.key] += 1
        }

        func colour(_ slot: Int) -> RGB {
            if slot == 0 { return style.isLight ? style.ink : style.ink.mixed(with: .white, 0.5) }
            let spark = style.spark((slot - 1) % 4)
            if style.isLight { return spark.scaled(0.82) }
            return spark.mixed(with: .white, slot > 4 ? 0.55 : 0.08)
        }
        var start = 0
        while start < sorted.count {
            let key = sorted[start].key
            var end = start
            while end < sorted.count, sorted[end].key == key { end += 1 }
            ctx.setFill(colour(key / levels), min(1, (Double(key % levels) + 0.6) / Double(levels)))
            rects.removeAll(keepingCapacity: true)
            var shapes = 0
            for k in start..<end {
                let s = sorted[k]
                let dx = s.head.x - s.tail.x, dy = s.head.y - s.tail.y
                let length = (dx * dx + dy * dy).squareRoot()
                if !s.square, length > s.radius * 0.8 {
                    addComet(ctx, head: s.head, tail: s.tail, length: length, radius: s.radius)
                } else if s.square || s.radius < 0.78 {
                    let side = s.radius * 1.77
                    rects.append(CGRect(x: s.head.x - side / 2, y: s.head.y - side / 2, width: side, height: side))
                    continue
                } else {
                    addDot(ctx, s.head, s.radius)
                }
                shapes += 1
                if shapes == Self.chunk {
                    ctx.fillPath()
                    shapes = 0
                }
            }
            if shapes > 0 { ctx.fillPath() }
            if !rects.isEmpty { ctx.fill(rects) }
            start = end
        }
    }
}

/// 0 below `lo`, 1 above `hi`, smooth between.
nonisolated private func smoothstep(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
    let t = min(max((x - lo) / (hi - lo), 0), 1)
    return t * t * (3 - 2 * t)
}

/// A spark with its trail: a sharp tail widening to a round head, added to the context's path.
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

/// A four-pointed twinkle: arms `arm` long, `waist` thick at the middle, added to the context's path.
nonisolated private func addSparkle(_ ctx: CGContext, _ p: CGPoint, arm: CGFloat, waist: CGFloat) {
    ctx.move(to: CGPoint(x: p.x + arm, y: p.y))
    ctx.addLine(to: CGPoint(x: p.x + waist, y: p.y + waist))
    ctx.addLine(to: CGPoint(x: p.x, y: p.y + arm))
    ctx.addLine(to: CGPoint(x: p.x - waist, y: p.y + waist))
    ctx.addLine(to: CGPoint(x: p.x - arm, y: p.y))
    ctx.addLine(to: CGPoint(x: p.x - waist, y: p.y - waist))
    ctx.addLine(to: CGPoint(x: p.x, y: p.y - arm))
    ctx.addLine(to: CGPoint(x: p.x + waist, y: p.y - waist))
    ctx.closePath()
}
