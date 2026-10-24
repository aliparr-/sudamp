// SPDX-License-Identifier: GPL-3.0-or-later
// Breakfast Band: the Dancing Toast's band, in pixel art on the same 46-pixel grid. A fried egg plays drums on a riser
// at the back: the kick drum booms on every kick, one stick ticks the hi-hat on the treble and the other hits the tom
// on the backbeat. A coffee mug plays bass on the left, plucking with the bass and swaying on the groove while steam
// curls from its top; a croissant plays keys on the right, its hands moving along the keyboard with the mids; and the
// toast fronts the band with a microphone, singing when the music swells. Lamps on a truss light them and pool on the
// stage. Through a breakdown the band sways slowly (the bassist with its eyes shut), the drummer keeps a soft hat
// going and the lights dim to the singer; when the bass comes back everyone jumps, the crash cymbal rings and crumbs,
// flakes and sparkles fly. In silence the band waits, eyes open, under dim lights. Each seed changes the band's
// looks: the mug's colour and print, the toast's bake and topping, the yolk, the drummer's sweatband, the croissant's
// bake (and sometimes a beret), the instruments' colours and the lights.
//
// Everyone is a small sprite drawn at whole pixels, with one-pixel limbs and white gloves as the Dancing Toast has;
// the singer is the Dancing Toast's own slice, cut smaller. A lean shifts a sprite's upper rows (pixel art doesn't
// rotate).

import CoreGraphics
import Foundation

