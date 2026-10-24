// SPDX-License-Identifier: GPL-3.0-or-later
// Skyline: a city at night by the water. Seven to ten buildings stand along the foot of the artwork in front of a
// paler, farther row, each listening to its own slice of the spectrum (the lows on the left, the highs on the right):
// its windows light floor by floor from the bottom up as its band rises, hold a moment and go out, and a few flicker
// with the treble. A red aircraft light on the tallest tower blinks on the beat, the lit windows shimmer in the water
// below, and a moon and a few stars hang over it all. Through a breakdown most of the windows go dark and the city hums
// quietly; the drop lights every window at once and sends searchlights sweeping across the sky for a few bars. In
// silence the lights go out but for a handful of late windows, leaving a calm late-night city. A seed builds the
// skyline: the buildings' heights and widths, their windows, their roofs (setbacks, spires, water towers, aerials),
// and whether the moon is full or a crescent. On light artwork the city is a pale print with dark windows.

import CoreGraphics
import Foundation

nonisolated final class SkylineScene: VisualizerScene {
    private struct Building {
        var x: CGFloat
        var width: CGFloat
        /// The roof's height (y, points from the top).
        var top: CGFloat
        /// Where along the spectrum it listens (0 the lows, 1 the highs), and how many floors of windows it has.
        var band: Double
        var floors: Int
        /// Its windows in `windows`.
        var windows: Range<Int>
    }

    private struct Window {
        var rect: CGRect
        var building: Int
        var floor: Int
        /// An empty office: dark unless the drop lights everything.
        var empty: Bool
        /// Someone up late: lit even in silence.
        var late: Bool
        /// A television: flickers with the treble.
        var flickers: Bool
        /// -1 for warm lamplight, otherwise a spark colour.
        var tint: Int
        /// How long it stays lit once its band falls away, as a share of the usual.
        var linger: Double
    }

    private struct Star {
        var x: CGFloat
        var y: CGFloat
        var bright: Double
        var phase: Double
    }

    /// The colours for a style, worked out once.
    private struct Paints {
        var style: SceneStyle
        var front: RGB
        var back: RGB
        var lamp: RGB
        var tints: [RGB]
        var moon: RGB
        var water: RGB
        var beam: CGGradient?
        var haze: CGGradient?
    }

    private typealias Layer = (image: CGImage?, rect: CGRect)

    private static let side: CGFloat = 92
    /// The street, where the buildings meet the water.
    private static let ground: CGFloat = 74
    /// Seconds a window stays lit after its band falls below it, and how fast it then goes out.
    private static let hold = 0.24
    private static let fade = 7.0
    /// The searchlights' run after a drop, in seconds.
    private static let sweep = 7.0

    private var buildings: [Building] = []
    private var windows: [Window] = []
    private var stars: [Star] = []
    /// Each window's light, 0...1, and how long it holds before going out.
    private var lit: [Double] = []
    private var holding: [Double] = []
    /// How many floors each building's band reaches this frame.
    private var reach: [Double] = []
    /// A television's brightness this frame.
    private var flicker: [Double] = []
    /// The city's outlines, made once: the far row, the near row (with its roofs), and the aerial's tip.
    private var farRow = CGMutablePath()
    private var nearRow = CGMutablePath()
    private var beacon = CGPoint.zero
    private var moon = (centre: CGPoint.zero, radius: CGFloat(6), crescent: true)
    private var random: SceneRandom
    private var activity = 0.0
    private var treble = 0.0
    private var bass = 0.0
    private var blink = 0.0
    private var soft = 0.0
    /// Seconds left of the searchlights, and where their sweep is (in beats).
    private var searching = 0.0
    private var sweepPhase = 0.0
    private var ripple = 0.0
    private var lastGroove = 0.0
    private var paints: Paints?
    /// The parts that don't change, drawn once for a style and scale (pixels a point): the moon, the streets' glow and
    /// the city's outline, each with the rect it covers.
    private var layers: (style: SceneStyle, scale: CGFloat, moon: Layer, haze: Layer, city: Layer)?
    private var rects: [CGRect] = []

    var glow: Double { 0 }

    init(seed: UInt64) {
        random = SceneRandom(seed: seed)
        buildFarRow()
        buildNearRow()
        // The moon, on the other side of the tallest tower from its mast (and clear of the window's buttons).
        let mast = beacon.x
        let moonX = mast < 53 ? random.range(mast + 17, min(mast + 30, 80))
                              : random.range(max(mast - 30, 36), mast - 17)
        moon = (CGPoint(x: moonX, y: random.range(15, 22)), random.range(5.5, 7), random.chance(0.6))
        lit = [Double](repeating: 0, count: windows.count)
        holding = [Double](repeating: 0, count: windows.count)
        flicker = [Double](repeating: 1, count: windows.count)
        reach = [Double](repeating: 0, count: buildings.count)
        for i in windows.indices where windows[i].late { lit[i] = 1 }
        // A few stars, clear of the moon, the towers and the window's buttons at the top left.
        var tries = 0
        while stars.count < 12, tries < 200 {
            tries += 1
            let x = CGFloat(random.range(4, 88)), y = CGFloat(random.range(4, 30))
            if x < 30, y < 17 { continue }
            if hypot(x - moon.centre.x, y - moon.centre.y) < moon.radius + 4 { continue }
            if buildings.contains(where: { x >= $0.x - 1 && x <= $0.x + $0.width + 1 && y > $0.top - 12 }) { continue }
            stars.append(Star(x: x.rounded(), y: y.rounded(), bright: random.range(0.35, 0.85),
                              phase: random.range(0, 2 * .pi)))
        }
    }

    /// The far row: plain towers, paler, standing up between the near ones.
    private func buildFarRow() {
        var x = CGFloat(-2)
        while x < Self.side + 2 {
            let width = CGFloat(random.range(6, 13)).rounded()
            let height = CGFloat(random.range(22, 44)).rounded()
            farRow.addRect(CGRect(x: x, y: Self.ground - height, width: width, height: height))
            if random.chance(0.3) {
                // A little aerial.
                farRow.addRect(CGRect(x: (x + width / 2).rounded(), y: Self.ground - height - 4, width: 1, height: 4))
            }
            x += width + CGFloat(random.int(3))
        }
    }

    /// The near row: the buildings that listen, with their windows and roofs.
    private func buildNearRow() {
        let count = 7 + random.int(4)
        var shares = (0..<count).map { _ in random.range(0.7, 1.35) }
        let total = shares.reduce(0, +)
        for i in shares.indices { shares[i] /= total }
        let gaps = (0..<count).map { _ in CGFloat(random.int(3)) }
        let room = Self.side + 4 - gaps.reduce(0, +)
        // Heights, with the tallest kept clear of the window's buttons at the top left.
        var heights = (0..<count).map { _ in random.range(16, 40) }
        var x = CGFloat(-2)
        var spans: [(x: CGFloat, width: CGFloat)] = []
        for i in 0..<count {
            let width = max(7, (room * CGFloat(shares[i])).rounded())
            spans.append((x, width))
            x += width + gaps[i]
        }
        let candidates = (0..<count).filter {
            (36...70).contains(spans[$0].x + spans[$0].width / 2) && spans[$0].width >= 9
        }
        let tallest = candidates.isEmpty ? count - 1 : candidates[random.int(candidates.count)]
        heights[tallest] = random.range(41, 46)
        for i in 0..<count where i != tallest { heights[i] = min(heights[i], heights[tallest] - 6) }

        // Window patterns: size and spacing, in whole points so they stay crisp at 1x.
        let patterns: [(w: CGFloat, h: CGFloat, across: CGFloat, up: CGFloat)] = [
            (2, 2, 4, 4), (2, 2, 3, 4), (1, 2, 3, 3), (3, 2, 5, 4), (2, 3, 4, 5),
        ]
        for i in 0..<count {
            let (bx, width) = spans[i]
            let top = (Self.ground - CGFloat(heights[i])).rounded()
            let p = patterns[random.int(patterns.count)]
            let columns = max(1, Int((width - 3 + (p.across - p.w)) / p.across))
            let used = CGFloat(columns) * p.across - (p.across - p.w)
            let left = (bx + (width - used) / 2).rounded(.down)
            let first = windows.count
            var floor = 0
            var y = Self.ground - 3 - p.h
            while y >= top + 3 {
                for c in 0..<columns {
                    let rect = CGRect(x: left + CGFloat(c) * p.across, y: y, width: p.w, height: p.h)
                    windows.append(Window(rect: rect, building: buildings.count, floor: floor,
                                          empty: random.chance(0.22), late: false, flickers: random.chance(0.06),
                                          tint: random.chance(0.18) ? random.int(4) : -1,
                                          linger: random.range(0.6, 1.6)))
                }
                floor += 1
                y -= p.up
            }
            let band = 0.03 + 0.8 * (Double(i) + 0.5) / Double(count)
            buildings.append(Building(x: bx, width: width, top: top, band: band, floors: floor,
                                      windows: first..<windows.count))
            nearRow.addRect(CGRect(x: bx, y: top, width: width, height: Self.ground - top + 0.5))
            addRoof(i == tallest, x: bx, width: width, top: top)
        }
        // A handful of flats with someone up late, spread across the city: a window or two side by side, in the
        // lower two thirds of a building, where they read best.
        let late = 5 + random.int(3)
        var placed = 0, tries = 0
        while placed < late, tries < 200, !windows.isEmpty {
            tries += 1
            let i = random.int(windows.count)
            let w = windows[i]
            guard !w.late, !w.empty, w.rect.width >= 2,
                  Double(w.floor) < Double(buildings[w.building].floors) * 0.7 else { continue }
            windows[i].late = true
            if random.chance(0.5), i + 1 < windows.count, windows[i + 1].floor == w.floor,
               windows[i + 1].building == w.building {
                windows[i + 1].late = true
                windows[i + 1].empty = false
            }
            placed += 1
        }
    }

    /// A roof: flat, stepped back, a spire or a slope, perhaps with a water tower or an aerial; the tallest tower
    /// carries the aircraft light on a mast.
    private func addRoof(_ tallest: Bool, x: CGFloat, width: CGFloat, top: CGFloat) {
        let mid = (x + width / 2).rounded()
        var peak = top
        let kind = tallest ? (random.chance(0.5) ? 1 : 2) : random.int(6)
        switch kind {
        case 1 where width >= 9:
            // Stepped back, twice.
            let a = (width * 0.62).rounded(), b = (width * 0.3).rounded()
            nearRow.addRect(CGRect(x: mid - (a / 2).rounded(), y: top - 4, width: a, height: 4.5))
            nearRow.addRect(CGRect(x: mid - (b / 2).rounded(), y: top - 7, width: b, height: 3.5))
            peak = top - 7
        case 2 where width >= 8:
            // A spire.
            nearRow.move(to: CGPoint(x: mid - (width * 0.32).rounded(), y: top + 0.5))
            nearRow.addLine(to: CGPoint(x: mid, y: top - 9))
            nearRow.addLine(to: CGPoint(x: mid + (width * 0.32).rounded(), y: top + 0.5))
            nearRow.closeSubpath()
            peak = top - 9
        case 3 where width >= 8:
            // A water tower on legs.
            let tx = x + (width * random.range(0.2, 0.5)).rounded()
            nearRow.addRect(CGRect(x: tx, y: top - 6, width: 4, height: 3))
            nearRow.move(to: CGPoint(x: tx - 0.5, y: top - 6))
            nearRow.addLine(to: CGPoint(x: tx + 2, y: top - 8))
            nearRow.addLine(to: CGPoint(x: tx + 4.5, y: top - 6))
            nearRow.closeSubpath()
            nearRow.addRect(CGRect(x: tx, y: top - 3, width: 1, height: 3.5))
            nearRow.addRect(CGRect(x: tx + 3, y: top - 3, width: 1, height: 3.5))
        case 4:
            // A slope.
            let rise = CGFloat(random.range(3, 5)).rounded()
            let leftUp = random.chance(0.5)
            nearRow.move(to: CGPoint(x: x, y: top + 0.5))
            nearRow.addLine(to: CGPoint(x: x, y: leftUp ? top - rise : top))
            nearRow.addLine(to: CGPoint(x: x + width, y: leftUp ? top : top - rise))
            nearRow.addLine(to: CGPoint(x: x + width, y: top + 0.5))
            nearRow.closeSubpath()
        case 5:
            // A small plant room and an aerial.
            let w = (width * 0.4).rounded()
            nearRow.addRect(CGRect(x: x + 2, y: top - 2, width: w, height: 2.5))
            nearRow.addRect(CGRect(x: x + 2 + (w / 2).rounded(), y: top - 7, width: 1, height: 5))
        default:
            break
        }
        if tallest {
            // The mast with the aircraft light.
            nearRow.addRect(CGRect(x: mid, y: peak - 6, width: 1, height: 6.5))
            beacon = CGPoint(x: mid + 0.5, y: peak - 6)
        }
    }

    // MARK: Update

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let target = smoothstep(0.02, 0.1, Double(input.level))
        activity += (target - activity) * (1 - exp(-dt / (target > activity ? 0.1 : 0.07)))
        treble += (Double(input.treble) - treble) * (1 - exp(-dt / 0.08))
        bass += (Double(input.bass) * activity - bass) * (1 - exp(-dt / 0.15))
        soft += (Double(input.breakdown) - soft) * (1 - exp(-dt / (target < 0.5 ? 0.08 : 0.5)))
        // The aircraft light blinks on each beat of the clock (and on each kick); at rest it glows dimly.
        let downbeat = input.groove < lastGroove - 0.5
        lastGroove = input.groove
        if activity > 0.5, downbeat || input.beat { blink = 1 }
        blink *= exp(-dt * 6)

        if input.drop, activity > 0.5 {
            // Every window on at once, going out again one by one.
            for i in windows.indices {
                lit[i] = 1
                holding[i] = 0.5 + 1.1 * windows[i].linger / 1.6
            }
            searching = Self.sweep
        }
        searching = max(0, searching - dt)
        sweepPhase += dt / min(max(input.beatInterval, 0.3), 1) * activity
        ripple += dt * activity

        // Windows light up to their band's level, floor by floor; in a breakdown most stay dark.
        let quiet = activity < 0.5
        let damp = 1 - 0.75 * soft
        for b in buildings.indices {
            // The highs run quieter than the lows, so the buildings that hear them listen harder.
            let band = Double(input.band(at: buildings[b].band)) * (1 + 0.6 * buildings[b].band)
            reach[b] = min(1, max(0, band - 0.15) / 0.75) * damp * activity * Double(buildings[b].floors)
        }
        let flickering = treble > 0.25 && !quiet
        for i in windows.indices {
            let w = windows[i]
            if !w.empty, Double(w.floor) + 0.5 < reach[w.building] {
                lit[i] = 1
                holding[i] = max(holding[i], Self.hold * w.linger)
            } else if w.late {
                lit[i] = min(1, lit[i] + dt * 4)
            } else if holding[i] > 0 {
                // Silence: let go sooner, so the city is at rest within half a second.
                holding[i] = quiet ? min(holding[i], 0.12) - dt : holding[i] - dt
            } else {
                lit[i] = max(0, lit[i] - dt * Self.fade * (quiet ? 1.6 : 1))
            }
            if w.flickers {
                flicker[i] = flickering && lit[i] > 0 ? random.range(0.35, 1) : 1
            }
        }
        for i in stars.indices { stars[i].phase += dt * activity * (1 + 5 * treble) }
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        if paints == nil || paints?.style != style { paints = Self.paints(style) }
        guard let paints, size.width > 0, size.height > 0 else { return }
        let isLight = style.isLight
        ctx.saveGState()
        ctx.scaleBy(x: size.width / Self.side, y: size.height / Self.side)

        // Stars.
        rects.removeAll(keepingCapacity: true)
        for star in stars {
            let b = star.bright * (0.75 + 0.25 * sin(star.phase))
            let s: CGFloat = b > 0.6 ? 1.5 : 1
            rects.append(CGRect(x: star.x - s / 2, y: star.y - s / 2, width: s, height: s))
        }
        ctx.setFill(style.ink, (isLight ? 0.45 : 0.7) * (1 - 0.3 * searchFade))
        ctx.fill(rects)

        let scale = abs(ctx.userSpaceToDeviceSpaceTransform.a)
        if layers?.style.isClose(to: style) != true || layers?.scale != scale {
            layers = makeLayers(paints, scale: scale)
        }
        guard let layers else { return }
        Self.place(layers.moon, in: ctx)
        // The glow of the streets, rising behind the city with the bass (dark artwork only).
        if !isLight {
            ctx.saveGState()
            ctx.setAlpha(0.35 + 0.65 * min(1, bass * 0.9 + 0.5 * searchFade))
            Self.place(layers.haze, in: ctx)
            ctx.restoreGState()
        }
        drawSearchlights(ctx, paints: paints, isLight: isLight)
        Self.place(layers.city, in: ctx)

        drawWindows(ctx, paints: paints, isLight: isLight)

        // The aircraft light.
        let red = isLight ? RGB(0.7, 0.08, 0.1) : RGB(1, 0.22, 0.2)
        let on = 0.3 + 0.7 * blink
        if !isLight, blink > 0.05 {
            ctx.fillGlow(at: beacon, radius: 5, color: red, alpha: 0.6 * blink)
        }
        ctx.setFill(isLight ? red : red.mixed(with: .white, 0.3 * blink), on)
        ctx.fill(CGRect(x: beacon.x - 1, y: beacon.y - 1.5, width: 2, height: 2))

        drawWater(ctx, paints: paints, isLight: isLight)
        ctx.restoreGState()
    }

    /// The searchlights' strength: up quickly at the drop, out over their last two seconds.
    private var searchFade: Double {
        guard searching > 0 else { return 0 }
        let elapsed = Self.sweep - searching
        return min(1, elapsed / 0.3) * min(1, searching / 2) * activity
    }

    /// The parts that don't change, as images at `scale` pixels a point.
    private func makeLayers(_ paints: Paints, scale: CGFloat) -> (style: SceneStyle, scale: CGFloat, moon: Layer,
                                                                   haze: Layer, city: Layer) {
        let G = Self.ground, W = Self.side
        let light = paints.style.isLight
        let reach = (moon.radius * 2.6).rounded(.up)
        let moonRect = CGRect(x: (moon.centre.x - reach).rounded(.down), y: (moon.centre.y - reach).rounded(.down),
                              width: 2 * reach + 1, height: 2 * reach + 1)
        let moonImage = Self.render(moonRect, scale: scale) { self.drawMoon($0, paints: paints, isLight: light) }
        let hazeRect = CGRect(x: 0, y: G - 34, width: W, height: 34)
        let hazeImage = light ? nil : Self.render(hazeRect, scale: scale) { ctx in
            if let haze = paints.haze {
                ctx.drawLinearGradient(haze, start: CGPoint(x: 0, y: G), end: CGPoint(x: 0, y: G - 34), options: [])
            }
        }
        let top = (min(farRow.boundingBox.minY, nearRow.boundingBox.minY) - 1).rounded(.down)
        let cityRect = CGRect(x: 0, y: top, width: W, height: G + 1 - top)
        let cityImage = Self.render(cityRect, scale: scale) { ctx in
            ctx.addPath(self.farRow)
            ctx.setFill(paints.back, light ? 0.16 : 0.75)
            ctx.fillPath()
            ctx.addPath(self.nearRow)
            ctx.setFill(paints.front, light ? 0.4 : 0.96)
            ctx.fillPath()
        }
        return (paints.style, scale, (moonImage, moonRect), (hazeImage, hazeRect), (cityImage, cityRect))
    }

    /// `body`, drawn in the scene's points, as an image of `rect` at `scale` pixels a point.
    private static func render(_ rect: CGRect, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let w = Int((rect.width * scale).rounded(.up)), h = Int((rect.height * scale).rounded(.up))
        guard w > 0, h > 0, w <= 4096, h <= 4096,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sceneColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Points, top-left origin, `rect`'s corner at the image's.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        body(ctx)
        return ctx.makeImage()
    }

    /// Draws a layer back over its rect (images draw bottom-up in the top-left-origin context).
    private static func place(_ layer: Layer, in ctx: CGContext) {
        guard let image = layer.image else { return }
        let scale = CGFloat(image.width) / max(layer.rect.width, 1)
        let height = CGFloat(image.height) / scale
        ctx.saveGState()
        ctx.translateBy(x: layer.rect.minX, y: layer.rect.minY + height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: height))
        ctx.restoreGState()
    }

    private func drawMoon(_ ctx: CGContext, paints: Paints, isLight light: Bool) {
        let c = moon.centre, r = moon.radius
        if !light { ctx.fillGlow(at: c, radius: r * 2.6, color: paints.moon, alpha: 0.22) }
        ctx.saveGState()
        let disc = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        if moon.crescent {
            // The disc less a disc offset towards the upper left.
            ctx.addEllipse(in: disc)
            ctx.clip()
            ctx.addRect(disc)
            ctx.addEllipse(in: disc.offsetBy(dx: -r * 0.55, dy: -r * 0.3))
            ctx.clip(using: .evenOdd)
        }
        ctx.setFill(paints.moon, light ? (moon.crescent ? 0.7 : 0.45) : 0.95)
        ctx.fillEllipse(in: disc)
        if !moon.crescent {
            // A couple of seas.
            ctx.setFill(light ? paints.style.ink : paints.moon.scaled(0.8), light ? 0.25 : 0.5)
            ctx.fillEllipse(in: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.4, width: r * 0.6, height: r * 0.5))
            ctx.fillEllipse(in: CGRect(x: c.x + r * 0.1, y: c.y + r * 0.15, width: r * 0.45, height: r * 0.4))
        }
        ctx.restoreGState()
    }

    /// Two searchlights from among the buildings, sweeping back and forth across the sky in time.
    private func drawSearchlights(_ ctx: CGContext, paints: Paints, isLight light: Bool) {
        let strength = searchFade
        guard strength > 0.01, let beam = paints.beam else { return }
        let bases: [(x: CGFloat, phase: Double)] = [(27, 0), (66, .pi * 0.8)]
        for base in bases {
            // A full sweep every eight beats.
            let angle = 0.55 * sin(sweepPhase * .pi / 4 + base.phase)
            let dx = CGFloat(sin(angle)), dy = -CGFloat(cos(angle))
            let length: CGFloat = 105, spread: CGFloat = 0.075
            let start = CGPoint(x: base.x, y: Self.ground)
            let end = CGPoint(x: start.x + dx * length, y: start.y + dy * length)
            let nx = -dy * length * spread, ny = dx * length * spread
            ctx.saveGState()
            ctx.move(to: CGPoint(x: start.x - dy * 1.2, y: start.y + dx * 1.2))
            ctx.addLine(to: CGPoint(x: end.x + nx, y: end.y + ny))
            ctx.addLine(to: CGPoint(x: end.x - nx, y: end.y - ny))
            ctx.addLine(to: CGPoint(x: start.x + dy * 1.2, y: start.y - dx * 1.2))
            ctx.closePath()
            ctx.clip()
            ctx.setAlpha(strength)
            ctx.drawLinearGradient(beam, start: start, end: end, options: [])
            ctx.restoreGState()
        }
    }

    /// The windows, in a few batches of one colour and brightness.
    private func drawWindows(_ ctx: CGContext, paints: Paints, isLight light: Bool) {
        let levels = 3
        for tint in -1..<paints.tints.count {
            let colour = tint < 0 ? paints.lamp : paints.tints[tint]
            for level in 0..<levels {
                rects.removeAll(keepingCapacity: true)
                for i in windows.indices where windows[i].tint == tint {
                    let v = brightness(i)
                    guard v > 0.04, min(levels - 1, Int(v * Double(levels))) == level else { continue }
                    rects.append(windows[i].rect)
                }
                guard !rects.isEmpty else { continue }
                let alpha = (Double(level) + 1) / Double(levels)
                ctx.setFill(colour, alpha * (light ? 0.85 : 1))
                ctx.fill(rects)
            }
        }
    }

    /// Window `i`'s brightness now, 0...1.
    private func brightness(_ i: Int) -> Double { lit[i] * flicker[i] }

    /// The water: dark under the city, with the lit windows shimmering in it.
    private func drawWater(_ ctx: CGContext, paints: Paints, isLight: Bool) {
        let G = Self.ground, W = Self.side
        ctx.setFill(paints.water, isLight ? 0.16 : 0.88)
        ctx.fill(CGRect(x: 0, y: G, width: W, height: W - G))
        // Reflections: each lit window's light, upside down and squashed, broken up by the ripples.
        let colour = isLight ? paints.style.ink : paints.lamp
        for pass in 0..<2 {
            rects.removeAll(keepingCapacity: true)
            for i in windows.indices {
                let v = brightness(i)
                guard v > 0.3 else { continue }
                let rect = windows[i].rect
                // On every other row of the water, so the light breaks into streaks.
                let y = G + 1 + 2 * ((G - rect.maxY) * 0.22).rounded()
                guard y < W - 3 else { continue }
                // Brighter near the shore.
                let near = (y - G) < 7
                guard near == (pass == 1) else { continue }
                let wave = sin(Double(y) * 1.7 + ripple * 3) + 0.5 * sin(Double(rect.minX) * 0.9 + ripple * 2)
                let shift = CGFloat(wave * 0.8).rounded()
                rects.append(CGRect(x: rect.minX + shift, y: y, width: rect.width, height: 1))
            }
            guard !rects.isEmpty else { continue }
            ctx.setFill(colour, (pass == 1 ? 0.45 : 0.25) * (isLight ? 0.6 : 1))
            ctx.fill(rects)
        }
        // The shoreline.
        ctx.setFill(isLight ? paints.style.ink : paints.lamp, isLight ? 0.3 : 0.25)
        ctx.fill(CGRect(x: 0, y: G, width: W, height: 0.5))
    }

    // MARK: Colours

    private static func paints(_ style: SceneStyle) -> Paints {
        func warmth(_ c: RGB) -> Double { c.r - c.b + (c.g - c.b) * 0.3 }
        let warmest = style.sparks.max { warmth($0) < warmth($1) } ?? style.accent
        let tints = (0..<4).map { style.spark($0) }
        if style.isLight {
            // A print: pale buildings, dark windows, no light of their own.
            let ink = style.ink
            let beam = CGGradient(colorsSpace: sceneColorSpace,
                                  colors: [ink.cgColor(alpha: 0.28), ink.cgColor(alpha: 0)] as CFArray,
                                  locations: [0, 1])
            return Paints(style: style, front: ink, back: ink, lamp: ink, tints: tints.map { $0.mixed(with: ink, 0.5) },
                          moon: ink, water: ink, beam: beam, haze: nil)
        }
        let lamp = RGB(1, 0.84, 0.55).mixed(with: warmest, 0.3)
        let beamColour = lamp.mixed(with: .white, 0.5)
        let beam = CGGradient(colorsSpace: sceneColorSpace,
                              colors: [beamColour.cgColor(alpha: 0.7), beamColour.cgColor(alpha: 0.25),
                                       beamColour.cgColor(alpha: 0)] as CFArray,
                              locations: [0, 0.5, 1])
        let glow = lamp.mixed(with: style.accent, 0.4)
        let haze = CGGradient(colorsSpace: sceneColorSpace,
                              colors: [glow.cgColor(alpha: 0.32), glow.cgColor(alpha: 0)] as CFArray, locations: [0, 1])
        let back = style.deep.mixed(with: style.mid, 0.3).scaled(0.62)
        return Paints(style: style, front: style.deep.scaled(0.32), back: back,
                      lamp: lamp, tints: tints.map { $0.mixed(with: .white, 0.2) },
                      moon: RGB(1, 0.97, 0.88).mixed(with: style.ink, 0.3), water: style.deep.scaled(0.22), beam: beam,
                      haze: haze)
    }
}

/// 0 below `lo`, 1 above `hi`, smooth between.
nonisolated private func smoothstep(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
    let t = min(max((x - lo) / (hi - lo), 0), 1)
    return t * t * (3 - 2 * t)
}
