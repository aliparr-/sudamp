// SPDX-License-Identifier: GPL-3.0-or-later
// Pixel DJ: a tiny pixel-art club. A DJ in headphones plays two turntables behind a booth, nodding on the beat, one
// hand on the decks or the mixer while the other pumps the air or holds a headphone to one ear. Lights sweep down
// from the rig, a mirror ball scatters specks through the breakdown, and a row of heads bobs in front. When the bass
// comes back after a breakdown the hands go up, the lights flash and confetti falls. In silence the DJ stands still
// and blinks under dim lights. Each seed brings a different DJ (hair, skin, shirt, shades) and crowd. Now and then a
// tiny toast (the Dancing Toast's) wanders along the front of the stage, about once a minute of steady music, or
// crowd-surfs over the heads after a drop, then leaves; never in silence.

import CoreGraphics

nonisolated final class PixelDJScene: VisualizerScene {
    /// The canvas is 46 pixels across: 2 points a pixel on the 92-point artwork, whole pixels at 1x and 2x.
    private static let side = 46

    private var canvas = PixelCanvas(width: PixelDJScene.side, height: PixelDJScene.side)
    private var random: SceneRandom
    private let look: Look
    private var dancers: [Dancer] = []
    private var specks: [Speck] = []
    private var confetti: [Confetto] = []
    private var colors: [RGB] = []
    private var styled: SceneStyle?
    private var cameo: ToastCameo

    // What the music is doing.
    private var time = 0.0
    /// 0 in silence, 1 while music plays (smoothed).
    private var activity = 0.0
    private var energy = 0.0
    private var bass = 0.0
    private var groove = 0.0
    private var beatIndex = 0
    private var silentFor = 10.0
    private var meter = [Double](repeating: 0, count: 7)
    // The breakdown and the drop: the bass's troughs sink in a breakdown and come back up with the kick.
    private var runMin = 1.0
    private var lastBass = 0.0
    private var bassFloor = 0.0
    private var floorRef = 0.0
    private var lull = 0.0
    private var lullFloor = 1.0
    /// How deep into a breakdown (0...1), and the excitement after a drop (1, fading).
    private var calm = 0.0
    private var hype = 0.0
    private var flash = 0.0

    // The DJ.
    private var hands: [SIMD2<Double>] = [Pose.rest(0), Pose.rest(1)]
    private var spins = [0.0, 0.0]
    private var blinkIn = 3.0
    private var blinkFor = 0.0
    private var beamAngles: [Double]
    private var ballTurn = 0.0

    /// None: the scene fills the artwork, so a glow would only haze it.
    var glow: Double { 0 }

    init(seed: UInt64) {
        random = SceneRandom(seed: seed)
        cameo = ToastCameo(seed: seed)
        look = Look(&random)
        beamAngles = Rig.fixtures.map { Rig.restAngle($0) }
        dancers = Dancer.crowd(&random)
        specks = (0..<26).map { _ in Speck(&random) }
        confetti = (0..<44).map { _ in Confetto() }
        blinkIn = random.range(1.5, 4)
    }

    // MARK: - Update

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        time += dt
        let silent = input.isSilent
        silentFor = silent ? silentFor + dt : 0
        activity = Self.approach(activity, silent ? 0 : 1, rate: silent ? 9 : 4, dt)
        energy = Self.approach(energy, silent ? 0 : min(Double(input.level) / 0.5, 1), rate: silent ? 9 : 3, dt)
        bass = Self.approach(bass, Double(input.bass), rate: 12, dt)

        // The beat clock: a beat each time the groove wraps.
        if !silent, input.groove < groove - 0.5 { beatIndex += 1 }
        groove = input.groove

        detectDrop(input, dt: dt)
        calm = Self.approach(calm, lull > 1.5 && !silent ? 1 : 0, rate: 1.6, dt)
        hype = silent ? Self.approach(hype, 0, rate: 9, dt) : max(0, hype - dt / 7)
        flash *= exp(-dt * 7)
        if input.beat, !silent {
            flash = max(flash, (beatIndex % 4 == 0 ? 0.32 : 0.16) * (1 - calm * 0.7))
        }

        // The LED meter: seven bands, quick up, falling back.
        let bars = input.bars
        for i in meter.indices {
            let lo = i * bars.count / meter.count, hi = max(lo + 1, (i + 1) * bars.count / meter.count)
            var sum: Float = 0
            for b in lo..<min(hi, bars.count) { sum += bars[b] }
            let v = silent ? 0 : Double(sum) / Double(max(1, min(hi, bars.count) - lo))
            meter[i] = max(v, meter[i] - dt * (silent ? 6 : 2.2))
        }

        updateDJ(input, dt: dt)
        updateLights(input, dt: dt)
        updateCrowd(dt: dt)
        updateConfetti(dt: dt)
        cameo.update(dt: dt, silent: silent, steady: calm < 0.3 && hype < 0.3)
    }

    /// A breakdown is a stretch where the bass's troughs (between its hits) sit well below where they were; the
    /// drop is when they come back up.
    private func detectDrop(_ input: VisualizerInput, dt: Double) {
        let bars = input.bars
        var sum: Float = 0
        for i in 0..<min(4, bars.count) { sum += bars[i] }
        let b = Double(sum) / 4
        if b > runMin + 0.08, b > lastBass {
            bassFloor += (runMin - bassFloor) * 0.6
            runMin = b
        } else {
            runMin = min(runMin, b)
        }
        bassFloor = min(bassFloor, b)
        lastBass = b
        floorRef = max(bassFloor, floorRef - dt * (lull > 10 ? 0.03 : 0.004))
        if bassFloor < floorRef - 0.1 {
            lull += dt
            lullFloor = min(lullFloor, bassFloor)
        } else if bassFloor > floorRef - 0.06 {
            if lull > 2.5, bassFloor > lullFloor + 0.12 { drop() }
            lull = max(0, lull - dt * 2)
            if lull == 0 { lullFloor = 1 }
        }
    }

    private func drop() {
        lull = 0
        lullFloor = 1
        hype = 1
        flash = 1
        cameo.dropped()
        for i in confetti.indices {
            let delay = random.range(0, 0.5)
            confetti[i].launch(&random, delay: delay)
        }
    }

    private func updateDJ(_ input: VisualizerInput, dt: Double) {
        let roles = currentRoles()
        let bob = Double(bodyDrop() + headDrop())
        for side in 0..<2 {
            let role = side == 0 ? roles.0 : roles.1
            let target = Pose.target(role, side: side, groove: groove, beat: Double(beatIndex) + groove, bob: bob,
                                     lull: lull)
            let rate = role == .pump ? 24.0 : role == .deck || role == .mixer ? 16 : 11
            let before = hands[side].x
            hands[side] += (target - hands[side]) * (1 - exp(-dt * rate))
            // A record turns once every two beats; with a hand on it, it follows the hand back and forth.
            if role == .deck {
                spins[side] += (hands[side].x - before) * (side == 0 ? 0.12 : -0.12)
            } else {
                spins[side] += dt / max(input.beatInterval * 2, 0.4) * activity
            }
        }
        // Blinks every few seconds, but never in the still frame a pause settles to.
        if blinkFor > 0 {
            blinkFor -= dt
        } else {
            blinkIn -= dt
            if blinkIn <= 0 {
                blinkFor = 0.14
                blinkIn = random.range(2.2, 5)
            }
        }
    }

    private func updateLights(_ input: VisualizerInput, dt: Double) {
        let beat = Double(beatIndex) + groove
        let program = look.programs[(beatIndex / 16) % look.programs.count]
        let speed = hype > 0.3 ? 2.0 : calm > 0.5 ? 0.5 : 1
        let phase = beat / 8 * 2 * .pi * speed
        for (i, fixture) in Rig.fixtures.enumerated() {
            let lit = Rig.showAngle(program, fixture: fixture, index: i, phase: phase)
            let target = Rig.restAngle(fixture) + (lit - Rig.restAngle(fixture)) * activity
            beamAngles[i] = Self.approach(beamAngles[i], target, rate: 7, dt)
        }
        ballTurn += dt * (0.25 + 0.5 * calm) * activity
    }

    private func updateCrowd(dt: Double) {
        let loud = energy * (1 - calm * 0.75)
        for i in dancers.indices {
            let up = activity > 0.5 && (hype > 0.3 || loud > dancers[i].threshold) ? 1.0 : 0
            dancers[i].hand = Self.approach(dancers[i].hand, up, rate: 6, dt)
        }
    }

    private func updateConfetti(dt: Double) {
        for i in confetti.indices where confetti[i].alive {
            if silentFor > 0.2 { confetti[i].alive = false; continue }
            confetti[i].step(dt: dt, time: time)
        }
    }

    private func currentRoles() -> (Pose.Role, Pose.Role) {
        if activity < 0.5 { return (.rest, .rest) }
        if hype > 0.55 { return (.up, .up) }
        let mirrored = look.leftHanded
        func m(_ a: Pose.Role, _ b: Pose.Role) -> (Pose.Role, Pose.Role) { mirrored ? (b, a) : (a, b) }
        if calm > 0.5 { return m(.mixer, lull > 5 ? .tease : .ear) }
        switch (beatIndex / 8 + look.routineStart) % 6 {
        case 0: return m(.deck, .pump)
        case 1: return m(.deck, .ear)
        case 2: return m(.mixer, .deck)
        case 3: return m(.pump, .deck)
        case 4: return m(.ear, .deck)
        default: return m(.deck, .mixer)
        }
    }

    /// The body dips on the downbeat when the music is going; the head nods a little more.
    private func bodyDrop() -> Int { activity > 0.5 && energy > 0.45 && calm < 0.5 && groove < 0.3 ? 1 : 0 }
    private func headDrop() -> Int { activity > 0.5 && (groove < 0.4 || groove > 0.95) ? 1 : 0 }

    // MARK: - Draw

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        if styled != style {
            colors = Ink.palette(for: style, look: look)
            styled = style
        }
        let rect = CGRect(origin: .zero, size: size)
        canvas.clear()
        paintBackdrop(&canvas, style: style)
        paint(&canvas, style: style)
        canvas.draw(in: ctx, rect: rect)
    }

    /// The club: the artwork dimmed on dark styles, with a flash of the lights' colour on the strong kicks.
    private func paintBackdrop(_ c: inout PixelCanvas, style: SceneStyle) {
        var color: RGB, alpha: Double
        if style.isLight {
            color = style.accent
            alpha = flash * 0.12
        } else {
            let wash = style.deep.mixed(with: .black, 0.35), washAlpha = 0.5 - 0.08 * activity
            let lights = style.spark(look.lightShift + beatIndex / 16), f = flash * 0.28
            alpha = washAlpha + f * (1 - washAlpha)
            color = alpha > 0 ? RGB((lights.r * f + wash.r * washAlpha * (1 - f)) / alpha,
                                    (lights.g * f + wash.g * washAlpha * (1 - f)) / alpha,
                                    (lights.b * f + wash.b * washAlpha * (1 - f)) / alpha) : wash
        }
        guard alpha > 0.01 else { return }
        c.box(0, 0, Self.side, Self.side, color, alpha)
    }

    private func paint(_ c: inout PixelCanvas, style: SceneStyle) {
        paintSpecks(&c, style: style)
        paintRig(&c, style: style)
        paintDJ(&c)
        paintBooth(&c, style: style)
        paintArms(&c)
        cameo.paint(&c, .walk, groove: groove, style: style)
        paintCrowd(&c, style: style)
        cameo.paint(&c, .surf, groove: groove, style: style)
        paintConfetti(&c, style: style)
    }

    private func paintSpecks(_ c: inout PixelCanvas, style: SceneStyle) {
        let strength = 0.14 + activity * (0.1 + 0.5 * calm)
        let color = style.isLight ? style.accent : style.ink
        for s in specks {
            let a = s.longitude + ballTurn * 2 * .pi
            let facing = cos(a)
            guard facing > 0.15 else { continue }
            let x = 23 + sin(a) * 26
            c.set(Int(x.rounded(.down)), s.y, color, strength * facing * s.brightness)
        }
    }

    private func paintRig(_ c: inout PixelCanvas, style: SceneStyle) {
        let beatEnvelope = pow(1 - groove, 3)
        let level = activity * (0.24 + 0.1 * beatEnvelope) * (1 - 0.55 * calm) + 0.07 * (1 - activity) + flash * 0.25
        let program = look.programs[(beatIndex / 16) % look.programs.count]
        let shift = look.lightShift + beatIndex / 16
        // Lasers in the laser phrases and after a drop, fanning from the top corners.
        let lasers = activity * max(program == .lasers ? 1 - calm : 0, hype)
        if lasers > 0.02 {
            let phase = (Double(beatIndex) + groove) / 4 * 2 * .pi
            for corner in 0..<2 {
                let x0 = corner == 0 ? 1.0 : 45.0
                let dir = corner == 0 ? 1.0 : -1.0
                let centre = dir * (0.75 + 0.35 * sin(phase + Double(corner) * .pi))
                let color = style.spark(shift + 1 + corner)
                for k in 0..<4 {
                    let angle = centre + dir * (Double(k) - 1.5) * 0.16
                    Self.line(&c, from: SIMD2(x0, 1), angle: angle, length: 60, color: color,
                              alpha: lasers * (style.isLight ? 0.55 : 0.6))
                }
            }
        }
        // Beams, a little whiter at heart on dark artwork; on each beat one lamp in turn kicks brighter.
        for (i, fixture) in Rig.fixtures.enumerated() {
            let color = style.isLight ? style.spark(shift + i) : style.spark(shift + i).mixed(with: .white, 0.3)
            let chase = beatIndex % 4 == i ? 0.14 * beatEnvelope * activity * (1 - calm) : 0
            let alpha = (level + chase) * (style.isLight ? 1.1 : 1)
            Self.beam(&c, x0: fixture, y0: 3, angle: beamAngles[i], length: 31, color: color, alpha: alpha)
        }
        // The truss and its lamps.
        let truss = colors[Ink.outline.rawValue]
        for x in 3..<43 { c.set(x, 0, truss, 0.75) }
        for (i, fixture) in Rig.fixtures.enumerated() {
            let x = Int(fixture) - 1
            c.box(x, 1, 2, 2, truss)
            c.set(x + (beamAngles[i] < -0.2 ? 0 : 1), 2, style.isLight ? style.spark(shift + i) : style.spark(shift + i).mixed(with: .white, 0.5),
                  0.35 + 0.65 * min(1, level * 3))
        }
        // The mirror ball, hanging in the middle.
        for y in 0..<2 { c.set(22, y, truss, 0.8) }
        let turn = Int((ballTurn * 12).rounded(.down))
        let light = style.isLight ? style.ink.mixed(with: .white, 0.45) : RGB(0.78, 0.8, 0.86)
        let dark = style.isLight ? style.ink : RGB(0.42, 0.44, 0.52)
        for (row, span) in Rig.ball.enumerated() {
            for x in span.0...span.1 {
                c.set(x, 2 + row, ((x + row + turn) & 1) == 0 ? light : dark)
            }
        }
        let glint = (turn / 3) % 4
        c.set(21 + glint % 2, 3 + glint / 2, .white, 0.9)
    }

    private func paintDJ(_ c: inout PixelCanvas) {
        let body = bodyDrop()
        let head = body + headDrop()
        look.torso.draw(&c, x: 16, y: 23 + body, colors: colors)
        look.head.draw(&c, x: 17, y: 9 + head, colors: colors)
        look.hair.draw(&c, x: 17, y: 9 + head, colors: colors)
        // Eyes, or shades; a blink is a line.
        let blinking = blinkFor > 0 && (silentFor == 0 || silentFor > 1.2)
        let eyeY = 9 + head + 8
        if look.shades {
            Look.shadesSprite.draw(&c, x: 17, y: 9 + head, colors: colors)
        } else if blinking {
            c.set(21, eyeY + 1, colors[Ink.skinShade.rawValue])
            c.set(24, eyeY + 1, colors[Ink.skinShade.rawValue])
        } else {
            c.box(21, eyeY, 1, 2, colors[Ink.eye.rawValue])
            c.box(24, eyeY, 1, 2, colors[Ink.eye.rawValue])
        }
        if hype > 0.3 {
            // A big grin.
            c.set(21, 9 + head + 10, colors[Ink.mouth.rawValue])
            c.box(22, 9 + head + 11, 2, 1, colors[Ink.mouth.rawValue])
            c.set(24, 9 + head + 10, colors[Ink.mouth.rawValue])
        }
        Look.phones.draw(&c, x: 17, y: 9 + head, colors: colors)
    }

    private func paintBooth(_ c: inout PixelCanvas, style: SceneStyle) {
        let top = colors[Ink.boothTop.rawValue], front = colors[Ink.boothFront.rawValue]
        c.box(3, 30, 40, 4, top)
        c.box(3, 34, 40, 12, front)
        // The decks: a plinth, the record with its label, a highlight running round, and the arm.
        let plinth = colors[Ink.plinth.rawValue], vinyl = colors[Ink.vinyl.rawValue]
        for deck in 0..<2 {
            let x0 = deck == 0 ? 5 : 29
            c.box(x0, 30, 12, 4, plinth)
            let rx = deck == 0 ? x0 + 1 : x0 + 3
            for (row, span) in Rig.record.enumerated() {
                for x in span.0...span.1 { c.set(rx + x, 30 + row, vinyl) }
            }
            c.box(rx + 3, 31, 2, 1, style.spark(look.labelShift + deck))
            let ring = Rig.ring
            var turn = spins[deck]
            if deck == 1 { turn = -turn }
            let k = ((Int((turn * Double(ring.count)).rounded(.down)) % ring.count) + ring.count) % ring.count
            c.set(rx + ring[k].0, 30 + ring[k].1, colors[Ink.vinylShine.rawValue])
            let armX = deck == 0 ? x0 + 10 : x0 + 1
            c.set(armX, 30, colors[Ink.plinthShade.rawValue])
            c.set(armX, 31, colors[Ink.plinthShade.rawValue])
            c.set(deck == 0 ? armX - 1 : armX + 1, 32, colors[Ink.plinthShade.rawValue])
        }
        // The mixer: knobs, two channel faders and the crossfader.
        let mixer = colors[Ink.mixer.rawValue]
        c.box(18, 30, 10, 4, mixer)
        for (i, x) in Rig.knobs.enumerated() {
            c.set(x, 30, style.spark(look.labelShift + i), 0.5 + 0.5 * activity)
        }
        let fader = colors[Ink.vinylShine.rawValue]
        for ch in 0..<2 {
            let x = ch == 0 ? 20 : 25
            let level = meter[ch == 0 ? 0 : 2]
            c.set(x, level > 0.55 ? 31 : 32, fader)
        }
        let fadeX = 20 + Int(((hands[0].x + hands[1].x) / 2 - 18).clamped(0, 5))
        c.set(fadeX, 33, fader)
        // The front: a lit edge, and the LED meter.
        let edge = style.isLight ? style.accent : style.spark(look.lightShift).mixed(with: .white, 0.3)
        let edgeAlpha = (0.35 + 0.45 * activity * min(1, bass * 1.2)) * (style.isLight ? 1 : 0.9)
        for x in 3..<43 { c.set(x, 34, edge, edgeAlpha) }
        let low = style.isLight ? style.ink : style.spark(look.lightShift + 1)
        let high = style.isLight ? style.accent : RGB.white.mixed(with: style.spark(look.lightShift), 0.25)
        for (i, v) in meter.enumerated() {
            let x = 13 + i * 3
            let lit = Int((v * 6 - 0.4).rounded(.down))
            for row in 0..<4 {
                let y = 39 - row
                if row < lit {
                    c.box(x, y, 2, 1, row == 3 ? high : low)
                } else {
                    c.box(x, y, 2, 1, low, 0.16)
                }
            }
        }
    }

    private func paintArms(_ c: inout PixelCanvas) {
        let drop = Double(bodyDrop())
        let skin = colors[Ink.skin.rawValue], shade = colors[Ink.skinShade.rawValue], shirt = colors[Ink.shirt.rawValue]
        for side in 0..<2 {
            let shoulder = SIMD2(side == 0 ? 18.0 : 28.0, 25.5 + drop)
            let hand = hands[side]
            let elbow = Pose.elbow(shoulder: shoulder, hand: hand, side: side)
            // A short sleeve, the arm, and a fist shaded underneath.
            Self.stroke(&c, from: shoulder, to: elbow, width: 2, color: skin)
            Self.stroke(&c, from: shoulder, to: shoulder + (elbow - shoulder) * 0.45, width: 2, color: shirt)
            Self.stroke(&c, from: elbow, to: hand, width: 2, color: skin)
            let x = Int((hand.x - 1).rounded()), y = Int((hand.y - 1).rounded())
            c.box(x, y, 2, 1, skin)
            c.box(x, y + 1, 2, 1, shade)
        }
    }

    /// The crowd, seen from behind: every other head a step further back and a shade lighter.
    private func paintCrowd(_ c: inout PixelCanvas, style: SceneStyle) {
        let rim = style.spark(look.lightShift)
        let rimAlpha = style.isLight ? 0 : 0.2 + 0.25 * activity * (1 - calm * 0.5)
        for pass in 0..<2 {
            let body = colors[(pass == 0 ? Ink.crowdBack : Ink.crowd).rawValue]
            for i in stride(from: pass, to: dancers.count, by: 2) {
                paintDancer(&c, dancers[i], body: body, rim: rim, rimAlpha: rimAlpha)
            }
        }
    }

    private func paintDancer(_ c: inout PixelCanvas, _ d: Dancer, body: RGB, rim: RGB, rimAlpha: Double) {
        let phase = (groove + d.phase + 1).truncatingRemainder(dividingBy: 1)
        var dy = activity > 0.5 && energy > 0.25 && phase < 0.4 ? 1 : 0
        if hype > 0.3, activity > 0.5 { dy = phase < 0.45 ? 0 : -2 }
        let top = d.top + dy
        let shape = Dancer.shapes[d.shape]
        // A hand up: an arm from the shoulder to above the head, the hand swaying with the beat.
        if d.hand > 0.05 {
            let reach = Int((d.hand * 8).rounded())
            let sway = sin((groove + d.phase) * 2 * .pi) > 0 ? d.side : 0
            let ax = d.x + (d.side > 0 ? 7 : 1)
            let base = top + shape.count + 1
            for k in 0..<reach { c.set(ax + (k > 4 ? sway : 0), base - k, body) }
            c.box(ax + (reach > 4 ? sway : 0) - (d.side > 0 ? 0 : 1), base - reach - 1, 2, 2, body)
        }
        for (row, span) in shape.enumerated() {
            c.box(d.x + span.0, top + row, span.1 - span.0 + 1, 1, body)
        }
        c.box(d.x + shape[0].0, top, shape[0].1 - shape[0].0 + 1, 1, rim, rimAlpha)
        c.box(d.x + 1, top + shape.count, 7, 1, body)
        c.box(d.x, top + shape.count + 1, 9, Self.side, body)
    }

    private func paintConfetti(_ c: inout PixelCanvas, style: SceneStyle) {
        for p in confetti where p.alive && p.delay <= 0 {
            // Each piece flutters: flat and wide, then edge-on and darker.
            let color = style.isLight ? style.spark(p.color) : style.spark(p.color).mixed(with: .white, 0.2)
            let face = sin(p.flip)
            c.box(Int(p.x.rounded(.down)), Int(p.y.rounded(.down)), face > 0.3 ? 2 : 1, 1,
                  face < 0 ? color.scaled(0.65) : color)
        }
    }

    // MARK: - Pixel helpers

    /// A soft-edged beam of light from (x0, y0), widening as it goes; angle 0 points straight down.
    private static func beam(_ c: inout PixelCanvas, x0: Double, y0: Int, angle: Double, length: Int, color: RGB,
                             alpha: Double) {
        guard alpha > 0.005 else { return }
        let slope = tan(angle)
        for dy in 1...length {
            let fy = Double(dy)
            let cx = x0 + slope * fy
            let half = 0.35 + fy * 0.09
            let fade = alpha * (1 - fy / Double(length + 4))
            let lo = Int((cx - half - 0.5).rounded(.down)), hi = Int((cx + half + 0.5).rounded(.up))
            for x in lo...hi {
                let cover = min(1, max(0, half + 0.5 - abs(Double(x) + 0.5 - cx)))
                if cover > 0.2 { c.set(x, y0 + dy, color, fade * (cover > 0.6 ? 1 : 0.5)) }
            }
        }
    }

    /// A one-pixel line from `from` at `angle` (0 down), fading along its length.
    private static func line(_ c: inout PixelCanvas, from: SIMD2<Double>, angle: Double, length: Int, color: RGB,
                             alpha: Double) {
        let step = SIMD2(sin(angle), cos(angle))
        var p = from
        for k in 0..<length {
            let x = Int(p.x.rounded(.down)), y = Int(p.y.rounded(.down))
            if x < -1 || x > side || y > side { break }
            c.set(x, y, color, alpha * (1 - Double(k) / Double(length)))
            p += step
        }
    }

    /// A thick line of square dabs, `width` pixels across, between two points (pixel centres).
    private static func stroke(_ c: inout PixelCanvas, from a: SIMD2<Double>, to b: SIMD2<Double>, width: Int,
                               color: RGB) {
        let d = b - a
        let n = max(1, Int(max(abs(d.x), abs(d.y)).rounded(.up)))
        let half = Double(width) / 2
        var last = (Int.min, Int.min)
        for k in 0...n {
            let p = a + d * (Double(k) / Double(n))
            let x = Int((p.x - half).rounded()), y = Int((p.y - half).rounded())
            if (x, y) == last { continue }
            last = (x, y)
            c.box(x, y, width, width, color)
        }
    }

    private static func approach(_ value: Double, _ target: Double, rate: Double, _ dt: Double) -> Double {
        value + (target - value) * (1 - exp(-dt * rate))
    }
}