nonisolated final class BreakfastBandScene: VisualizerScene {
    /// 46 pixels across: 2 points a pixel on the 92-point artwork, whole pixels at 1x and 2x.
    private static let side = 46
    /// Rows: the back of the stage floor, the drum riser's top, and the singer's sneakers.
    private static let floorTop = 38
    private static let riserTop = 27
    private static let singerFeet = 42
    /// The singer's slice, in points (two to a pixel): standing, and squashed on the beat.
    private static let sliceSizes: [(CGFloat, CGFloat)] = [(26, 25), (28, 23)]

    private var canvas = PixelCanvas(width: BreakfastBandScene.side, height: BreakfastBandScene.side)
    private var random: SceneRandom
    private let look: Look
    private var paints: Paints?
    private let slices: [ToastSprite]
    private var bits: [Bit] = []

    // The music.
    private var activity = 0.0
    private var pulse = 0.0
    private var calm = 0.0
    private var groove = 0.0
    private var beatIndex = 0
    private var tempo = 0.5
    private var mid = 0.0
    private var midAverage = 0.45
    private var lastTreble: Float = 0
    private var lastMid: Float = 0
    private var sinceHat = 1.0
    private var sinceChord = 1.0
    /// Beats left of the jump after a drop, and the lights' flash.
    private var jump = 0.0
    private var flash = 0.0

    // The players.
    /// The kick drum's boom, the hi-hat stick's strike and the crash cymbal's ring (1 on a hit, dying away).
    private var boom = 0.0
    private var hat = 0.0
    private var crash = 0.0
    /// The bass's pluck, and the fretting hand's place on the neck (0 at the body, 1 at the headstock).
    private var pluck = 0.0
    private var fret = 0.4
    /// The keys: each hand's column on the keyboard (eased) and where it's going, which hand played last, and how
    /// hard the last chord was struck.
    private var keyAt = [3.5, 9.5]
    private var keyTarget = [3, 10]
    private var keyHand = 0
    private var chord = 0.0
    private var chordIndex = 0
    /// How wide the singer's mouth is open (0...1).
    private var mouth = 0.0
    /// The steam's drift.
    private var steam = 0.0
    /// Blinks for the drummer, the bassist, the keys and the singer.
    private var blinkIn: [Double] = []
    private var blinkFor = [0.0, 0.0, 0.0, 0.0]

    /// None: a halo would blur the pixels.
    var glow: Double { 0 }

    init(seed: UInt64) {
        random = SceneRandom(seed: seed)
        look = Look(&random)
        slices = Self.sliceSizes.map { ToastScene.sprite(width: $0.0, height: $0.1) }
        blinkIn = (0..<4).map { _ in random.range(1.5, 4.5) }
    }

    // MARK: - Update

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let sounding = !input.isSilent
        // Activity eases in over half a second and out in a third of one, so a pause's still frame is at rest.
        activity = Self.approach(activity, sounding ? 1 : 0, rate: sounding ? 3 : 9, dt)
        pulse = Double(input.pulse)
        calm = sounding ? Double(input.breakdown) : Self.approach(calm, 0, rate: 9, dt)
        if sounding, input.groove < groove - 0.5 { beatIndex += 1 }
        groove = input.groove
        tempo = input.beatInterval
        mid = Self.approach(mid, Double(input.mid), rate: 10, dt)
        midAverage = Self.approach(midAverage, Double(input.mid), rate: 0.5, dt)

        // The hats and the chords: sharp rises in the treble and in the mids.
        let treble = AudioFeatures.mean(input.bars, 12..<input.bars.count)
        let mids = AudioFeatures.mean(input.bars, 4..<12)
        sinceHat += dt
        sinceChord += dt
        if sounding, treble - lastTreble > 0.07, treble > 0.25, sinceHat > 0.09 {
            sinceHat = 0
            hat = 1
        }
        if sounding, mids - lastMid > 0.05, sinceChord > 0.12 {
            sinceChord = 0
            playChord()
        }
        lastTreble = treble
        lastMid = mids

        if sounding, input.beat {
            boom = 1 - 0.85 * calm
            pluck = 1
            if beatIndex % 2 == 0 { fret = look.bassline[(beatIndex / 2) % look.bassline.count] }
            flash = max(flash, (beatIndex % 4 == 0 ? 0.3 : 0.16) * (1 - 0.8 * calm))
            if calm < 0.5 { shakeCrumbs(count: 1 + random.int(2), speed: 1) }
        }
        if sounding, input.drop { drop() }

        // Everything rings down, quickly in silence so the still frame is at rest.
        let fade = sounding ? 1.0 : 4.0
        boom *= exp(-dt * 9 * fade)
        hat *= exp(-dt * 13 * fade)
        pluck *= exp(-dt * 8 * fade)
        chord *= exp(-dt * 6 * fade)
        crash *= exp(-dt * 1.8 * fade)
        flash *= exp(-dt * 6 * fade)
        jump = max(0, jump - dt * (sounding ? 1 / max(tempo, 0.3) : 8))

        // The singer sings when the music swells.
        let swell = (mid - midAverage) * 5 + (mid - 0.36) * 1.5 + pulse * 0.25
        mouth = Self.approach(mouth, sounding ? min(1, max(0, swell)) : 0, rate: 14, dt)

        // The hands glide along the keys; at rest they sit over a chord in the middle.
        if !sounding { keyTarget = [4, 9] }
        for i in 0..<2 { keyAt[i] = Self.approach(keyAt[i], Double(keyTarget[i]), rate: 16, dt) }
        if !sounding { fret = Self.approach(fret, 0.4, rate: 9, dt) }

        steam += dt * (0.5 + 1.1 * activity)
        updateBlinks(dt)
        updateBits(dt, sounding: sounding)
    }

    /// The bass came back after a breakdown: everyone jumps, the crash rings, and crumbs, flakes and sparkles fly.
    private func drop() {
        jump = 2
        crash = 1
        flash = 1
        shakeCrumbs(count: 6, speed: 1.5)
        for i in 0..<12 {
            let angle = Double(i) / 12 * 2 * .pi + random.range(-0.25, 0.25)
            let speed = random.range(14, 26)
            let from = i % 3 == 0 ? (35.0, 9.0) : i % 3 == 1 ? (23.0, 30.0) : (Double(8 + random.int(30)), 20.0)
            addBit(Bit(x: from.0, y: from.1, vx: cos(angle) * speed, vy: sin(angle) * speed - 10,
                       life: random.range(0.7, 1.1), kind: .sparkle, color: i))
        }
        // Flakes off the croissant, and coffee slopped over the mug's rim.
        for _ in 0..<5 {
            addBit(Bit(x: random.range(31, 44), y: random.range(19, 24), vx: random.range(-12, 12),
                       vy: random.range(-28, -14), life: random.range(0.8, 1.2), kind: .flake, color: 0))
        }
        for _ in 0..<4 {
            addBit(Bit(x: random.range(5, 11), y: 25, vx: random.range(-8, 8), vy: random.range(-26, -16),
                       life: random.range(0.6, 0.9), kind: .coffee, color: 0))
        }
    }

    /// A chord on the keys: one hand (in turn) moves to the next place in the croissant's pattern and strikes.
    private func playChord() {
        chord = 1 - 0.4 * calm
        keyHand = 1 - keyHand
        chordIndex += 1
        let pattern = look.keyPattern
        let next = pattern[chordIndex % pattern.count]
        keyTarget[keyHand] = keyHand == 0 ? next : 13 - next
    }

    private func shakeCrumbs(count: Int, speed: Double) {
        let x = 23.0, y = 33.0
        for _ in 0..<count {
            let side: Double = random.chance(0.5) ? -1 : 1
            addBit(Bit(x: x + side * random.range(4, 7), y: y + random.range(-4, 4),
                       vx: side * random.range(6, 18) * speed, vy: -random.range(12, 26) * speed,
                       life: random.range(0.5, 0.9), kind: .crumb, color: random.int(2)))
        }
    }

    private func addBit(_ bit: Bit) {
        if bits.count >= 64 { bits.removeFirst() }
        bits.append(bit)
    }

    private func updateBits(_ dt: Double, sounding: Bool) {
        for i in bits.indices {
            switch bits[i].kind {
            case .sparkle:
                bits[i].vx *= exp(-dt * 2)
                bits[i].vy = bits[i].vy * exp(-dt * 2) + 12 * dt
                bits[i].x += bits[i].vx * dt
                bits[i].y += bits[i].vy * dt
            case .crumb, .flake, .coffee:
                bits[i].vy += (bits[i].kind == .flake ? 40 : 75) * dt
                bits[i].x += bits[i].vx * dt
                bits[i].y += bits[i].vy * dt
                let floor = Double(bits[i].x < 16 || bits[i].x > 30 ? Self.floorTop : Self.singerFeet + 1)
                if bits[i].y > floor, bits[i].vy > 0 {
                    bits[i].y = floor
                    bits[i].vy *= -0.3
                    bits[i].vx *= 0.5
                }
            }
            bits[i].life -= dt * (sounding ? 1 : 4)
        }
        bits.removeAll { $0.life <= 0 }
    }

    /// Blinks only while playing, so a paused still frame never catches anyone's eyes shut.
    private func updateBlinks(_ dt: Double) {
        for i in 0..<4 {
            if blinkFor[i] > 0 {
                blinkFor[i] -= dt
            } else if activity > 0.5 {
                blinkIn[i] -= dt
                if blinkIn[i] <= 0 {
                    blinkFor[i] = 0.13
                    blinkIn[i] = random.range(2.2, 5.5)
                }
            }
            if activity < 0.2 { blinkFor[i] = 0 }
        }
    }

    // MARK: - The dance

    private var playing: Bool { activity > 0.5 }
    private var beat: Double { Double(beatIndex) + groove }

    /// How high a jump after the drop has everyone (pixels, up to `height`).
    private func hop(_ height: Double) -> Int {
        guard jump > 0 else { return 0 }
        let t = 2 - jump
        return Int((height * sin(.pi * (t - t.rounded(.down))) * min(1, jump * 2)).rounded())
    }

    /// Down a pixel on the beat (not in a breakdown).
    private func dip(_ until: Double = 0.22) -> Int { playing && calm < 0.5 && groove < until ? 1 : 0 }

    /// A sway from side to side (-1...1, a little wider through a breakdown): over two beats while playing, four
    /// through a breakdown.
    private func sway(_ phase: Double = 0) -> Double {
        let fast = sin(.pi * (beat + phase)), slow = sin(.pi * (beat + phase) / 2)
        return activity * (fast + (slow - fast) * calm) * (1 + 0.5 * calm)
    }

    // MARK: - Draw

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        if paints?.style != style { paints = Paints(style, look: look) }
        guard let p = paints else { return }
        canvas.clear()
        paintRoom(p)
        paintStage(p)
        paintDrums(p)
        paintKeys(p)
        paintBass(p)
        paintSinger(p)
        paintBits(p)
        canvas.draw(in: ctx, rect: CGRect(origin: .zero, size: size))
    }

    /// The room: the artwork dimmed on dark styles (a flash of the lights' colour on the strong kicks), the beams
    /// from the lamps, and the truss.
    private func paintRoom(_ p: Paints) {
        let style = p.style
        if !style.isLight {
            let wash = style.deep.mixed(with: .black, 0.4), washAlpha = 0.32 - 0.04 * activity + 0.12 * calm
            let tint = style.spark(look.lightShift + beatIndex / 8), f = flash * 0.25
            let alpha = washAlpha + f * (1 - washAlpha)
            let color = RGB((tint.r * f + wash.r * washAlpha * (1 - f)) / alpha,
                            (tint.g * f + wash.g * washAlpha * (1 - f)) / alpha,
                            (tint.b * f + wash.b * washAlpha * (1 - f)) / alpha)
            canvas.rect(0, 0, Self.side, Self.side, color, alpha)
        }
        // Each lamp lights a player; through a breakdown the outer two dim and the inner two hold the singer.
        let envelope = pow(1 - groove, 3)
        for (i, lamp) in Lamp.all.enumerated() {
            let chase = beatIndex % 4 == i ? 0.1 * envelope * activity * (1 - calm) : 0
            let outer = i == 0 || i == 3
            var strength = 0.06 + activity * (0.12 + chase) + flash * 0.2
            if outer { strength *= 1 - 0.75 * calm } else { strength *= 1 + 0.3 * calm }
            let aim = lamp.target.0 + 2.5 * sway(Double(i) * 0.5) * (1 - calm)
            let color = style.isLight ? p.lamps[i] : p.lamps[i].mixed(with: .white, 0.3)
            beam(from: (lamp.x, 3), to: (aim, lamp.target.1), color: color, alpha: strength * (style.isLight ? 1.1 : 1))
        }
        for x in 7...38 { canvas.set(x, 0, p.truss, 0.85) }
        for (i, lamp) in Lamp.all.enumerated() {
            let x = Int(lamp.x) - 1
            canvas.rect(x, 1, 2, 2, p.truss)
            let lit = 0.35 + 0.65 * min(1, activity * (1 - 0.6 * calm) + flash)
            canvas.set(x + (lamp.target.0 < lamp.x ? 0 : 1), 2, p.lampsLit[i], lit)
        }
    }

    /// The stage: a wooden floor with pools of light under the players, and the drum riser.
    private func paintStage(_ p: Paints) {
        let top = Self.floorTop
        canvas.rect(0, top, Self.side, Self.side - top, p.floor)
        for (row, alpha) in [(top, 0.5), (top + 2, 0.18), (top + 5, 0.18)] {
            canvas.rect(0, row, Self.side, 1, p.floorLine, alpha)
        }
        // Pools of light where the beams land.
        for (i, lamp) in Lamp.all.enumerated() {
            let outer = i == 0 || i == 3
            var strength = 0.08 + 0.1 * activity + flash * 0.15
            if outer { strength *= 1 - 0.7 * calm }
            let x = Int(lamp.pool.0), y = Int(lamp.pool.1)
            let w = lamp.poolWidth
            canvas.rect(x - w / 2 + 2, y, w - 4, 1, p.lamps[i], strength)
            canvas.rect(x - w / 2, y, 2, 1, p.lamps[i], strength * 0.5)
            canvas.rect(x + w / 2 - 2, y, 2, 1, p.lamps[i], strength * 0.5)
            canvas.rect(x - w / 2 + 3, y + 1, w - 6, 1, p.lamps[i], strength * 0.5)
        }
        // The riser.
        canvas.rect(12, Self.riserTop, 23, Self.floorTop - Self.riserTop, p.riser)
        canvas.rect(12, Self.riserTop, 23, 1, p.riserTop)
        canvas.rect(12, Self.riserTop + 2, 23, 1, p.riserEdge, 0.5 + 0.4 * activity * (1 - calm) * (0.5 + 0.5 * boom))
    }

    // MARK: The drummer

    private func paintDrums(_ p: Paints) {
        let lift = hop(2)
        // The drummer bounces on the kick, and sways behind the kit through a breakdown.
        let eggX = 15 + Int((sway(1) * calm).rounded()), eggY = 3 + (playing && boom > 0.45 ? 1 : 0) - lift

        // The stands, behind the drummer.
        let hatX = 8
        for y in 19..<Self.riserTop { canvas.set(hatX + 3, y, p.metal) }
        canvas.set(hatX + 2, Self.riserTop - 1, p.metal)
        canvas.set(hatX + 4, Self.riserTop - 1, p.metal)
        for y in 9..<Self.riserTop { canvas.set(36, y, p.metal) }

        // The crash: tipped towards us, rocking while it rings.
        let wobble = crash > 0.08 ? (Int((steam * 30).rounded(.down)) % 2 == 0 ? 1 : -1) : 0
        let crashLit = crash > 0.3
        let brass = crashLit ? p.brassLight : p.brass
        canvas.rect(32, 8 + (wobble < 0 ? -1 : 0), 4, 1, brass)
        canvas.rect(36, 7 + (wobble > 0 ? 1 : 0), 4, 1, brass)
        canvas.set(36, 7, p.brassLight)
        if crashLit { canvas.set(34, 7, .white, crash) }

        // The egg.
        look.egg.draw(&canvas, x: eggX, y: eggY, colors: p.egg)
        if look.sweatband {
            for (x, y) in [(4, 1), (5, 1), (6, 1), (7, 1), (8, 1), (9, 1), (10, 1), (11, 2), (12, 2)] {
                canvas.set(eggX + x, eggY + y + 1, p.sweatband)
            }
        }
        for (x, y) in look.pepper { canvas.set(eggX + x, eggY + y, p.pepper) }
        paintEggFace(p, x: eggX, y: eggY)

        // The kick drum, its head flashing on the kick, and a heart on it.
        let kickX = 18, kickY = 16
        Art.kick.draw(&canvas, x: kickX, y: kickY, colors: p.kick)
        if boom > 0.05 {
            canvas.rect(kickX + 3, kickY + 2, 5, 7, p.kickFlash, boom * 0.6)
            canvas.rect(kickX + 2, kickY + 3, 7, 5, p.kickFlash, boom * 0.6)
        }
        let hx = kickX + 3, hy = kickY + 4
        canvas.rect(hx, hy, 2, 1, p.emblem)
        canvas.rect(hx + 3, hy, 2, 1, p.emblem)
        canvas.rect(hx, hy + 1, 5, 1, p.emblem)
        canvas.rect(hx + 1, hy + 2, 3, 1, p.emblem)
        canvas.set(hx + 2, hy + 3, p.emblem)
        canvas.set(hx, hy, p.emblem.mixed(with: .white, 0.5))
        // Two toms on the kick, hiding the drummer's lower half.
        for tomX in [15, 26] { Art.tom.draw(&canvas, x: tomX, y: 14, colors: p.tom) }

        // The hi-hat: two cymbals that open between hits.
        let open = playing && hat < 0.5 ? 1 : 0
        canvas.rect(hatX, 18, 7, 1, p.brass)
        canvas.rect(hatX, 17 - open, 7, 1, hat > 0.5 ? p.brassLight : p.brass)
        canvas.set(hatX + 3, 16 - open, p.brass)

        // Arms and sticks. The left stick ticks the hat on the treble (softly through a breakdown); the right hits the
        // tom on the backbeat, winding up between, and the crash on the drop.
        let shoulderY = eggY + 9
        let amount = activity * (1 - 0.55 * calm)
        let hatLift = amount * (1 - hat)
        let hatHand = lerp((12, 13), (12, 10), hatLift), hatTip = lerp((9, 16), (10, 6), hatLift)
        var tomLift = 0.0
        if playing, calm < 0.5 {
            let s = (Double(beatIndex % 2 == 1 ? 0 : 1) + groove) / 2
            tomLift = min(1, s * 5) * min(1, (1 - s) * 4)
        }
        tomLift *= activity * (1 - calm)
        var tomHand = lerp((32, 12), (33, 9), tomLift), tomTip = lerp((29, 14), (32, 5), tomLift)
        if jump > 1 {
            tomHand = (32, 5)
            tomTip = (35, 7)
        }
        paintArm(from: (eggX + 2, shoulderY), to: hatHand, stick: hatTip, p: p)
        paintArm(from: (eggX + 14, shoulderY), to: tomHand, stick: tomTip, p: p)
    }

    private func paintEggFace(_ p: Paints, x: Int, y: Int) {
        let eyeY = y + 6
        if blinkFor[0] > 0 {
            canvas.set(x + 6, eyeY + 1, p.eye)
            canvas.set(x + 10, eyeY + 1, p.eye)
        } else {
            canvas.rect(x + 6, eyeY, 1, 2, p.eye)
            canvas.rect(x + 10, eyeY, 1, 2, p.eye)
        }
        let excited = crash > 0.4 || jump > 0.5
        if excited {
            canvas.rect(x + 7, y + 8, 3, 2, p.mouth)
        } else {
            canvas.set(x + 6, y + 8, p.eye)
            canvas.rect(x + 7, y + 9, 3, 1, p.eye)
            canvas.set(x + 10, y + 8, p.eye)
        }
    }

    /// A one-pixel arm from a shoulder to a white-gloved hand, holding a stick out to `stick`.
    private func paintArm(from shoulder: (Int, Int), to hand: (Double, Double), stick: (Double, Double), p: Paints) {
        let h = (Int(hand.0.rounded()), Int(hand.1.rounded()))
        let t = (Int(stick.0.rounded()), Int(stick.1.rounded()))
        line(shoulder, h, p.limb)
        line(h, t, p.stick)
        canvas.set(t.0, t.1, p.stickTip)
        glove(h.0, h.1, 2, 1, p)
    }

    // MARK: The keys

    private func paintKeys(_ p: Paints) {
        let lift = hop(2)
        let bob = dip()
        let lean = Int((sway(0.5) * 1.2).rounded())
        let x = 27, y = 17 + bob - lift
        let kx = 31, ky = 26
        // Legs under the keyboard, between the stand's.
        for (hip, foot) in [(35, 34), (40, 41)] {
            line((hip, ky + 3 - lift), (foot, Self.floorTop - 1 - lift), p.limb)
            canvas.rect(foot - 1, Self.floorTop - 1 - lift, 2, 1, p.shoes[1])
            canvas.rect(foot - 1, Self.floorTop - lift, 2, 1, p.sole)
        }
        look.croissant.draw(&canvas, x: x, y: y, colors: p.croissant, shift: { row in row < 4 ? lean : 0 })
        if look.beret {
            let bx = x + 6 + lean
            canvas.rect(bx, y - 1, 7, 1, p.beret)
            canvas.rect(bx + 1, y - 2, 5, 1, p.beret)
            canvas.set(bx + 3, y - 3, p.beret)
        }
        paintCroissantFace(p, x: x + lean, y: y)

        // The keyboard on its stand: a lit key under each hand that's playing.
        line((33, ky + 4), (42, Self.floorTop - 1), p.metal)
        line((42, ky + 4), (33, Self.floorTop - 1), p.metal)
        Art.keyboard.draw(&canvas, x: kx, y: ky, colors: p.keyboard)
        for i in 0..<3 { canvas.set(kx + 2 + i * 2, ky, p.lamps[(i + look.lightShift) % 4], 0.5 + 0.5 * activity) }
        for side in 0..<2 {
            let col = Int(keyAt[side].rounded())
            let striking = side == keyHand && chord > 0.35
            if striking { canvas.rect(kx + col, ky + 1, 1, 2, p.keyLit) }
            let hand = (kx + col, ky + (striking ? 1 : 0))
            let shoulder = (x + (side == 0 ? 5 : 13) + lean, y + 7)
            line(shoulder, hand, p.limb)
            glove(hand.0 - (side == 0 ? 1 : 0), hand.1, 2, 1, p, outlined: true)
        }
    }

    private func paintCroissantFace(_ p: Paints, x: Int, y: Int) {
        let eyeY = y + 3
        if blinkFor[2] > 0 {
            canvas.set(x + 7, eyeY + 1, p.eye)
            canvas.set(x + 11, eyeY + 1, p.eye)
        } else {
            canvas.rect(x + 7, eyeY, 1, 2, p.eye)
            canvas.rect(x + 11, eyeY, 1, 2, p.eye)
        }
        if jump > 0.5 || chord > 0.7 {
            canvas.rect(x + 8, y + 5, 3, 2, p.mouth)
        } else {
            canvas.set(x + 8, y + 5, p.eye)
            canvas.set(x + 9, y + 6, p.eye)
            canvas.set(x + 10, y + 5, p.eye)
        }
        canvas.set(x + 6, y + 5, p.cheek, 0.8)
        canvas.set(x + 12, y + 5, p.cheek, 0.8)
    }

    // MARK: The bassist

    private func paintBass(_ p: Paints) {
        let lift = hop(2)
        let s = sway()
        let shift = Int((s * 1.1).rounded())
        let lean = Int((s * 1.6).rounded()) - shift
        let bob = dip()
        let x = 1 + shift, y = 24 + bob - lift

        // Steam curling up from the coffee.
        for wisp in 0..<2 {
            let base = Double(x + 3 + wisp * 3 + lean)
            for k in 0..<7 {
                let rise = Double(k) + (steam * 2.2 + Double(wisp) * 1.7).truncatingRemainder(dividingBy: 1)
                let wave = sin(rise * 0.9 - steam * 2.4 + Double(wisp) * 2.1) * 1.3
                let alpha = (1 - rise / 7.5) * (p.style.isLight ? 0.4 : 0.5)
                canvas.set(Int((base + wave).rounded()), y - 1 - Int(rise.rounded()), p.steam, alpha)
            }
        }
        // Legs and sneakers.
        for (hip, foot) in [(x + 3, 3), (x + 6, 7)] {
            line((hip, y + 12), (foot + shift / 2, Self.floorTop - 1 - lift), p.limb)
            canvas.rect(foot - 1 + shift / 2, Self.floorTop - 1 - lift, 3, 1, p.shoes[0])
            canvas.rect(foot - 1 + shift / 2, Self.floorTop - lift, 3, 1, p.sole)
        }
        look.mug.draw(&canvas, x: x, y: y, colors: p.mug, shift: { row in row < 6 ? lean : 0 })
        paintPrint(p, x: x, y: y, lean: lean)
        paintMugFace(p, x: x + lean, y: y)

        // The bass, slung low: the body at the bottom right, the neck up to the left, past the mug.
        let bodyX = x + 7, bodyY = y + 8
        let nut = (x, y + 7)
        line((bodyX, bodyY + 2), nut, p.neck)
        canvas.rect(nut.0 - 1, nut.1 - 2, 2, 3, p.headstock)
        canvas.set(nut.0 - 1, nut.1 - 2, p.peg)
        canvas.set(nut.0, nut.1 - 1, p.peg)
        Art.bass.draw(&canvas, x: bodyX, y: bodyY, colors: p.bass)
        // Fretting hand on the neck, sliding with the bassline; plucking hand at the body, flicking on each note.
        let along = 0.55 + 0.35 * fret
        let fretHand = (Int((Double(bodyX) + Double(nut.0 - bodyX) * along).rounded()),
                        Int((Double(bodyY + 2) + Double(nut.1 - bodyY - 2) * along).rounded()))
        line((x, y + 5), fretHand, p.limb)
        glove(fretHand.0, fretHand.1 - 1, 1, 2, p)
        let flick = pluck > 0.5 ? 1 : 0
        if pluck > 0.3 { canvas.rect(bodyX + 2, bodyY + 2, 3, 1, p.peg, pluck) }
        let pluckHand = (bodyX + 3 + flick, bodyY + 1 - flick)
        line((x + 10, y + 9), pluckHand, p.limb)
        glove(pluckHand.0, pluckHand.1, 2, 1, p)
    }

    private func paintPrint(_ p: Paints, x: Int, y: Int, lean: Int) {
        switch look.print {
        case .stripes:
            canvas.rect(x + 1 + lean, y + 3, 9, 1, p.print)
            canvas.rect(x + 1, y + 11, 9, 1, p.print)
        case .dots:
            for (dx, dy) in [(2, 3), (5, 3), (8, 3), (2, 9), (4, 11)] {
                canvas.set(x + dx + (dy < 6 ? lean : 0), y + dy, p.print)
            }
        case .rim:
            canvas.rect(x + 1 + lean, y + 2, 9, 1, p.print)
        case .plain:
            break
        }
    }

    private func paintMugFace(_ p: Paints, x: Int, y: Int) {
        let eyeY = y + 4
        if playing, calm > 0.6 {
            // Lost in the breakdown: eyes shut, smiling (open again long before a pause's still frame).
            for ex in [x + 3, x + 7] {
                canvas.set(ex - 1, eyeY + 1, p.eye)
                canvas.set(ex, eyeY, p.eye)
                canvas.set(ex + 1, eyeY + 1, p.eye)
            }
        } else if blinkFor[1] > 0 {
            canvas.set(x + 3, eyeY + 1, p.eye)
            canvas.set(x + 7, eyeY + 1, p.eye)
        } else {
            canvas.rect(x + 3, eyeY, 1, 2, p.eye)
            canvas.rect(x + 7, eyeY, 1, 2, p.eye)
        }
        if jump > 0.5 {
            canvas.rect(x + 4, y + 6, 3, 2, p.mouth)
        } else {
            canvas.set(x + 4, y + 6, p.eye)
            canvas.set(x + 5, y + 7, p.eye)
            canvas.set(x + 6, y + 6, p.eye)
        }
        canvas.set(x + 2, y + 6, p.cheek, 0.7)
        canvas.set(x + 8, y + 6, p.cheek, 0.7)
    }

    // MARK: The singer

    private func paintSinger(_ p: Paints) {
        let lift = hop(4)
        let bob = dip(0.25)
        let s = sway(0.25)
        let shift = Int((s * 1.2).rounded())
        let cx = 23 + shift
        let bottom = 40 + bob - lift
        let sprite = slices[bob == 1 ? 1 : 0]

        // Legs, stepping on alternate beats.
        let step = playing && calm < 0.5 && groove > 0.25 && groove < 0.7 ? 1 : 0
        for side in 0..<2 {
            let lifted = (beatIndex % 2 == side ? step : 0) + lift / 2
            let hip = (cx + (side == 0 ? -3 : 2), bottom)
            let foot = (cx + (side == 0 ? -4 : 3) - shift / 2, Self.singerFeet - lifted - lift / 2)
            line(hip, foot, p.limb)
            let fx = foot.0 + (side == 0 ? -1 : 0)
            canvas.rect(fx, foot.1 - 1, 3, 1, p.shoes[2])
            canvas.rect(fx, foot.1, 3, 1, p.sole)
        }

        // The slice: outline, crust, toast and a paler middle.
        let colors = [p.outline, look.toast.crust.scaled(0.55), look.toast.crust, look.toast.face, look.toast.middle]
        for row in sprite.rows {
            for col in sprite.columns {
                let cell = sprite[col, row]
                guard cell != 0 else { continue }
                canvas.set(cx + col, bottom + row, colors[Int(cell)])
            }
        }
        paintTopping(p, x: cx, y: bottom + sprite.crown)
        paintSingerFace(p, x: cx, y: bottom - 7)

        // The microphone hand at the mouth, and the other arm dancing.
        let shoulderY = bottom - 6
        let micHand = (cx + 4, bottom - 2)
        line((cx + 6, shoulderY), (cx + 8, bottom - 3), p.limb)
        line((cx + 8, bottom - 3), micHand, p.limb)
        canvas.rect(micHand.0 - 1, micHand.1 - 3, 2, 2, p.mic)
        canvas.set(micHand.0 - 1, micHand.1 - 3, p.micShine)
        canvas.set(micHand.0, micHand.1 - 1, p.micHandle)
        canvas.set(micHand.0 - 1, micHand.1 - 2, p.micHandle, 0.5)
        glove(micHand.0, micHand.1, 2, 1, p)

        let free = freeHand(cx: cx, bottom: bottom)
        let shoulder = (cx - 7, shoulderY)
        let elbow = (Int(((Double(shoulder.0) + free.0) / 2 - 1.5).rounded()),
                     Int(((Double(shoulder.1) + free.1) / 2 + 1).rounded()))
        let hand = (Int(free.0.rounded()), Int(free.1.rounded()))
        line(shoulder, elbow, p.limb)
        line(elbow, hand, p.limb)
        glove(hand.0 - 1, hand.1 - 1, 2, 2, p)
    }

    /// Where the singer's free hand goes: down at rest, pumping on the beat, reaching out on a big note, waving through
    /// a breakdown, up for the drop.
    private func freeHand(cx: Int, bottom: Int) -> (Double, Double) {
        let x = Double(cx), y = Double(bottom)
        let rest = (x - 8, y - 2)
        guard activity > 0.01 else { return rest }
        var target: (Double, Double)
        if jump > 0.3 {
            target = (x - 5, y - 18)
        } else {
            let pump = groove < 0.3 ? (x - 6, y - 16) : (x - 8, y - 10)
            let reach = (x - 9, y - 14)
            target = lerp(pump, reach, min(1, max(0, (mouth - 0.6) * 3)))
            let wave = (x - 5 + 1.5 * sin(.pi * beat / 2), y - 17)
            target = lerp(target, wave, calm)
        }
        return lerp(rest, target, activity)
    }

    private func paintSingerFace(_ p: Paints, x: Int, y: Int) {
        if blinkFor[3] > 0 {
            canvas.rect(x - 4, y + 1, 2, 1, p.eye)
            canvas.rect(x + 2, y + 1, 2, 1, p.eye)
        } else {
            canvas.rect(x - 4, y, 2, 2, p.eye)
            canvas.rect(x + 2, y, 2, 2, p.eye)
            canvas.set(x - 4, y, .white)
            canvas.set(x + 2, y, .white)
        }
        canvas.rect(x - 6, y + 2, 1, 1, p.cheek, 0.7)
        canvas.rect(x + 5, y + 2, 1, 1, p.cheek, 0.7)
        let m = y + 3
        if mouth > 0.55 || jump > 0.5 {
            canvas.rect(x - 2, m, 3, 3, p.mouth)
            canvas.rect(x - 1, m + 2, 1, 1, p.tongue)
        } else if mouth > 0.2 {
            canvas.rect(x - 1, m, 2, 2, p.mouth)
        } else {
            canvas.set(x - 2, m, p.eye)
            canvas.rect(x - 1, m + 1, 2, 1, p.eye)
            canvas.set(x + 1, m, p.eye)
        }
    }

    private func paintTopping(_ p: Paints, x: Int, y: Int) {
        let hopped = jump > 1.2 ? -1 : 0
        switch look.toast.topping {
        case .butter:
            canvas.rect(x - 2, y - 2 + hopped, 4, 1, RGB(hex: 0xFFF0A8))
            canvas.rect(x - 3, y - 1, 6, 1, RGB(hex: 0xF7D660))
        case .jam:
            canvas.rect(x - 2, y - 2 + hopped, 3, 1, RGB(hex: 0xC8102E))
            canvas.rect(x - 3, y - 1, 6, 1, RGB(hex: 0xC8102E))
            canvas.set(x - 2, y - 2 + hopped, .white, 0.7)
        case .avocado:
            canvas.rect(x - 3, y - 2 + hopped, 2, 1, RGB(hex: 0x9CCB4A))
            canvas.rect(x, y - 2, 3, 1, RGB(hex: 0x7FB13A))
            canvas.rect(x - 3, y - 1, 6, 1, RGB(hex: 0x6E9F2E))
        }
    }

    private func paintBits(_ p: Paints) {
        for bit in bits {
            let alpha = min(1, bit.life * 2.5)
            let x = Int(bit.x.rounded(.down)), y = Int(bit.y.rounded(.down))
            switch bit.kind {
            case .crumb:
                canvas.set(x, y, bit.color == 0 ? look.toast.crust : look.toast.face, alpha)
            case .flake:
                canvas.set(x, y, look.bake.light, alpha)
            case .coffee:
                canvas.set(x, y, p.coffee, alpha)
            case .sparkle:
                let color = p.style.spark(bit.color)
                canvas.set(x, y, p.style.isLight ? color : color.mixed(with: .white, 0.5), alpha)
                if bit.life > 0.35 {
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        canvas.set(x + dx, y + dy, color, alpha * 0.8)
                    }
                }
            }
        }
    }

    // MARK: - Pixel helpers

    /// A white glove, outlined on light artwork (or wherever it would vanish) as the Dancing Toast's are.
    private func glove(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ p: Paints, outlined: Bool = false) {
        if outlined || p.style.isLight {
            canvas.rect(x - 1, y, w + 2, h, p.outline)
            canvas.rect(x, y - 1, w, h + 2, p.outline)
        }
        canvas.rect(x, y, w, h, p.glove)
    }

    /// A soft beam of light from `from`, widening towards `to` and fading as it goes.
    private func beam(from: (Double, Int), to: (Double, Double), color: RGB, alpha: Double) {
        guard alpha > 0.005 else { return }
        let length = max(1, to.1 - Double(from.1))
        let slope = (to.0 - from.0) / length
        for dy in 1...Int(length) {
            let fy = Double(dy)
            let cx = from.0 + slope * fy
            let half = 0.4 + fy * 0.11
            let fade = alpha * (1 - fy / (length + 6))
            let lo = Int((cx - half - 0.5).rounded(.down)), hi = Int((cx + half + 0.5).rounded(.up))
            for x in lo...hi {
                let cover = min(1, max(0, half + 0.5 - abs(Double(x) + 0.5 - cx)))
                if cover > 0.2 { canvas.set(x, from.1 + dy, color, fade * (cover > 0.6 ? 1 : 0.5)) }
            }
        }
    }

    /// A one-pixel line between two pixels.
    private func line(_ a: (Int, Int), _ b: (Int, Int), _ color: RGB, _ alpha: Double = 1) {
        var x0 = a.0, y0 = a.1
        let dx = abs(b.0 - x0), dy = -abs(b.1 - y0)
        let stepX = x0 < b.0 ? 1 : -1, stepY = y0 < b.1 ? 1 : -1
        var error = dx + dy
        while true {
            canvas.set(x0, y0, color, alpha)
            if x0 == b.0, y0 == b.1 { break }
            let e2 = 2 * error
            if e2 >= dy {
                error += dy
                x0 += stepX
            }
            if e2 <= dx {
                error += dx
                y0 += stepY
            }
        }
    }

    private func lerp(_ a: (Double, Double), _ b: (Double, Double), _ t: Double) -> (Double, Double) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
    }

    private static func approach(_ value: Double, _ target: Double, rate: Double, _ dt: Double) -> Double {
        value + (target - value) * (1 - exp(-dt * rate))
    }
}

