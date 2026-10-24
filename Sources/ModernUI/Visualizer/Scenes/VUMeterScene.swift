// SPDX-License-Identifier: GPL-3.0-or-later
// VU Meters: a pair of analogue needle meters, as on the front of an old hi-fi amplifier, one reading the lows and one
// the highs (the analyser is mono, so the pair splits the music by pitch rather than faking stereo). Each warm,
// backlit dial carries an arced scale from -20 to +3 with a red zone past 0, and a black needle swings over it from a
// pivot below the dial on a spring with VU ballistics: it rises in about 300 ms with a slight overshoot and falls back
// smoothly, reading the band against the music's usual level the way an engineer sets the gain. A red peak lamp lights
// while its needle is in the red. Kicks throw the low needle up; through a breakdown it sags while the high one keeps
// moving; the drop slams both into the red, flashes the lamps and brightens the dials. In silence the needles fall
// back to their stops, the lamps go out and the backlight dims a little. A seed picks the dials' tint (cream, amber,
// honey, or cream tinged with the artwork's colour) and the bezels (black or brushed metal).

import CoreGraphics
import Foundation

nonisolated final class VUMeterScene: VisualizerScene {
    /// A needle on its spring: its deflection runs from 0 (the left stop, -20 and below) to 1 (+3, the scale's right
    /// end); the movement's pin lets it swing a little past either end. (Not private, for the tests.)
    struct Needle {
        var x = 0.0
        var velocity = 0.0
        /// The peak lamp: 0...1, and how much longer it stays lit after the needle leaves the red.
        var lamp = 0.0
        var hold = 0.0

        /// Natural frequency and damping: rises to 99% in about 0.3 s with an overshoot of about 1.5%, as a VU meter's
        /// movement does.
        static let omega = 15.0
        static let damping = 0.79
        static let stops = (-0.01, 1.07)

        /// Moves on by `dt` towards `target`, in small steps so a long frame can't blow up.
        mutating func step(toward target: Double, dt: Double) {
            let steps = max(1, Int((dt * 240).rounded(.up)))
            let h = dt / Double(steps)
            for _ in 0..<steps {
                let accel = Self.omega * Self.omega * (target - x) - 2 * Self.damping * Self.omega * velocity
                velocity += accel * h
                x += velocity * h
                // The stop pins: a dull knock and a small bounce.
                if x < Self.stops.0 {
                    x = Self.stops.0
                    if velocity < 0 { velocity *= -0.25 }
                } else if x > Self.stops.1 {
                    x = Self.stops.1
                    if velocity > 0 { velocity *= -0.3 }
                }
            }
            // The lamp lights in the red and holds a moment after, so a quick swing still shows.
            if x > Self.zero {
                lamp = 1
                hold = 0.12
            } else if hold > 0 {
                hold -= dt
            } else {
                lamp *= exp(-dt / 0.05)
                if lamp < 0.01 { lamp = 0 }
            }
        }

        /// Where 0 VU sits: the scale is linear in voltage, so 0 dB is 1/1.4125 of the way to +3 dB.
        static let zero = Scale.position(0)
    }

    /// The scale's geometry: deflection for a level in VU (dB), and the marks printed on the dial.
    private enum Scale {
        static func position(_ db: Double) -> Double { pow(10, db / 20) / pow(10, 3.0 / 20) }
        /// Marks with numbers: the value, and its label (red past 0).
        static let numbered: [(Double, String)] = [(-20, "20"), (-10, "10"), (-5, "5"), (-3, "3"), (0, "0"), (3, "+3")]
        /// Short marks between them.
        static let minor: [Double] = [-7, -2, -1, 1, 2]
        /// The needle's sweep, end to end, in radians (about 92°).
        static let sweep = 1.6
    }

    /// A dial's layout in points, worked out once per size.
    private struct Dial {
        var bezel: CGRect
        var face: CGRect
        var pivot: CGPoint
        var radius: CGFloat
    }

    /// What only changes with the size, the pixels per point or the style: the layout, and the meters' fixed parts
    /// (bezels, lit dials, printed scales, unlit lamps) drawn once into an image, so a frame only adds the needles and
    /// lamps over it.
    private struct Paint {
        var size: CGSize
        var scale: CGFloat
        var style: SceneStyle
        var dials: [Dial]
        var faces: CGPath
        var housings: CGPath
        var housingColour: RGB
        var backdrop: CGImage?
    }

    private static let ink = RGB(0.13, 0.1, 0.08)
    private static let needleInk = RGB(0.07, 0.06, 0.05)
    private static let redInk = RGB(0.8, 0.14, 0.1)
    private static let lampOn = RGB(1, 0.28, 0.16)
    private static let lampOff = RGB(0.42, 0.12, 0.09)
    /// What the dials darken towards as the backlight dims.
    private static let dimmed = RGB(0.3, 0.12, 0)

    private var needles = [Needle(), Needle()]
    /// Each band's usual level (raw bar units): the needles read the music against it.
    private var reference = [0.75, 0.42]
    /// The drop's push into the red (decays), and its brightening of the dials.
    private var slam = 0.0
    private var slamHold = 0.0
    private var flash = 0.0
    /// The backlight: 1 while music plays, 0 in silence (where the dials dim a little but stay lit).
    private var light = 0.0
    /// The dials' colour, and how far it leans towards the artwork's accent.
    private let tint: RGB
    private let tinge: Double
    private let metal: Bool
    private var paint: Paint?

    init(seed: UInt64) {
        var random = SceneRandom(seed: seed)
        // Cream, amber, honey, or cream taking more of the artwork's colour.
        let tints = [(RGB(1, 0.9, 0.68), 0.1), (RGB(1, 0.78, 0.42), 0.06), (RGB(1, 0.85, 0.58), 0.08),
                     (RGB(1, 0.9, 0.7), 0.28)]
        (tint, tinge) = tints[random.int(tints.count)]
        metal = random.chance(0.4)
    }

    /// A little: the lit dials spill a soft light around their bezels.
    var glow: Double { 0.35 }

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let sounding = !input.isSilent
        // The lows are the bottom four bars; the highs, the mids and treble together.
        let raw = [Double(AudioFeatures.mean(input.bars, 0..<4)),
                   Double(AudioFeatures.mean(input.bars, 5..<input.bars.count))]
        let breakdown = Double(input.breakdown)

        // The gain: each band's usual level, followed slowly while the music runs as usual (not through a breakdown,
        // so the low needle sags there).
        if sounding, breakdown < 0.2 {
            let follow = 1 - exp(-dt / 3)
            for i in 0..<2 where raw[i] > 0.05 {
                reference[i] += (raw[i] - reference[i]) * follow
            }
            reference[0] = min(max(reference[0], 0.3), 0.95)
            reference[1] = min(max(reference[1], 0.15), 0.9)
        }

        // The drop: both needles thrown hard into the red.
        if input.drop {
            slam = 1
            slamHold = 0.3
            flash = 1
            for i in 0..<2 { needles[i].velocity += 3 }
        }
        if slamHold > 0 {
            slamHold -= dt
        } else {
            slam *= exp(-dt / 0.35)
        }
        flash *= exp(-dt / 0.35)

        // A kick knocks the low needle up at once (the movement's answer to a sharp transient), harder with more bass.
        if input.beat, breakdown < 0.5 {
            needles[0].velocity += 1.8 + 3 * Double(max(input.bass - 0.4, 0))
        }
        for i in 0..<2 {
            var target = -0.06
            if sounding, raw[i] > 0.02 {
                // Raw bar units are roughly logarithmic: 45 dB a unit, the usual level reading a few dB under 0 VU
                // (the lows a little hotter, so strong kicks flick into the red).
                var db = (raw[i] - reference[i]) * 45 - (i == 0 ? 3.6 : 4.4) + 10 * slam
                if i == 0 { db -= 6 * breakdown }
                target = Scale.position(db)
            }
            needles[i].step(toward: target, dt: dt)
        }
        light += ((sounding ? 1 : 0) - light) * (1 - exp(-dt / (sounding ? 0.15 : 0.1)))
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let device = ctx.userSpaceToDeviceSpaceTransform
        let scale = max(1, (device.a * device.a + device.b * device.b).squareRoot())
        if paint == nil || paint?.size != size || paint?.scale != scale || paint?.style.isClose(to: style) != true {
            paint = makePaint(size: size, scale: scale, style: style)
        }
        guard let paint else { return }
        let u = size.width / 92

        if let backdrop = paint.backdrop {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            // The context is flipped (y down); images draw bottom-up, so flip back.
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(backdrop, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
        // The backlight dims in silence (warmer, as a bulb does turned down) and flares at the drop.
        let dim = 0.24 * (1 - light) - 0.12 * flash
        if abs(dim) > 0.003 {
            ctx.addPath(paint.faces)
            ctx.setFill(dim > 0 ? Self.dimmed : .white, abs(dim))
            ctx.fillPath()
        }

        // The peak lamps, lit: bright, with a glow on the dial.
        for (i, dial) in paint.dials.enumerated() where needles[i].lamp > 0 {
            let lamp = needles[i].lamp
            let c = Self.lampCentre(dial, u: u)
            ctx.fillGlow(at: c, radius: 8 * u, color: Self.lampOn, alpha: 0.55 * lamp)
            let r = 2.3 * u
            ctx.setFill(Self.lampOff.mixed(with: Self.lampOn, lamp))
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            if lamp > 0.3 {
                // A hot spot.
                let s = 0.9 * u
                ctx.setFill(RGB(1, 0.75, 0.6), lamp)
                ctx.fillEllipse(in: CGRect(x: c.x - s - 0.5 * u, y: c.y - s - 0.5 * u, width: s * 2, height: s * 2))
            }
        }

        // The needles, each with a faint shadow on the dial behind it.
        ctx.saveGState()
        ctx.setLineCap(.round)
        for (i, dial) in paint.dials.enumerated() {
            let angle = (needles[i].x - 0.5) * Scale.sweep
            let dx = CGFloat(sin(angle)), dy = CGFloat(-cos(angle))
            // From where it comes out from under the dial's foot to just past the scale.
            let from = (dial.pivot.y - dial.face.maxY) / max(-dy, 0.3), to = dial.radius + 2.5 * u
            let root = CGPoint(x: dial.pivot.x + dx * from, y: dial.pivot.y + dy * from)
            let tip = CGPoint(x: dial.pivot.x + dx * to, y: dial.pivot.y + dy * to)
            ctx.setStroke(.black, 0.16)
            ctx.setLineWidth(1.4 * u)
            ctx.strokeLineSegments(between: [CGPoint(x: root.x + 1.2 * u, y: root.y + 1.4 * u),
                                             CGPoint(x: tip.x + 1.2 * u, y: tip.y + 1.4 * u)])
            ctx.setStroke(Self.needleInk)
            ctx.setLineWidth(1.3 * u)
            ctx.strokeLineSegments(between: [root, tip])
        }
        ctx.restoreGState()

        // The housings that hide the needles' pivots.
        ctx.addPath(paint.housings)
        ctx.setFill(paint.housingColour)
        ctx.fillPath()
    }

    /// The peak lamp sits in the dial's top right corner, beyond the scale, where the needle never passes.
    private static func lampCentre(_ dial: Dial, u: CGFloat) -> CGPoint {
        CGPoint(x: (dial.face.maxX - 5.5 * u).rounded(), y: (dial.face.minY + 5.5 * u).rounded())
    }

    /// Lays out the two dials (stacked, wide), prints their scales and draws their fixed parts into the backdrop.
    private func makePaint(size: CGSize, scale: CGFloat, style: SceneStyle) -> Paint {
        let u = size.width / 92
        func r(_ v: CGFloat) -> CGFloat { (v * u).rounded() }
        var dials: [Dial] = []
        for top in [CGFloat(8), 48] {
            let bezel = CGRect(x: r(8), y: r(top), width: r(76), height: r(36))
            let face = bezel.insetBy(dx: r(2), dy: r(2))
            let pivot = CGPoint(x: face.midX, y: face.maxY + 12 * u)
            dials.append(Dial(bezel: bezel, face: face, pivot: pivot, radius: pivot.y - face.minY - 13 * u))
        }

        let printed = CGMutablePath(), red = CGMutablePath(), bezels = CGMutablePath(), faces = CGMutablePath()
        let housings = CGMutablePath(), lamps = CGMutablePath()
        for (index, dial) in dials.enumerated() {
            bezels.addRoundedRect(in: dial.bezel, cornerWidth: 4.5 * u, cornerHeight: 4.5 * u)
            faces.addRoundedRect(in: dial.face, cornerWidth: 2.5 * u, cornerHeight: 2.5 * u)
            Self.printScale(on: dial, index: index, u: u, ink: printed, red: red)
            let lamp = Self.lampCentre(dial, u: u), lampRadius = 2.3 * u
            lamps.addEllipse(in: CGRect(x: lamp.x - lampRadius, y: lamp.y - lampRadius, width: lampRadius * 2,
                                        height: lampRadius * 2))
            // The pivot's housing: a dark half-disc at the foot of the dial.
            let c = dial.pivot, h = 6.5 * u
            housings.move(to: CGPoint(x: c.x - h, y: dial.face.maxY))
            housings.addArc(center: CGPoint(x: c.x, y: dial.face.maxY), radius: h, startAngle: .pi, endAngle: 0,
                            clockwise: false)
            housings.closeSubpath()
        }

        let bezelColour = style.deep.mixed(with: .black, 0.72)
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        var backdrop: CGImage?
        if w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: sceneColorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)

            // The bezels: black, or brushed metal with a crease of light across the middle.
            ctx.addPath(bezels)
            if metal, let gradient = CGGradient(colorsSpace: sceneColorSpace, colors: [
                RGB(0.86, 0.86, 0.88).cgColor(alpha: 1), RGB(0.62, 0.62, 0.65).cgColor(alpha: 1),
                RGB(0.8, 0.8, 0.82).cgColor(alpha: 1), RGB(0.55, 0.55, 0.58).cgColor(alpha: 1),
            ] as CFArray, locations: [0, 0.48, 0.52, 1]) {
                ctx.saveGState()
                ctx.clip()
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: dials[0].bezel.minY),
                                       end: CGPoint(x: 0, y: dials[1].bezel.maxY), options: [])
                ctx.restoreGState()
            } else {
                ctx.setFill(bezelColour)
                ctx.fillPath()
            }

            // The dials: the seed's tint, leaning a little towards the artwork's accent, brightest at the foot where
            // the lamp behind sits, with the bezel's shadow across the top.
            let lit = tint.mixed(with: style.accent, tinge)
            let glass = CGGradient(colorsSpace: sceneColorSpace, colors: [
                lit.mixed(with: .white, 0.35).cgColor(alpha: 1), lit.cgColor(alpha: 1),
                lit.scaled(0.8).cgColor(alpha: 1),
            ] as CFArray, locations: [0, 0.45, 1])
            let shade = CGGradient(colorsSpace: sceneColorSpace, colors: [
                RGB.black.cgColor(alpha: 0.28), RGB.black.cgColor(alpha: 0),
            ] as CFArray, locations: [0, 1])
            for dial in dials {
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: dial.face, cornerWidth: 2.5 * u, cornerHeight: 2.5 * u,
                                   transform: nil))
                ctx.clip()
                let c = CGPoint(x: dial.face.midX, y: dial.face.maxY)
                if let glass {
                    ctx.drawRadialGradient(glass, startCenter: c, startRadius: 0, endCenter: c,
                                           endRadius: dial.face.width * 0.62, options: [.drawsAfterEndLocation])
                }
                if let shade {
                    ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: dial.face.minY),
                                           end: CGPoint(x: 0, y: dial.face.minY + 6 * u), options: [])
                }
                ctx.restoreGState()
            }

            // The printed scales and the unlit lamps.
            ctx.addPath(printed)
            ctx.setFill(Self.ink)
            ctx.fillPath()
            ctx.addPath(red)
            ctx.setFill(Self.redInk)
            ctx.fillPath()
            ctx.addPath(lamps)
            ctx.setFill(Self.lampOff)
            ctx.fillPath()
            backdrop = ctx.makeImage()
        }
        return Paint(size: size, scale: scale, style: style, dials: dials, faces: faces, housings: housings,
                     housingColour: metal ? RGB(0.16, 0.16, 0.17) : bezelColour, backdrop: backdrop)
    }

    /// Prints a dial's scale into `ink` and `red`: the arc (red past 0), its ticks and numbers, and the legend.
    private static func printScale(on dial: Dial, index: Int, u: CGFloat, ink: CGMutablePath, red: CGMutablePath) {
        let c = dial.pivot, radius = dial.radius
        func angle(_ db: Double) -> CGFloat { CGFloat((Scale.position(db) - 0.5) * Scale.sweep) }
        func point(_ a: CGFloat, _ d: CGFloat) -> CGPoint { CGPoint(x: c.x + sin(a) * d, y: c.y - cos(a) * d) }
        // The scale's angles run from straight up; Core Graphics measures from +x (clockwise on screen, y down), hence
        // the quarter turns below.
        let left = CGFloat(-Scale.sweep / 2), zero = angle(0), right = CGFloat(Scale.sweep / 2)

        // The arc: a line in ink up to 0, then a red band.
        let line = CGMutablePath()
        line.addArc(center: c, radius: radius, startAngle: left - .pi / 2, endAngle: zero - .pi / 2, clockwise: false)
        ink.addPath(line.copy(strokingWithWidth: 1 * u, lineCap: .butt, lineJoin: .miter, miterLimit: 4))
        let band = CGMutablePath()
        band.addArc(center: c, radius: radius - 0.5 * u, startAngle: zero - .pi / 2, endAngle: right - .pi / 2,
                    clockwise: false)
        band.addArc(center: c, radius: radius + 2.4 * u, startAngle: right - .pi / 2, endAngle: zero - .pi / 2,
                    clockwise: true)
        band.closeSubpath()
        red.addPath(band)

        // Ticks: long ones at the numbers, short between.
        let ticks = CGMutablePath(), redTicks = CGMutablePath()
        for (db, length) in Scale.numbered.map({ ($0.0, 4.0) }) + Scale.minor.map({ ($0, 2.6) }) {
            let a = angle(db)
            let path = db > 0 ? redTicks : ticks
            path.move(to: point(a, radius))
            path.addLine(to: point(a, radius + CGFloat(length) * u))
        }
        ink.addPath(ticks.copy(strokingWithWidth: 1.1 * u, lineCap: .butt, lineJoin: .miter, miterLimit: 4))
        red.addPath(redTicks.copy(strokingWithWidth: 1.1 * u, lineCap: .butt, lineJoin: .miter, miterLimit: 4))

        // The numbers, upright above their ticks, on whole points so the pixels stay crisp.
        for (db, label) in Scale.numbered {
            let p = point(angle(db), radius + 7.5 * u)
            let w = CGFloat(PixelFont.width(label)) * u
            let origin = CGPoint(x: (p.x - w / 2).rounded(), y: (p.y - 2.5 * u).rounded())
            addText(label, to: db >= 0 ? red : ink, at: origin, pixel: u)
        }
        // The legend: which band, under the middle of the scale, and VU tucked in the bottom right corner, clear of
        // the needle even hard against its right stop (the bottom left is where it rests).
        let name = index == 0 ? "LOW" : "HIGH"
        let nameWidth = CGFloat(PixelFont.width(name)) * u
        addText(name, to: ink, at: CGPoint(x: (c.x - nameWidth / 2).rounded(), y: (c.y - radius + 7 * u).rounded()),
                pixel: u)
        let corner = CGPoint(x: (dial.face.maxX - 9 * u).rounded(), y: (dial.face.maxY - 8 * u).rounded())
        addText("VU", to: ink, at: corner, pixel: u)
    }

    /// Adds `text` in the pixel font to `path`, its top-left at `origin`, `pixel` points a font pixel.
    private static func addText(_ text: String, to path: CGMutablePath, at origin: CGPoint, pixel: CGFloat) {
        var left = 0
        for c in text {
            if let rows = PixelFont.glyph(c) {
                for (row, bits) in rows.enumerated() {
                    for col in 0..<PixelFont.glyphWidth where bits & (0b100 >> UInt8(col)) != 0 {
                        path.addRect(CGRect(x: origin.x + CGFloat(left + col) * pixel,
                                            y: origin.y + CGFloat(row) * pixel, width: pixel, height: pixel))
                    }
                }
            }
            left += PixelFont.glyphWidth + 1
        }
    }
}