// MARK: - The look

/// The colours a sprite cell can take.
nonisolated private enum Ink: Int, CaseIterable {
    case clear, outline, skin, skinShade, hair, hairLight, phones, phonesLit, eye, shirt, shirtShade, print,
         mouth, lens, glint, crowd, crowdBack, boothTop, boothFront, plinth, plinthShade, vinyl, vinylShine, mixer

    static func of(_ ch: Character) -> Ink {
        switch ch {
        case "o": .outline
        case "s": .skin
        case "S": .skinShade
        case "h": .hair
        case "H": .hairLight
        case "p": .phones
        case "c": .phonesLit
        case "e": .eye
        case "t": .shirt
        case "T": .shirtShade
        case "a": .print
        case "m": .mouth
        case "g": .lens
        case "G": .glint
        default: .clear
        }
    }

    /// Every ink's colour for a style and a DJ. Dark artwork gets a lit figure; light artwork a darker one in the
    /// style's ink.
    static func palette(for style: SceneStyle, look: Look) -> [RGB] {
        var p = [RGB](repeating: .black, count: allCases.count)
        let light = style.isLight
        p[Ink.outline.rawValue] = light ? style.ink.scaled(0.55) : style.deep.mixed(with: RGB(0.03, 0.02, 0.05), 0.8)
        p[Ink.skin.rawValue] = look.skin
        p[Ink.skinShade.rawValue] = look.skin.scaled(0.8)
        let hair = look.hairColor
        p[Ink.hair.rawValue] = light ? hair.mixed(with: style.ink, 0.4) : hair
        p[Ink.hairLight.rawValue] = (light ? hair.mixed(with: style.ink, 0.4) : hair).mixed(with: .white, 0.3)
        p[Ink.phones.rawValue] = light ? style.ink.scaled(0.7) : RGB(0.2, 0.2, 0.24)
        p[Ink.phonesLit.rawValue] = light ? style.accent : style.spark(look.phonesShift)
        p[Ink.eye.rawValue] = RGB(0.1, 0.07, 0.1)
        let shirt = light ? style.ink.mixed(with: style.accent, look.shirtMix) : look.shirt(style)
        p[Ink.shirt.rawValue] = shirt
        p[Ink.shirtShade.rawValue] = shirt.scaled(0.78)
        p[Ink.print.rawValue] = light ? style.accent.mixed(with: .white, 0.5) : style.spark(look.phonesShift + 2)
        p[Ink.mouth.rawValue] = RGB(0.45, 0.12, 0.16)
        p[Ink.lens.rawValue] = RGB(0.08, 0.08, 0.12)
        p[Ink.glint.rawValue] = RGB(0.85, 0.9, 1)
        p[Ink.crowd.rawValue] = light ? style.ink.scaled(0.62) : style.deep.mixed(with: .black, 0.88)
        p[Ink.crowdBack.rawValue] = light ? style.ink.scaled(0.85) : style.deep.mixed(with: .black, 0.7)
        p[Ink.boothTop.rawValue] = light ? style.ink.mixed(with: .white, 0.3) : style.deep.mixed(with: RGB(0.55, 0.55, 0.6), 0.6)
        p[Ink.boothFront.rawValue] = light ? style.ink.mixed(with: style.mid, 0.6) : style.deep.mixed(with: RGB(0.36, 0.36, 0.4), 0.5)
        p[Ink.plinth.rawValue] = light ? style.ink.mixed(with: .white, 0.6) : RGB(0.62, 0.63, 0.68)
        p[Ink.plinthShade.rawValue] = light ? style.ink.mixed(with: .white, 0.85) : RGB(0.9, 0.9, 0.94)
        p[Ink.vinyl.rawValue] = RGB(0.07, 0.07, 0.09)
        p[Ink.vinylShine.rawValue] = RGB(0.7, 0.72, 0.78)
        p[Ink.mixer.rawValue] = light ? style.ink.scaled(0.6) : RGB(0.13, 0.13, 0.16)
        return p
    }
}