// MARK: - The lights

/// The lamps on the truss: where each hangs, what it lights, and the pool it leaves on the floor.
private nonisolated struct Lamp {
    let x: Double
    let target: (Double, Double)
    let pool: (Double, Double)
    let poolWidth: Int

    static let all = [
        Lamp(x: 9, target: (7, 36), pool: (7, 39), poolWidth: 14),
        Lamp(x: 18, target: (24, 40), pool: (23, 43), poolWidth: 16),
        Lamp(x: 28, target: (22, 40), pool: (23, 43), poolWidth: 16),
        Lamp(x: 37, target: (38, 34), pool: (38, 39), poolWidth: 14),
    ]
}

// MARK: - The looks

/// The band's looks, picked by the seed.
private nonisolated struct Look {
    enum Print: CaseIterable { case stripes, dots, rim, plain }
    enum Topping: CaseIterable { case butter, jam, avocado }

    struct Toast {
        let crust: RGB
        let face: RGB
        let middle: RGB
        let topping: Topping
    }

    struct Bake {
        let crust: RGB
        let body: RGB
        let light: RGB
        let shade: RGB
    }

    let toast: Toast
    let bake: Bake
    let mugColor: RGB
    let printColor: RGB?
    let print: Print
    let yolk: (RGB, RGB, RGB)
    let sweatband: Bool
    let pepper: [(Int, Int)]
    let beret: Bool
    let bassColor: RGB
    let keysColor: RGB
    let kitColor: RGB
    let kitShift: Int
    let lightShift: Int
    let shoeShift: Int
    /// Where the bassist's fretting hand goes, every two beats, and the croissant's chords.
    let bassline: [Double]
    let keyPattern: [Int]
    let egg: BandSprite
    let mug: BandSprite
    let croissant: BandSprite

    /// Whether two colours would blur together.
    static func near(_ a: RGB, _ b: RGB) -> Bool { abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) < 0.45 }

    init(_ r: inout SceneRandom) {
        // The toast: light, golden, well done or wholemeal, as the Dancing Toast's.
        let tones: [(UInt32, UInt32, UInt32)] = [(0xC98A3D, 0xF2D58E, 0xF8E7B5), (0xB5651D, 0xE8B04B, 0xF3CF7A),
                                                 (0x7A4214, 0xC47F2E, 0xD99A47), (0x8A5A2B, 0xC99560, 0xD9AE7C)]
        let tone = tones[r.int(tones.count)]
        toast = Toast(crust: RGB(hex: tone.0), face: RGB(hex: tone.1), middle: RGB(hex: tone.2),
                      topping: Topping.allCases[r.int(Topping.allCases.count)])
        // The croissant: pale, golden or deeply baked.
        let bakes: [(UInt32, UInt32, UInt32, UInt32)] = [(0xB0702A, 0xE9B865, 0xF7DA9A, 0xC98B3E),
                                                         (0x8E4C17, 0xD9922F, 0xF2C46B, 0xB36A22),
                                                         (0x6A3410, 0xB86A22, 0xDE9A45, 0x8E4E18)]
        let bake = bakes[r.int(bakes.count)]
        self.bake = Bake(crust: RGB(hex: bake.0), body: RGB(hex: bake.1), light: RGB(hex: bake.2),
                         shade: RGB(hex: bake.3))
        // The mug: diner white, red, teal, mustard, cobalt or pink, and its print.
        let mugs: [(UInt32, UInt32?)] = [(0xF4EFE6, 0xD94A3A), (0xD8433A, 0xFFFFFF), (0x2FA39A, 0xFFF4D6),
                                        (0xE8B23A, 0x8A3B12), (0x3D62C9, 0xFFFFFF), (0xF08AA8, 0xFFFFFF)]
        let mug = mugs[r.int(mugs.count)]
        mugColor = RGB(hex: mug.0)
        printColor = mug.1.map { RGB(hex: $0) }
        print = Print.allCases[r.int(Print.allCases.count)]
        // The yolk: sunny, deep orange, or over easy (a pale film over it).
        let yolks: [(UInt32, UInt32, UInt32)] = [(0xFFB21C, 0xFFE27A, 0xE07A00), (0xFF8A1C, 0xFFC46A, 0xC85A00),
                                                 (0xFFD25A, 0xFFF0B8, 0xE8A030)]
        let yolk = yolks[r.int(yolks.count)]
        self.yolk = (RGB(hex: yolk.0), RGB(hex: yolk.1), RGB(hex: yolk.2))
        sweatband = r.chance(0.5)
        pepper = r.chance(0.5) ? [(3, 11), (13, 4), (12, 12), (2, 6)] : []
        beret = r.chance(0.4)
        // The bass: sunburst red, cream, blue, natural wood or mint, never the mug's own colour.
        let basses: [UInt32] = [0xC8462A, 0xF2EEE6, 0x2B6CB0, 0xD9A35E, 0x6CCFB0]
        let start = r.int(basses.count), mugRGB = RGB(hex: mug.0)
        let pick = (0..<basses.count).map { (start + $0) % basses.count }
            .first { !Self.near(RGB(hex: basses[$0]), mugRGB) } ?? start
        bassColor = RGB(hex: basses[pick])
        let keys: [UInt32] = [0xC8202A, 0x1E1E24, 0x2E2E36]
        keysColor = RGB(hex: keys[r.int(keys.count)])
        // The kit: red, blue, green or purple sparkle, or black.
        let kits: [UInt32] = [0xC8302E, 0x2F5FC0, 0x23915A, 0x7A3FB0, 0x2A2730]
        kitColor = RGB(hex: kits[r.int(kits.count)])
        kitShift = r.int(4)
        lightShift = r.int(4)
        shoeShift = r.int(4)
        bassline = (0..<8).map { _ in r.range(0, 1) }
        keyPattern = (0..<6).map { _ in 1 + r.int(5) }
        egg = BandSprite(Art.eggRows, key: "owsyYd")
        self.mug = BandSprite(Art.mugRows, key: "orcHmM")
        croissant = BandSprite(Art.croissantRows, key: "okgGd")
    }
}

