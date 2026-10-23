// SPDX-License-Identifier: GPL-3.0-or-later
// Dancing Toast: a pixel-art slice of toast in sneakers dances under a stage light, on the same 46-pixel grid as
// Pixel DJ. It bobs down on every beat and changes routine every eight beats (hands on hips, clapping, waving, disco
// pointing, stepping, the robot), sings when the music swells, and shakes crumbs loose on the kicks. Through a
// breakdown it sways with its arms up; when the bass comes back it jumps, sparkles fly and the butter (or jam) on its
// head flips. In silence it stands, smiles and blinks. Each seed toasts a different slice: light, golden, well done or
// wholemeal, butter or jam, sometimes sunglasses.
//
// The dance is worked out in points (a 92-point square), then drawn as whole pixels: the slice is a sprite cut from
// its outline once per squash, it leans by shifting its upper rows (pixel art doesn't rotate), and the limbs are
// one-pixel lines.

import CoreGraphics
import Foundation

nonisolated final class ToastScene: VisualizerScene {
    /// The scene is drawn in a 92-point square and scaled to the artwork.
    private static let side: CGFloat = 92
    private static let floorY: CGFloat = 82
    private static let bodyWidth: CGFloat = 34
    private static let bodyHeight: CGFloat = 36
    /// Upper and lower limb lengths (both halves the same).
    private static let armBone: CGFloat = 9.5
    private static let legBone: CGFloat = 6
    /// The body's underside above the floor when standing.
    private static let hipHeight: CGFloat = 10

    private var random: SceneRandom
    private let look: Look
    private let routine: [Move]

    // The music.
    private var activity = 0.0
    private var beatIndex = 0
    private var lastGroove = 0.0
    private var groove = 0.0
    private var level = 0.0
    private var mid = 0.0
    private var pulse = 0.0
    /// The bass's low points between hits (recovering slowly), what they usually are, and how long they have sat
    /// well below that: a breakdown (a bassline alone keeps hitting, so a gap in kicks won't do).
    private var trough = 1.0
    private var usualTrough = 0.6
    private var lowFor = 0.0
    private var sinceDrop = 10.0
    /// How far into a breakdown (0...1), and the jump after a drop (beats left).
    private var calm = 0.0
    private var jumpBeats = 0.0

    // The toast.
    private var pose = Pose.rest
    private var butterY = 0.0, butterVY = 0.0
    private var butterSpin = 0.0, butterSpinV = 0.0
    private var blinkIn = 3.0
    private var blinkFor = 0.0
    private var crumbs: [Crumb] = []

    // The pixels.
    private var canvas = PixelCanvas(width: ToastScene.grid, height: ToastScene.grid)
    /// Slices already cut, by size in pixels.
    private var sprites: [Int: ToastSprite] = [:]
    /// 46 pixels across: 2 points a pixel, whole pixels at 1x and 2x.
    static let grid = 46

    /// None: a halo would blur the pixels.
    var glow: Double { 0 }

    init(seed: UInt64) {
        random = SceneRandom(seed: seed)
        look = Look(&random)
        var moves = Move.allCases
        for i in stride(from: moves.count - 1, to: 0, by: -1) { moves.swapAt(i, random.int(i + 1)) }
        routine = moves
        blinkIn = random.range(2, 4)
    }

    // MARK: Update

    func update(_ input: VisualizerInput, dt: Double) {
        let sounding = !input.isSilent
        // Activity eases in over half a second and out in a third of one, so the still frame after a pause is at rest.
        activity += ((sounding ? 1 : 0) - activity) * min(1, dt * (sounding ? 3 : 9))
        level = Double(input.level)
        mid += (Double(input.mid) - mid) * min(1, dt * 10)
        pulse = Double(input.pulse)
        groove = input.groove
        if sounding, groove < lastGroove - 0.5 { beatIndex += 1 }
        lastGroove = groove

        // A breakdown: the bass's low points sink well below their usual level. The drop: the first hit on the
        // downbeat after one (a breakdown's bassline hits as hard as a kick, but between the beats).
        let bass = Double(AudioFeatures.mean(input.bars, 0..<4))
        trough = min(bass, trough + dt * 0.5)
        if sounding, trough < usualTrough - 0.12 {
            lowFor += dt
        } else {
            if sounding, lowFor < 0.5 { usualTrough += (trough - usualTrough) * min(1, dt * 0.4) }
            lowFor = 0
        }
        sinceDrop += dt
        if input.beat, sounding {
            let downbeat = input.groove < 0.25 || input.groove > 0.75
            if lowFor > 1.5, downbeat, bass > usualTrough, sinceDrop > 8 {
                sinceDrop = 0
                drop()
                lowFor = 0
                trough = bass
            }
            shakeCrumbs(count: 2 + random.int(3), speed: 1)
            butterVY -= 26 * Double(input.pulse)
        }
        let breakdown = lowFor > 1
        calm += ((breakdown ? 1 : 0) - calm) * min(1, dt * 2.5)
        if jumpBeats > 0 { jumpBeats = max(0, jumpBeats - dt / max(input.beatInterval, 0.3)) }

        // The pose follows the dance, eased so routines blend into each other.
        let target = Pose.rest.mixed(with: dance(input), activity)
        pose = pose.mixed(with: target, min(1, dt * 16))

        // The butter rides a spring: it hops on kicks and spins on the drop.
        butterVY += (-160 * butterY - 9 * butterVY) * dt
        butterY += butterVY * dt
        butterSpinV += (-140 * butterSpin - 10 * butterSpinV) * dt
        butterSpin += butterSpinV * dt
        if !sounding {
            butterY *= max(0, 1 - dt * 10)
            butterSpin *= max(0, 1 - dt * 10)
        }

        // Blinks only while dancing, so a paused still frame never catches the eyes shut.
        if blinkFor > 0 {
            blinkFor -= dt
        } else if activity > 0.5 {
            blinkIn -= dt
            if blinkIn <= 0 {
                blinkFor = 0.13
                blinkIn = random.range(2.2, 5)
            }
        }
        if activity < 0.2 { blinkFor = 0 }

        for i in crumbs.indices {
            crumbs[i].vy += 150 * dt
            crumbs[i].x += crumbs[i].vx * dt
            crumbs[i].y += crumbs[i].vy * dt
            crumbs[i].life -= dt * (sounding ? 1 : 3)
            if crumbs[i].y > Self.floorY, crumbs[i].vy > 0 {
                crumbs[i].y = Self.floorY
                crumbs[i].vy *= -0.3
                crumbs[i].vx *= 0.6
            }
        }
        crumbs.removeAll { $0.life <= 0 }
    }

    /// The bass came back after a breakdown: jump, flip the topping, scatter crumbs and sparkles.
    private func drop() {
        jumpBeats = 2
        butterVY = -70
        butterSpinV = 30
        shakeCrumbs(count: 10, speed: 1.6)
        for i in 0..<8 {
            let angle = Double(i) / 8 * 2 * .pi + random.range(-0.3, 0.3)
            let speed = random.range(40, 70)
            crumbs.append(Crumb(x: 46, y: 46, vx: cos(angle) * speed, vy: sin(angle) * speed - 30, size: random.range(2, 3.2),
                                life: random.range(0.7, 1.1), sparkle: true, color: i))
        }
    }

    private func shakeCrumbs(count: Int, speed: Double) {
        for _ in 0..<count where crumbs.count < 48 {
            let side: Double = random.chance(0.5) ? -1 : 1
            crumbs.append(Crumb(x: 46 + Double(pose.sway) + side * random.range(10, 17),
                                y: Double(Self.floorY - Self.hipHeight - Self.bodyHeight * 0.5) + random.range(-8, 8),
                                vx: side * random.range(15, 45) * speed, vy: -random.range(25, 60) * speed,
                                size: random.range(1.3, 2.3), life: random.range(0.6, 1),
                                sparkle: false, color: random.int(2)))
        }
    }

    /// Where the dance puts everything this frame.
    private func dance(_ input: VisualizerInput) -> Pose {
        let p = groove
        let b = beatIndex
        // Down on the beat, up between beats.
        let lift = sin(.pi * p)
        let dip = max(0, 1 - p * 4)
        var pose = Pose.rest
        pose.bob = CGFloat(-2.2 * lift + 1.4 * dip) * CGFloat(0.6 + 0.4 * level)
        pose.squash = CGFloat(dip * (0.5 + pulse * 0.5))
        let swing = sin(.pi * (Double(b % 2) + p))
        let move = routine[(b / 8) % routine.count]
        switch move {
        case .hips:
            pose.hands = [CGPoint(x: -3, y: 11), CGPoint(x: -3, y: 11)]
            pose.sway = CGFloat(3 * swing)
            pose.lean = CGFloat(0.1 * swing)
        case .clap:
            let together = pow(cos(.pi * p), 8)
            let x = -2 - 13 * together
            pose.hands = [CGPoint(x: x, y: 7 - 4 * together), CGPoint(x: x, y: 7 - 4 * together)]
            pose.feet = b % 2 == 0 ? [CGPoint(x: 1, y: 3 * lift), CGPoint(x: 1, y: 0)] : [CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 3 * lift)]
        case .wave:
            let s = sin(.pi * (Double(b) + p) / 2)
            pose.hands = [CGPoint(x: 4 - 7 * s, y: -17), CGPoint(x: 4 + 7 * s, y: -17)]
            pose.lean = CGFloat(0.12 * s)
            pose.sway = CGFloat(2 * s)
        case .disco:
            let up = (b / 2) % 2 == 0
            let right = (b / 4) % 2 == 0
            let point = up ? CGPoint(x: 13, y: -14) : CGPoint(x: -5, y: 15)
            pose.hands = right ? [CGPoint(x: -3, y: 11), point] : [point, CGPoint(x: -3, y: 11)]
            pose.lean = CGFloat((right ? 1 : -1) * (up ? 0.14 : -0.08))
            pose.sway = CGFloat(2.5 * swing)
        case .step:
            let left = b % 2 == 0
            let kick = 4.5 * lift
            pose.feet = left ? [CGPoint(x: 3, y: kick), CGPoint(x: -1, y: 0)] : [CGPoint(x: -1, y: 0), CGPoint(x: 3, y: kick)]
            pose.sway = CGFloat(left ? 2.5 : -2.5) * CGFloat(lift)
            pose.hands = left ? [CGPoint(x: 3, y: 15 - 12 * lift), CGPoint(x: 5, y: 12)] : [CGPoint(x: 5, y: 12), CGPoint(x: 3, y: 15 - 12 * lift)]
        case .robot:
            // Snapping between held positions on the half beats.
            let half = (b * 2 + (p < 0.5 ? 0 : 1)) % 4
            let raised = [CGPoint(x: 13, y: -4), CGPoint(x: 13, y: 7), CGPoint(x: 7, y: -11), CGPoint(x: 13, y: 7)][half]
            let other = [CGPoint(x: 13, y: 7), CGPoint(x: 13, y: -4), CGPoint(x: 13, y: 7), CGPoint(x: 7, y: -11)][half]
            pose.hands = [raised, other]
            pose.lean = CGFloat([0, 0.06, 0, -0.06][half])
            pose.bob = CGFloat(-0.8 * dip)
        }
        // A breakdown: arms up, swaying slowly over two beats.
        if calm > 0.01 {
            let s = sin(.pi * (Double(b) + p) / 2)
            var sway = Pose.rest
            sway.hands = [CGPoint(x: 5 - 6 * s, y: -17), CGPoint(x: 5 + 6 * s, y: -17)]
            sway.sway = CGFloat(4 * s)
            sway.lean = CGFloat(0.1 * s)
            pose = pose.mixed(with: sway, calm)
        }
        // The drop: a jump with both arms up and the feet tucked.
        if jumpBeats > 0 {
            let t = 2 - jumpBeats
            let hop = sin(.pi * (t - t.rounded(.down)))
            var jump = Pose.rest
            jump.hands = [CGPoint(x: 10, y: -16), CGPoint(x: 10, y: -16)]
            jump.hop = CGFloat(11 * hop)
            jump.feet = [CGPoint(x: 2, y: 3 * hop), CGPoint(x: 2, y: 3 * hop)]
            jump.squash = CGFloat(-0.25 * hop)
            pose = pose.mixed(with: jump, min(1, jumpBeats * 2))
        }
        pose.mouth = CGFloat(min(1, max(0, pulse * 0.7 + (mid - 0.35) * 1.6)))
        return pose
    }

    // MARK: Draw

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        canvas.clear()
        let lit = !style.isLight
        let floorRow = Self.px(Self.floorY)
        let cx = 46 + pose.sway
        let bottom = Self.floorY - Self.hipHeight - pose.bob - pose.hop

        // The stage: a cone of light from above onto a lit spot on the floor, and the toast's shadow.
        let beam = style.isLight ? style.accent : style.accent.mixed(with: .white, 0.35)
        let strength = (lit ? 0.1 : 0.07) + 0.08 * pulse * activity
        for row in 0..<floorRow {
            let half = 2 + Double(row) / Double(floorRow) * 11
            let core = half * 0.45
            for col in Int((23 - half).rounded())...Int((23 + half).rounded()) {
                canvas.set(col, row, beam, abs(Double(col) - 23) <= core ? strength * 1.6 : strength)
            }
        }
        // Flat pixel ovals: a wide middle row, shorter rows above and below.
        for (dy, inset) in [(-1, 4), (0, 0), (1, 4), (2, 9)] { canvas.rect(23 - 15 + inset, floorRow + dy, 30 - inset * 2, 1, beam, lit ? 0.2 : 0.13) }
        let shadow = max(4, 8 - Int((pose.hop / 3).rounded()))
        let shade = style.isLight ? style.ink : RGB.black
        canvas.rect(Self.px(cx) - shadow, floorRow, shadow * 2, 1, shade, lit ? 0.4 : 0.2)
        canvas.rect(Self.px(cx) - shadow + 2, floorRow + 1, shadow * 2 - 4, 1, shade, lit ? 0.25 : 0.12)
        drawCrumbs(style, sparkles: false)

        // Where the body goes, in points: squashed and leaning about its bottom centre.
        let sx = 1 + pose.squash * 0.12, sy = 1 - pose.squash * 0.1
        let body = CGAffineTransform(translationX: cx, y: bottom).rotated(by: pose.lean).scaledBy(x: sx, y: sy)
        func world(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(body) }
        let w = Self.bodyWidth, h = Self.bodyHeight
        let limbColor = RGB(hex: 0x4A2A12)

        // Legs behind the body, down to sneakers on the floor.
        for side in 0..<2 {
            let s: CGFloat = side == 0 ? -1 : 1
            let hip = world(s * w * 0.2, -1)
            let foot = CGPoint(x: cx + s * (w * 0.2 + pose.feet[side].x), y: Self.floorY - 2 - pose.feet[side].y - pose.hop * 0.4)
            line([hip, Self.joint(hip, foot, Self.legBone, bend: s), foot], limbColor)
            let fx = Self.px(foot.x) + (side == 0 ? -2 : 0), fy = Self.px(foot.y)
            canvas.rect(fx, fy - 1, 3, 1, look.shoe(style))
            canvas.rect(fx, fy, 3, 1, .white, 0.9)
        }

        // The slice.
        let sprite = sprite(width: sx, height: sy)
        let bx = Self.px(cx), by = Self.px(bottom)
        let lean = pose.lean
        let leanShift = { (row: Int) -> Int in max(-2, min(2, Int((lean * CGFloat(-row) * 0.9).rounded()))) }
        let colors: [RGB] = [.black, look.crust.scaled(0.55), look.crust, look.toast, look.middle]
        for row in sprite.rows {
            let shift = leanShift(row)
            for col in sprite.columns {
                let cell = sprite[col, row]
                guard cell != 0 else { continue }
                var color = colors[Int(cell)]
                if look.wholemeal, cell >= 3, look.seeds.contains(where: { $0.x == col && $0.y == row }) { color = look.crust }
                canvas.set(bx + col + shift, by + row, color)
            }
        }
        // The face, the topping, both shifted with the rows they sit on.
        let eyeRow = -Int((h * sy * 0.56 / 2).rounded())
        drawFace(at: (bx + leanShift(eyeRow), by + eyeRow))
        let top = sprite.crown
        drawTopping(at: (bx + leanShift(top), by + top + Int((butterY / 2).rounded())))

        // Arms in front, out to white-gloved hands.
        for side in 0..<2 {
            let s: CGFloat = side == 0 ? -1 : 1
            let shoulder = world(s * (w / 2 - 0.5), -h * 0.5)
            let target = CGPoint(x: shoulder.x + s * pose.hands[side].x, y: shoulder.y + pose.hands[side].y)
            let hand = Self.reach(shoulder, target, Self.armBone * 2)
            line([shoulder, Self.joint(shoulder, target, Self.armBone, bend: s), hand], limbColor)
            let hx = Self.px(hand.x) - (side == 0 ? 1 : 0), hy = Self.px(hand.y) - 1
            if style.isLight {
                // Outlined, or white gloves vanish on light artwork.
                canvas.rect(hx - 1, hy, 4, 2, limbColor)
                canvas.rect(hx, hy - 1, 2, 4, limbColor)
            }
            canvas.rect(hx, hy, 2, 2, .white)
        }
        drawCrumbs(style, sparkles: true)
        canvas.draw(in: ctx, rect: CGRect(origin: .zero, size: size))
    }

    /// A point (in the 92-point square) as a pixel.
    private static func px(_ v: CGFloat) -> Int { Int((v / 2).rounded(.down)) }

    /// A one-pixel line through `points` (in points).
    private func line(_ points: [CGPoint], _ color: RGB) {
        for (a, b) in zip(points, points.dropFirst()) {
            var x0 = Self.px(a.x), y0 = Self.px(a.y)
            let x1 = Self.px(b.x), y1 = Self.px(b.y)
            let dx = abs(x1 - x0), dy = -abs(y1 - y0)
            let stepX = x0 < x1 ? 1 : -1, stepY = y0 < y1 ? 1 : -1
            var error = dx + dy
            while true {
                canvas.set(x0, y0, color)
                if x0 == x1, y0 == y1 { break }
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
    }

    /// Eyes (or shades), cheeks and the mouth; `at` is the left eye row at the slice's middle (between two columns).
    private func drawFace(at origin: (Int, Int)) {
        let (c, y) = origin
        let dark = RGB(hex: 0x2A160A)
        if look.shades {
            canvas.rect(c - 6, y, 4, 2, RGB(hex: 0x15151A))
            canvas.rect(c + 2, y, 4, 2, RGB(hex: 0x15151A))
            canvas.rect(c - 2, y, 4, 1, RGB(hex: 0x15151A))
            canvas.set(c - 6, y, .white, 0.7)
            canvas.set(c + 2, y, .white, 0.7)
        } else if blinkFor > 0 {
            canvas.rect(c - 5, y + 1, 2, 1, dark)
            canvas.rect(c + 3, y + 1, 2, 1, dark)
        } else {
            canvas.rect(c - 5, y, 2, 2, dark)
            canvas.rect(c + 3, y, 2, 2, dark)
            canvas.set(c - 5, y, .white)
            canvas.set(c + 3, y, .white)
        }
        let pink = RGB(hex: 0xFF6F7F)
        canvas.rect(c - 7, y + 2, 2, 1, pink, 0.7)
        canvas.rect(c + 5, y + 2, 2, 1, pink, 0.7)
        let m = y + 3
        if pose.mouth > 0.55 {
            canvas.rect(c - 2, m, 4, 3, RGB(hex: 0x5A1E12))
            canvas.rect(c - 1, m + 2, 2, 1, RGB(hex: 0xF0717E))
        } else if pose.mouth > 0.18 {
            canvas.rect(c - 1, m, 2, 2, RGB(hex: 0x5A1E12))
        } else {
            canvas.set(c - 3, m, dark)
            canvas.rect(c - 2, m + 1, 4, 1, dark)
            canvas.set(c + 2, m, dark)
        }
    }

    /// Butter or jam on the crown, tipping as it spins.
    private func drawTopping(at origin: (Int, Int)) {
        let (c, y) = origin
        let tilt = Double(butterSpin) * 0.08 - Double(pose.lean) * 0.6
        let lift = tilt > 0.25 ? (0, -1) : tilt < -0.25 ? (-1, 0) : (0, 0)
        if look.jam {
            let red = RGB(hex: 0xC8102E)
            canvas.rect(c - 2, y - 2 + lift.0, 3, 1, red)
            canvas.rect(c - 3, y - 1, 6, 1, red)
            canvas.rect(c + 1, y - 2 + lift.1, 1, 1, red)
            canvas.set(c - 2, y - 2 + lift.0, .white, 0.7)
        } else {
            canvas.rect(c - 3, y - 2 + lift.0, 3, 1, RGB(hex: 0xFFF0A8))
            canvas.rect(c, y - 2 + lift.1, 3, 1, RGB(hex: 0xFFF0A8))
            canvas.rect(c - 3, y - 1, 6, 1, RGB(hex: 0xF7D660))
        }
    }

    private func drawCrumbs(_ style: SceneStyle, sparkles: Bool) {
        for crumb in crumbs where crumb.sparkle == sparkles {
            let alpha = min(1, crumb.life * 2.5)
            let x = Self.px(CGFloat(crumb.x)), y = Self.px(CGFloat(crumb.y))
            if sparkles {
                // A plus that shrinks to a point as it fades.
                let color = style.spark(crumb.color)
                canvas.set(x, y, color.mixed(with: .white, 0.5), alpha)
                if crumb.life > 0.35 {
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] { canvas.set(x + dx, y + dy, color, alpha * 0.8) }
                }
            } else {
                canvas.set(x, y, crumb.color == 0 ? look.crust : look.toast, alpha)
            }
        }
    }

    /// The slice cut as pixels for a squash (`width` and `height` scales), cached.
    private func sprite(width sx: CGFloat, height sy: CGFloat) -> ToastSprite {
        let key = Int((sx * 50).rounded()) * 1000 + Int((sy * 50).rounded())
        if let sprite = sprites[key] { return sprite }
        let sprite = Self.sprite(width: Self.bodyWidth * sx, height: Self.bodyHeight * sy)
        sprites[key] = sprite
        return sprite
    }

    // MARK: Shapes

    /// A slice of bread standing on its bottom centre (0, 0): straight sides, a crown that bulges out over them with a
    /// small dip in the middle of the top.
    static func slice(width w: CGFloat, height h: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let r: CGFloat = 4.5
        path.move(to: CGPoint(x: -w / 2 + r, y: 0))
        path.addLine(to: CGPoint(x: w / 2 - r, y: 0))
        path.addQuadCurve(to: CGPoint(x: w / 2, y: -r), control: CGPoint(x: w / 2, y: 0))
        path.addLine(to: CGPoint(x: w / 2, y: -h * 0.6))
        path.addCurve(to: CGPoint(x: w * 0.18, y: -h), control1: CGPoint(x: w / 2 + 10, y: -h * 0.66),
                      control2: CGPoint(x: w * 0.56, y: -h * 1.04))
        path.addCurve(to: CGPoint(x: -w * 0.18, y: -h), control1: CGPoint(x: w * 0.07, y: -h * 0.96),
                      control2: CGPoint(x: -w * 0.07, y: -h * 0.96))
        path.addCurve(to: CGPoint(x: -w / 2, y: -h * 0.6), control1: CGPoint(x: -w * 0.56, y: -h * 1.04),
                      control2: CGPoint(x: -w / 2 - 10, y: -h * 0.66))
        path.addLine(to: CGPoint(x: -w / 2, y: -r))
        path.addQuadCurve(to: CGPoint(x: -w / 2 + r, y: 0), control: CGPoint(x: -w / 2, y: 0))
        path.closeSubpath()
        return path
    }

    /// A slice `width` × `height` points as 2-point pixels around its bottom centre: an outline, a ring of crust, the
    /// toast, and a paler middle (cell values 1, 2, 3, 4; 0 is empty).
    static func sprite(width w: CGFloat, height h: CGFloat) -> ToastSprite {
        let outline = slice(width: w, height: h)
        var middleTransform = CGAffineTransform(translationX: 0, y: -h * 0.48).scaledBy(x: 0.58, y: 0.58)
            .translatedBy(x: 0, y: h * 0.48)
        let middle = outline.copy(using: &middleTransform) ?? outline
        let left = -Int((w / 4 + 2).rounded(.up)), right = -left - 1
        let top = -Int((h / 2 + 1).rounded(.up))
        var sprite = ToastSprite(columns: left...right, rows: top...(-1))
        func inside(_ col: Int, _ row: Int) -> Bool {
            guard sprite.columns.contains(col), sprite.rows.contains(row) else { return false }
            return outline.contains(CGPoint(x: CGFloat(col) * 2 + 1, y: CGFloat(row) * 2 + 1))
        }
        for row in sprite.rows {
            for col in sprite.columns where inside(col, row) {
                let edge = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { !inside(col + $0.0, row + $0.1) }
                let nearEdge = [(1, 1), (-1, 1), (1, -1), (-1, -1), (2, 0), (-2, 0), (0, 2), (0, -2)]
                    .contains { !inside(col + $0.0, row + $0.1) }
                let inMiddle = middle.contains(CGPoint(x: CGFloat(col) * 2 + 1, y: CGFloat(row) * 2 + 1))
                sprite[col, row] = edge ? 1 : nearEdge ? 2 : inMiddle ? 4 : 3
            }
        }
        sprite.crown = sprite.rows.first { row in sprite[-1, row] != 0 || sprite[0, row] != 0 } ?? sprite.rows.lowerBound
        return sprite
    }

    /// The middle joint of a two-bone limb from `root` towards `target` (bones of `bone` each), bent to `bend`'s side.
    static func joint(_ root: CGPoint, _ target: CGPoint, _ bone: CGFloat, bend: CGFloat) -> CGPoint {
        let end = reach(root, target, bone * 2)
        let dx = end.x - root.x, dy = end.y - root.y
        let d = max((dx * dx + dy * dy).squareRoot(), 0.001)
        let rise = (max(bone * bone - d * d / 4, 0)).squareRoot()
        // Perpendicular to the limb: outwards, or downwards when the limb points sideways.
        var nx = -dy / d, ny = dx / d
        if abs(nx) < 0.2 ? ny < 0 : nx * bend < 0 {
            nx = -nx
            ny = -ny
        }
        return CGPoint(x: root.x + dx / 2 + nx * rise, y: root.y + dy / 2 + ny * rise)
    }

    /// `target`, or as near it as a limb `length` long reaches from `root`.
    static func reach(_ root: CGPoint, _ target: CGPoint, _ length: CGFloat) -> CGPoint {
        let dx = target.x - root.x, dy = target.y - root.y
        let d = (dx * dx + dy * dy).squareRoot()
        guard d > length * 0.98, d > 0 else { return target }
        let k = length * 0.98 / d
        return CGPoint(x: root.x + dx * k, y: root.y + dy * k)
    }
}

