// SPDX-License-Identifier: GPL-3.0-or-later
// Drumming Cat: a pixel-art cat plays a pair of bongos, on the same 46-pixel grid as Pixel DJ. One paw slaps the big
// drum on every kick and the other the small drum on the treble's hits (the hats between the kicks), each winding up
// before its hit; the drum head squashes under the paw and a little impact flicks off it. The tail swishes to the
// beat, the head nods on the downbeat, an ear twitches now and then and the eyes narrow happily when the music is
// loud. Through a breakdown the paws only tap and the head sways; when the bass comes back the cat drums a flurry with
// both paws, meows, and musical notes burst out of the bongos. In silence it curls up on the bongos and sleeps, with a
// "z". Each seed brings a different cat (ginger, grey tabby, black, white, calico or tuxedo, and its eyes) and
// different bongos (the wood, the rims, the band round them, which side the big drum is on) and tail side.
//
// The cat is drawn from outlined pixel shapes, back to front (tail, body, head, drums, arms), so each part's outline
// falls over the one behind it as in hand-drawn pixel art; the face is a hand-placed sprite.

import CoreGraphics
import Foundation

nonisolated final class DrummingCatScene: VisualizerScene {
    /// 46 pixels across: 2 points a pixel on the 92-point artwork, whole pixels at 1x and 2x.
    private static let side = 46
    /// The drums' centre columns (left, right), and the top row of their heads.
    private static let drumX = [14, 32]
    private static let drumTop = 27
    /// The head sprite's top-left pixel, and the shoulders (pixel centres) the arms hang from.
    private static let headX = 13, headY = 4
    private static let shoulders = [SIMD2(17.0, 24.0), SIMD2(29.5, 24.0)]

    private var canvas = PixelCanvas(width: DrummingCatScene.side, height: DrummingCatScene.side)
    /// A scratch mask for one outlined shape, reused.
    private var mask = [Bool](repeating: false, count: DrummingCatScene.side * DrummingCatScene.side)
    private var random: SceneRandom
    private let coat: Coat
    private let kit: Kit
    private var paints = Paints()
    private var styled: SceneStyle?

    // What the music is doing.
    private var activity = 0.0
    private var level = 0.0
    private var groove = 0.0
    private var beatIndex = 0
    private var calm = 0.0
    private var pulse = 0.0
    private var silentFor = 10.0
    /// Loud: the eyes narrow happily (with some hysteresis, so they don't flicker).
    private var squint = false
    // The treble's hits: a quick rise in the upper bars, well above their recent low, that isn't a kick.
    private var lastTreble = 0.0
    private var trebleFloor = 0.0
    private var sinceKick = 1.0
    private var sinceTreble = 1.0
    /// The usual time between treble hits, for winding the paw up in time for the next.
    private var trebleGap = 0.48

    // The cat.
    /// The paws, by drum (0 the left drum, 1 the right).
    private var paws = [Paw(), Paw()]
    private var squash = [0.0, 0.0]
    private var marks: [Mark] = []
    private var notes: [Note] = []
    /// Seconds left of the drop's flurry, and the last sixteenth it hit on.
    private var flurry = 0.0
    private var flurryStep = 0
    /// Notes still to fling out during the flurry.
    private var burst = 0
    private var meow = 0.0
    private var kicks = 0
    private var blinkIn = 3.0
    private var blinkFor = 0.0
    private var earIn = 2.0
    private var earFor = 0.0
    private var earSide = 0
    /// Which drum the eyes glance at (-1 left, 1 right), and for how long.
    private var glance = 0
    private var glanceFor = 0.0

    /// None: a halo would blur the pixels.
    var glow: Double { 0 }

    init(seed: UInt64) {
        random = SceneRandom(seed: seed)
        // Stir the generator first: neighbouring seeds' first draws are alike.
        for _ in 0..<4 { _ = random.next() }
        coat = Coat(&random)
        kit = Kit(&random)
        blinkIn = random.range(2, 4)
        earIn = random.range(1.5, 3.5)
    }

    private var asleep: Bool { silentFor > 0.12 }
    /// The drum the kicks play (the big one) and the one the treble plays.
    private var kickDrum: Int { kit.bigLeft ? 0 : 1 }
    private var trebleDrum: Int { kit.bigLeft ? 1 : 0 }

    // MARK: - Update

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let silent = input.isSilent
        silentFor = silent ? silentFor + dt : 0
        activity = Self.approach(activity, silent ? 0 : 1, rate: silent ? 12 : 5, dt)
        level = Self.approach(level, silent ? 0 : Double(input.level), rate: 5, dt)
        let downbeat = !silent && input.groove < groove - 0.5
        if downbeat { beatIndex += 1 }
        groove = input.groove
        calm = silent ? 0 : Double(input.breakdown)
        pulse = Double(input.pulse)
        if level > 0.54 { squint = true } else if level < 0.48 { squint = false }

        let trebleHit = hearTreble(input, dt: dt)
        if asleep {
            settle()
        } else {
            if input.beat {
                hit(kickDrum)
                kicks += 1
                // Now and then a note floats up from a good hit.
                if kicks % 4 == 0, calm < 0.3, level > 0.4 { launchNote(from: kickDrum, burst: false) }
            }
            if trebleHit { hit(trebleDrum) }
            // No kicks for a while (a breakdown without a beat): the kick's paw keeps time on the beat clock.
            if downbeat, !input.beat, sinceKick > input.beatInterval * 1.6 {
                hit(kickDrum)
            }
            if input.drop {
                flurry = max(1.2, input.beatInterval * 3.5)
                flurryStep = Int(((Double(beatIndex) + groove) * 4).rounded(.down))
                meow = 0.9
                launchNote(from: kickDrum, burst: true)
                launchNote(from: trebleDrum, burst: true)
                burst = 10
            }
            if flurry > 0 {
                // Sixteenths, the paws taking turns, notes pouring out of the drums.
                flurry -= dt
                let step = Int(((Double(beatIndex) + groove) * 4).rounded(.down))
                if step != flurryStep {
                    flurryStep = step
                    let d = step % 2 == 0 ? kickDrum : trebleDrum
                    hit(d)
                    for _ in 0..<min(burst, 2) {
                        launchNote(from: d, burst: true)
                        burst -= 1
                    }
                }
            }
        }
        movePaws(dt: dt)
        moveFace(dt: dt)
        for i in squash.indices { squash[i] *= exp(-dt * 13) }
        for i in marks.indices { marks[i].age += dt }
        marks.removeAll { $0.age > 0.14 }
        for i in notes.indices {
            notes[i].vy += 14 * dt
            notes[i].x += notes[i].vx * dt
            notes[i].y += notes[i].vy * dt
            notes[i].vx *= exp(-dt * 1.2)
            notes[i].life -= dt * (silent ? 5 : 1)
        }
        notes.removeAll { $0.life <= 0 || $0.y < -6 }
        meow = max(0, meow - dt)
    }

    /// A treble hit: the upper bars jump well clear of their recent low in a frame, away from the kicks (the kick's
    /// paw plays those, and the treble jumps with them).
    private func hearTreble(_ input: VisualizerInput, dt: Double) -> Bool {
        let bars = input.bars
        let treble = Double(AudioFeatures.mean(bars, 12..<bars.count))
        let floor = trebleFloor
        defer {
            lastTreble = treble
            trebleFloor = min(treble, trebleFloor + dt * 0.6)
        }
        sinceTreble += dt
        sinceKick = input.beat ? 0 : sinceKick + dt
        let offBeat = input.groove > 0.12 && input.groove < 0.85
        guard !input.isSilent, offBeat, sinceKick > 0.1, dt > 0, treble - lastTreble > 0.06, treble - floor > 0.1,
              sinceTreble > 0.12 else { return false }
        if sinceTreble < 1.2 { trebleGap += (sinceTreble - trebleGap) * 0.3 }
        sinceTreble = 0
        return true
    }

    /// A paw slaps drum `d`: down it goes, the head squashes and (unless it's a breakdown's soft tap) an impact flicks.
    private func hit(_ d: Int) {
        let soft = calm > 0.5 && flurry <= 0
        paws[d].lift = 0
        paws[d].hold = 0.06
        paws[d].since = 0
        squash[d] = soft ? 0.45 : 1
        if !soft { marks.append(Mark(drum: d)) }
        glance = d == 0 ? -1 : 1
        glanceFor = 0.18
    }

    /// Asleep: nothing in the air, the paws tucked in.
    private func settle() {
        notes.removeAll()
        marks.removeAll()
        flurry = 0
        burst = 0
        meow = 0
        blinkFor = 0
        earFor = 0
        for d in paws.indices { paws[d] = Paw() }
    }

    /// Each paw rises after its hit and winds up for the next: the kick's paw on the beat clock, the treble's on the
    /// usual gap between its hits (settling back if none comes). A breakdown only lifts them a little.
    private func movePaws(dt: Double) {
        for d in paws.indices {
            paws[d].since += dt
            if paws[d].hold > 0 {
                paws[d].hold -= dt
                paws[d].lift = 0
                continue
            }
            var target = 0.0
            if !asleep {
                let wind: Double
                if flurry > 0 {
                    wind = 0.35
                } else if d == kickDrum {
                    wind = Self.smoothstep(0.45, 0.9, groove)
                } else {
                    let x = paws[d].since / min(max(trebleGap, 0.15), 1)
                    wind = x < 1.4 ? Self.smoothstep(0.3, 0.85, x) : max(0, 1 - (x - 1.4))
                }
                target = (0.28 + 0.72 * wind) * (1 - 0.7 * calm) * activity
            }
            paws[d].lift = Self.approach(paws[d].lift, target, rate: target > paws[d].lift ? 20 : 26, dt)
        }
    }

    private func moveFace(dt: Double) {
        glanceFor = max(0, glanceFor - dt)
        if glanceFor == 0 { glance = 0 }
        guard !asleep else { return }
        // Blinks and ear twitches every few seconds.
        if blinkFor > 0 {
            blinkFor -= dt
        } else {
            blinkIn -= dt
            if blinkIn <= 0 {
                blinkFor = 0.12
                blinkIn = random.range(2.2, 5)
            }
        }
        if earFor > 0 {
            earFor -= dt
        } else {
            earIn -= dt
            if earIn <= 0 {
                earFor = 0.24
                earSide = random.int(2)
                earIn = random.range(1.8, 4.5)
            }
        }
    }

    /// A note from drum `d`'s outer edge, floating up and out (flung faster in the drop's burst).
    private func launchNote(from d: Int, burst: Bool) {
        let out: Double = d == 0 ? -1 : 1
        let x = Double(Self.drumX[d]) + out * random.range(2, 6) - 3
        let angle = random.range(0.35, 1.25), speed = burst ? random.range(26, 40) : random.range(13, 18)
        notes.append(Note(x: x, y: Double(Self.drumTop) - random.range(4, 7),
                          vx: out * speed * cos(angle) * (burst ? 1 : 0.4), vy: -speed * sin(angle),
                          life: random.range(1.3, 1.9),
                          beamed: random.chance(0.4), color: random.int(4)))
        if notes.count > 16 { notes.removeFirst() }
    }

    // MARK: - Draw

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        if styled != style {
            paints = Paints(style, coat: coat, kit: kit)
            styled = style
        }
        canvas.clear()
        paintBackdrop(style)
        if asleep {
            for d in 0..<2 { paintDrum(d) }
            paintSleeper()
            paintZs()
        } else {
            paintTail()
            paintBody()
            paintHead()
            for d in 0..<2 { paintDrum(d) }
            for d in 0..<2 { paintArm(d) }
            paintMarks()
        }
        paintNotes()
        canvas.draw(in: ctx, rect: CGRect(origin: .zero, size: size))
    }

    /// A soft round lamp light behind the cat (darker on light artwork), and a rug under the bongos.
    private func paintBackdrop(_ style: SceneStyle) {
        let strength = (asleep ? 0.6 : 1) + 0.4 * pulse * activity * (1 - calm)
        let light = paints.lamp
        let alpha = style.isLight ? 0.06 : 0.11
        for y in 0..<Self.side {
            for x in 0..<Self.side {
                let dx = Double(x) + 0.5 - 23, dy = Double(y) + 0.5 - 19
                let d = dx * dx + dy * dy
                if d < 18 * 18 { canvas.set(x, y, light, alpha * strength * (d < 13 * 13 ? 2 : 1)) }
            }
        }
        // The rug: an oval with a border.
        for y in 39..<Self.side {
            for x in 0..<Self.side {
                let dx = (Double(x) + 0.5 - 23) / 17, dy = (Double(y) + 0.5 - 42.3) / 3.2
                let d = dx * dx + dy * dy
                guard d <= 1 else { continue }
                canvas.set(x, y, d > 0.55 ? paints.rugEdge : paints.rug)
            }
        }
    }

    // MARK: The cat, awake

    /// The head's offset this frame: a nod on the downbeat, a slow sway through a breakdown.
    private var headShift: (x: Int, y: Int) {
        let nod = activity > 0.5 && calm < 0.5 && level > 0.3 && groove < 0.18 ? 1 : 0
        var sway = 0
        if calm > 0.4 {
            let s = sin(.pi * (Double(beatIndex) + groove) / 2)
            sway = s > 0.4 ? 1 : s < -0.4 ? -1 : 0
        }
        return (sway, nod)
    }

    private func paintTail() {
        let side: Double = kit.tailRight ? 1 : -1
        // Swishes once every two beats, half as fast through a breakdown.
        let beat = Double(beatIndex) + groove
        let swish = (sin(.pi * beat) * (1 - calm) + sin(.pi * beat / 2) * calm) * activity
        var points: [SIMD2<Double>] = []
        // Out from behind the drum, up the side, a hook at the tip.
        var p = SIMD2(23 + side * 12, 33.0)
        var angle = 0.3
        for (k, curl) in Self.tailCurl.enumerated() {
            points.append(p)
            let t = Double(k) / Double(Self.tailCurl.count - 1)
            angle += curl + swish * (k == 0 ? 0.12 : 0.04 + 0.05 * t)
            p += SIMD2(side * cos(angle), -sin(angle)) * 1.9
        }
        points.append(p)
        let count = Double(points.count - 1)
        stroke(points, radius: 1.25) { [coat] along in coat.tail(along: along / count) }
    }

    /// How much the tail turns at each of its segments, root to tip.
    private static let tailCurl = [0.18, 0.18, 0.18, 0.18, 0.18, 0.04, 0.04, 0.04, 0.04, 0.35, 0.35, 0.35]

    private func paintBody() {
        let shift = headShift
        let cx = 23.0 + Double(shift.x) * 0.5
        let top = 17.0
        shape(x0: 11, y0: 16, x1: 35, y1: 35, outline: paints.outline, inside: { x, y in
            guard y > top, y < 34 else { return false }
            let half = 6.4 + (y - top) * 0.3
            let round = y - top < 2 ? (2 - (y - top)) * 1.5 : 0
            return abs(x - cx) < half - round
        }, fill: { [coat] x, y in
            let half = 6.4 + (Double(y) + 0.5 - top) * 0.3
            let edge = half - abs(Double(x) + 0.5 - cx)
            return coat.body(x: x, y: y, cx: cx, edge: edge)
        })
    }

    private func paintHead() {
        let shift = headShift
        let ox = Self.headX + shift.x, oy = Self.headY + shift.y
        // An ear twitches with two quick flicks; through a breakdown the ear on the low side of the sway dips.
        let flick = earFor > 0.15 || (earFor > 0 && earFor < 0.07)
        for (row, line) in Head.rows.enumerated() {
            for (col, m) in line.enumerated() where m != .clear {
                let ear = row < 4 ? (col < 10 ? 0 : 1) : -1
                var x = ox + col, y = oy + row
                if ear >= 0 {
                    let dipped = (flick && ear == earSide) || (shift.x != 0 && (shift.x < 0) == (ear == 0))
                    if dipped {
                        x += flick && ear == earSide ? (ear == 0 ? -1 : 1) : 0
                        y += 1
                    }
                }
                canvas.set(x, y, coat.head(m, col: col, row: row, outline: paints.outline))
            }
        }
        paintFace(ox, oy)
    }

    /// Eyes, nose, mouth and whiskers on the head at (ox, oy).
    private func paintFace(_ ox: Int, _ oy: Int) {
        let outline = paints.outline
        let lid = coat.dark ? coat.highlight.mixed(with: .white, 0.3) : outline
        let eyes = [ox + 5, ox + 13]
        let ey = oy + 8
        for x in eyes {
            if meow > 0 {
                paintEye(x, ey, wide: true)
            } else if blinkFor > 0 {
                for i in 0..<3 { canvas.set(x + i, ey + 1, lid) }
            } else if squint && calm < 0.5 {
                // Happy: upturned arcs.
                canvas.set(x + 1, ey, lid)
                canvas.set(x, ey + 1, lid)
                canvas.set(x + 2, ey + 1, lid)
            } else if calm > 0.5 {
                // Dreamy: half closed under a lid.
                for i in 0..<3 { canvas.set(x + i, ey + 1, lid) }
                canvas.set(x, ey + 2, coat.eye)
                canvas.set(x + 1, ey + 2, RGB(hex: 0x14100E))
                canvas.set(x + 2, ey + 2, coat.eye)
            } else {
                paintEye(x, ey, wide: false)
            }
        }
        // Nose and mouth: a pink nose over a little "w", open in a meow.
        for i in 0..<3 { canvas.set(ox + 9 + i, oy + 11, coat.nose) }
        if meow > 0 {
            canvas.rect(ox + 9, oy + 12, 3, 3, outline)
            canvas.set(ox + 10, oy + 13, RGB(hex: 0xE0576B))
            canvas.set(ox + 10, oy + 14, RGB(hex: 0xE0576B))
        } else {
            let mouth = coat.kind == .black ? lid : outline
            for i in [8, 10, 12] { canvas.set(ox + i, oy + 12, mouth) }
            canvas.set(ox + 9, oy + 13, mouth)
            canvas.set(ox + 11, oy + 13, mouth)
        }
        // Whiskers, out past the cheeks.
        for side in 0..<2 {
            let x0 = side == 0 ? ox - 1 : ox + 21
            let step = side == 0 ? -1 : 1
            canvas.set(x0, oy + 12, paints.whisker, 0.8)
            canvas.set(x0 + step, oy + 11, paints.whisker, 0.8)
            canvas.set(x0, oy + 14, paints.whisker, 0.8)
            canvas.set(x0 + step, oy + 15, paints.whisker, 0.6)
        }
    }

    /// An open eye: the iris either side of a slit pupil (glancing at the drum just hit), with a glint.
    private func paintEye(_ x: Int, _ y: Int, wide: Bool) {
        let pupil = RGB(hex: 0x14100E)
        canvas.rect(x, y, 3, 3, coat.eye)
        let px = x + 1 + (wide ? 0 : glance)
        // Wide open (the meow): a round pupil, not a slit.
        canvas.rect(px, wide ? y + 1 : y, 1, wide ? 2 : 3, pupil)
        canvas.set(px == x ? x + 2 : x, y, .white)
    }

    private func paintArm(_ d: Int) {
        let shoulder = Self.shoulders[d] + SIMD2(Double(headShift.x) * 0.5, 0)
        let out: Double = d == 0 ? -1 : 1
        let down = SIMD2(Double(Self.drumX[d]) + 0.5 - out * 0.5, Double(Self.drumTop) + 1.6)
        let up = SIMD2(Double(Self.drumX[d]) + 0.5 + out * 1.5, Double(Self.drumTop) - 8)
        let paw = down + (up - down) * paws[d].lift
        stroke([shoulder, paw], radius: 1.1) { [coat] along in coat.arm(along: along) }
        // The paw: a round mitt with two toe lines.
        let (pc, sock) = (paw, coat.paw)
        shape(x0: Int(pc.x) - 4, y0: Int(pc.y) - 3, x1: Int(pc.x) + 4, y1: Int(pc.y) + 3, outline: paints.outline,
              inside: { x, y in
                  let dx = (x - pc.x) / 2.6, dy = (y - pc.y) / 1.9
                  return dx * dx + dy * dy <= 1
              }, fill: { _, _ in sock })
        let toeY = Int((pc.y + 1).rounded(.down))
        canvas.set(Int((pc.x - 0.7).rounded(.down)), toeY, paints.outline, 0.85)
        canvas.set(Int((pc.x + 0.7).rounded(.down)), toeY, paints.outline, 0.85)
    }

    private func paintMarks() {
        // Little slap lines either side of the paw, flying out as they fade.
        for mark in marks {
            let x = Self.drumX[mark.drum], y = Self.drumTop + 1
            let color = paints.impact
            let r = mark.age < 0.07 ? 4 : 5
            let alpha = mark.age < 0.07 ? 1 : 0.7
            for s in [-1, 1] {
                canvas.set(x + s * r, y - 1, color, alpha)
                canvas.set(x + s * (r + 1), y - 1, color, alpha)
                canvas.set(x + s * (r - 1), y - 3, color, alpha)
                canvas.set(x + s * r, y - 4, color, alpha)
            }
        }
    }

    // MARK: The cat, asleep

    /// Curled up across both drum heads: a round back with the haunch showing, the head resting at one end with its
    /// eyes shut, the tail wrapped round the front and under the chin.
    private func paintSleeper() {
        let outline = paints.outline
        let headLeft = !kit.tailRight
        func mx(_ x: Double) -> Double { headLeft ? x : 46 - x }
        let dir: Double = headLeft ? 1 : -1
        // A slow breath once the cat has been asleep a while (the paused still is between breaths).
        let breath = silentFor > 1.5 && sin((silentFor - 1.5) * 1.9) > 0.5 ? 0.7 : 0
        let body = SIMD2(mx(27), 25.8 - breath / 2)
        let top = Int((body.y - 7).rounded(.down))
        let fur = { [coat] (x: Int, y: Int) in
            coat.sleeper(u: (Double(x) + 0.5 - body.x) * dir, v: Double(y) + 0.5 - body.y, y: y, top: top)
        }
        shape(x0: 12, y0: 17, x1: 40, y1: 31, outline: outline, inside: { x, y in
            let dx = (x - body.x) / 9.8, dy = (y - body.y) / (7.0 + breath / 2)
            return dx * dx + dy * dy <= 1 && y < 30.8
        }, fill: fur)
        let haunch = SIMD2(mx(31.6), 26.6)
        shape(x0: 22, y0: 20, x1: 40, y1: 31, outline: outline, inside: { x, y in
            let dx = (x - haunch.x) / 4.9, dy = (y - haunch.y) / 4.1
            return dx * dx + dy * dy <= 1 && y < 30
        }, fill: fur)
        // The head, ears up.
        let head = SIMD2(mx(15), 25)
        for ear in [(SIMD2(mx(10.1), 17), SIMD2(mx(8.1), 23.2), SIMD2(mx(14.3), 21)),
                    (SIMD2(mx(19.9), 17.2), SIMD2(mx(15.7), 21), SIMD2(mx(21.9), 23.2))] {
            let (tip, a, b) = ear
            let centre = (tip + a + b) / 3
            let shrink = { (p: SIMD2<Double>) in centre + (p - centre) * 0.5 }
            shape(x0: Int(min(a.x, b.x)) - 1, y0: 15, x1: Int(max(a.x, b.x)) + 1, y1: 23, outline: outline,
                  inside: { x, y in Self.inTriangle(SIMD2(x, y), tip, a, b) },
                  fill: { [coat] x, y in
                      let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                      return Self.inTriangle(p, shrink(tip) + SIMD2(0, 0.4), shrink(a), shrink(b)) ? coat.innerEar
                          : coat.sleeperHead(x: x, y: y, cx: head.x, cy: head.y, dir: dir)
                  })
        }
        shape(x0: Int(head.x) - 8, y0: 17, x1: Int(head.x) + 8, y1: 31, outline: outline, inside: { x, y in
            let dx = (x - head.x) / 6.6, dy = (y - head.y) / 5.3
            return dx * dx + dy * dy <= 1
        }, fill: { [coat] x, y in coat.sleeperHead(x: x, y: y, cx: head.x, cy: head.y, dir: dir) })
        // The tail, round the front, under the chin, its tip peeking out past the head.
        let tail = [SIMD2(mx(36.2), 27.2), SIMD2(mx(34.8), 29.9), SIMD2(mx(29), 31), SIMD2(mx(21), 31.3),
                    SIMD2(mx(14), 31.1), SIMD2(mx(9.6), 30.4), SIMD2(mx(8.2), 28.6)]
        stroke(tail, radius: 1.15) { [coat] along in coat.tail(along: along / 6) }
        // Shut eyes and a nose.
        let ex = Int(head.x.rounded(.down)), ey = Int(head.y.rounded(.down))
        let lid = coat.dark ? coat.highlight.mixed(with: .white, 0.3) : outline
        for e in [ex - 4, ex + 2] {
            canvas.set(e, ey, lid)
            canvas.set(e + 1, ey + 1, lid)
            canvas.set(e + 2, ey, lid)
        }
        canvas.set(ex, ey + 2, coat.nose)
    }

    /// A small "z" and a bigger one over the sleeping head (they drift up once the cat has slept a while).
    private func paintZs() {
        let headLeft = !kit.tailRight
        let drift = max(0, silentFor - 1.2) / 2.6
        for k in 0..<2 {
            let p = (0.3 + drift + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
            let alpha = min(1, 3 * sin(.pi * p)) * 0.9
            let big = p > 0.55
            let x = 16.5 + p * 6, y = 14 - p * 9
            let px = Int((headLeft ? x : 46 - x - (big ? 5 : 3)).rounded()), py = Int(y.rounded())
            if big {
                paintGlyph(Self.bigZ, width: 5, x: px, y: py, color: paints.zee, alpha: alpha)
            } else {
                PixelFont.draw("Z", into: &canvas, x: px, y: py, color: paints.zee, alpha: alpha)
            }
        }
    }

    private static let bigZ: [UInt8] = [0b11111, 0b00010, 0b00100, 0b01000, 0b11111]

    // MARK: The bongos

    private func paintDrum(_ d: Int) {
        let big = (d == 0) == kit.bigLeft
        let half = big ? 6 : 5
        let cx = Double(Self.drumX[d]) + 0.5
        let top = Double(Self.drumTop)
        let sq = asleep ? 0 : squash[d]
        let outline = paints.outline
        // The block joining the pair, behind the shells.
        if d == 0 {
            let x0 = Self.drumX[0] + 5, x1 = Self.drumX[1] - 5, y0 = Self.drumTop + 6
            shape(x0: x0, y0: y0, x1: x1, y1: y0 + 2, outline: outline, inside: { _, _ in true },
                  fill: { [kit] _, y in y == y0 ? kit.woodLight : kit.woodShade })
        }
        // The shell: a metal rim under the head, wood tapering down, a coloured band round it.
        shape(x0: Int(cx) - half - 1, y0: Self.drumTop + 3, x1: Int(cx) + half + 1, y1: Self.drumTop + 13,
              outline: outline, inside: { x, y in
                  let h = Double(half) + 0.6 - max(0, y - top - 6) * 0.2
                  return abs(x - cx) < h
              }, fill: { [kit, paints] x, y in
                  let row = y - Self.drumTop
                  let h = Double(half) + 0.6 - max(0, Double(y) + 0.5 - top - 6) * 0.2
                  let u = (Double(x) + 0.5 - cx) / h
                  if row <= 6 { return row == 5 ? kit.rimLight : kit.rim.mixed(with: kit.rimLight, u < -0.4 ? 0.6 : 0) }
                  if row == 9 || row == 10 { return u > 0.55 ? paints.band.scaled(0.75) : paints.band }
                  if row == 13 { return kit.rim }
                  if u < -0.45, u > -0.8 { return kit.woodLight }
                  return u > 0.5 ? kit.woodShade : kit.wood
              })
        // The head, squashed flat and wide for a moment when hit.
        let rx = Double(half) + 0.55 + sq * 0.7
        let ry = 1.75 - sq * 0.6
        let cy = top + 1.9 + sq * 0.5
        shape(x0: Int(cx) - half - 2, y0: Self.drumTop - 1, x1: Int(cx) + half + 2, y1: Self.drumTop + 4,
              outline: outline, inside: { x, y in
                  let dx = (x - cx) / rx, dy = (y - cy) / ry
                  return dx * dx + dy * dy <= 1
              }, fill: { [kit] _, y in Double(y) + 0.5 > cy + 0.9 ? kit.skinShade : kit.skin })
    }

    private func paintNotes() {
        for note in notes {
            let alpha = min(1, note.life * 2.5)
            let color = paints.notes[note.color % paints.notes.count]
            let x = Int(note.x.rounded(.down)), y = Int(note.y.rounded(.down))
            paintGlyph(note.beamed ? Self.beamed : Self.eighth, width: 7, x: x, y: y, color: color, alpha: alpha)
        }
    }

    /// ♪ and ♫, as rows of up to seven pixels.
    private static let eighth: [UInt8] = [0b0010000, 0b0011000, 0b0010100, 0b0010000, 0b1110000, 0b1100000]
    private static let beamed: [UInt8] = [0b0011111, 0b0010001, 0b0010001, 0b1110111, 0b1100110]

    // MARK: - Pixel helpers

    /// A little picture as rows of bits, `width` across with the leftmost pixel the highest bit.
    private func paintGlyph(_ rows: [UInt8], width: Int, x: Int, y: Int, color: RGB, alpha: Double) {
        for (row, bits) in rows.enumerated() {
            for col in 0..<width where bits & (1 << (width - 1 - col)) != 0 {
                canvas.set(x + col, y + row, color, alpha)
            }
        }
    }

    /// Paints an outlined shape: every pixel whose centre is `inside` (within the box) in `fill`'s colour, and the
    /// pixels around them in `outline`, which falls over whatever was drawn before.
    private func shape(x0 rawX0: Int, y0 rawY0: Int, x1 rawX1: Int, y1 rawY1: Int, outline: RGB,
                       inside: (Double, Double) -> Bool, fill: (Int, Int) -> RGB) {
        let n = Self.side
        let x0 = max(rawX0, 0), y0 = max(rawY0, 0), x1 = min(rawX1, n - 1), y1 = min(rawY1, n - 1)
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 {
            for x in x0...x1 { mask[y * n + x] = inside(Double(x) + 0.5, Double(y) + 0.5) }
        }
        func at(_ x: Int, _ y: Int) -> Bool { x >= x0 && x <= x1 && y >= y0 && y <= y1 && mask[y * n + x] }
        for y in (y0 - 1)...(y1 + 1) {
            for x in (x0 - 1)...(x1 + 1) where !at(x, y) {
                if at(x - 1, y) || at(x + 1, y) || at(x, y - 1) || at(x, y + 1) { canvas.set(x, y, outline) }
            }
        }
        for y in y0...y1 {
            for x in x0...x1 where mask[y * n + x] { canvas.set(x, y, fill(x, y)) }
        }
    }

    /// A thick outlined line through `points` (pixel coordinates); `fill` colours each pixel by how far along the line
    /// it is (in segments).
    private func stroke(_ points: [SIMD2<Double>], radius: Double, fill: (Double) -> RGB) {
        guard let first = points.first else { return }
        var lo = first, hi = first
        for p in points {
            lo = SIMD2(min(lo.x, p.x), min(lo.y, p.y))
            hi = SIMD2(max(hi.x, p.x), max(hi.y, p.y))
        }
        func nearest(_ q: SIMD2<Double>) -> (distance: Double, along: Double) {
            var best = (Double.infinity, 0.0)
            for i in 0..<max(points.count - 1, 1) {
                let a = points[i], b = points[min(i + 1, points.count - 1)]
                let ab = b - a
                let len2 = (ab * ab).sum()
                let t = len2 > 0 ? min(max(((q - a) * ab).sum() / len2, 0), 1) : 0
                let d = q - (a + ab * t)
                let dist = (d * d).sum()
                if dist < best.0 { best = (dist, Double(i) + t) }
            }
            return (best.0.squareRoot(), best.1)
        }
        let r = radius
        shape(x0: Int((lo.x - r).rounded(.down)), y0: Int((lo.y - r).rounded(.down)), x1: Int((hi.x + r).rounded(.up)),
              y1: Int((hi.y + r).rounded(.up)), outline: paints.outline, inside: { x, y in
                  nearest(SIMD2(x, y)).distance <= r
              }, fill: { x, y in fill(nearest(SIMD2(Double(x) + 0.5, Double(y) + 0.5)).along) })
    }

    private static func inTriangle(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>,
                                   _ c: SIMD2<Double>) -> Bool {
        func cross(_ u: SIMD2<Double>, _ v: SIMD2<Double>, _ w: SIMD2<Double>) -> Double {
            (v.x - u.x) * (w.y - u.y) - (v.y - u.y) * (w.x - u.x)
        }
        let d1 = cross(a, b, p), d2 = cross(b, c, p), d3 = cross(c, a, p)
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
    }

    private static func approach(_ value: Double, _ target: Double, rate: Double, _ dt: Double) -> Double {
        value + (target - value) * (1 - exp(-dt * rate))
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

// MARK: - The cat

/// What a pixel of the head sprite is.
nonisolated private enum Material {
    case clear, outline, fur, shade, light, pink, highlight

    init(_ c: Character) {
        switch c {
        case "o": self = .outline
        case "f": self = .fur
        case "d": self = .shade
        case "m": self = .light
        case "p": self = .pink
        case "h": self = .highlight
        default: self = .clear
        }
    }
}

nonisolated private enum Head {
    /// 21 across, ears to chin: the face is rows 5...17, the eyes on rows 8...10 at columns 5 and 13.
    static let rows: [[Material]] = [
        "...o.............o...",
        "...oo...........oo...",
        "...opo.........opo...",
        "...oppo.......oppo...",
        "..oopppooooooopppoo..",
        ".offfffhhhhhhhfffffo.",
        "offfffffffffffffffffo",
        "offfffffffffffffffffo",
        "offfffffffffffffffffo",
        "offfffffffffffffffffo",
        "offfffffffffffffffffo",
        "offfffffmmmmmfffffffo",
        "offffffmmmmmmmffffffo",
        "offffffmmmmmmmffffffo",
        ".odfffffmmmmmfffffdo.",
        "..ooddfffmmmfffddoo..",
        "....oooddmmmddooo....",
        ".......ooooooo.......",
    ].map { $0.map(Material.init) }
}

/// The cat's coat: its colours and markings.
nonisolated private struct Coat {
    enum Kind: CaseIterable { case ginger, greyTabby, black, white, calico, tuxedo }

    let kind: Kind
    let fur: RGB
    let shade: RGB
    let light: RGB
    let highlight: RGB
    let stripe: RGB
    /// Calico's black patches (its orange ones are `stripe`).
    let patch: RGB
    let eye: RGB
    let innerEar = RGB(hex: 0xF2A3AE)
    let nose = RGB(hex: 0xF08C9A)

    init(_ r: inout SceneRandom) {
        kind = Kind.allCases[r.int(Kind.allCases.count)]
        switch kind {
        case .ginger:
            (fur, shade, light, highlight, stripe) = (RGB(hex: 0xEE9A45), RGB(hex: 0xC8702C), RGB(hex: 0xFCE6C4),
                                                      RGB(hex: 0xF8B867), RGB(hex: 0xC0601E))
            eye = [RGB(hex: 0x9CCB3B), RGB(hex: 0x7FC6A4)][r.int(2)]
        case .greyTabby:
            (fur, shade, light, highlight, stripe) = (RGB(hex: 0x9A9BA6), RGB(hex: 0x74757F), RGB(hex: 0xE4E2DE),
                                                      RGB(hex: 0xB6B7C0), RGB(hex: 0x55565F))
            eye = [RGB(hex: 0xF2B233), RGB(hex: 0x9CCB3B)][r.int(2)]
        case .black:
            (fur, shade, light, highlight, stripe) = (RGB(hex: 0x3A3846), RGB(hex: 0x2A2833), RGB(hex: 0x44424F),
                                                      RGB(hex: 0x575566), RGB(hex: 0x3A3846))
            eye = [RGB(hex: 0xF4D23A), RGB(hex: 0xA6D84A)][r.int(2)]
        case .white:
            (fur, shade, light, highlight, stripe) = (RGB(hex: 0xF4F1EA), RGB(hex: 0xD3CDC4), RGB(hex: 0xFFFFFF),
                                                      RGB(hex: 0xFFFFFF), RGB(hex: 0xF4F1EA))
            eye = [RGB(hex: 0x6EC1F0), RGB(hex: 0xF2B233)][r.int(2)]
        case .calico:
            (fur, shade, light, highlight, stripe) = (RGB(hex: 0xF6F2EA), RGB(hex: 0xD8D0C4), RGB(hex: 0xFFFFFF),
                                                      RGB(hex: 0xFFFFFF), RGB(hex: 0xE58E3C))
            eye = [RGB(hex: 0x9CCB3B), RGB(hex: 0xF2B233)][r.int(2)]
        case .tuxedo:
            (fur, shade, light, highlight, stripe) = (RGB(hex: 0x2E2C36), RGB(hex: 0x211F28), RGB(hex: 0xF8F6F0),
                                                      RGB(hex: 0x46444F), RGB(hex: 0x2E2C36))
            eye = [RGB(hex: 0xB5D43B), RGB(hex: 0xF4D23A)][r.int(2)]
        }
        patch = RGB(hex: 0x3A3532)
    }

    private var striped: Bool { kind == .ginger || kind == .greyTabby }
    /// Black fur: lines on the face are drawn light rather than in the outline.
    var dark: Bool { kind == .black || kind == .tuxedo }

    /// A head sprite pixel's colour, with the coat's markings.
    func head(_ m: Material, col: Int, row: Int, outline: RGB) -> RGB {
        switch m {
        case .clear, .outline: return outline
        case .pink: return innerEar
        case .light: return kind == .black ? fur : light
        default: break
        }
        let base = m == .shade ? shade : m == .highlight ? highlight : fur
        if striped {
            // An "M" on the brow and two stripes on each cheek.
            let brow = (row == 5 || row == 6) && [8, 10, 12].contains(col) || row == 7 && col == 10
            let cheek = (row == 10 || row == 12) && (col <= 2 || col >= 18)
            if brow || cheek { return stripe }
        }
        if kind == .calico {
            // Orange over one ear and eye, black over the other ear.
            if col <= 9 && row <= 11 && col + row <= 17 { return m == .shade ? stripe.scaled(0.85) : stripe }
            if col >= 12 && row <= 8 && (col - 12) + (8 - row) >= 2 { return patch }
        }
        return base
    }

    /// The body (behind the drums): shaded at its sides, a pale chest for most coats, stripes or patches.
    func body(x: Int, y: Int, cx: Double, edge: Double) -> RGB {
        // Below the drum heads the body is in the drums' shadow.
        if y >= 31 { return shade.scaled(0.8) }
        let dx = (Double(x) + 0.5 - cx) / 3.6, dy = (Double(y) + 0.5 - 25) / 5.5
        let chest = dx * dx + dy * dy <= 1
        if chest && kind != .black { return light }
        if striped && y % 3 == 0 && edge < 3.5 { return stripe }
        if kind == .calico {
            if x < 21 && y > 23 { return stripe }
            if x > 26 && y < 27 { return patch }
        }
        return edge < 1.6 ? shade : fur
    }

    /// The front legs: bands down them for tabbies, white socks for tuxedos and calicos.
    func arm(along: Double) -> RGB {
        if (kind == .tuxedo || kind == .calico) && along > 0.6 { return light }
        if striped && Int(along * 6) % 2 == 1 { return stripe }
        if kind == .calico { return stripe }
        return fur
    }

    var paw: RGB { kind == .tuxedo || kind == .calico ? light : kind == .black ? highlight : fur }

    /// The tail, `along` 0 at its root to 1 at the tip: ringed for tabbies, a dark tip on a calico.
    func tail(along: Double) -> RGB {
        if striped { return Int(along * 7) % 2 == 1 ? stripe : fur }
        if kind == .calico { return along > 0.55 ? patch : stripe }
        return along > 0.85 && kind == .white ? highlight : fur
    }

    /// The curled-up body: its back (the top) in the coat's fur, the belly side pale.
    /// The curled-up body at (`u`, `v`) from its middle, `u` running from the head towards the tail end; `top` is
    /// its top row.
    func sleeper(u: Double, v: Double, y: Int, top: Int) -> RGB {
        if striped && (Int(u.rounded(.down)) + Int(v.rounded(.down)) / 2) & 3 == 0 && y < top + 10 { return stripe }
        if kind == .calico {
            // An orange patch over the back, a black one on the haunch.
            let a = ((u + 2.5) / 5.5, (v + 3) / 4.2), b = ((u - 5.5) / 4.2, (v - 0.5) / 3.6)
            if a.0 * a.0 + a.1 * a.1 <= 1 { return stripe }
            if b.0 * b.0 + b.1 * b.1 <= 1 { return patch }
        }
        if kind == .tuxedo && y >= top + 11 { return light }
        return y <= top + 1 ? highlight : fur
    }

    /// The sleeping head; `dir` is 1 when the body lies to its right.
    func sleeperHead(x: Int, y: Int, cx: Double, cy: Double, dir: Double) -> RGB {
        let dx = (Double(x) + 0.5 - cx) * dir, dy = Double(y) + 0.5 - cy
        let muzzle = abs(dx) < 2.6 && dy > 0.6 && dy < 4.5
        if muzzle && kind != .black { return light }
        if striped && dy < -2.5 && Int(dx.rounded()) % 2 == 0 { return stripe }
        if kind == .calico && dx < -1 && dy < 1 { return stripe }
        if kind == .calico && dx > 1.5 && dy < 0 { return patch }
        return dy < -3.6 ? highlight : fur
    }
}

/// The bongos: wood, rims, and which drum is the big one.
nonisolated private struct Kit {
    let wood: RGB
    let woodShade: RGB
    let woodLight: RGB
    let rim: RGB
    let rimLight: RGB
    let skin = RGB(hex: 0xF0E3C6)
    let skinShade = RGB(hex: 0xD6C39C)
    let bigLeft: Bool
    let tailRight: Bool
    let band: Int
    let rug: Int

    init(_ r: inout SceneRandom) {
        let woods: [(UInt32, UInt32, UInt32)] = [(0xC98A44, 0x99602B, 0xE6B06E), (0x8A5232, 0x623620, 0xAE7650),
                                                 (0xB5402F, 0x822B20, 0xD9705B), (0x4A3F52, 0x332B3A, 0x6E6278)]
        let wood = woods[r.int(woods.count)]
        self.wood = RGB(hex: wood.0)
        woodShade = RGB(hex: wood.1)
        woodLight = RGB(hex: wood.2)
        let rims: [(UInt32, UInt32)] = [(0xA9AFBC, 0xE4E8EF), (0xB98A2E, 0xF0CB6A), (0x3C3A44, 0x6A6874)]
        let rim = rims[r.int(rims.count)]
        self.rim = RGB(hex: rim.0)
        rimLight = RGB(hex: rim.1)
        bigLeft = r.chance(0.5)
        tailRight = r.chance(0.5)
        band = r.int(4)
        rug = r.int(4)
    }
}

/// Colours that depend on the artwork.
nonisolated private struct Paints {
    var outline = RGB(hex: 0x1E1418)
    var lamp = RGB.white
    var rug = RGB.black
    var rugEdge = RGB.black
    var band = RGB.white
    var impact = RGB.white
    var whisker = RGB.white
    var zee = RGB.white
    var notes: [RGB] = [.white]

    init() {}

    init(_ style: SceneStyle, coat: Coat, kit: Kit) {
        let light = style.isLight
        outline = light ? style.ink.mixed(with: RGB(hex: 0x1E1418), 0.6).scaled(0.7)
            : RGB(hex: 0x1C1318).mixed(with: style.deep, 0.2)
        lamp = light ? style.ink : style.accent.mixed(with: .white, 0.3)
        let rugColor = style.spark(kit.rug)
        rug = light ? rugColor.mixed(with: style.mid, 0.5) : rugColor.mixed(with: style.deep, 0.55)
        rugEdge = light ? rugColor.mixed(with: style.ink, 0.3) : rugColor.mixed(with: style.deep, 0.25)
        band = light ? style.accent.mixed(with: style.ink, 0.3) : style.spark(kit.band)
        impact = light ? style.ink : style.spark(kit.band + 1).mixed(with: .white, 0.4)
        whisker = light ? style.ink : RGB(hex: 0xF4F2EE)
        zee = light ? style.ink : style.ink.mixed(with: style.accent, 0.2)
        notes = (0..<4).map {
            light ? style.spark($0).mixed(with: style.ink, 0.35) : style.spark($0).mixed(with: .white, 0.25)
        }
    }
}

nonisolated private struct Paw {
    /// 0 down on the drum head, 1 wound right up.
    var lift = 0.0
    /// Held down on the drum for a moment after a hit.
    var hold = 0.0
    var since = 1.0
}

nonisolated private struct Mark {
    var drum: Int
    var age = 0.0
}

nonisolated private struct Note {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var life: Double
    var beamed: Bool
    var color: Int
}
