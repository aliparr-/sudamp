// SPDX-License-Identifier: GPL-3.0-or-later
// Demoscene: a homage to the 90s demo. A chunky plasma swirls behind everything in the artwork's colours, copper bars
// bounce across it on the beat, and a sine scroller sends the name of what's playing (or a greeting, when nothing is
// known) rippling across the middle in chrome letters with a drop shadow. The scroller keeps the tempo, the letters
// hop in a ripple on every kick, and the plasma runs hotter with the music. Through a breakdown the plasma slows and
// darkens and the bars float; the drop flashes the screen and sends the text racing. In silence everything stops: the
// plasma holds, the letters settle flat across the middle with a word lined up at the left (or the whole title
// centred, when it fits). On light artwork the plasma turns pastel and the letters dark. A seed varies the plasma's
// pattern and the bars' colours.
//
// The letters are CoreText glyph outlines (any script, with the system's fallback fonts; colour emoji are drawn as
// glyphs), laid out once per caption and moved as paths each frame.

import CoreGraphics
import CoreText
import Foundation

nonisolated final class DemosceneScene: VisualizerScene {
    /// One glyph of the scroller's text.
    private struct Letter {
        /// Its left edge and width along the line, in points.
        var x: CGFloat
        var width: CGFloat
        /// The middle of its character along the line, where it meets the wave (an accent or other mark rides with
        /// its letter).
        var centre: CGFloat = 0
        /// Which character it belongs to.
        var cluster: Int
        /// The outline (nil for a colour emoji, drawn as a glyph instead).
        var path: CGPath?
        var font: CTFont
        var glyph: CGGlyph
    }

    private struct Bar {
        var phase: Double
        var colour: Int
    }

    private static let grid = 46
    /// The backdrop's rows: a point each, for the copper bars (the plasma's cells are two rows tall).
    private static let lines = 92
    private static let table = 1024
    private static let fontSize: CGFloat = 18
    private static let fallback = "SUDAMP · NOW PLAYING · GREETINGS TO ALL LISTENERS"
    /// The scroller's centre line and the wave's length, in points (at 92 across).
    private static let lineY: CGFloat = 46
    private static let waveLength: CGFloat = 64
    private static let inset: CGFloat = 7

    // The plasma.
    private var sine = [Int32](repeating: 0, count: table)
    /// Squared distances across and down from the plasma's moving centre, per column and row.
    private var across = [Float](repeating: 0, count: grid)
    private var down = [Float](repeating: 0, count: grid)
    /// Where the rings' centre is on its slow orbit.
    private var orbit: Double
    /// The backdrop's pixels: 46 cells across, a row a point.
    private var pixels = [UInt32](repeating: 0, count: grid * lines)
    /// This frame's waves across, down and along the diagonals, per column, row and diagonal.
    private var acrossWave = [Int32](repeating: 0, count: grid)
    private var downWave = [Int32](repeating: 0, count: grid)
    private var diagonalWave = [Int32](repeating: 0, count: grid * 2)
    /// This frame's plasma colours (shaded for a breakdown), and what they were made for.
    private var frame: [UInt32] = []
    private var paletteShade = 0.0
    private var paletteStyle: SceneStyle?
    /// Spatial frequencies (table steps per cell) and the phases of the four waves, and the palette's turn.
    private let steps: (Int, Int, Int, Int)
    private var phases: (Double, Double, Double, Double)
    private let rates: (Double, Double, Double, Double)
    private var cycle = 0.0

    // The scroller.
    private var caption: String?
    private var letters: [Letter] = []
    /// Where each word starts along the line, for settling.
    private var anchors: [CGFloat] = []
    /// The line's length, with the gap before it comes round again.
    private var period: CGFloat = 1
    private var scroll: CGFloat = 0
    private var speed = 0.0
    private var wave = 0.0
    private var amplitude = 0.0
    private var sinceKick = 10.0
    private var hop = 0.0
    private var burst = 0.0
    private var flash = 0.0
    private var energy = 0.0
    private var calm = 0.0
    private var lift = 0.0

    private var bars: [Bar] = []
    private var barTime = 0.0
    private var paints: (style: SceneStyle, plasma: [RGB], bars: [[RGB]], text: CGGradient?)?
    private var textPath = CGMutablePath()

    init(seed: UInt64) {
        var random = SceneRandom(seed: seed)
        for i in 0..<Self.table { sine[i] = Int32((sin(2 * .pi * Double(i) / Double(Self.table)) * 64).rounded()) }
        steps = (random.int(14) + 18, random.int(14) + 16, random.int(10) + 10, random.int(14) + 22)
        phases = (random.range(0, 1024), random.range(0, 1024), random.range(0, 1024), random.range(0, 1024))
        rates = (random.range(60, 110), random.range(-120, -70), random.range(40, 80), random.range(-140, -90))
        orbit = random.range(0, 2 * .pi)
        let first = random.int(4)
        bars = (0..<3).map { Bar(phase: $0 == 0 ? 0 : Double($0) * 0.3 + random.range(0, 0.1), colour: first + $0) }
        cycle = random.range(0, 256)
    }

    var glow: Double { 0 }

    // MARK: Update

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let text = input.caption.isEmpty ? Self.fallback : input.caption
        if text != caption { layOut(text) }

        let sounding = !input.isSilent
        energy += ((sounding ? 1 : 0) - energy) * (1 - exp(-dt / (sounding ? 0.15 : 0.08)))
        calm += (Double(input.breakdown) - calm) * (1 - exp(-dt / 0.5))
        lift = sounding ? min(1, Double(input.level) * 1.8) : lift * exp(-dt / 0.1)
        if input.drop {
            flash = 1
            burst = 1
        }
        flash *= exp(-dt / 0.2)
        burst *= exp(-dt / 0.7)

        // The plasma runs with the music, slower and lazier through a breakdown, and holds in silence.
        let pace = energy * (0.35 + 0.65 * lift) * (1 - 0.6 * calm) * (1 + 1.5 * burst)
        // (Phases are in steps of the sine table, kept within a turn.)
        let turn = Double(Self.table)
        phases.0 = (phases.0 + rates.0 * dt * pace).truncatingRemainder(dividingBy: turn)
        phases.1 = (phases.1 + rates.1 * dt * pace).truncatingRemainder(dividingBy: turn)
        phases.2 = (phases.2 + rates.2 * dt * pace).truncatingRemainder(dividingBy: turn)
        phases.3 = (phases.3 + rates.3 * dt * pace).truncatingRemainder(dividingBy: turn)
        cycle = (cycle + dt * pace * 40).truncatingRemainder(dividingBy: 256)
        orbit += dt * pace * 0.9

        // The bars: bouncing on the beat (the first lands on the downbeat, pulled into step with the beat clock),
        // floating through a breakdown.
        barTime += dt * energy * (1 - 0.55 * calm) / max(input.beatInterval, 0.3)
        if sounding {
            var error = input.groove - (barTime - barTime.rounded(.down))
            if error > 0.5 { error -= 1 }
            if error < -0.5 { error += 1 }
            barTime += error * (1 - exp(-dt / 0.4)) * (1 - calm)
        }

        // The scroller keeps the tempo; the drop sends it racing.
        let wanted = sounding ? 17 / max(input.beatInterval, 0.3) * (1 - 0.35 * calm) * (1 + 3 * burst) : 0
        speed += (wanted - speed) * (1 - exp(-dt / (sounding ? 0.3 : 0.07)))
        scroll += CGFloat(speed * dt)
        wave += dt * energy * 2 * .pi * (0.5 / max(input.beatInterval, 0.3)) * (1 - 0.4 * calm)
        let swing = sounding ? 7 - 3 * calm : 0
        amplitude += (swing - amplitude) * (1 - exp(-dt / (sounding ? 0.3 : 0.08)))
        sinceKick += dt
        if input.beat, sounding {
            sinceKick = 0
            hop = 5 + 4 * Double(input.bass)
        }
        if !sounding { hop *= exp(-dt / 0.06) }

        // Settling in silence: glide to the nearest word start at the left, or centre a title that fits.
        if !sounding {
            settle(dt: dt)
        }
        scroll = scroll.truncatingRemainder(dividingBy: period)
        if scroll < 0 { scroll += period }
    }

    private func settle(dt: Double) {
        let target: CGFloat
        if period - gap <= 92 - 2 * Self.inset {
            target = -(92 - (period - gap)) / 2
        } else {
            // The nearest word start, going round.
            var best = scroll, bestDistance = CGFloat.infinity
            for a in anchors {
                var d = (a - Self.inset - scroll).truncatingRemainder(dividingBy: period)
                if d > period / 2 { d -= period }
                if d < -period / 2 { d += period }
                if abs(d) < bestDistance {
                    bestDistance = abs(d)
                    best = scroll + d
                }
            }
            target = best
        }
        var d = (target - scroll).truncatingRemainder(dividingBy: period)
        if d > period / 2 { d -= period }
        if d < -period / 2 { d += period }
        scroll += d * CGFloat(1 - exp(-dt / 0.08))
    }

    private var gap: CGFloat { Self.fontSize * 1.6 }

    /// Lays the text out once: each glyph's place along the line and its outline, in whatever font CoreText picks
    /// for it (Japanese, accents and emoji included).
    private func layOut(_ text: String) {
        caption = text
        letters.removeAll()
        anchors.removeAll()
        let upper = text.precomposedStringWithCanonicalMapping.uppercased()
        // Each UTF-16 unit's character, so the glyphs of one character (a letter and its marks) move as one.
        var clusters: [Int] = []
        for (index, character) in upper.enumerated() {
            clusters.append(contentsOf: repeatElement(index, count: character.utf16.count))
        }
        let base = CTFontCreateUIFontForLanguage(.emphasizedSystem, Self.fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, Self.fontSize, nil)
        let heavy = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.62]] as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(base, Self.fontSize, nil, heavy)
        let attributed = CFAttributedStringCreate(nil, upper as CFString,
                                                  [kCTFontAttributeName: font] as CFDictionary)
        guard let attributed else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            // The font CoreText chose for this run (a fallback for scripts the system font lacks).
            var runFont = font
            let attributes = CTRunGetAttributes(run) as NSDictionary
            if let value = attributes[kCTFontAttributeName], CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() {
                runFont = value as! CTFont // Checked just above, so it can't fail.
            }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
            let colourGlyphs = CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
            for k in 0..<count {
                let path = CTFontCreatePathForGlyph(runFont, glyphs[k], nil)
                // Spaces have no outline and nothing to draw.
                guard path != nil || colourGlyphs else { continue }
                let cluster = indices[k] >= 0 && indices[k] < clusters.count ? clusters[indices[k]] : -1 - letters.count
                letters.append(Letter(x: positions[k].x, width: advances[k].width, cluster: cluster, path: path,
                                      font: runFont, glyph: glyphs[k]))
            }
        }
        letters.sort { $0.x < $1.x }
        // Each character's middle, across all its glyphs.
        var spans: [Int: (CGFloat, CGFloat)] = [:]
        for letter in letters {
            let span = spans[letter.cluster] ?? (letter.x, letter.x + letter.width)
            spans[letter.cluster] = (min(span.0, letter.x), max(span.1, letter.x + letter.width))
        }
        for i in letters.indices {
            let span = spans[letters[i].cluster] ?? (letters[i].x, letters[i].x + letters[i].width)
            letters[i].centre = (span.0 + span.1) / 2
        }
        // Word starts (a letter or digit after a space, or the start), for the text to settle on.
        var previousSpace = true
        var offset = 0
        for character in upper {
            let space = character.isWhitespace
            if previousSpace, character.isLetter || character.isNumber {
                anchors.append(CTLineGetOffsetForStringIndex(line, offset, nil))
            }
            previousSpace = space
            offset += character.utf16.count
        }
        period = max(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), 1) + gap
        // A fresh scroller starts with the text in place.
        scroll = 0
        settle(dt: 10)
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let u = min(size.width, size.height) / 92
        ctx.saveGState()
        ctx.translateBy(x: (size.width - 92 * u) / 2, y: (size.height - 92 * u) / 2)
        ctx.scaleBy(x: u, y: u)
        drawBackdrop(ctx, style: style)
        drawText(ctx, style: style)
        if flash > 0.01 {
            ctx.setFill(style.isLight ? style.accent : .white, (style.isLight ? 0.35 : 0.7) * flash)
            ctx.fill(CGRect(x: 0, y: 0, width: 92, height: 92))
        }
        ctx.restoreGState()
    }

    /// The plasma and the copper bars, painted together into one bitmap: the plasma in 2-point cells, the bars in
    /// 1-point rows (a copper bar changes colour line by line).
    private func drawBackdrop(_ ctx: CGContext, style: SceneStyle) {
        if paints == nil || paints?.style != style { paints = Self.paints(style, bars: bars) }
        guard let paints else { return }
        // A breakdown dims the plasma: the palette is shaded to suit.
        let shade = calm
        if abs(shade - paletteShade) > 0.004 || frame.isEmpty || paletteStyle != style {
            paletteShade = shade
            paletteStyle = style
            frame = paints.plasma.map { c in
                Self.pack(style.isLight ? c.mixed(with: style.mid, 0.3 * shade) : c.scaled(1 - 0.35 * shade))
            }
        }
        let n = Self.grid, height = Self.lines, mask = Int32(Self.table - 1)
        func wrapped(_ phase: Double) -> Int32 { Int32(phase.rounded(.down)) & mask }
        let p0 = wrapped(phases.0), p1 = wrapped(phases.1), p2 = wrapped(phases.2), p3 = wrapped(phases.3)
        for i in 0..<n {
            acrossWave[i] = sine[Int((Int32(i * steps.0) + p0) & mask)]
            downWave[i] = sine[Int((Int32(i * steps.1) + p1) & mask)]
        }
        for i in 0..<(n * 2) { diagonalWave[i] = sine[Int((Int32(i * steps.2) + p2) & mask)] }
        let turn = Int32(cycle.truncatingRemainder(dividingBy: 256))
        // The rings' centre wanders on a slow Lissajous orbit.
        let half = Double(n) / 2
        let cx = Float(half + half * 0.6 * sin(orbit)), cy = Float(half + half * 0.6 * sin(orbit * 0.77 + 1.3))
        for i in 0..<n {
            across[i] = (Float(i) - cx) * (Float(i) - cx)
            down[i] = (Float(i) - cy) * (Float(i) - cy)
        }
        let radial = Float(steps.3)
        sine.withUnsafeBufferPointer { sine in
            frame.withUnsafeBufferPointer { palette in
                pixels.withUnsafeMutableBufferPointer { out in
                    for y in 0..<n {
                        let row = downWave[y], dy = down[y]
                        let top = y * 2 * n
                        for x in 0..<n {
                            let r = sine[Int((Int32((across[x] + dy).squareRoot() * radial) + p3) & mask)]
                            // Four waves, -256...256, onto the palette's 256 colours, turning.
                            let v = acrossWave[x] + row + diagonalWave[x + y] + r
                            let colour = palette[Int((v / 2 + turn) & 255)]
                            out[top + x] = colour
                            out[top + n + x] = colour
                        }
                    }
                }
            }
        }

        // The copper bars: bouncing like balls, one bounce a beat, or floating on a slow sine through a breakdown.
        let thickness = 6.5
        for (k, bar) in bars.enumerated() {
            let t = barTime + bar.phase
            let bounce = abs(sin(.pi * t))
            let float = 0.5 + 0.5 * sin(.pi * t * 0.5)
            let rise = bounce * (1 - calm) + float * calm
            let top = 80 - 62 * rise - thickness / 2
            let stops = paints.bars[k % paints.bars.count]
            let first = max(0, Int(top.rounded(.down))), last = min(height - 1, Int((top + thickness).rounded(.up)) - 1)
            guard first <= last else { continue }
            for r in first...last {
                let cover = min(Double(r + 1), top + thickness) - max(Double(r), top)
                guard cover > 0 else { continue }
                let f = min(max((Double(r) + 0.5 - top) / thickness, 0), 1) * Double(stops.count - 1)
                let i = min(Int(f), stops.count - 2)
                let c = stops[i].mixed(with: stops[i + 1], f - Double(i))
                blendRow(r, c, min(cover, 1) * 0.95)
            }
        }

        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: n, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                                  space: sceneColorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: 0, y: 92)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 92, height: 92))
        ctx.restoreGState()
    }

    /// Paints `colour` at `alpha` over a whole row of the backdrop (opaque underneath).
    private func blendRow(_ row: Int, _ colour: RGB, _ alpha: Double) {
        let a = UInt32(min(max(alpha, 0), 1) * 256), keep = 256 - a
        let r = UInt32(colour.r * 255 + 0.5) * a, g = UInt32(colour.g * 255 + 0.5) * a
        let b = UInt32(colour.b * 255 + 0.5) * a
        let n = Self.grid
        pixels.withUnsafeMutableBufferPointer { out in
            for i in (row * n)..<(row * n + n) {
                let p = out[i]
                let nr = ((p & 0xFF) * keep + r) >> 8
                let ng = (((p >> 8) & 0xFF) * keep + g) >> 8
                let nb = (((p >> 16) & 0xFF) * keep + b) >> 8
                out[i] = nr | ng << 8 | nb << 16 | 0xFF00_0000
            }
        }
    }

    private func drawText(_ ctx: CGContext, style: SceneStyle) {
        guard !letters.isEmpty else { return }
        let size = Self.fontSize
        let baseline = Self.lineY + size * 0.36
        textPath = CGMutablePath()
        var emoji: [(Letter, CGPoint)] = []
        // Copies of the line going round, as many as cover the artwork.
        var copy = -scroll
        while copy < 92 {
            for letter in letters {
                let x = copy + letter.x
                guard x + letter.width > -2, x < 94 else { continue }
                let centre = copy + letter.centre
                var y = baseline + CGFloat(amplitude * sin(Double(centre / Self.waveLength) * 2 * .pi - wave))
                // A kick's hop ripples across from the left.
                let age = sinceKick - Double(centre) / 260
                if age > 0, age < 0.3 { y -= CGFloat(hop * sin(.pi * age / 0.3)) }
                if let path = letter.path {
                    textPath.addPath(path, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x, ty: y))
                } else {
                    emoji.append((letter, CGPoint(x: x, y: y)))
                }
            }
            copy += period
        }
        // The drop shadow, then the letters filled with a chrome gradient fixed across the band.
        ctx.saveGState()
        ctx.translateBy(x: 1.3, y: 1.3)
        ctx.addPath(textPath)
        ctx.setFill(style.isLight ? .white : style.deep.scaled(0.35), style.isLight ? 0.7 : 0.75)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(textPath)
        ctx.clip()
        if let text = paints?.text {
            ctx.drawLinearGradient(text, start: CGPoint(x: 0, y: Self.lineY - 16),
                                   end: CGPoint(x: 0, y: Self.lineY + 16),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
        // Colour emoji have no outline: drawn as glyphs, flipped upright about their baseline.
        for (letter, point) in emoji {
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: point.x, y: point.y)
            ctx.scaleBy(x: 1, y: -1)
            var glyph = letter.glyph, origin = CGPoint.zero
            CTFontDrawGlyphs(letter.font, &glyph, &origin, 1, ctx)
            ctx.restoreGState()
        }
    }

    // MARK: Colours

    /// Premultiplied, opaque, as bytes R, G, B, A in memory.
    private static func pack(_ c: RGB) -> UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32(min(max(v, 0), 1) * 255 + 0.5) }
        return byte(c.r) | byte(c.g) << 8 | byte(c.b) << 16 | 0xFF00_0000
    }

    /// The scene's colours. The plasma's 256 go round a loop of the artwork's own, deep and moody over dark artwork
    /// and pastel over light, so the letters stand out; each copper bar shades from dark edges to a bright middle; the
    /// letters are chrome (or deep ink, over light artwork).
    private static func paints(_ style: SceneStyle, bars: [Bar])
        -> (style: SceneStyle, plasma: [RGB], bars: [[RGB]], text: CGGradient?) {
        let stops: [RGB]
        if style.isLight {
            stops = [style.mid.mixed(with: .white, 0.45), style.spark(0).mixed(with: .white, 0.6),
                     style.accent.mixed(with: .white, 0.55), style.spark(1).mixed(with: .white, 0.6),
                     style.mid.mixed(with: .white, 0.3), style.spark(2).mixed(with: .white, 0.6)]
        } else {
            stops = [style.deep.scaled(0.7), style.spark(0).mixed(with: style.deep, 0.5).scaled(0.85),
                     style.mid.scaled(0.75), style.spark(1).mixed(with: style.deep, 0.45).scaled(0.85),
                     style.deep.scaled(0.5), style.spark(2).mixed(with: style.deep, 0.55).scaled(0.85)]
        }
        let plasma = (0..<256).map { i -> RGB in
            let t = Double(i) / 256 * Double(stops.count)
            let k = Int(t), f = t - Double(k)
            return stops[k % stops.count].mixed(with: stops[(k + 1) % stops.count], f * f * (3 - 2 * f))
        }
        let copper = bars.map { bar -> [RGB] in
            let c = style.spark(bar.colour)
            if style.isLight {
                return [c.scaled(0.45), c.scaled(0.75), c.mixed(with: .white, 0.35), c.scaled(0.75), c.scaled(0.45)]
            }
            return [c.scaled(0.3), c.scaled(0.8), c.mixed(with: .white, 0.7), c.scaled(0.8), c.scaled(0.3)]
        }
        func gradient(_ colours: [RGB]) -> CGGradient? {
            let locations: [CGFloat] = colours.indices.map { CGFloat($0) / CGFloat(max(colours.count - 1, 1)) }
            return CGGradient(colorsSpace: sceneColorSpace, colors: colours.map(\.cgColor) as CFArray,
                              locations: locations)
        }
        let text: CGGradient?
        if style.isLight {
            let ink = style.ink
            text = gradient([ink.mixed(with: style.spark(0), 0.3), ink.scaled(0.6), ink, style.deep.scaled(0.5)])
        } else {
            // Chrome: a pale sky above the horizon, a bright line, then the ground's warm colour below.
            let sky = style.spark(0).mixed(with: .white, 0.75), ground = style.spark(1).mixed(with: .white, 0.3)
            text = gradient([.white, sky, sky.scaled(0.85), .white, ground, ground.mixed(with: .white, 0.5)])
        }
        return (style, plasma, copper, text)
    }
}