/// Every colour the band is painted in, for a style.
private nonisolated struct Paints {
    let style: SceneStyle
    let outline = RGB(hex: 0x24150E)
    let limb: RGB
    let eye = RGB(hex: 0x2A160A)
    let mouth = RGB(hex: 0x5A1E12)
    let tongue = RGB(hex: 0xF0717E)
    let cheek = RGB(hex: 0xFF6F7F)
    let glove = RGB.white
    let sole = RGB(hex: 0xF4F4F4)
    let eggWhite = RGB(hex: 0xFFFCF2)
    let pepper = RGB(hex: 0x3A3430)
    let metal: RGB
    let brass = RGB(hex: 0xD9A93C)
    let brassLight = RGB(hex: 0xFFE9A0)
    let stick = RGB(hex: 0xE8C48A)
    let stickTip = RGB(hex: 0xFFF1D6)
    let drumHead = RGB(hex: 0xEFE4CC)
    let coffee = RGB(hex: 0x4A2C18)
    let neck: RGB
    let headstock = RGB(hex: 0x6A4426)
    let peg = RGB(hex: 0xFFF6E0)
    let mic = RGB(hex: 0x4A4C58)
    let micShine = RGB(hex: 0xE8EAF0)
    let micHandle = RGB(hex: 0x1E1E24)
    let keyLit: RGB
    let shell: RGB
    let kickFlash: RGB
    let print: RGB
    let sweatband: RGB
    let beret: RGB
    let steam: RGB
    let truss: RGB
    let floor: RGB
    let floorLine: RGB
    let riser: RGB
    let riserTop: RGB
    let riserEdge: RGB
    let lamps: [RGB]
    let lampsLit: [RGB]
    let shoes: [RGB]
    let egg: [RGB]
    let kick: [RGB]
    let emblem: RGB
    let tom: [RGB]
    let mug: [RGB]
    let bass: [RGB]
    let croissant: [RGB]
    let keyboard: [RGB]

    init(_ style: SceneStyle, look: Look) {
        self.style = style
        let light = style.isLight
        // The Dancing Toast's dark limbs, a shade lighter over the dimmed stage so they still show.
        limb = light ? RGB(hex: 0x4A2A12) : RGB(hex: 0x6A3C1C)
        metal = light ? style.ink.scaled(0.75) : RGB(hex: 0xA8ACB8)
        lamps = (0..<4).map { style.spark(look.lightShift + $0) }
        lampsLit = lamps.map { light ? $0 : $0.mixed(with: .white, 0.5) }
        keyLit = style.spark(look.lightShift + 1).mixed(with: .white, light ? 0 : 0.3)
        shell = look.kitColor
        kickFlash = light ? look.kitColor.mixed(with: .white, 0.5)
            : style.spark(look.lightShift).mixed(with: .white, 0.6)
        print = look.printColor ?? style.spark(look.kitShift + 2)
        sweatband = style.spark(look.kitShift + 1)
        beret = look.keysColor == RGB(hex: 0xC8202A) ? RGB(hex: 0x1E1E24) : RGB(hex: 0xB0202A)
        steam = light ? style.ink : .white
        truss = light ? style.ink.scaled(0.6) : style.deep.mixed(with: RGB(0.05, 0.04, 0.07), 0.75)
        floor = light ? style.ink.mixed(with: style.mid, 0.55) : RGB(hex: 0x2A1A12).mixed(with: style.deep, 0.35)
        floorLine = light ? style.ink : RGB(hex: 0x7A5034)
        riser = light ? style.ink.mixed(with: style.mid, 0.35) : style.deep.mixed(with: RGB(0.2, 0.2, 0.24), 0.6)
        riserTop = light ? style.ink.mixed(with: .white, 0.35) : style.deep.mixed(with: RGB(0.6, 0.6, 0.66), 0.6)
        riserEdge = light ? style.accent : style.spark(look.lightShift).mixed(with: .white, 0.3)
        shoes = (0..<3).map { style.spark(look.shoeShift + $0).mixed(with: RGB(hex: 0xE23B3B), 0.3) }
        egg = [outline, eggWhite, RGB(hex: 0xE4D9C4), look.yolk.0, look.yolk.1, look.yolk.2]
        kick = [outline, shell, drumHead]
        emblem = look.kitColor == RGB(hex: 0x2A2730) ? RGB(hex: 0xD8323A) : look.kitColor
        tom = [outline, drumHead, shell, shell.scaled(0.75)]
        let m = look.mugColor
        // A pale maple neck, or rosewood across a pale mug.
        neck = m.luminance > 0.45 ? RGB(hex: 0x6A4426) : RGB(hex: 0xF0D2A0)
        mug = [outline, m.mixed(with: .white, 0.35), coffee, m.mixed(with: .white, 0.45), m, m.scaled(0.78)]
        bass = [outline, look.bassColor, look.bassColor.scaled(0.7), RGB(hex: 0xF4F1EA), RGB(hex: 0x1E1E24)]
        croissant = [outline, look.bake.crust, look.bake.body, look.bake.light, look.bake.shade]
        keyboard = [outline, look.keysColor, RGB(hex: 0xF4F1EA), RGB(hex: 0x1A1A1E)]
    }
}

