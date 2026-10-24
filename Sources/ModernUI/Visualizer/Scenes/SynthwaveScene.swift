// SPDX-License-Identifier: GPL-3.0-or-later
// Synthwave: a retrowave sunset drive. A big striped sun sits on the horizon, the gaps across its lower half drifting
// slowly down; mountains line the horizon with the spectrum as their ridge (the bass at the edges, the treble low in
// the middle, mirrored), under a sky with a few stars; and a neon grid floor rolls towards the viewer in time, one
// line passing on every beat of the clock, so it keeps rolling through a breakdown. The sun swells and brightens on
// the kicks and the grid lines flash. Through a breakdown the floor rolls at half time, the colours soften and the sun
// glows. The drop flashes the sky and sends the grid surging forward. In silence the floor stops and the scene rests
// as a calm sunset. A seed shapes the mountains, places the stars and sets the sun's stripes. On light artwork it is
// drawn as a dusk print, in dark ink with no light of its own.

import CoreGraphics
import Foundation

nonisolated final class SynthwaveScene: VisualizerScene {
    /// A corner of the mountains' ridge on the left half (the right half mirrors it).
    private struct Ridge {
        enum Kind {
            /// Rises with its band.
            case peak
            /// Sits `share` of the way up the lower of its neighbours.
            case valley
            /// A knee on a flank: `share` of the way from the lower neighbour to the higher.
            case shoulder
        }

        var kind: Kind
        /// Points in from the left edge.
        var x: Double
        /// Where along the spectrum a peak listens (0 the lows, 1 the highs), and its height in points at full level.
        var band = 0.0
        var tall = 0.0
        var share = 0.0
    }

    private struct Star {
        var x: Double
        var y: Double
        var bright: Double
        var phase: Double
    }

    /// The colours for a style, worked out once.
    private struct Paints {
        var style: SceneStyle
        var sunTop: RGB
        var sunFoot: RGB
        /// The sun at rest, top to foot.
        var sun: CGGradient?
        /// The glow round the sun.
        var halo: RGB
        var neon: RGB
        var sky: CGGradient?
        var floor: CGGradient?
        var haze: CGGradient?
        var mountain: RGB
        var star: RGB
    }

    // The layout, in a 92-point square.
    private static let side: CGFloat = 92
    private static let horizon: CGFloat = 55
    private static let sunX: CGFloat = 46
    private static let sunY: CGFloat = 40
    private static let sunRadius: CGFloat = 20
    /// The floor's perspective: a line `d` lines away sits `depth / (d + near)` points below the horizon.
    private static let depth = 66.0
    private static let near = 1.5
    private static let farthest = 6
    /// The grid's long lines, fanning out from the middle of the horizon: their spacing along the foot.
    private static let fan: CGFloat = 15

    private var ridge: [Ridge] = []
    private var levels: [Double]
    private var stars: [Star] = []
    /// The sun's stripes: the gaps' spacing in points, and how far they have drifted down (in gaps).
    private let gapSpacing: CGFloat
    private var stripes: Double
    /// The floor's position in grid lines (its fraction is what shows).
    private var scroll: Double
    /// The drop's surge: 0...1 through it (1 when there is none).
    private var surge = 1.0
    private var flash = 0.0
    private var activity = 0.0
    private var pulse = 0.0
    private var soft = 0.0
    private var halfTime = 0.0
    private var treble = 0.0
    private var paints: Paints?
    /// The sky, the sun's resting glow and the floor, drawn for a style at a size in pixels.
    private var backdrop: (style: SceneStyle, pixels: Int, image: CGImage?)?
    private var rects: [CGRect] = []

    var glow: Double { 0 }

    init(seed: UInt64) {
        var random = SceneRandom(seed: seed)
        // The mountains: peaks and valleys from the edge in to the middle, the peaks listening from the bass at the
        // edge to the highs near the middle, tallest at the edge.
        let peaks = 3 + random.int(2)
        let step = 40.0 / Double(peaks)
        var x = -3.0
        for k in 0..<peaks {
            let f = Double(k) / Double(peaks - 1)
            let peakX = x + step * random.range(0.4, 0.6)
            // Now and then a knee on one flank, so the range isn't a row of plain triangles.
            let knee = random.next()
            if knee < 0.3, k > 0 {
                let kneeX = peakX - step * random.range(0.2, 0.3)
                ridge.append(Ridge(kind: .shoulder, x: kneeX, share: random.range(0.55, 0.75)))
            }
            let tall = (18 - 10 * f) * random.range(0.8, 1.15)
            ridge.append(Ridge(kind: .peak, x: peakX, band: 0.03 + 0.75 * f, tall: tall))
            if knee > 0.7 {
                let kneeX = peakX + step * random.range(0.2, 0.3)
                ridge.append(Ridge(kind: .shoulder, x: kneeX, share: random.range(0.55, 0.75)))
            }
            x += step
            ridge.append(Ridge(kind: .valley, x: x + random.range(-1, 1), share: random.range(0.35, 0.6)))
        }
        levels = [Double](repeating: 0, count: ridge.count)
        // A few stars, clear of the sun and the window's buttons at the top left.
        var tries = 0
        while stars.count < 11, tries < 200 {
            tries += 1
            let sx = random.range(5, 87), sy = random.range(5, 40)
            if sx < 30, sy < 17 { continue }
            let dx = sx - Double(Self.sunX), dy = sy - Double(Self.sunY)
            if (dx * dx + dy * dy).squareRoot() < Double(Self.sunRadius) + 5 { continue }
            stars.append(Star(x: sx, y: sy, bright: random.range(0.35, 0.8), phase: random.range(0, 2 * .pi)))
        }
        gapSpacing = CGFloat(random.range(3.6, 4.6))
        stripes = random.next()
        scroll = random.next()
    }

    // MARK: Update

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let level = Double(input.level)
        let target = smoothstep(0.03, 0.1, level)
        activity += (target - activity) * (1 - exp(-dt / (target > activity ? 0.1 : 0.05)))
        pulse = Double(input.pulse) * activity
        // Everything settles quickly when the music stops, so a pause shows a still scene.
        let settle = target < 0.5
        soft += (Double(input.breakdown) - soft) * (1 - exp(-dt / (settle ? 0.08 : 0.4)))
        halfTime += ((input.breakdown > 0.5 ? 1 : 0) - halfTime) * (1 - exp(-dt / 0.35))
        treble += (Double(input.treble) - treble) * (1 - exp(-dt / 0.1))
        flash *= exp(-dt * (settle ? 12 : 4))

        // The mountains follow their bands: up quickly, down more gently, and down to rest within a moment of silence.
        let rise = 1 - exp(-dt / 0.05), fall = 1 - exp(-dt / (settle ? 0.06 : 0.35))
        for i in ridge.indices where ridge[i].kind == .peak {
            let v = Double(input.band(at: ridge[i].band)) * activity * (1 - 0.35 * soft)
            levels[i] += (v - levels[i]) * (v > levels[i] ? rise : fall)
        }

        // The floor rolls one line a beat (one every two through a breakdown), held in step with the beat clock: a
        // line passes under the viewer on each downbeat.
        let beat = min(max(input.beatInterval, 0.3), 1)
        let rate = (1 - 0.5 * halfTime) / beat
        var aim = input.groove
        if halfTime > 0.5 {
            // Half time: either half of the two-beat cycle, whichever the floor is nearer.
            aim = input.groove / 2
            if abs(wrapped(aim + 0.5 - scroll)) < abs(wrapped(aim - scroll)) { aim += 0.5 }
        }
        scroll += dt * activity * (rate + 2.5 * wrapped(aim - scroll))
        scroll -= scroll.rounded(.down)
        stripes += dt * activity * 0.3 / beat
        stripes -= stripes.rounded(.down)

        if input.drop, activity > 0.5 {
            surge = 0
            flash = 1
        }
        // The surge runs with the floor (and stops with it).
        surge = min(1, surge + dt * activity / 0.9)
        for i in stars.indices { stars[i].phase += dt * activity * (1 + 6 * treble) }
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        if paints == nil || paints?.style != style { paints = Self.paints(style) }
        guard let paints, size.width > 0, size.height > 0 else { return }
        let light = style.isLight
        ctx.saveGState()
        ctx.scaleBy(x: size.width / Self.side, y: size.height / Self.side)
        let H = Self.horizon, W = Self.side

        // The sky, the sun's resting glow and the floor don't move: drawn once for the style and size.
        let scale = abs(ctx.userSpaceToDeviceSpaceTransform.a)
        let pixels = Int((Self.side * scale).rounded())
        if backdrop?.style.isClose(to: style) != true || backdrop?.pixels != pixels {
            backdrop = (style, pixels, Self.backdrop(paints, pixels: pixels))
        }
        if let image = backdrop?.image {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: W)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: W))
            ctx.restoreGState()
        }

        // Stars, twinkling with the treble (still in silence).
        for band in 0..<2 {
            rects.removeAll(keepingCapacity: true)
            for star in stars {
                let b = star.bright * (0.7 + 0.3 * sin(star.phase))
                guard (b > 0.5 ? 1 : 0) == band else { continue }
                let s: CGFloat = band == 1 ? 1.4 : 1
                rects.append(CGRect(x: CGFloat(star.x) - s / 2, y: CGFloat(star.y) - s / 2, width: s, height: s))
            }
            ctx.setFill(paints.star, (band == 1 ? 0.85 : 0.5) * (1 - 0.6 * soft) * (light ? 0.7 : 1))
            ctx.fill(rects)
        }

        // The sun swells a little on a kick; it glows wider through a breakdown and at the drop.
        let r = Self.sunRadius + CGFloat(1.2 * pulse)
        let sun = CGPoint(x: Self.sunX, y: Self.sunY)
        let extra = 0.3 * soft + 0.2 * flash
        if !light, extra > 0.03 {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: H))
            ctx.fillGlow(at: sun, radius: r * CGFloat(1.6 + 0.3 * soft), color: paints.halo, alpha: extra)
            ctx.restoreGState()
        }
        drawSun(ctx, paints: paints, centre: sun, radius: r, light: light)

        // The mountains, their ridge the spectrum.
        drawMountains(ctx, paints: paints, light: light)

        // The grid on the floor, and a haze along the horizon that swallows its far end, where its lines would crowd
        // into a smudge.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: H, width: W, height: W - H))
        drawGrid(ctx, paints: paints, light: light)
        if let haze = paints.haze {
            ctx.clip(to: CGRect(x: 0, y: H, width: W, height: 9))
            ctx.drawLinearGradient(haze, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: H + 9), options: [])
        }
        ctx.restoreGState()

        // The horizon itself, lit by the sun.
        let edge = light ? style.ink : paints.sunFoot.mixed(with: .white, 0.35 + 0.3 * pulse)
        ctx.setFill(edge, light ? 0.55 : 0.75 + 0.25 * pulse)
        ctx.fill(CGRect(x: 0, y: H - 0.5, width: W, height: 1))

        // The drop: a flash of light from the sun across the whole scene (on light artwork, a wash of the accent).
        if flash > 0.01 {
            if light {
                ctx.setFill(style.accent, flash * 0.3)
                ctx.fill(CGRect(x: 0, y: 0, width: W, height: W))
            } else {
                ctx.saveGState()
                ctx.setBlendMode(.plusLighter)
                ctx.setFill(paints.sunTop, flash * 0.25)
                ctx.fill(CGRect(x: 0, y: 0, width: W, height: W))
                ctx.fillGlow(at: sun, radius: 70, color: paints.sunTop.mixed(with: .white, 0.4), alpha: flash * 0.7)
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()
    }

    /// The sun: a disc shading from top to foot, cut across its lower half by gaps that widen as they drift down.
    private func drawSun(_ ctx: CGContext, paints: Paints, centre: CGPoint, radius r: CGFloat, light: Bool) {
        let H = Self.horizon
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: Self.side, height: H))
        // The disc with each gap a hole (even-odd). A gap's ends sit on the rim, so it cuts the disc cleanly.
        let disc = CGMutablePath()
        disc.addEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
        func chord(_ y: CGFloat) -> CGFloat {
            let dy = y - centre.y
            return max(0, r * r - dy * dy).squareRoot()
        }
        let start = centre.y - 2
        let span = H - start
        var k = -1.0
        while true {
            let y = start + CGFloat(k + stripes) * gapSpacing
            if y > H + 2 { break }
            k += 1
            let t = max(0, (y - start) / span)
            let thick = 0.3 + 2.9 * t * t.squareRoot()
            guard y >= start - 1 else { continue }
            let top = y - thick / 2, bottom = min(y + thick / 2, centre.y + r)
            let a = chord(top) - 0.01, b = chord(bottom) - 0.01
            guard a > 0, b > 0 else { continue }
            disc.move(to: CGPoint(x: centre.x - a, y: top))
            disc.addLine(to: CGPoint(x: centre.x + a, y: top))
            disc.addLine(to: CGPoint(x: centre.x + b, y: bottom))
            disc.addLine(to: CGPoint(x: centre.x - b, y: bottom))
            disc.closeSubpath()
        }
        ctx.addPath(disc)
        ctx.clip(using: .evenOdd)
        // Brightened on a kick, through a breakdown and at the drop (a gradient made for the frame).
        let lift = light ? 0 : 0.3 * pulse + 0.2 * soft + 0.3 * flash
        let shading = lift < 0.01 ? paints.sun : Self.sunGradient(paints.sunTop.mixed(with: .white, lift),
                                                                  paints.sunFoot.mixed(with: .white, lift * 0.6))
        if let shading {
            let top = CGPoint(x: 0, y: centre.y - r)
            ctx.drawLinearGradient(shading, start: top, end: CGPoint(x: 0, y: H), options: [])
        }
        ctx.restoreGState()
    }

    /// The mountains: a dark range along the horizon, its ridge traced in neon.
    private func drawMountains(_ ctx: CGContext, paints: Paints, light: Bool) {
        let H = Double(Self.horizon), W = Double(Self.side)
        var heights = [Double](repeating: 0, count: ridge.count)
        for i in ridge.indices where ridge[i].kind == .peak {
            heights[i] = ridge[i].tall * (0.4 + 0.6 * min(1, levels[i] * 1.15))
        }
        // Valleys between the peaks (the last, in the middle, low enough to show the sun), then the knees.
        func peakNear(_ i: Int, _ way: Int) -> Double {
            var j = i + way
            while j >= 0, j < ridge.count, ridge[j].kind != .peak { j += way }
            return j >= 0 && j < ridge.count ? heights[j] : 2
        }
        for i in ridge.indices where ridge[i].kind == .valley {
            heights[i] = min(peakNear(i, -1), peakNear(i, 1)) * ridge[i].share
        }
        for i in ridge.indices where ridge[i].kind == .shoulder {
            let a = heights[max(i - 1, 0)], b = heights[min(i + 1, ridge.count - 1)]
            heights[i] = min(a, b) + abs(a - b) * ridge[i].share
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -2, y: H + 1))
        for i in ridge.indices { path.addLine(to: CGPoint(x: ridge[i].x, y: H - heights[i])) }
        for i in ridge.indices.reversed() { path.addLine(to: CGPoint(x: W - ridge[i].x, y: H - heights[i])) }
        path.addLine(to: CGPoint(x: W + 2, y: H + 1))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFill(paints.mountain, light ? 0.8 : 0.96)
        ctx.fillPath()

        // The ridge line (not along the foot).
        let ridgeLine = CGMutablePath()
        ridgeLine.move(to: CGPoint(x: -2, y: H - heights[0] * 0.8))
        for i in ridge.indices { ridgeLine.addLine(to: CGPoint(x: ridge[i].x, y: H - heights[i])) }
        for i in ridge.indices.reversed() { ridgeLine.addLine(to: CGPoint(x: W - ridge[i].x, y: H - heights[i])) }
        ridgeLine.addLine(to: CGPoint(x: W + 2, y: H - heights[0] * 0.8))
        ctx.saveGState()
        ctx.setLineJoin(.miter)
        ctx.addPath(ridgeLine)
        if !light {
            ctx.setStroke(paints.neon, 0.22 + 0.15 * pulse)
            ctx.setLineWidth(2.6)
            ctx.strokePath()
            ctx.addPath(ridgeLine)
        }
        ctx.setStroke(light ? paints.neon : paints.neon.mixed(with: .white, 0.25 + 0.3 * pulse), light ? 0.9 : 0.95)
        ctx.setLineWidth(1.1)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The grid floor: long lines fanning out from the middle of the horizon, and cross lines rolling towards the
    /// viewer, bolder as they come close and flashing on the kicks. Each set in one fill, with a wider, fainter fill
    /// behind it for the neon's glow (dark artwork only).
    private func drawGrid(_ ctx: CGContext, paints: Paints, light: Bool) {
        let H = Self.horizon, W = Self.side
        let foot = W - H
        let base = (light ? 0.75 : 0.8) * (1 - 0.3 * soft)
        let bright = min(1, base + 0.35 * pulse + 0.4 * flash)
        let colour = light ? paints.neon : paints.neon.mixed(with: .white, 0.15 + 0.35 * pulse + 0.3 * flash)

        // The long lines: thin wedges, narrow at the horizon and wider at the foot. Each passes through its place along
        // the foot, drawn on to twice the floor's depth (past the edges).
        func fans(_ width: CGFloat) -> CGMutablePath {
            let path = CGMutablePath()
            let reach: CGFloat = 2
            for i in -6...6 {
                let top = Self.sunX + CGFloat(i) * 0.4
                let x = top + (Self.sunX + CGFloat(i) * Self.fan - top) * reach
                let half = width * reach
                path.move(to: CGPoint(x: top - 0.2 * width, y: H))
                path.addLine(to: CGPoint(x: top + 0.2 * width, y: H))
                path.addLine(to: CGPoint(x: x + half, y: H + foot * reach))
                path.addLine(to: CGPoint(x: x - half, y: H + foot * reach))
                path.closeSubpath()
            }
            return path
        }
        // The cross lines, rolling in: a line `d` lines away, `d` falling as the floor rolls; thicker up close.
        let shift = scroll + 2 * surgeEase
        let frac = shift - shift.rounded(.down)
        func crossings(_ spread: CGFloat) -> [CGRect] {
            rects.removeAll(keepingCapacity: true)
            for j in 0...Self.farthest {
                let d = Double(j) + 1 - frac
                let y = H + CGFloat(Self.depth / (d + Self.near))
                guard y < W + 3 else { continue }
                // The farthest grows in from nothing as it comes over the horizon's haze.
                let grow = CGFloat(j == Self.farthest ? frac : 1)
                let thick = (0.55 + 1.3 * (y - H) / foot) * grow + spread
                rects.append(CGRect(x: 0, y: y - thick / 2, width: W, height: thick))
            }
            return rects
        }
        if !light {
            ctx.setFill(colour, 0.22 * bright)
            ctx.addPath(fans(1.6))
            ctx.fillPath()
            ctx.fill(crossings(1.6))
        }
        ctx.setFill(colour, bright)
        ctx.addPath(fans(0.75))
        ctx.fillPath()
        ctx.fill(crossings(0))
    }

    /// The drop's surge, eased: 0 to 1 over its run (and 0 again after, which shows the same).
    private var surgeEase: Double {
        guard surge < 1 else { return 0 }
        return 1 - pow(1 - surge, 3)
    }

    // MARK: Colours

    private static func paints(_ style: SceneStyle) -> Paints {
        func warmth(_ c: RGB) -> Double { c.r - c.b + (c.g - c.b) * 0.3 }
        // The sun's foot: a neighbouring hue to its top (gold to rose, peach to violet), not the opposite one.
        func footScore(_ c: RGB, _ top: RGB) -> Double {
            let d = abs(c.hsb.hue - top.hsb.hue), turn = min(d, 1 - d)
            return min(turn, 0.18) * min(c.hsb.saturation, top.hsb.saturation) - (turn > 0.3 ? 1 : 0)
        }
        let sparks = style.sparks
        let warmest = sparks.max { warmth($0) < warmth($1) } ?? style.accent
        let other = sparks.max { footScore($0, warmest) < footScore($1, warmest) } ?? style.accent
        if style.isLight {
            // A dusk print: the sun in the accent deepening to the ink, ink mountains and grid on a pale ground.
            let ink = style.ink
            let sky = CGGradient(colorsSpace: sceneColorSpace,
                                 colors: [style.accent.cgColor(alpha: 0), style.accent.cgColor(alpha: 0.16)] as CFArray,
                                 locations: [0.3, 1])
            let floor = CGGradient(colorsSpace: sceneColorSpace,
                                   colors: [style.accent.cgColor(alpha: 0.22),
                                            style.accent.cgColor(alpha: 0.1)] as CFArray,
                                   locations: [0, 1])
            let mist = style.accent.mixed(with: .white, 0.75)
            let haze = CGGradient(colorsSpace: sceneColorSpace,
                                  colors: [mist.cgColor(alpha: 0.9), mist.cgColor(alpha: 0)] as CFArray,
                                  locations: [0, 1])
            let sunTop = style.accent.mixed(with: .white, 0.15)
            return Paints(style: style, sunTop: sunTop, sunFoot: ink, sun: sunGradient(sunTop, ink), halo: ink,
                          neon: ink,
                          sky: sky, floor: floor, haze: haze, mountain: ink.mixed(with: style.accent, 0.25), star: ink)
        }
        let sunTop = warmest.mixed(with: .white, 0.25)
        let sunFoot = (footScore(other, warmest) > 0.005 ? other : style.accent).adjusted(saturation: 1.5)
        let neon = style.accent.adjusted(saturation: 1.6)
        let night = style.deep.scaled(0.45)
        let sky = CGGradient(colorsSpace: sceneColorSpace,
                             colors: [night.cgColor(alpha: 0.75), style.deep.cgColor(alpha: 0.45),
                                      sunFoot.scaled(0.55).cgColor(alpha: 0.5)] as CFArray,
                             locations: [0, 0.6, 1])
        let ground = style.deep.scaled(0.25)
        let floor = CGGradient(colorsSpace: sceneColorSpace,
                               colors: [sunFoot.scaled(0.3).cgColor(alpha: 0.95),
                                        ground.cgColor(alpha: 0.95)] as CFArray,
                               locations: [0, 0.6])
        let mist = sunFoot.scaled(0.35)
        let haze = CGGradient(colorsSpace: sceneColorSpace,
                              colors: [mist.cgColor(alpha: 1), mist.cgColor(alpha: 0)] as CFArray, locations: [0, 1])
        return Paints(style: style, sunTop: sunTop, sunFoot: sunFoot, sun: sunGradient(sunTop, sunFoot),
                      halo: sunFoot.mixed(with: sunTop, 0.3), neon: neon, sky: sky, floor: floor, haze: haze,
                      mountain: style.deep.scaled(0.3), star: style.ink)
    }

    /// The sun's shading: its top colour over the first part, then down to its foot's.
    private static func sunGradient(_ top: RGB, _ foot: RGB) -> CGGradient? {
        CGGradient(colorsSpace: sceneColorSpace, colors: [top.cgColor, top.cgColor, foot.cgColor] as CFArray,
                   locations: [0, 0.15, 0.9])
    }

    /// The parts that don't move, as an image `pixels` across: the sky (over the horizon), the sun's resting glow
    /// (dark artwork only) and the floor.
    private static func backdrop(_ paints: Paints, pixels: Int) -> CGImage? {
        guard pixels > 0, pixels <= 4096,
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sceneColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let k = CGFloat(pixels) / side
        // Points, top-left origin.
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: k, y: -k)
        let H = horizon, W = side
        if let sky = paints.sky {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: H))
            ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: H), options: [])
            ctx.restoreGState()
        }
        if !paints.style.isLight {
            ctx.fillGlow(at: CGPoint(x: sunX, y: sunY), radius: sunRadius * 1.75, color: paints.halo, alpha: 0.22)
        }
        if let floor = paints.floor {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: H, width: W, height: W - H))
            ctx.drawLinearGradient(floor, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: W), options: [])
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}

/// `x` wrapped into -0.5..<0.5 (the shorter way round a cycle).
nonisolated private func wrapped(_ x: Double) -> Double { x - (x + 0.5).rounded(.down) }

/// 0 below `lo`, 1 above `hi`, smooth between.
nonisolated private func smoothstep(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
    let t = min(max((x - lo) / (hi - lo), 0), 1)
    return t * t * (3 - 2 * t)
}