// MARK: - Pieces

private nonisolated enum Move: CaseIterable {
    case hips, clap, wave, disco, step, robot
}

/// Everything the dance moves: hand targets from each shoulder and feet from each hip (x outwards), and the body.
private nonisolated struct Pose {
    var hands: [CGPoint]
    var feet: [CGPoint]
    var sway: CGFloat = 0
    var lean: CGFloat = 0
    var bob: CGFloat = 0
    var hop: CGFloat = 0
    var squash: CGFloat = 0
    var mouth: CGFloat = 0

    static let rest = Pose(hands: [CGPoint(x: 2, y: 16), CGPoint(x: 2, y: 16)], feet: [.zero, .zero])

    func mixed(with other: Pose, _ t: Double) -> Pose {
        let k = CGFloat(min(max(t, 0), 1))
        func m(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }
        func p(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: m(a.x, b.x), y: m(a.y, b.y)) }
        return Pose(hands: [p(hands[0], other.hands[0]), p(hands[1], other.hands[1])],
                    feet: [p(feet[0], other.feet[0]), p(feet[1], other.feet[1])], sway: m(sway, other.sway),
                    lean: m(lean, other.lean), bob: m(bob, other.bob), hop: m(hop, other.hop), squash: m(squash, other.squash),
                    mouth: m(mouth, other.mouth))
    }
}

