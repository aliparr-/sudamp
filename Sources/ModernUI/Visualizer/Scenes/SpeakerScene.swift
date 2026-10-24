// SPDX-License-Identifier: GPL-3.0-or-later
// Speaker: the front of a hi-fi speaker filling the artwork, its woofer pumping with the bass. The cone is a mass on a
// spring driven by the low bars: it surges towards you on each kick (swelling, its rubber surround stretching flat,
// the shadow inside its rim shrinking and its walls catching more light) and rings back past rest before it settles.
// The tweeter above shimmers with the treble, a highlight flickering on its dome and ripples running off it, and the
// power light pulses with the kicks. Specks of dust on the cone hop off it on every kick and fall back under gravity,
// landing a little way from where they rose. Through a breakdown the cone breathes slowly and softly and the dust
// barely stirs; the drop is a big thump that throws the dust high and shakes the cabinet. In silence the cone settles
// and the dust falls back within half a second: a still speaker with its light on. Each seed builds a different
// speaker: walnut, teak, black ash or a lacquer in the artwork's colours, with a black, grey, Kevlar-yellow,
// aluminium or tinted cone.
//
// The cabinet, the woofer's frame, the tweeter's plate and the port never change, so they are drawn once into a bitmap;
// each frame adds the moving cone, the dust and the tweeter's shimmer.

import CoreGraphics
import Foundation