/// A small picture made of inks, drawn at whole pixels.
nonisolated private struct Sprite {
    let width: Int
    let height: Int
    let cells: [UInt8]

    init(_ rows: [String]) {
        width = rows.map(\.count).max() ?? 0
        height = rows.count
        var cells = [UInt8](repeating: 0, count: width * height)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() { cells[y * width + x] = UInt8(Ink.of(ch).rawValue) }
        }
        self.cells = cells
    }

    func draw(_ c: inout PixelCanvas, x: Int, y: Int, colors: [RGB]) {
        for row in 0..<height {
            for col in 0..<width {
                let v = cells[row * width + col]
                if v != 0 { c.set(x + col, y + row, colors[Int(v)]) }
            }
        }
    }
}

/// The DJ's looks, picked by the seed.
nonisolated private struct Look {
    enum Hair: CaseIterable {
        case short, afro, mohawk, long, bun
    }

    let skin: RGB
    let hairStyle: Hair
    let hairColor: RGB
    let shades: Bool
    let leftHanded: Bool
    let routineStart: Int
    let lightShift: Int
    let labelShift: Int
    let phonesShift: Int
    let shirtIndex: Int
    let shirtMix: Double
    let programs: [Rig.Program]
    let head: Sprite
    let hair: Sprite
    let torso: Sprite

    static let skins = [RGB(hex: 0xF4CBA6), RGB(hex: 0xE0A983), RGB(hex: 0xC08660), RGB(hex: 0x8D5B3E), RGB(hex: 0x6B4430)]
    static let hairs = [RGB(hex: 0x2A1F1C), RGB(hex: 0x15131A), RGB(hex: 0x6B4426), RGB(hex: 0xE2BE6A), RGB(hex: 0xC2582B)]

    init(_ r: inout SceneRandom) {
        skin = Self.skins[r.int(Self.skins.count)]
        hairStyle = Hair.allCases[r.int(Hair.allCases.count)]
        hairColor = Self.hairs[r.int(Self.hairs.count)]
        shades = r.chance(0.4)
        leftHanded = r.chance(0.5)
        routineStart = r.int(6)
        lightShift = r.int(4)
        labelShift = r.int(4)
        phonesShift = r.int(4)
        shirtIndex = r.int(5)
        shirtMix = r.range(0, 0.5)
        var programs = Rig.Program.allCases
        for i in stride(from: programs.count - 1, to: 0, by: -1) { programs.swapAt(i, r.int(i + 1)) }
        self.programs = programs
        head = Sprite(Self.headRows)
        hair = Sprite(Self.hairRows(hairStyle))
        torso = Sprite(Self.torsoRows)
    }

    func shirt(_ style: SceneStyle) -> RGB {
        switch shirtIndex {
        case 0: style.ink.mixed(with: style.spark(0), 0.15)
        default: style.spark(shirtIndex).scaled(0.92)
        }
    }

    // 12 across, from 3 rows above the headphones' band to the neck; the face is columns 2...9.
    static let headRows = [
        "............",
        "............",
        "............",
        "............",
        "...oooooo...",
        "..osssssso..",
        ".osssssssso.",
        ".osssssssso.",
        ".osssssssso.",
        ".osssssssso.",
        ".osssssssso.",
        "..oSssssSo..",
        "...oooooo...",
        "....oSSo....",
    ]

    static let phones = Sprite([
        "............",
        "............",
        "............",
        "...pppppp...",
        "..p......p..",
        ".p........p.",
        ".p........p.",
        "pc........cp",
        "pc........cp",
        "pc........cp",
    ])

    static let shadesSprite = Sprite([
        "", "", "", "", "", "", "", "",
        "...GgggGg...",
        "...gg..gg...",
    ])

    static func hairRows(_ hair: Hair) -> [String] {
        switch hair {
        case .short:
            [
                "............",
                "............",
                "............",
                "............",
                "...hHhhhh...",
                "..hHhhhhhh..",
                ".hhhhhhhhhh.",
                ".hh......hh.",
                ".h........h.",
            ]
        case .afro:
            [
                "............",
                "...hhhhhh...",
                "..hHHhhhhh..",
                ".hHhhhhhhhh.",
                "hhhhhhhhhhhh",
                "hhhhhhhhhhhh",
                "hhhhhhhhhhhh",
                "hhh......hhh",
                ".hh......hh.",
            ]
        case .mohawk:
            [
                ".....HH.....",
                ".....hh.....",
                ".....hh.....",
                ".....hh.....",
                "....hhhh....",
                "............",
            ]
        case .long:
            [
                "............",
                "............",
                "............",
                "............",
                "...hHhhhh...",
                "..hHhhhhhh..",
                ".hhhhhhhhhh.",
                ".hhh....hhh.",
                ".hh......hh.",
                ".hh......hh.",
                ".hh......hh.",
                ".hh......hh.",
                ".hh......hh.",
                ".hh......hh.",
            ]
        case .bun:
            [
                "............",
                "....hhhh....",
                "....hHhh....",
                "....hhhh....",
                "...hHhhhh...",
                "..hHhhhhhh..",
                ".hhhhhhhhhh.",
                ".hh......hh.",
                ".h........h.",
            ]
        }
    }

    // 14 across, from the collar down behind the booth.
    static let torsoRows = [
        "...ottSStto...",
        ".otttttttttto.",
        "otttttttttttto",
        "oTttttttttttTo",
        "oTttttaattttTo",
        "oTttttaattttTo",
        "oTttttttttttTo",
        "oTttttttttttTo",
    ]
}

