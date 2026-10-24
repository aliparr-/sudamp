// SPDX-License-Identifier: GPL-3.0-or-later
// Turntable: a record playing, seen from above. The record turns at 33⅓ (about half a turn a second) on a silver
// platter, and its grooves glint with the spectrum: eight rings, the bass at the rim and the treble by the label, each
// catching the light in a bow-tie of sheen that stays put while the record turns, the glints stretching and
// brightening as their band gets louder. The label, printed in the artwork's colours, turns with it; the tonearm's
// headshell rides the groove and creeps inwards, and at the run-out lifts and swings back to the start. Kicks flash
// the outer grooves and nudge the stylus. Through a breakdown the grooves dim to a soft shimmer; the drop is a quick
// scratch (the record jerks back and forth, then plays on). In silence the motor brakes the record to a stop within
// half a second and the arm lifts: a still record. Before anything has played the arm sits on its rest. Each seed
// prints a different label (split, rays, a band with a logo, an eclipse) in different colours, and now and then
// presses the record in coloured vinyl.
//
// The platter, the vinyl and its sheen don't change from frame to frame, so they are drawn once into a bitmap; each
// frame adds the glints, the label and the arm.

import CoreGraphics
import Foundation

nonisolated final class TurntableScene: VisualizerScene {
    private enum Label: CaseIterable { case split, rays, band, eclipse }

    /// 33⅓ turns a minute, in radians a second.
    private static let speed = 2 * Double.pi * (100.0 / 3) / 60
    /// Where things are, in a 92-point square.
    private static let centre = CGPoint(x: 40, y: 48)
    private static let platterRadius: CGFloat = 35.5
    private static let recordRadius: CGFloat = 32
    private static let labelRadius: CGFloat = 11.5
    private static let pivot = CGPoint(x: 81, y: 17)
    /// The tonearm: a straight tube from the pivot and a headshell kinked inwards at its end, so the cartridge lies
    /// along the groove.
    private static let tube: CGFloat = 44
    private static let shell: CGFloat = 9.5
    private static let kink = 0.4
    /// The stylus's distance from the pivot, and how far its direction is turned from the tube's by the kink.
    private static let reach = Double(tube * tube + shell * shell + 2 * tube * shell * CGFloat(cos(kink))).squareRoot()
    private static let kinkTurn = atan2(Double(shell) * sin(kink), Double(tube) + Double(shell) * cos(kink))
    /// The arm's angle (of the stylus about the pivot) on its rest, off the record to the right.
    private static let restAngle = 92 * Double.pi / 180
    /// The grooves the stylus plays, outermost first, and how long one side takes to play in seconds.
    private static let leadIn = 29.5, runOut = 15.0
    private static let sideLength = 75.0
    /// The glinting rings, bass outermost.
    private static let rings = 8
    private static let ringRadii: [CGFloat] = (0..<rings).map { 30.2 - CGFloat($0) * 2.2 }
    /// The sheen's axis (up-right and down-left, clear of the arm), in radians, y down.
    private static let sheenAngle = -0.7
    /// The scratch on a drop: how long the hand holds the record, and how fast it rocks it.
    private static let scratchLength = 0.5
    private static let strobeDots = 36

    private let label: Label
    /// Which spark colours the label takes, and the coloured vinyl's (nil: black vinyl).
    private let labelColour: Int
    private let vinylColour: Int?
    /// The label's printed design, turned by a seed so no two pressings line up the same.
    private let labelTurn: Double

    /// The record's angle and speed (radians, y down: positive turns clockwise on screen).
    private var angle: Double
    private var spin = 0.0
    /// The platter's speed (it keeps turning under the record while a hand scratches it).
    private var platter = 0.0
    /// The strobe dots' apparent drift: still at exactly 33⅓, creeping when the platter is off speed.
    private var strobe = 0.0
    private var scratch: Double?
    private var levels = [Double](repeating: 0, count: rings)
    private var flash = 0.0
    private var breakdown = 0.0
    private var shimmer = 0.0
    private var nudge = 0.0
    /// The arm: its angle about the pivot, how far it is lifted (0 down, 1 up), and how far through the side it is.
    private var arm = TurntableScene.restAngle
    private var lift = 0.0
    private var progress: Double
    private var played = false

    private struct Paints {
        var style: SceneStyle
        var width: Int
        var height: Int
        var body: CGImage?
        /// Each ring's glint colour, rim to label.
        var glints: [RGB]
        var labelBase: RGB
        var labelSecond: RGB
        var labelPrint: RGB
        var cartridge: RGB
    }

    private var paints: Paints?

    /// The polar table behind the glints, for one bitmap size, and the pixels they are drawn into.
    private struct Grooves {
        struct Entry {
            var index: Int32
            var ring: UInt8
            var radial: Float
            var angle: Float
        }

        var width = 0
        var height = 0
        var entries: [Entry] = []
        var pixels: [UInt32] = []
    }

    private var grooves = Grooves()

    init(seed: UInt64) {
        var random = SceneRandom(seed: seed)
        label = Label.allCases[random.int(Label.allCases.count)]
        labelColour = random.int(4)
        vinylColour = random.chance(0.22) ? random.int(4) : nil
        labelTurn = random.range(0, 2 * .pi)
        angle = random.range(0, 2 * .pi)
        progress = random.range(0, 0.35)
    }

    var glow: Double { 0 }

    // MARK: Motion

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let playing = !input.isSilent
        if playing { played = true }

        // The grooves: each ring hears its share of the spectrum, quick to light and slower to fade.
        let rise = 1 - exp(-dt * 30), fall = 1 - exp(-dt * 7)
        for i in 0..<Self.rings {
            let f = Double(i) / Double(Self.rings - 1)
            let d = 0.5 / Double(Self.rings)
            let raw = Double(input.band(at: f)) * 0.5 + Double(input.band(at: f - d) + input.band(at: f + d)) * 0.25
            let target = playing ? min(max((raw - 0.2) / 0.65, 0), 1) : 0
            levels[i] += (target - levels[i]) * (target > levels[i] ? rise : fall)
        }
        flash *= exp(-dt * 6)
        nudge *= exp(-dt * 9)
        if input.beat {
            flash = max(flash, 0.7)
            nudge = 1
        }
        // The breakdown's shimmer dies away quickly in silence, so the still frame is still.
        breakdown += (Double(input.breakdown) - breakdown) * (1 - exp(-dt * (playing ? 4 : 12)))
        shimmer += dt * 2.4

        // The motor: up to speed in a third of a second, braked to a stop in under half a second.
        if playing {
            platter = min(Self.speed, platter + Self.speed / 0.3 * dt)
        } else {
            platter = max(0, platter - Self.speed / 0.32 * dt)
        }
        if input.drop, playing {
            scratch = 0
            flash = 1.5
            // The breakdown is over the moment the bass is back.
            breakdown *= 0.2
        }
        if let age = scratch {
            // A hand rocks the record back and forth twice, pulling back first, then lets go.
            let s = age / Self.scratchLength
            spin = -22 * sin(2 * .pi * 2 * s) * (1 - 0.3 * s)
            let next = age + dt
            scratch = next < Self.scratchLength && playing ? next : nil
        } else {
            // The slipmat drags the record back up to the platter's speed.
            spin += (platter - spin) * (1 - exp(-dt * 25))
        }
        angle = (angle + spin * dt).truncatingRemainder(dividingBy: 2 * .pi)
        // A strobe lamp at a fixed rate: the dots seem to stand still at speed, drift back just under it, and creep
        // forwards when the platter is slow.
        let apparent = platter - Self.speed * (platter / Self.speed).rounded()
        strobe = (strobe + apparent * dt).truncatingRemainder(dividingBy: 2 * .pi)

        // The arm: from its rest to the groove once music plays, inwards as the side plays, lifted in silence. It
        // lifts before it swings and lowers once it is over its groove.
        if playing, lift < 0.05, abs(arm - Self.playAngle(progress)) < 0.01 {
            progress += dt / Self.sideLength
            if progress >= 1 { progress = 0 }
        }
        let target = played ? Self.playAngle(progress) : Self.restAngle
        let far = abs(arm - target) > 0.004
        let resting = !played && !far
        let up = far || (!playing && !resting)
        lift = up ? min(1, lift + dt / 0.2) : max(0, lift - dt / 0.3)
        if far, lift > 0.85 {
            let step = 1.3 * dt
            arm += max(-step, min(step, (target - arm) * min(1, dt * 9) + (target > arm ? 0.2 : -0.2) * dt))
        } else if !far {
            arm = target
        }
    }

    /// The arm's angle (of the stylus about the pivot, y down) with the stylus `progress` of the way through the side.
    private static func playAngle(_ progress: Double) -> Double {
        let r = leadIn + (runOut - leadIn) * min(max(progress, 0), 1)
        let dx = Double(centre.x - pivot.x), dy = Double(centre.y - pivot.y)
        let d = (dx * dx + dy * dy).squareRoot()
        // The angle at the pivot between the spindle and the stylus.
        let cosine = (reach * reach + d * d - r * r) / (2 * reach * d)
        return atan2(dy, dx) - acos(min(max(cosine, -1), 1))
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let scale = min(max(abs(ctx.userSpaceToDeviceSpaceTransform.a), 1), 3)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        if paints?.style.isClose(to: style) != true || paints?.width != width || paints?.height != height {
            paints = makePaints(style, size: size, scale: scale, width: width, height: height)
        }
        guard let paints, size.width > 0 else { return }
        if let body = paints.body {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(body, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
        ctx.saveGState()
        let u = size.width / 92
        ctx.scaleBy(x: u, y: u)
        drawStrobe(ctx)
        ctx.restoreGState()
        drawGrooves(ctx, size: size, width: width, height: height, paints)
        ctx.saveGState()
        ctx.scaleBy(x: u, y: u)
        drawLabel(ctx, paints)
        drawArm(ctx, paints)
        ctx.restoreGState()
    }

    /// The platter's strobe dots, round its rim.
    private func drawStrobe(_ ctx: CGContext) {
        let c = Self.centre, r = Self.recordRadius + 1.8
        let dots = CGMutablePath()
        for i in 0..<Self.strobeDots {
            let a = strobe + Double(i) * 2 * .pi / Double(Self.strobeDots)
            let p = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
            dots.addEllipse(in: CGRect(x: p.x - 0.75, y: p.y - 0.75, width: 1.5, height: 1.5))
        }
        ctx.addPath(dots)
        ctx.setFill(RGB(0.92, 0.93, 0.95), 0.85)
        ctx.fillPath()
    }

    /// The grooves: each band's ring catches the light either side of the sheen's axis, in a glint that stretches,
    /// thickens and whitens with its level, over a faint glow all the way round. Worked out per pixel from the polar
    /// table (stroking two dozen arcs a frame costs several times as much).
    private func drawGrooves(_ ctx: CGContext, size: CGSize, width: Int, height: Int, _ paints: Paints) {
        if grooves.width != width || grooves.height != height {
            grooves = Self.grooveTable(size: size, width: width, height: height)
        }
        let dim = 1 - 0.6 * breakdown
        // Each ring's glint this frame: its reach along the ring, its half-thickness, its glow round the ring and the
        // kick's flash, and its colour.
        var reach = [Float](repeating: 0, count: Self.rings), half = reach, base = reach, rim = reach
        var lit = false
        for i in 0..<Self.rings {
            let kick = flash * max(0, 1 - Double(i) * 0.2)
            let wave = 0.5 + 0.5 * sin(shimmer - Double(i) * 0.9)
            let level = min(1, levels[i] * dim + kick * 0.4 + breakdown * 0.25 * wave)
            if level > 0.02 || kick > 0.02 { lit = true }
            reach[i] = Float(level > 0.02 ? 0.1 + 0.9 * level : 0)
            half[i] = Float(0.4 + 0.4 * level + 0.25 * min(kick, 1))
            base[i] = Float(0.12 * level)
            rim[i] = Float(min(0.8, kick * 0.75))
        }
        guard lit else { return }
        let colours = paints.glints.map { (Float($0.r), Float($0.g), Float($0.b)) }
        let entries = grooves.entries
        grooves.pixels.withUnsafeMutableBufferPointer { out in
            out.update(repeating: 0)
            for e in entries {
                let i = Int(e.ring)
                let h = half[i]
                // Solid across the groove's glint, with a soft edge 0.6 points wide.
                let across = min(1, (h - abs(e.radial)) / 0.6)
                guard across > 0 else { continue }
                var along = reach[i] > 0 ? max(0, 1 - e.angle / reach[i]) : 0
                along = along * along * (3 - 2 * along)
                let glint = along * (0.8 + 0.2 * (reach[i] - 0.1) / 0.9)
                let a = min(1, across * (glint + base[i] + rim[i]))
                guard a > 0.004 else { continue }
                // The middle of a bright glint goes white.
                let white = min(1, along * along * along * (0.3 + (reach[i] - 0.1) * 1.2) + rim[i] * 0.5)
                let c = colours[i]
                let r = c.0 + (1 - c.0) * white, g = c.1 + (1 - c.1) * white, b = c.2 + (1 - c.2) * white
                out[Int(e.index)] = Self.pack(r * a, g * a, b * a, a)
            }
        }
        let data = grooves.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: sceneColorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }

    /// Every pixel over the grooves: its nearest ring, how far it is from that ring (points, at 92 across) and how far
    /// round from the sheen's axis (radians, 0 on the axis, either side).
    private static func grooveTable(size: CGSize, width: Int, height: Int) -> Grooves {
        var table = Grooves(width: width, height: height)
        table.pixels = [UInt32](repeating: 0, count: width * height)
        // Pixels per point of the 92-point square.
        let perPoint = Double(width) / 92
        let inner = Double(ringRadii[rings - 1]) - 1.6, outer = Double(ringRadii[0]) + 1.6
        let cx = Double(centre.x), cy = Double(centre.y)
        let x0 = max(0, Int((cx - outer) * perPoint)), x1 = min(width - 1, Int((cx + outer) * perPoint) + 1)
        let y0 = max(0, Int((cy - outer) * perPoint)), y1 = min(height - 1, Int((cy + outer) * perPoint) + 1)
        guard x0 <= x1, y0 <= y1 else { return table }
        let spacing = Double(ringRadii[0] - ringRadii[1])
        for py in y0...y1 {
            for px in x0...x1 {
                let x = (Double(px) + 0.5) / perPoint - cx, y = (Double(py) + 0.5) / perPoint - cy
                let r = (x * x + y * y).squareRoot()
                guard r > inner, r < outer else { continue }
                let ring = min(max(Int(((Double(ringRadii[0]) - r) / spacing).rounded()), 0), rings - 1)
                // Round from the axis, folded so both of the bow-tie's sides count.
                var a = abs(atan2(y, x) - sheenAngle).truncatingRemainder(dividingBy: .pi)
                a = min(a, .pi - a)
                table.entries.append(.init(index: Int32(py * width + px), ring: UInt8(ring),
                                           radial: Float(r - Double(ringRadii[ring])), angle: Float(a)))
            }
        }
        return table
    }

    /// Premultiplied components, 0...1, as bytes R, G, B, A in memory.
    private static func pack(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> UInt32 {
        func byte(_ v: Float) -> UInt32 { UInt32(min(max(v, 0), 1) * 255 + 0.5) }
        return byte(r) | byte(g) << 8 | byte(b) << 16 | byte(a) << 24
    }

    /// The label, turning with the record, and the spindle.
    private func drawLabel(_ ctx: CGContext, _ paints: Paints) {
        let c = Self.centre, r = Self.labelRadius
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: CGFloat(angle + labelTurn))
        let disc = CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
        ctx.setFill(paints.labelBase)
        ctx.fillEllipse(in: disc)
        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.clip()
        ctx.setFill(paints.labelSecond)
        switch label {
        case .split:
            ctx.fill(CGRect(x: -r, y: -r, width: 2 * r, height: r))
            // A logo on the top half and two lines of print on the bottom.
            ctx.setFill(paints.labelBase)
            ctx.fillEllipse(in: CGRect(x: -2.2, y: -r * 0.72, width: 4.4, height: 4.4))
            ctx.setFill(paints.labelPrint)
            ctx.fill(CGRect(x: -r * 0.55, y: r * 0.28, width: r * 1.1, height: 1.6))
            ctx.fill(CGRect(x: -r * 0.35, y: r * 0.56, width: r * 0.7, height: 1.6))
        case .rays:
            let rays = CGMutablePath()
            for k in 0..<4 {
                let a = Double(k) * .pi / 2
                rays.move(to: .zero)
                rays.addArc(center: .zero, radius: r + 1, startAngle: CGFloat(a), endAngle: CGFloat(a + .pi / 4),
                            clockwise: false)
                rays.closeSubpath()
            }
            ctx.addPath(rays)
            ctx.fillPath()
            // A round logo in one of the plain quarters, so the turn reads.
            ctx.setFill(paints.labelPrint)
            ctx.fillEllipse(in: CGRect(x: -r * 0.78, y: -r * 0.78 + 0.5, width: r * 0.5, height: r * 0.5))
        case .band:
            let band = CGMutablePath()
            band.addEllipse(in: disc.insetBy(dx: r * 0.12, dy: r * 0.12))
            band.addEllipse(in: disc.insetBy(dx: r * 0.3, dy: r * 0.3))
            ctx.addPath(band)
            ctx.fillPath(using: .evenOdd)
            // A curve of print round the top and a dot of a logo below the hole.
            ctx.setStroke(paints.labelPrint)
            ctx.setLineWidth(1.8)
            ctx.setLineCap(.round)
            ctx.addArc(center: .zero, radius: r * 0.47, startAngle: CGFloat(-.pi * 0.8), endAngle: CGFloat(-.pi * 0.2),
                       clockwise: false)
            ctx.strokePath()
            ctx.setFill(paints.labelPrint)
            ctx.fillEllipse(in: CGRect(x: -1.5, y: r * 0.3, width: 3, height: 3))
        case .eclipse:
            ctx.fillEllipse(in: CGRect(x: -r * 0.2, y: -r * 0.85, width: r * 1.7, height: r * 1.7))
            ctx.setFill(paints.labelPrint)
            ctx.fill(CGRect(x: -r * 0.88, y: -0.9, width: r * 0.55, height: 1.8))
        }
        ctx.restoreGState()
        // The edge of the label where the vinyl begins, and the spindle through its hole.
        ctx.setStroke(RGB.black, 0.35)
        ctx.setLineWidth(0.8)
        ctx.strokeEllipse(in: disc.insetBy(dx: 0.4, dy: 0.4))
        ctx.restoreGState()
        ctx.setFill(RGB(0.12, 0.12, 0.13), 0.8)
        ctx.fillEllipse(in: CGRect(x: c.x - 2.3, y: c.y - 2.3, width: 4.6, height: 4.6))
        ctx.setFill(RGB(0.86, 0.87, 0.9))
        ctx.fillEllipse(in: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
        ctx.setFill(.white, 0.9)
        ctx.fillEllipse(in: CGRect(x: c.x - 1, y: c.y - 1, width: 1.1, height: 1.1))
    }

    /// The tonearm: its shadow on the record (further off the more it is lifted), the pivot and counterweight, the
    /// tube, and the headshell with its cartridge.
    private func drawArm(_ ctx: CGContext, _ paints: Paints) {
        let p = Self.pivot
        // A kick jolts the stylus up a touch.
        let raised = min(1, lift + 0.12 * nudge)
        let heading = arm - Self.kinkTurn
        let along = CGPoint(x: CGFloat(cos(heading)), y: CGFloat(sin(heading)))
        let joint = CGPoint(x: p.x + along.x * Self.tube, y: p.y + along.y * Self.tube)
        let shellHeading = heading + Self.kink
        let shellAlong = CGPoint(x: CGFloat(cos(shellHeading)), y: CGFloat(sin(shellHeading)))
        let silver = RGB(0.86, 0.87, 0.9), edge = RGB(0.16, 0.16, 0.18)

        // The rest the arm sits in when it isn't playing.
        let rest = CGPoint(x: p.x + CGFloat(cos(Self.restAngle - Self.kinkTurn)) * 36,
                           y: p.y + CGFloat(sin(Self.restAngle - Self.kinkTurn)) * 36)
        ctx.setFill(edge, 0.9)
        ctx.fillEllipse(in: CGRect(x: rest.x - 2.4, y: rest.y - 2.4, width: 4.8, height: 4.8))
        ctx.setFill(RGB(0.45, 0.46, 0.5))
        ctx.fillEllipse(in: CGRect(x: rest.x - 1.4, y: rest.y - 1.4, width: 2.8, height: 2.8))

        // The shadow, cast down and to the right.
        let fall = CGFloat(1.2 + 2.6 * raised)
        ctx.saveGState()
        ctx.translateBy(x: fall * 0.7, y: fall)
        ctx.setStroke(.black, 0.32 - 0.1 * raised)
        ctx.setLineCap(.round)
        ctx.setLineWidth(2.6)
        ctx.strokeLineSegments(between: [p, joint])
        headshell(ctx, at: joint, along: shellAlong, grow: 0, fill: .black, alpha: 0.32 - 0.1 * raised)
        ctx.restoreGState()

        // The counterweight behind the pivot (a ribbed drum), then the pivot's base over its end.
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.concatenate(CGAffineTransform(a: along.x, b: along.y, c: -along.y, d: along.x, tx: 0, ty: 0))
        let drum = CGRect(x: -12.5, y: -4, width: 9, height: 8)
        ctx.setFill(edge)
        ctx.addPath(CGPath(roundedRect: drum.insetBy(dx: -0.7, dy: -0.7), cornerWidth: 2, cornerHeight: 2,
                           transform: nil))
        ctx.fillPath()
        ctx.setFill(RGB(0.38, 0.39, 0.42))
        ctx.addPath(CGPath(roundedRect: drum, cornerWidth: 1.4, cornerHeight: 1.4, transform: nil))
        ctx.fillPath()
        ctx.setFill(RGB(0.7, 0.71, 0.75))
        ctx.fill(CGRect(x: -11, y: -4, width: 1.4, height: 8))
        ctx.fill(CGRect(x: -7.8, y: -4, width: 1.4, height: 8))
        ctx.restoreGState()
        ctx.setFill(edge)
        ctx.fillEllipse(in: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
        ctx.setFill(RGB(0.62, 0.63, 0.67))
        ctx.fillEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))

        // The tube: a dark edge under silver, so it reads on any record.
        ctx.setLineCap(.round)
        ctx.setStroke(edge, 0.9)
        ctx.setLineWidth(2.9)
        ctx.strokeLineSegments(between: [p, joint])
        ctx.setStroke(silver)
        ctx.setLineWidth(1.7)
        ctx.strokeLineSegments(between: [p, joint])
        ctx.setFill(silver)
        ctx.fillEllipse(in: CGRect(x: p.x - 2.6, y: p.y - 2.6, width: 5.2, height: 5.2))
        ctx.setFill(edge)
        ctx.fillEllipse(in: CGRect(x: p.x - 1.1, y: p.y - 1.1, width: 2.2, height: 2.2))

        // The headshell grows a little as it lifts towards us.
        headshell(ctx, at: joint, along: shellAlong, grow: CGFloat(0.12 * raised), fill: silver, alpha: 1, edge: edge,
                  cartridge: paints.cartridge)
    }

    /// The headshell from `joint` along `along`: a plate with a finger lift, and the cartridge under its front.
    private func headshell(_ ctx: CGContext, at joint: CGPoint, along: CGPoint, grow: CGFloat, fill: RGB, alpha: Double,
                           edge: RGB? = nil, cartridge: RGB? = nil) {
        ctx.saveGState()
        ctx.translateBy(x: joint.x, y: joint.y)
        ctx.concatenate(CGAffineTransform(a: along.x, b: along.y, c: -along.y, d: along.x, tx: 0, ty: 0))
        ctx.scaleBy(x: 1 + grow, y: 1 + grow)
        // In the shell's own frame: x runs from the joint to the stylus, y across.
        let plate = CGRect(x: -1, y: -2.5, width: Self.shell + 2, height: 5)
        let lift = CGRect(x: Self.shell - 3.2, y: -5.6, width: 1.6, height: 3.6)
        if let edge {
            ctx.setFill(edge, 0.9)
            ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: -0.7, dy: -0.7), cornerWidth: 1.6, cornerHeight: 1.6,
                               transform: nil))
            ctx.addPath(CGPath(roundedRect: lift.insetBy(dx: -0.6, dy: -0.6), cornerWidth: 1, cornerHeight: 1,
                               transform: nil))
            ctx.fillPath()
        }
        ctx.setFill(fill, alpha)
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 1, cornerHeight: 1, transform: nil))
        ctx.addPath(CGPath(roundedRect: lift, cornerWidth: 0.6, cornerHeight: 0.6, transform: nil))
        ctx.fillPath()
        if let cartridge {
            ctx.setFill(cartridge)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 2.8, y: -1.7, width: Self.shell - 2.6, height: 3.4),
                               cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    // MARK: Colours and the still parts

    private func makePaints(_ style: SceneStyle, size: CGSize, scale: CGFloat, width: Int, height: Int) -> Paints {
        // The glints are light on the dark vinyl whatever the artwork, shading from one spark colour at the rim to
        // another by the label.
        let outer = style.isLight ? style.accent.mixed(with: .white, 0.45) : style.spark(1).mixed(with: .white, 0.15)
        let inner = style.isLight ? style.spark(2).mixed(with: .white, 0.5) : style.spark(0).mixed(with: .white, 0.15)
        let glints = (0..<Self.rings).map { outer.mixed(with: inner, Double($0) / Double(Self.rings - 1)) }
        let base: RGB, second: RGB, print: RGB
        if style.isLight {
            base = style.spark(labelColour == 1 ? 0 : labelColour)
            second = style.accent.mixed(with: .white, 0.55)
            print = style.ink
        } else {
            base = style.spark(labelColour)
            second = style.spark(labelColour + 1).mixed(with: style.deep, 0.35)
            print = style.deep.scaled(0.7)
        }
        // The cartridge in the boldest of the artwork's colours.
        let boldest = style.sparks.max { $0.hsb.saturation < $1.hsb.saturation } ?? style.accent
        let cartridge = style.isLight ? style.ink : boldest.adjusted(saturation: 1.5, brightness: 0.9)
        let vinyl = vinylColour.map { style.spark($0).adjusted(saturation: 1.3, brightness: 0.42) }
            ?? RGB(0.07, 0.07, 0.08)
        let body = Self.body(style: style, vinyl: vinyl, size: size, scale: scale, width: width, height: height)
        return Paints(style: style, width: width, height: height, body: body, glints: glints,
                      labelBase: base, labelSecond: second, labelPrint: print, cartridge: cartridge)
    }

    /// The parts that never change: the platter's shadow and rim, the vinyl with its fine grooves, and the sheen.
    private static func body(style: SceneStyle, vinyl: RGB, size: CGSize, scale: CGFloat, width: Int,
                             height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sceneColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        let u = size.width / 92
        ctx.scaleBy(x: u, y: u)
        let c = centre
        func disc(_ r: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) -> CGRect {
            CGRect(x: c.x - r + dx, y: c.y - r + dy, width: 2 * r, height: 2 * r)
        }

        // A soft shadow under the platter, in a few steps.
        for k in 0..<4 {
            ctx.setFill(.black, style.isLight ? 0.05 : 0.09)
            ctx.fillEllipse(in: disc(platterRadius + 2.4 - CGFloat(k) * 0.8, dx: 1.2, dy: 2.4))
        }
        // The platter's rim: brushed metal, lit from the top left.
        ctx.saveGState()
        ctx.addEllipse(in: disc(platterRadius))
        ctx.clip()
        let metal = [RGB(0.78, 0.79, 0.82), RGB(0.5, 0.51, 0.55), RGB(0.34, 0.35, 0.38)]
        if let gradient = CGGradient(colorsSpace: sceneColorSpace, colors: metal.map { $0.cgColor } as CFArray,
                                     locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: c.x - platterRadius, y: c.y - platterRadius),
                                   end: CGPoint(x: c.x + platterRadius, y: c.y + platterRadius), options: [])
        }
        ctx.restoreGState()
        ctx.setStroke(.black, 0.45)
        ctx.setLineWidth(0.8)
        ctx.strokeEllipse(in: disc(platterRadius - 0.4))

        // The vinyl, its grooves in fine rings, a smooth band before the label, and a glossy lip at the rim.
        ctx.setFill(.black, 0.5)
        ctx.fillEllipse(in: disc(recordRadius + 0.6))
        ctx.setFill(vinyl)
        ctx.fillEllipse(in: disc(recordRadius))
        ctx.setLineWidth(0.5)
        var r: CGFloat = 13.6
        while r < recordRadius - 1.4 {
            ctx.setStroke(.white, 0.045)
            ctx.strokeEllipse(in: disc(r))
            r += 1.1
        }
        ctx.setStroke(.white, 0.14)
        ctx.setLineWidth(0.8)
        ctx.strokeEllipse(in: disc(recordRadius - 0.7))

        // The sheen: two soft wedges of light across the record, built up from nested fans.
        let sheen = style.isLight ? RGB.white : style.glow.mixed(with: .white, 0.5)
        for side in 0..<2 {
            let axis = sheenAngle + Double(side) * .pi
            for (spread, alpha) in [(0.5, 0.035), (0.34, 0.04), (0.2, 0.045), (0.09, 0.05)] {
                let fan = CGMutablePath()
                fan.addArc(center: c, radius: recordRadius - 1.2, startAngle: CGFloat(axis - spread),
                           endAngle: CGFloat(axis + spread), clockwise: false)
                fan.addArc(center: c, radius: labelRadius + 1, startAngle: CGFloat(axis + spread),
                           endAngle: CGFloat(axis - spread), clockwise: true)
                fan.closeSubpath()
                ctx.addPath(fan)
                ctx.setFill(sheen, alpha)
                ctx.fillPath()
            }
        }
        return ctx.makeImage()
    }
}