nonisolated final class SpeakerScene: VisualizerScene {
    private enum Finish: CaseIterable { case walnut, teak, blackAsh, lacquer }
    private enum Cone: CaseIterable { case paper, polypropylene, kevlar, aluminium, tinted }

    /// A speck of dust: where it sits on the cone (a share of the cone's radius, so it rides the cone's swell), and how
    /// high it has hopped off it (points, towards you, drawn upwards).
    private struct Speck {
        var x: Double
        var y: Double
        /// Where it first lay: each landing drifts it back a little that way, so the dust stays spread round the cone.
        let homeX: Double
        var height = 0.0
        var rise = 0.0
        var drift = 0.0
        var size: Double
        var colour: Int
        var resting: Bool { height <= 0 && rise == 0 }
    }

    /// Where things are, in a 92-point square.
    private static let cabinet = CGRect(x: 11, y: 4.5, width: 70, height: 83)
    private static let woofer = CGPoint(x: 46, y: 57.5)
    private static let frameRadius: CGFloat = 25.5
    private static let surroundRadius: CGFloat = 22.8
    private static let rimRadius: CGFloat = 19
    private static let capRadius: CGFloat = 6.8
    private static let tweeter = CGPoint(x: 46, y: 19.5)
    private static let port = CGPoint(x: 67.5, y: 19.5)
    private static let light = CGPoint(x: 24.5, y: 19.5)
    /// The cone's spring, for a natural frequency of 4.5 Hz and a damping ratio of 0.3 (so it rings a little), and the
    /// dust's gravity in points a second squared.
    private static let stiffness = pow(2 * Double.pi * 4.5, 2)
    private static let damping = 2 * 0.3 * (2 * Double.pi * 4.5)
    private static let gravity = 420.0

    private let finish: Finish
    private let cone: Cone
    /// The dust cap matches the cone, or is a contrasting dome.
    private let plainCap: Bool
    private let silkDome: Bool
    private var random: SceneRandom

    /// The cone's excursion (0 at rest, 1 a full push towards you) and its speed.
    private var excursion = 0.0
    private var velocity = 0.0
    /// The drop's extra push, fading.
    private var thump = 0.0
    private var breath = 0.0
    private var breakdown = 0.0
    private var shake = 0.0
    private var clock = 0.0
    /// The treble's flicker on the tweeter, and its ripples' phase.
    private var sparkle = 0.0
    private var ripple = 0.0
    private var treble = 0.0
    private var power = 0.0
    private var pulse = 0.0
    private var specks: [Speck] = []

    private struct Paints {
        var style: SceneStyle
        var width: Int
        var height: Int
        var body: CGImage?
        var cone: RGB
        var capShade: CGGradient?
        var coneShade: CGGradient?
        var dome: CGGradient?
        var specks: [RGB]
        var shimmer: RGB
        var lamp: RGB
    }

    private var paints: Paints?

    init(seed: UInt64) {
        var random = SceneRandom(seed: seed)
        finish = Finish.allCases[random.int(Finish.allCases.count)]
        cone = Cone.allCases[random.int(Cone.allCases.count)]
        plainCap = random.chance(0.5)
        silkDome = random.chance(0.4)
        // Dust spread round the cone, a few on the dust cap.
        for k in 0..<12 {
            let a = (Double(k) + random.range(0.2, 0.8)) / 12 * 2 * .pi
            let r = k % 4 == 0 ? random.range(0.12, 0.3) : random.range(0.45, 0.88)
            specks.append(Speck(x: cos(a) * r, y: sin(a) * r, homeX: cos(a) * r, size: random.range(0.9, 1.3),
                                colour: random.int(3)))
        }
        self.random = random
    }

    var glow: Double { 0 }

    // MARK: Motion

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let playing = !input.isSilent
        clock += dt
        breakdown += (Double(input.breakdown) - breakdown) * (1 - exp(-dt * 4))
        if input.drop {
            // The breakdown is over the moment the bass is back.
            breakdown *= 0.2
        }
        let calm = 1 - 0.8 * breakdown

        // The cone: the low bars push it out, a kick kicks it, and its spring pulls it back (past rest, a little).
        var bass = 0.0
        if input.bars.count >= 4 { bass = Double(input.bars[0] + input.bars[1] + input.bars[2] + input.bars[3]) / 4 }
        let drive = playing ? min(max((bass - 0.58) / 0.36, 0), 1) : 0
        // Through a breakdown it breathes, out and in over two beats.
        breath += dt * .pi / max(input.beatInterval, 0.3)
        let breathing = playing ? breakdown * 0.32 * (0.5 - 0.5 * cos(breath)) : 0
        thump *= exp(-dt * 5)
        if playing, input.beat { velocity += 9 * calm }
        if playing, input.drop {
            velocity += 24
            thump = 1
            shake = 1
        }
        let target = drive * calm + breathing + thump * 0.7
        let steps = max(1, Int((dt * 240).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            velocity += (-Self.stiffness * (excursion - target) - Self.damping * velocity) * h
            excursion += velocity * h
        }
        excursion = min(max(excursion, -0.7), 1.9)
        shake *= exp(-dt * 6)
        if shake < 0.01 { shake = 0 }

        // The dust: everything at rest hops on a kick (higher on the drop), and falls back.
        if playing, input.beat || input.drop {
            let hop = input.drop ? 175.0 : 95 * calm
            for i in specks.indices where specks[i].resting {
                specks[i].rise = hop * random.range(input.drop ? 0.75 : 0.55, 1.1)
                specks[i].drift = random.range(-1, 1) * (input.drop ? 0.5 : 0.25)
            }
        }
        // In silence the dust drops faster, so it is down within half a second.
        let g = playing ? Self.gravity : Self.gravity * 2.4
        for i in specks.indices where !specks[i].resting {
            var s = specks[i]
            s.rise -= g * dt
            s.height += s.rise * dt
            s.x += s.drift * dt
            if s.height <= 0 {
                s.height = 0
                // A small bounce off the cone, then still.
                s.rise = s.rise < -60 ? -s.rise * 0.25 : 0
                // Back on the cone: no further out than its rim.
                s.x += (s.homeX - s.x) * 0.3
                let r = (s.x * s.x + s.y * s.y).squareRoot()
                if r > 0.9 {
                    s.x *= 0.9 / r
                    s.y *= 0.9 / r
                }
            }
            specks[i] = s
        }

        // The tweeter: the highest bars flicker its highlight and send ripples off it.
        var high = 0.0
        if input.bars.count >= 19 {
            for i in 13..<19 { high += Double(input.bars[i]) }
            high /= 6
        }
        let shine = playing ? min(max((high - 0.15) / 0.55, 0), 1) : 0
        sparkle += (shine - sparkle) * (shine > sparkle ? 1 - exp(-dt * 40) : 1 - exp(-dt * 10))
        treble += ((playing ? Double(input.treble) : 0) - treble) * (1 - exp(-dt * 8))
        ripple = (ripple + dt * (1.4 + 2.6 * treble)).truncatingRemainder(dividingBy: 1)
        power += ((playing ? 1 : 0) - power) * (1 - exp(-dt * 6))
        pulse = playing ? Double(input.pulse) : pulse * exp(-dt * 10)
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let scale = min(max(abs(ctx.userSpaceToDeviceSpaceTransform.a), 1), 3)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        if paints?.style.isClose(to: style) != true || paints?.width != width || paints?.height != height {
            paints = makePaints(style, size: size, scale: scale, width: width, height: height)
        }
        guard let paints, size.width > 0 else { return }
        let u = size.width / 92
        // The drop's shake: a quick rattle that dies away.
        let jolt = CGPoint(x: CGFloat(shake * 2.2 * sin(clock * 83)), y: CGFloat(shake * 1.5 * sin(clock * 61 + 1)))
        if let body = paints.body {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: jolt.x * u, y: size.height + jolt.y * u)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(body, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.scaleBy(x: u, y: u)
        ctx.translateBy(x: jolt.x, y: jolt.y)
        drawWoofer(ctx, paints)
        drawTweeter(ctx, paints)
        // The dust last: it flies in front of everything.
        drawDust(ctx, paints)
        ctx.restoreGState()
    }

    /// The cone's radius now: it swells as it comes towards you.
    private var rim: CGFloat { min(Self.rimRadius * CGFloat(1 + 0.13 * excursion), Self.surroundRadius - 0.5) }

    private func drawWoofer(_ ctx: CGContext, _ paints: Paints) {
        let c = Self.woofer, rim = rim
        let out = CGFloat(min(max(excursion, 0), 1.6) / 1.6), back = CGFloat(min(max(-excursion, 0), 0.7) / 0.7)
        func disc(_ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }

        // The surround: a roll of rubber between the frame and the cone, lit along its upper left. Pushed out it
        // stretches flat and the light along it fades; pulled in it bunches up and catches more.
        let mid = (rim + Self.surroundRadius) / 2
        ctx.setLineCap(.round)
        ctx.setStroke(.white, Double(0.24 - 0.14 * out + 0.08 * back))
        ctx.setLineWidth(1.5 - 0.6 * out)
        ctx.addArc(center: c, radius: mid, startAngle: .pi * 0.95, endAngle: .pi * 1.65, clockwise: false)
        ctx.strokePath()
        ctx.setStroke(.black, 0.35)
        ctx.setLineWidth(1.2)
        ctx.addArc(center: c, radius: mid, startAngle: .pi * -0.05, endAngle: .pi * 0.65, clockwise: false)
        ctx.strokePath()

        // The cone: its colour, then its shading as a bowl lit from the upper left (its far wall catches the light),
        // brighter the further out it comes.
        ctx.setFill(paints.cone)
        ctx.fillEllipse(in: disc(rim))
        if let shade = paints.coneShade {
            ctx.saveGState()
            ctx.addEllipse(in: disc(rim))
            ctx.clip()
            ctx.setAlpha(Double(0.75 + 0.25 * out - 0.2 * back))
            ctx.drawLinearGradient(shade, start: CGPoint(x: c.x - rim * 0.75, y: c.y - rim * 0.75),
                                   end: CGPoint(x: c.x + rim * 0.75, y: c.y + rim * 0.75), options: [])
            ctx.restoreGState()
        }
        // Ribs pressed into the cone, and the shadow the rim casts inside it, which shrinks as the cone comes out.
        ctx.setStroke(.black, 0.16)
        ctx.setLineWidth(0.7)
        ctx.strokeEllipse(in: disc(rim * 0.72))
        ctx.strokeEllipse(in: disc(rim * 0.5))
        ctx.setStroke(.black, Double(0.42 - 0.25 * out + 0.15 * back))
        ctx.setLineWidth(1.6 + 1.2 * back - 0.7 * out)
        ctx.addArc(center: c, radius: rim - 1, startAngle: .pi * 0.9, endAngle: .pi * 1.75, clockwise: false)
        ctx.strokePath()
        ctx.setStroke(.white, Double(0.1 + 0.18 * out))
        ctx.setLineWidth(1)
        ctx.addArc(center: c, radius: rim - 0.8, startAngle: .pi * 0.05, endAngle: .pi * 0.6, clockwise: false)
        ctx.strokePath()

        // The dust cap: a dome in the middle, swelling most of all.
        let cap = Self.capRadius * CGFloat(1 + 0.22 * excursion)
        ctx.setFill(.black, 0.35)
        ctx.fillEllipse(in: disc(cap + 0.9))
        if let dome = paints.capShade {
            ctx.saveGState()
            ctx.addEllipse(in: disc(cap))
            ctx.clip()
            let hot = CGPoint(x: c.x - cap * 0.38, y: c.y - cap * 0.42)
            ctx.drawRadialGradient(dome, startCenter: hot, startRadius: 0, endCenter: c, endRadius: cap * 1.05,
                                   options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }
    }

    /// The dust: shadows on the cone under anything in the air, then the specks, a touch bigger the higher they are.
    private func drawDust(_ ctx: CGContext, _ paints: Paints) {
        let c = Self.woofer, rim = Double(rim)
        let shadows = CGMutablePath()
        let dots = [CGMutablePath(), CGMutablePath(), CGMutablePath()]
        for s in specks {
            let x = Double(c.x) + s.x * rim, y = Double(c.y) + s.y * rim
            let r = s.size * (1 + s.height / 45)
            if s.height > 0.6 {
                let w = s.size * max(0.5, 1 - s.height / 40)
                shadows.addEllipse(in: CGRect(x: x - w, y: y - w * 0.7, width: 2 * w, height: 1.4 * w))
            }
            dots[s.colour].addEllipse(in: CGRect(x: x - r, y: y - s.height - r, width: 2 * r, height: 2 * r))
        }
        if !shadows.isEmpty {
            ctx.addPath(shadows)
            ctx.setFill(.black, 0.3)
            ctx.fillPath()
        }
        for k in 0..<3 where !dots[k].isEmpty {
            ctx.addPath(dots[k])
            ctx.setFill(paints.specks[k])
            ctx.fillPath()
        }
    }

    /// The tweeter's dome, its flickering highlight and the ripples running off it, and the power light.
    private func drawTweeter(_ ctx: CGContext, _ paints: Paints) {
        let c = Self.tweeter, dome: CGFloat = 4.3
        if let gradient = paints.dome {
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: c.x - dome, y: c.y - dome, width: 2 * dome, height: 2 * dome))
            ctx.clip()
            ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: c.x - 1.5, y: c.y - 1.7), startRadius: 0,
                                   endCenter: c, endRadius: dome * 1.1, options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }
        // Ripples off the dome, as many as the treble keeps going.
        if treble > 0.03 {
            for k in 0..<2 {
                let t = (ripple + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                let r = 5 + CGFloat(t) * 3.6
                ctx.setStroke(paints.shimmer, min(0.7, treble * 1.3) * (1 - t) * (1 - t))
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }
        }
        // The highlight on the dome flickers with the hi-hats.
        let glint = 0.35 + 0.65 * sparkle
        let g = 0.9 + 0.7 * CGFloat(sparkle)
        ctx.setFill(paints.shimmer, glint)
        ctx.fillEllipse(in: CGRect(x: c.x - 1.6 - g / 2, y: c.y - 1.8 - g / 2, width: g, height: g))
        if sparkle > 0.45 {
            let arm = CGFloat(1.5 + 2.5 * (sparkle - 0.45))
            let p = CGPoint(x: c.x - 1.6, y: c.y - 1.8)
            ctx.setStroke(paints.shimmer, (sparkle - 0.45) * 1.6)
            ctx.setLineWidth(0.7)
            ctx.strokeLineSegments(between: [CGPoint(x: p.x - arm, y: p.y), CGPoint(x: p.x + arm, y: p.y),
                                             CGPoint(x: p.x, y: p.y - arm), CGPoint(x: p.x, y: p.y + arm)])
        }

        // The power light: on whenever the speaker is, brighter on a kick, softer in silence.
        let l = Self.light
        let on = 0.5 + 0.3 * power + 0.2 * pulse
        ctx.setFill(paints.lamp, on)
        ctx.fillEllipse(in: CGRect(x: l.x - 1.3, y: l.y - 1.3, width: 2.6, height: 2.6))
        ctx.setFill(.white, 0.5 * on)
        ctx.fillEllipse(in: CGRect(x: l.x - 0.8, y: l.y - 0.9, width: 0.9, height: 0.9))
    }

    // MARK: Colours and the still parts

    private func makePaints(_ style: SceneStyle, size: CGSize, scale: CGFloat, width: Int, height: Int) -> Paints {
        let coneColour: RGB = switch cone {
        case .paper: RGB(0.13, 0.13, 0.14)
        case .polypropylene: RGB(0.38, 0.39, 0.42)
        case .kevlar: RGB(0.8, 0.63, 0.2)
        case .aluminium: RGB(0.66, 0.68, 0.71)
        case .tinted: (style.isLight ? style.ink : style.spark(1)).adjusted(saturation: 1.1, brightness: 0.5)
        }
        let capColour = plainCap ? coneColour.scaled(0.92)
            : (coneColour.luminance > 0.2 ? RGB(0.12, 0.12, 0.13) : RGB(0.7, 0.71, 0.74))
        func gradient(_ colours: [(RGB, Double)], _ locations: [CGFloat]) -> CGGradient? {
            CGGradient(colorsSpace: sceneColorSpace, colors: colours.map { $0.0.cgColor(alpha: $0.1) } as CFArray,
                       locations: locations)
        }
        // A bowl lit from the upper left: its near (upper-left) wall in shadow, its far wall lit.
        let coneShade = gradient([(.black, 0.5), (.black, 0.12), (.white, 0), (.white, 0.2)], [0, 0.35, 0.55, 1])
        let capShade = gradient([(capColour.mixed(with: .white, 0.55), 1), (capColour, 1), (capColour.scaled(0.55), 1)],
                                [0, 0.45, 1])
        let domeColour = silkDome ? RGB(0.16, 0.16, 0.17) : RGB(0.72, 0.74, 0.78)
        let dome = gradient([(domeColour.mixed(with: .white, 0.5), 1), (domeColour, 1), (domeColour.scaled(0.5), 1)],
                            [0, 0.5, 1])
        // Dust that shows on the cone: light flecks in the artwork's colours on a dark cone, dark grit on a light one.
        let specks: [RGB] = coneColour.luminance > 0.25
            ? [RGB(0.2, 0.19, 0.18), (style.isLight ? style.ink : style.deep).scaled(0.7), RGB(0.36, 0.34, 0.32)]
            : [style.spark(0).mixed(with: .white, 0.35), style.spark(2).mixed(with: .white, 0.35), RGB(0.8, 0.78, 0.74)]
        let shimmer = style.isLight ? style.accent.mixed(with: .white, 0.6) : style.accent.mixed(with: .white, 0.5)
        let boldest = style.sparks.max { $0.hsb.saturation < $1.hsb.saturation } ?? style.accent
        let lamp = boldest.adjusted(saturation: 1.3)
        let body = Self.body(style: style, finish: finish, size: size, scale: scale, width: width, height: height)
        return Paints(style: style, width: width, height: height, body: body, cone: coneColour, capShade: capShade,
                      coneShade: coneShade, dome: dome, specks: specks, shimmer: shimmer, lamp: lamp)
    }

    /// The finish's colour, and whether it has a grain.
    private static func wood(_ finish: Finish, style: SceneStyle) -> (colour: RGB, grain: Bool, baffle: RGB) {
        let tint = style.isLight ? style.ink : style.deep
        switch finish {
        case .walnut: return (RGB(0.34, 0.21, 0.13).mixed(with: tint, 0.12), true, RGB(0.09, 0.09, 0.1))
        case .teak: return (RGB(0.62, 0.37, 0.17).mixed(with: tint, 0.08), true, RGB(0.1, 0.09, 0.09))
        case .blackAsh: return (RGB(0.12, 0.12, 0.13).mixed(with: tint, 0.25), true, RGB(0.07, 0.07, 0.08))
        case .lacquer:
            let base = style.isLight ? style.ink.scaled(0.75) : style.deep.mixed(with: style.mid, 0.3).scaled(0.9)
            return (base, false, base.scaled(0.45))
        }
    }

    /// The parts that never move: the cabinet and its shadow, the baffle, the woofer's frame and screws, the tweeter's
    /// plate and surround, the port and the light's bezel.
    private static func body(style: SceneStyle, finish: Finish, size: CGSize, scale: CGFloat, width: Int,
                             height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sceneColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        let u = size.width / 92
        ctx.scaleBy(x: u, y: u)
        let (colour, grain, baffleColour) = wood(finish, style: style)
        let box = cabinet
        func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
            CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        func disc(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }

        // A soft shadow under the cabinet.
        for k in 0..<4 {
            let spread = -2 + CGFloat(k) * 0.7
            ctx.addPath(rounded(box.offsetBy(dx: 1, dy: 2).insetBy(dx: spread, dy: spread), 9))
            ctx.setFill(.black, style.isLight ? 0.05 : 0.09)
            ctx.fillPath()
        }
        // The cabinet: its finish, a grain running down it, lit from the top.
        ctx.addPath(rounded(box, 7))
        ctx.setFill(colour)
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(rounded(box, 7))
        ctx.clip()
        if !grain {
            // Lacquer: a sharp reflection across its top corner.
            ctx.move(to: CGPoint(x: box.minX, y: box.minY + 22))
            ctx.addLine(to: CGPoint(x: box.minX + 22, y: box.minY))
            ctx.addLine(to: CGPoint(x: box.minX + 30, y: box.minY))
            ctx.addLine(to: CGPoint(x: box.minX, y: box.minY + 30))
            ctx.closePath()
            ctx.setFill(.white, 0.12)
            ctx.fillPath()
        } else {
            var random = SceneRandom(seed: 11)
            var x = box.minX + 0.6
            while x < box.maxX {
                let w = CGFloat(random.range(0.3, 0.9))
                ctx.setStroke(.black, random.range(0.08, 0.2))
                ctx.setLineWidth(w)
                let bend = CGFloat(random.range(-1.5, 1.5))
                ctx.move(to: CGPoint(x: x, y: box.minY))
                ctx.addCurve(to: CGPoint(x: x + bend * 0.4, y: box.maxY),
                             control1: CGPoint(x: x + bend, y: box.minY + box.height * 0.35),
                             control2: CGPoint(x: x - bend, y: box.minY + box.height * 0.7))
                ctx.strokePath()
                x += CGFloat(random.range(1.2, 2.6))
            }
        }
        if let light = CGGradient(colorsSpace: sceneColorSpace,
                                  colors: [RGB.white.cgColor(alpha: 0.16), RGB.white.cgColor(alpha: 0),
                                           RGB.black.cgColor(alpha: 0.2)] as CFArray, locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(light, start: CGPoint(x: box.minX, y: box.minY),
                                   end: CGPoint(x: box.maxX, y: box.maxY), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(rounded(box.insetBy(dx: 0.4, dy: 0.4), 6.6))
        ctx.setStroke(.white, 0.18)
        ctx.setLineWidth(0.8)
        ctx.strokePath()

        // The baffle, set into the cabinet: a dark edge along its top and left, a lit one along its bottom and right.
        let baffle = box.insetBy(dx: 3.6, dy: 3.6)
        ctx.addPath(rounded(baffle.insetBy(dx: -0.6, dy: -0.6), 5))
        ctx.setFill(.black, 0.45)
        ctx.fillPath()
        ctx.addPath(rounded(baffle, 4.5))
        ctx.setFill(baffleColour)
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(rounded(baffle, 4.5))
        ctx.clip()
        if let sheen = CGGradient(colorsSpace: sceneColorSpace,
                                  colors: [RGB.white.cgColor(alpha: 0.1), RGB.white.cgColor(alpha: 0)] as CFArray,
                                  locations: [0, 1]) {
            ctx.drawLinearGradient(sheen, start: CGPoint(x: baffle.minX, y: baffle.minY),
                                   end: CGPoint(x: baffle.midX, y: baffle.midY), options: [])
        }
        ctx.restoreGState()

        // The woofer's frame, with four screws, and the dark well the cone sits in.
        let w = woofer
        ctx.setFill(.black, 0.5)
        ctx.fillEllipse(in: disc(CGPoint(x: w.x + 0.4, y: w.y + 0.8), frameRadius + 0.6))
        ctx.setFill(RGB(0.2, 0.2, 0.22))
        ctx.fillEllipse(in: disc(w, frameRadius))
        ctx.setStroke(.white, 0.22)
        ctx.setLineWidth(0.8)
        ctx.addArc(center: w, radius: frameRadius - 0.5, startAngle: .pi * 0.9, endAngle: .pi * 1.7, clockwise: false)
        ctx.strokePath()
        for k in 0..<4 {
            let a = Double.pi / 4 + Double(k) * .pi / 2
            let p = CGPoint(x: w.x + (frameRadius - 1.35) * CGFloat(cos(a)),
                            y: w.y + (frameRadius - 1.35) * CGFloat(sin(a)))
            ctx.setFill(RGB(0.05, 0.05, 0.06))
            ctx.fillEllipse(in: disc(p, 1.05))
            ctx.setFill(RGB(0.75, 0.76, 0.8))
            ctx.fillEllipse(in: disc(CGPoint(x: p.x - 0.15, y: p.y - 0.15), 0.7))
        }
        ctx.setFill(RGB(0.04, 0.04, 0.05))
        ctx.fillEllipse(in: disc(w, surroundRadius + 0.5))
        ctx.setFill(RGB(0.1, 0.1, 0.11))
        ctx.fillEllipse(in: disc(w, surroundRadius))

        // The tweeter's plate and the dark ring round its dome.
        let t = tweeter
        ctx.setFill(.black, 0.5)
        ctx.fillEllipse(in: disc(CGPoint(x: t.x + 0.3, y: t.y + 0.6), 8.9))
        ctx.setFill(RGB(0.2, 0.2, 0.22))
        ctx.fillEllipse(in: disc(t, 8.5))
        ctx.setStroke(.white, 0.22)
        ctx.setLineWidth(0.7)
        ctx.addArc(center: t, radius: 8.1, startAngle: .pi * 0.9, endAngle: .pi * 1.7, clockwise: false)
        ctx.strokePath()
        ctx.setFill(RGB(0.06, 0.06, 0.07))
        ctx.fillEllipse(in: disc(t, 5.7))

        // The port: a flared mouth into the dark.
        let p = port
        ctx.setFill(RGB(0.24, 0.24, 0.26))
        ctx.fillEllipse(in: disc(p, 4.6))
        ctx.setStroke(.white, 0.2)
        ctx.setLineWidth(0.7)
        ctx.addArc(center: p, radius: 4.2, startAngle: .pi * 0.9, endAngle: .pi * 1.7, clockwise: false)
        ctx.strokePath()
        ctx.setFill(RGB(0.02, 0.02, 0.03))
        ctx.fillEllipse(in: disc(p, 3.3))

        // The light's bezel.
        ctx.setFill(RGB(0.03, 0.03, 0.04))
        ctx.fillEllipse(in: disc(light, 2.1))
        return ctx.makeImage()
    }
}