// MARK: - Poses

nonisolated private enum Pose {
    enum Role { case rest, deck, mixer, pump, ear, up, tease }

    /// Where a hand rests in silence, beside the mixer.
    static func rest(_ side: Int) -> SIMD2<Double> { mirror(SIMD2(16, 30), side) }

    /// The hand's target (pixel centre) for a role; `side` 0 is the left of the picture, 1 the right.
    static func target(_ role: Role, side: Int, groove: Double, beat: Double, bob: Double,
                       lull: Double) -> SIMD2<Double> {
        let p: SIMD2<Double>
        switch role {
        case .rest:
            p = SIMD2(16, 30)
        case .deck:
            // Scratching: the record back and forth once a beat.
            p = SIMD2(10 + 1.2 * sin(beat * .pi * 2), 31)
        case .mixer:
            p = SIMD2(20.5 + 1.5 * sin(beat / 4 * .pi), 31)
        case .pump:
            let high = groove < 0.22 || groove > 0.92
            p = high ? SIMD2(13, 11 + bob) : SIMD2(14.5, 19 + bob)
        case .ear:
            p = SIMD2(17.5, 17.5 + bob)
        case .up:
            let wave = sin(beat * .pi) * 0.8
            p = SIMD2(13 + wave, 10 + bob * 0.5)
        case .tease:
            // Slowly up through the breakdown, a finger to the sky.
            let rise = min(1, (lull - 5) / 3)
            p = SIMD2(15 - rise * 1.5, 22 - rise * 10 + bob)
        }
        return mirror(p, side)
    }

    static func mirror(_ p: SIMD2<Double>, _ side: Int) -> SIMD2<Double> { side == 0 ? p : SIMD2(46 - p.x, p.y) }

    /// The elbow for a two-bone arm, bent outwards. A short reach is an arm coming forwards, towards us, so the
    /// bones shorten with it rather than folding out sideways.
    static func elbow(shoulder: SIMD2<Double>, hand: SIMD2<Double>, side: Int) -> SIMD2<Double> {
        var d = hand - shoulder
        var dist = (d * d).sum().squareRoot()
        if dist < 0.001 { d = SIMD2(0, 1); dist = 1 }
        let upper = min(max(dist / 1.75, 2.5), 6.6), fore = upper
        let reach = min(dist, upper + fore - 0.01)
        let dir = d / dist
        let along = (upper * upper - fore * fore + reach * reach) / (2 * reach)
        let out = max(0, upper * upper - along * along).squareRoot()
        let normal = SIMD2(-dir.y, dir.x)
        let a = shoulder + dir * along + normal * out
        let b = shoulder + dir * along - normal * out
        // Outwards: away from the middle of the body.
        return side == 0 ? (a.x < b.x ? a : b) : (a.x > b.x ? a : b)
    }
}