// MARK: - The art

/// A small picture from rows of characters: each character is a colour, its place in `key`; anything else is clear.
private nonisolated struct BandSprite {
    let width: Int
    let height: Int
    private let cells: [UInt8]

    init(_ rows: [String], key: String) {
        let key = Array(key)
        width = rows.map(\.count).max() ?? 0
        height = rows.count
        var cells = [UInt8](repeating: 0, count: width * height)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                if let i = key.firstIndex(of: ch) { cells[y * width + x] = UInt8(i + 1) }
            }
        }
        self.cells = cells
    }

    /// Draws with the top-left at (x, y), each row moved sideways by `shift(row)` (a lean).
    func draw(_ c: inout PixelCanvas, x: Int, y: Int, colors: [RGB], shift: (Int) -> Int = { _ in 0 }) {
        for row in 0..<height {
            let dx = shift(row)
            for col in 0..<width {
                let v = Int(cells[row * width + col])
                if v != 0, v <= colors.count { c.set(x + col + dx, y + row, colors[v - 1]) }
            }
        }
    }
}

private nonisolated enum Art {
    /// The fried egg: a wavy white round the yolk, which is its face.
    static let eggRows = [
        ".....oooo..ooo...",
        "...oowwwwoowwwoo.",
        "..owwwwwwwwwwwwwo",
        ".owwwwdddddwwwwso",
        ".owwwdyYYyydwwwso",
        "owwwdyYyyyyydwwso",
        "owwwdyyyyyyydwwo.",
        "owwwdyyyyyyydwwo.",
        ".owwdyyyyyyydwso.",
        ".owwwdyyyyydwwso.",
        "owwwwwdddddwwwsso",
        "owwwwwwwwwwwwwsso",
        ".owwwwwwwwwwwsso.",
        "..oowwwwwwwssoo..",
        "....ooooooooo....",
    ]

    /// The mug, handle to the right: rim, coffee, the front lip, a highlight down the left and shade down the right.
    static let mugRows = [
        ".ooooooooo....",
        "orcccccccro...",
        "orrrrrrrrro...",
        "oHmmmmmmmMooo.",
        "oHmmmmmmmMommo",
        "oHmmmmmmmMo.mo",
        "oHmmmmmmmMo.mo",
        "oHmmmmmmmMommo",
        "oHmmmmmmmMooo.",
        "oHmmmmmmmMo...",
        "oHmmmmmmmMo...",
        "oMMmmmmmMMo...",
        ".ooooooooo....",
    ]

    /// The croissant: a fat middle (its face) between creased side lobes, curling down to the tips.
    static let croissantRows = [
        ".......ooooo.......",
        "......oGGGGGo......",
        "...oooGgggggGooo...",
        "..oGGkgggggggkGGo..",
        ".okggkgggggggkggko.",
        "oGkggkgggggggkggkGo",
        "ogkdgkdgggggdkgdkgo",
        "ogdoddodddddoddodgo",
        "odo.oo.ooooo.oo.odo",
        ".o...............o.",
    ]

    /// The kick drum from the front: a rim in the kit's colour round a pale head.
    static let kick = BandSprite([
        "...ooooo...",
        ".oosssssoo.",
        ".oshhhhhso.",
        "oshhhhhhhso",
        "oshhhhhhhso",
        "oshhhhhhhso",
        "oshhhhhhhso",
        "oshhhhhhhso",
        ".oshhhhhso.",
        ".oosssssoo.",
        "...ooooo...",
    ], key: "osh")

    /// A tom: a pale head over a shell in the kit's colour.
    static let tom = BandSprite([
        ".oooo.",
        "ohhhho",
        "osssso",
        "oSssSo",
        ".oooo.",
    ], key: "ohsS")

    /// The bass's body (the neck is drawn to it): two horns towards the neck, a pickguard, a pickup.
    static let bass = BandSprite([
        ".ooo.oo.",
        "obbbobbo",
        "obwwbkbo",
        "obbwbkBo",
        ".obbbBo.",
        "..oooo..",
    ], key: "obBwk")

    /// The keyboard: a panel, white and black keys, a front edge.
    static let keyboard = BandSprite([
        "oppppppppppppo",
        "pwkwkwwkwkwkwp",
        "pwwwwwwwwwwwwp",
        "oooooooooooooo",
    ], key: "opwk")
}

private nonisolated struct Bit {
    enum Kind { case crumb, flake, coffee, sparkle }

    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var life: Double
    var kind: Kind
    var color: Int
}
