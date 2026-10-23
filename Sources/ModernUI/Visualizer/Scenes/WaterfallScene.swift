// SPDX-License-Identifier: GPL-3.0-or-later
// Waterfall: a scrolling spectrogram laid on a floor that recedes towards a far horizon, the lows down the middle and
// the highs out to both sides. Each moment's spectrum enters as a row at the foot of the artwork and slides away up
// the floor, glowing from clear through the artwork's colour to near-white where it is loud, and fading into the
// distance. Kicks leave a faint line across the floor, so the beat rolls away with the music.

import CoreGraphics
import Foundation

nonisolated final class WaterfallScene: VisualizerScene {
    static let columns = 46
    static let rows = 64
    /// Seconds per row.
    static let rowTime = 1.0 / 30
    /// The oldest row shown, in seconds: it reaches the top of the artwork as it fades out.
    static let depth = 1.9
    /// How wide the floor is at the top of the artwork, as a share of its width at the foot.
    static let far = 0.5

    /// Finished rows, newest at `head - 1`, wrapping; levels 0...1.
    private var history = [Float](repeating: 0, count: columns * rows)
    /// Whether a kick landed in each row (as 0 or 1, so rows blend).
    private var beats = [Float](repeating: 0, count: rows)
    private var head = 0
    /// The row coming in: the loudest of the frames since the last row.
    private var live = [Float](repeating: 0, count: columns)
    private var liveBeat: Float = 0
    private var current = [Float](repeating: 0, count: columns)
    /// How long ago the newest row was finished, in rows (0..<1).
    private var phase: Double = 0
    /// Finished rows in a row with nothing in them, and whether the row coming in has anything.
    private var emptyRows = rows
    private var liveEmpty = true
    private var line = [Float](repeating: 0, count: columns)
    private var pixels: [UInt32] = []
    private var ramp: (style: SceneStyle, colors: [UInt32], beat: UInt32)?

    var glow: Double { 0 }

    func update(_ input: VisualizerInput, dt: Double) {
        let n = Self.columns
        liveEmpty = true
        for c in 0..<n {
            let f = (Double(c) + 0.5) / Double(n)
            // The analyser's floor cut off, the highs lifted a little, and a curve so the loudest moments glow and the
            // rest stays faint.
            let v = min(max((input.band(at: f) + 0.12 * Float(f) - 0.22) / 0.72, 0), 1)
            current[c] = v * v * (1.4 - 0.4 * v)
            live[c] = max(live[c], current[c])
            if live[c] > 0 { liveEmpty = false }
        }
        if input.beat { liveBeat = 1 }
        phase += dt / Self.rowTime
        while phase >= 1 {
            phase -= 1
            let base = head * n
            for c in 0..<n { history[base + c] = live[c] }
            beats[head] = liveBeat
            head = (head + 1) % Self.rows
            emptyRows = liveEmpty && liveBeat == 0 ? min(emptyRows + 1, Self.rows) : 0
            liveEmpty = true
            for c in 0..<n {
                live[c] = current[c]
                if live[c] > 0 { liveEmpty = false }
            }
            liveBeat = 0
        }
    }

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        // An empty floor still shows faintly, so a quiet Waterfall is not mistaken for no visualiser.
        let quiet = Double(emptyRows) / Double(Self.rows - 1)
        if quiet > 0.05 { drawFloor(in: ctx, size: size, style: style, alpha: min(quiet, 1)) }
        // Nothing has sounded for as long as the floor reaches back.
        if liveEmpty, emptyRows >= Self.rows - 1 { return }
        if ramp == nil || ramp?.style != style { ramp = Self.ramp(style) }
        guard let ramp, size.width >= 1, size.height >= 1 else { return }
        // Drawn a sample per pixel, so it goes to the screen as it is.
        let scale = min(max(abs(ctx.userSpaceToDeviceSpaceTransform.a), 1), 3)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        if pixels.count != width * height { pixels = [UInt32](repeating: 0, count: width * height) }
        let n = Self.columns, rows = Self.rows
        // The horizon sits just out of sight above the artwork, where the floor would narrow to nothing.
        let horizon = -Double(height) * Self.far / (1 - Self.far)
        // The floor at the foot, as a share of the artwork's width (its sides fade over the outer columns).
        let spread = 1.08
        let lastRow = Double(rows - 2)
        pixels.withUnsafeMutableBufferPointer { out in
            ramp.colors.withUnsafeBufferPointer { lut in
                for y in 0..<height {
                    let base = y * width
                    // How near this line of the floor is (1 at the foot), and so how long ago its row went by.
                    let u = (Double(y) + 0.5 - horizon) / (Double(height) - horizon)
                    let age = (1 / u - 1) / (1 / Self.far - 1) * Self.depth
                    let fade = 1 - age / Self.depth
                    guard fade > 0.01 else {
                        for x in 0..<width { out[base + x] = 0 }
                        continue
                    }
                    // The rows either side of that age, blended (the row coming in is age 0).
                    let q = age / Self.rowTime - phase
                    let newest = (head - 1 + rows) % rows
                    let beat: Float
                    if q < 0 {
                        let w = Float(phase > 0 ? (q + phase) / phase : 0)
                        for c in 0..<n { line[c] = live[c] + (history[newest * n + c] - live[c]) * w }
                        beat = liveBeat + (beats[newest] - liveBeat) * w
                    } else {
                        let j = Int(min(q, lastRow)), w = Float(min(q, lastRow) - Double(j))
                        let a = (newest - j + rows) % rows, b = (a - 1 + rows) % rows
                        for c in 0..<n { line[c] = history[a * n + c] + (history[b * n + c] - history[a * n + c]) * w }
                        beat = beats[a] + (beats[b] - beats[a]) * w
                    }
                    let weight = 256 * pow(fade, 0.8)
                    let beatColor = Self.scaled(ramp.beat, UInt32(256 * Double(beat)))
                    // Across the floor: the column under each pixel, mirrored about the middle.
                    let perColumn = Double(n) / (Double(width) * spread * u)
                    let left = Double(width) / 2 - Double(width) * spread * u / 2
                    for x in 0..<width {
                        let p = (Double(x) + 0.5 - left) * perColumn - 0.5
                        let side = min(p + 0.5, Double(n) - 0.5 - p) / 3
                        guard side > 0 else {
                            out[base + x] = 0
                            continue
                        }
                        let m = min(abs(p - Double(n - 1) / 2) * 2, Double(n - 1))
                        let i = min(Int(m), n - 2), f = Float(m - Double(i))
                        let v = line[i] + (line[i + 1] - line[i]) * f
                        var color = lut[Int(min(max(v, 0), 1) * 255)]
                        if beat > 0.01 { color = Self.over(beatColor, color) }
                        out[base + x] = Self.scaled(color, UInt32(side < 1 ? weight * side : weight))
                    }
                }
            }
        }
        guard let image = image(width: width, height: height) else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        // Bitmaps draw bottom-up, so flip.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }

    /// The bare floor: lanes running to the horizon and a few rungs across, fading with distance.
    private func drawFloor(in ctx: CGContext, size: CGSize, style: SceneStyle, alpha: Double) {
        let w = Double(size.width), h = Double(size.height)
        let horizon = -h * Self.far / (1 - Self.far)
        func y(_ u: Double) -> Double { horizon + u * (h - horizon) }
        func x(_ lane: Double, _ u: Double) -> Double { w / 2 + (lane - 0.5) * w * 1.08 * u }
        let ink = style.isLight ? style.accent : style.ink
        let strength = (style.isLight ? 0.2 : 0.14) * alpha
        ctx.saveGState()
        ctx.setLineCap(.butt)
        ctx.setLineWidth(0.8)
        // Each lane in four pieces, fainter towards the horizon.
        let steps = [1.0, 0.85, 0.72, 0.6, Self.far]
        for (i, pair) in zip(steps, steps.dropFirst()).enumerated() {
            var segments: [CGPoint] = []
            for lane in stride(from: 1.0 / 6, through: 5.0 / 6 + 0.001, by: 1.0 / 6) {
                segments.append(CGPoint(x: x(lane, pair.0), y: y(pair.0)))
                segments.append(CGPoint(x: x(lane, pair.1), y: y(pair.1)))
            }
            ctx.setStroke(ink, strength * (1 - Double(i) * 0.22))
            ctx.strokeLineSegments(between: segments)
        }
        for (u, fade) in [(0.9, 0.8), (0.74, 0.55), (0.62, 0.3)] {
            ctx.setStroke(ink, strength * fade)
            ctx.strokeLineSegments(between: [CGPoint(x: x(1.0 / 6, u), y: y(u)), CGPoint(x: x(5.0 / 6, u), y: y(u))])
        }
        ctx.restoreGState()
    }

    private func image(width: Int, height: Int) -> CGImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// A premultiplied RGBA pixel (bytes R, G, B, A in memory) with every channel scaled by `weight`/256.
    private static func scaled(_ pixel: UInt32, _ weight: UInt32) -> UInt32 {
        guard weight < 256 else { return pixel }
        let rb = (((pixel & 0x00FF_00FF) &* weight) >> 8) & 0x00FF_00FF
        let ga = ((((pixel >> 8) & 0x00FF_00FF) &* weight) >> 8) & 0x00FF_00FF
        return rb | ga << 8
    }

    /// Premultiplied `top` over `bottom`.
    private static func over(_ top: UInt32, _ bottom: UInt32) -> UInt32 {
        top &+ scaled(bottom, 256 - (top >> 24))
    }

    /// The heat ramp, 256 premultiplied pixels from silent to loud: clear, then the artwork's colour, then near-white
    /// (on light artwork, its deep ink instead of white). And the faint line a kick leaves.
    private static func ramp(_ style: SceneStyle) -> (style: SceneStyle, colors: [UInt32], beat: UInt32) {
        let stops: [(t: Double, color: RGB, alpha: Double)]
        if style.isLight {
            stops = [(0, style.accent, 0.08), (0.2, style.accent, 0.25), (0.55, style.accent, 0.65),
                     (1, style.ink.scaled(0.8), 0.95)]
        } else {
            let hue = style.spark(0), warm = hue.mixed(with: style.spark(1), 0.5)
            stops = [(0, hue, 0), (0.18, hue, 0.12), (0.45, hue, 0.6), (0.72, warm.mixed(with: .white, 0.3), 0.92),
                     (1, style.ink.mixed(with: .white, 0.6), 1)]
        }
        func pack(_ color: RGB, _ alpha: Double) -> UInt32 {
            func byte(_ v: Double) -> UInt32 { UInt32(min(max(v, 0), 1) * 255 + 0.5) }
            return byte(color.r * alpha) | byte(color.g * alpha) << 8 | byte(color.b * alpha) << 16 | byte(alpha) << 24
        }
        let colors = (0..<256).map { i -> UInt32 in
            let t = Double(i) / 255
            let j = stops.lastIndex { $0.t <= t } ?? 0
            let a = stops[j], b = stops[min(j + 1, stops.count - 1)]
            let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
            let s = f * f * (3 - 2 * f)
            return pack(a.color.mixed(with: b.color, s), a.alpha + (b.alpha - a.alpha) * s)
        }
        return (style, colors, pack(style.ink, style.isLight ? 0.1 : 0.16))
    }
}