// MARK: - The rig

nonisolated private enum Rig {
    enum Program: CaseIterable { case sweep, fan, cross, lasers }

    /// The lamps along the truss: where their beams start, between a lamp's two pixels.
    static let fixtures: [Double] = [7, 15, 31, 39]

    /// Resting, the lamps point softly in towards the booth.
    static func restAngle(_ x: Double) -> Double { atan2(23 - x, 34) * 0.7 }

    static func showAngle(_ program: Program, fixture x: Double, index i: Int, phase: Double) -> Double {
        switch program {
        case .sweep: return 0.55 * sin(phase)
        case .fan: return (x - 23) / 16 * (0.25 + 0.3 * (0.5 + 0.5 * sin(phase)))
        case .cross: return (i % 2 == 0 ? 1 : -1) * 0.5 * sin(phase)
        case .lasers: return atan2(23 - x, 20) + 0.15 * sin(phase * 2 + Double(i))
        }
    }

    /// The mixer's knobs (columns).
    static let knobs = [19, 21, 24, 26]

    /// The mirror ball's rows, as column spans.
    static let ball: [(Int, Int)] = [(21, 24), (20, 25), (20, 25), (21, 24)]

    /// A record seen from the front, as column spans per row, and the pixels round its edge (clockwise).
    static let record: [(Int, Int)] = [(1, 6), (0, 7), (1, 6)]
    static let ring: [(Int, Int)] = [(1, 0), (2, 0), (3, 0), (4, 0), (5, 0), (6, 0), (7, 1), (6, 2), (5, 2), (4, 2),
                                     (3, 2), (2, 2), (1, 2), (0, 1)]
}