/// This slice: how toasted, which topping, shades or not, the sneakers.
private nonisolated struct Look {
    let crust: RGB
    let toast: RGB
    let middle: RGB
    let wholemeal: Bool
    let jam: Bool
    let shades: Bool
    let shoeIndex: Int
    /// Wholemeal's seeds, as pixels on the slice.
    let seeds: [(x: Int, y: Int)]

    init(_ random: inout SceneRandom) {
        // Light, golden, well done, wholemeal: crust, toasted face, middle.
        let tones: [(UInt32, UInt32, UInt32)] = [(0xC98A3D, 0xF2D58E, 0xF8E7B5), (0xB5651D, 0xE8B04B, 0xF3CF7A),
                                                 (0x7A4214, 0xC47F2E, 0xD99A47), (0x8A5A2B, 0xC99560, 0xD9AE7C)]
        let pick = random.int(tones.count)
        crust = RGB(hex: tones[pick].0)
        toast = RGB(hex: tones[pick].1)
        middle = RGB(hex: tones[pick].2)
        wholemeal = pick == 3
        jam = random.chance(0.4)
        self.shades = random.chance(0.34)
        shoeIndex = random.int(4)
        var seeds: [(x: Int, y: Int)] = []
        for _ in 0..<7 { seeds.append((random.int(12) - 6, -3 - random.int(12))) }
        self.seeds = seeds
    }

    /// Sneakers in one of the artwork's bright colours (dark ink on light artwork).
    func shoe(_ style: SceneStyle) -> RGB {
        style.isLight ? style.ink : style.spark(shoeIndex).mixed(with: RGB(hex: 0xE23B3B), 0.35)
    }
}

/// A slice as pixels: cell values by column and row around the bottom centre (rows negative, upwards).
nonisolated struct ToastSprite {
    let columns: ClosedRange<Int>
    let rows: ClosedRange<Int>
    /// The top row of the crown in the middle (where the topping sits).
    var crown = 0
    private var cells: [UInt8]

    init(columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
        self.columns = columns
        self.rows = rows
        cells = [UInt8](repeating: 0, count: columns.count * rows.count)
    }

    subscript(col: Int, row: Int) -> UInt8 {
        get {
            guard columns.contains(col), rows.contains(row) else { return 0 }
            return cells[(row - rows.lowerBound) * columns.count + col - columns.lowerBound]
        }
        set { cells[(row - rows.lowerBound) * columns.count + col - columns.lowerBound] = newValue }
    }
}

private nonisolated struct Crumb {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var size: Double
    var life: Double
    /// A sparkle from the drop rather than a crumb.
    var sparkle: Bool
    var color: Int
}