// MARK: - The crowd, the specks, the confetti

nonisolated private struct Dancer {
    var x: Int
    var top: Int
    var shape: Int
    var phase: Double
    var threshold: Double
    var side: Int
    var hand = 0.0

    /// Heads seen from behind, as column spans per row in a box 9 across; the shoulders follow.
    static let shapes: [[(Int, Int)]] = [
        [(3, 5), (2, 6), (2, 6), (2, 6), (3, 5)],
        [(2, 6), (1, 7), (1, 7), (1, 7), (2, 6)],
        [(4, 4), (3, 5), (2, 6), (2, 6), (2, 6), (3, 5)],
        [(3, 5), (2, 6), (2, 6), (2, 7), (3, 7)],
        [(3, 5), (2, 6), (2, 6), (3, 5)],
    ]

    static func crowd(_ r: inout SceneRandom) -> [Dancer] {
        var dancers: [Dancer] = []
        var x = -4 - r.int(2)
        while x < 42 {
            let shape = r.int(shapes.count)
            let top = 39 + r.int(3) + (shapes[shape].count < 5 ? 1 : 0) - (shapes[shape].count > 5 ? 1 : 0)
            dancers.append(Dancer(x: x, top: top, shape: shape, phase: r.range(-0.12, 0.12),
                                  threshold: r.range(0.45, 1.05), side: r.chance(0.5) ? 1 : -1))
            x += 6 + r.int(2)
        }
        return dancers
    }
}

nonisolated private struct Speck {
    let longitude: Double
    let y: Int
    let brightness: Double

    init(_ r: inout SceneRandom) {
        longitude = r.range(0, 2 * .pi)
        y = 2 + r.int(30)
        brightness = r.range(0.5, 1)
    }
}

nonisolated private struct Confetto {
    var alive = false
    var delay = 0.0
    var x = 0.0
    var y = 0.0
    var fall = 0.0
    var drift = 0.0
    var flip = 0.0
    var flipRate = 0.0
    var color = 0

    mutating func launch(_ r: inout SceneRandom, delay: Double) {
        alive = true
        self.delay = delay
        x = r.range(1, 45)
        y = r.range(-6, 0)
        fall = r.range(7, 12)
        drift = r.range(0, 2 * .pi)
        flip = r.range(0, 2 * .pi)
        flipRate = r.range(8, 16)
        color = r.int(4)
    }

    mutating func step(dt: Double, time: Double) {
        if delay > 0 { delay -= dt; return }
        y += fall * dt
        x += sin(time * 3 + drift) * 4 * dt
        flip += flipRate * dt
        if y > 46 { alive = false }
    }
}

// MARK: - The cameo

/// Now and then a tiny toast, the Dancing Toast's, strolls along the front of the stage (after a minute or so of steady
/// music) or crowd-surfs over the heads (a good chance after a drop), and leaves. It has its own random source and
/// only draws over the club, so with no toast about the club is exactly as it would be without it. In silence it
/// slips away at once, so a paused still frame never shows it.
nonisolated private struct ToastCameo {
    enum Act { case walk, surf }

    private var random: SceneRandom
    private var act: Act?
    /// Its left edge, heading, time on stage, and how visible it is (it fades out in silence).
    private var x = 0.0
    private var heading = 1.0
    private var clock = 0.0
    private var alpha = 1.0
    /// Seconds of steady music before the next stroll, and a crowd-surf waiting for the hands to go up.
    private var strollIn: Double
    private var surfIn = -1.0
    private let crust: RGB
    private let face: RGB
    private let jam: Bool
    private let shoe: Int

    /// The slice, 8 pixels square: 1 outline, 2 crust, 3 toast.
    private static let slice: [[Int]] = [
        [0, 1, 1, 1, 1, 1, 1, 0],
        [1, 2, 2, 2, 2, 2, 2, 1],
        [1, 2, 3, 3, 3, 3, 2, 1],
        [1, 2, 3, 3, 3, 3, 2, 1],
        [1, 2, 3, 3, 3, 3, 2, 1],
        [1, 2, 3, 3, 3, 3, 2, 1],
        [1, 2, 2, 2, 2, 2, 2, 1],
        [0, 1, 1, 1, 1, 1, 1, 0],
    ]

    init(seed: UInt64) {
        random = SceneRandom(seed: seed ^ 0x7A57_B7EA_D0C0_FFEE)
        // Sometimes soon, so a scene shown for a while in Rotate may see one too.
        strollIn = random.range(6, 50)
        let tones: [(UInt32, UInt32)] = [(0xC98A3D, 0xF2D58E), (0xB5651D, 0xE8B04B), (0x7A4214, 0xC47F2E)]
        let tone = tones[random.int(tones.count)]
        crust = RGB(hex: tone.0)
        face = RGB(hex: tone.1)
        jam = random.chance(0.4)
        shoe = random.int(4)
    }

    /// The bass came back: a good chance of a crowd-surf once the hands are up.
    mutating func dropped() {
        if act == nil, random.chance(0.65) { surfIn = 0.5 }
    }

    mutating func update(dt: Double, silent: Bool, steady: Bool) {
        guard !silent else {
            surfIn = -1
            if act != nil {
                alpha -= dt * 8
                if alpha <= 0 { leave() }
            }
            return
        }
        if surfIn >= 0 {
            surfIn -= dt
            if surfIn < 0, act == nil { enter(.surf) }
        }
        if act == nil, steady {
            strollIn -= dt
            if strollIn <= 0 { enter(.walk) }
        }
        guard let act else { return }
        clock += dt
        alpha = min(1, alpha + dt * 4)
        x += heading * (act == .walk ? 6 : 11) * dt
        if x < -12 || x > 58 { leave() }
    }

    private mutating func enter(_ act: Act) {
        self.act = act
        heading = random.chance(0.5) ? 1 : -1
        x = heading > 0 ? -10 : 54
        clock = 0
        alpha = 1
    }

    private mutating func leave() {
        act = nil
        strollIn = random.range(40, 90)
    }

    /// Draws the toast if it's doing `which`: strolling between the booth and the crowd (drawn before the crowd, so
    /// heads pass in front of its feet), or carried along over the heads with its arms up (drawn after them).
    func paint(_ c: inout PixelCanvas, _ which: Act, groove: Double, style: SceneStyle) {
        guard act == which, alpha > 0.01 else { return }
        let limb = RGB(hex: 0x4A2A12), eye = RGB(hex: 0x2A160A)
        let shoe = style.isLight ? style.ink : style.spark(shoe).mixed(with: RGB(hex: 0xE23B3B), 0.35)
        let left = Int(x.rounded(.down))
        let step = Int((clock * 4).rounded(.down)) % 2
        let top: Int
        if which == .walk {
            // A bounce on the beat, legs stepping and arms swinging.
            top = 31 + (groove < 0.25 ? 1 : 0)
            for (i, hip) in [2, 5].enumerated() {
                let forward = i == step ? Int(heading) : -Int(heading)
                c.set(left + hip, top + 8, limb, alpha)
                c.set(left + hip + forward, top + 9, limb, alpha)
                c.box(left + hip + forward - (forward < 0 ? 1 : 0), top + 10, 2, 1, shoe, alpha)
            }
            for (side, armX) in [(0, left - 1), (1, left + 8)] {
                c.set(armX, top + 4, limb, alpha)
                c.set(armX, top + (side == step ? 4 : 6), .white, alpha)
            }
        } else {
            // Bobbing along on the hands, feet kicking, both arms up.
            top = 31 + (groove < 0.5 ? 0 : 1)
            for (i, hip) in [2, 5].enumerated() {
                let kick = i == step ? 1 : 0
                c.set(left + hip, top + 8, limb, alpha)
                c.box(left + hip - (i == 0 ? 1 : 0), top + 9 - kick, 2, 1, shoe, alpha)
            }
            for (side, armX) in [(0, left - 1), (1, left + 8)] {
                c.set(armX, top + 2, limb, alpha)
                c.set(armX, top + 1, limb, alpha)
                c.set(armX + (side == 0 ? -1 : 1) * (side == step ? 1 : 0), top, .white, alpha)
            }
        }
        // The slice, its face and the topping.
        let colors = [RGB(hex: 0x24150E), crust, face]
        for (row, cells) in Self.slice.enumerated() {
            for (col, ink) in cells.enumerated() where ink > 0 { c.set(left + col, top + row, colors[ink - 1], alpha) }
        }
        c.set(left + 2, top + 3, eye, alpha)
        c.set(left + 5, top + 3, eye, alpha)
        // A smile, or a whoop on the hands.
        c.box(left + 3, top + 4, 2, which == .surf ? 2 : 1, which == .surf ? RGB(hex: 0x5A1E12) : eye, alpha)
        c.box(left + 2, top - 1, 4, 1, jam ? RGB(hex: 0xC8102E) : RGB(hex: 0xF7D660), alpha)
    }
}

nonisolated private extension PixelCanvas {
    /// A filled rectangle, clipped to the grid (`rect` traps on one wholly outside it).
    mutating func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: RGB, _ alpha: Double = 1) {
        let x0 = max(x, 0), x1 = min(x + w, width), y0 = max(y, 0), y1 = min(y + h, height)
        guard x0 < x1, y0 < y1 else { return }
        for yy in y0..<y1 {
            for xx in x0..<x1 { set(xx, yy, color, alpha) }
        }
    }
}

nonisolated private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
