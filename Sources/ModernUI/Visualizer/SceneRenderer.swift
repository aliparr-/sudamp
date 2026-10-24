// SPDX-License-Identifier: GPL-3.0-or-later
// Runs the visualiser's scenes: the one showing, a cross-fade when it changes (a pick, or the rotation moving on),
// the rotation's timing, the effect laid over the frame (VHS or Kaleidoscope), and the bitmap each frame is drawn
// into. No AppKit: the artwork view hands it frames and shows the images it returns; tests and the preview's contact
// sheets use it offscreen.

import CoreGraphics
import Foundation

nonisolated final class SceneRenderer {
    typealias Mode = ModernPlayerState.Visualizer

    /// The scene showing (nil before the first `show`).
    private(set) var mode: Mode?
    private var scene: (any VisualizerScene)?
    /// The scene fading out, and how far the fade has gone (0...1).
    private var outgoing: (any VisualizerScene)?
    private(set) var fade: Double = 1
    var fadeDuration = 0.9
    var style = SceneStyle.standard
    /// The finish over the frame.
    var effect = ModernPlayerState.VisualizerEffect.none
    private var seed: UInt64
    private var canvas: (context: CGContext, width: Int, height: Int)?
    /// The kaleidoscope draws the scene here first, then mirrors a wedge of it.
    private var source: (context: CGContext, width: Int, height: Int)?
    /// The effects' own motion: it follows the music and stops in silence, so a still frame is still.
    private var activity = 0.0
    private var pulse = 0.0
    private var spin = 0.0
    /// Where the kaleidoscope looks (radians round the middle, y down: straight down to start), and where the scene
    /// is busiest, which it turns towards.
    private var look = Double.pi / 2
    private var busiest = Double.pi / 2
    private var tracking = 0.0
    private var frames: UInt64 = 0
    /// A row's worth of pixels, reused by the VHS pass.
    private var row: [UInt8] = []

    init(seed: UInt64 = 1) { self.seed = seed }

    var isFading: Bool { outgoing != nil }

    /// Shows `mode` (a scene). Animated, the scene showing fades out while the new one fades in.
    func show(_ mode: Mode, animated: Bool) {
        guard mode.isScene, mode != self.mode else { return }
        seed &+= 0x9E37_79B9
        let next = mode.makeScene(seed: seed)
        if animated, let scene {
            outgoing = scene
            fade = 0
        } else {
            outgoing = nil
            fade = 1
        }
        scene = next
        self.mode = mode
    }

    /// Moves every scene on by `dt` with `input`, and the fade.
    func update(_ input: VisualizerInput, dt: Double) {
        let step = min(max(dt.isFinite ? dt : 0, 0), 0.25)
        activity += ((input.isSilent ? 0 : 1) - activity) * min(1, step * (input.isSilent ? 9 : 3))
        pulse = Double(input.pulse) * activity
        spin += step * activity * (0.12 + 0.25 * Double(input.level) + 0.6 * pulse)
        // Towards the busiest part of the scene, the short way round, unhurried.
        let turnTo = remainder(busiest - look, 2 * .pi)
        look += turnTo * min(1, step * 0.9 * activity)
        tracking += step * activity * (0.09 + 0.3 * pulse)
        if !input.isSilent { frames &+= 1 }
        scene?.update(input, dt: dt)
        if let outgoing {
            outgoing.update(input, dt: dt)
            fade = min(1, fade + dt / max(fadeDuration, 0.01))
            if fade >= 1 { self.outgoing = nil }
        }
    }

    /// The glow the scene showing wants (blended through a fade), 0...1.
    var glow: Double {
        let current = scene?.glow ?? 0
        guard let outgoing else { return current }
        return outgoing.glow + (current - outgoing.glow) * fade
    }

    /// Draws the scenes into `ctx` (points, origin top-left), cross-fading.
    func draw(in ctx: CGContext, size: CGSize) {
        if let outgoing {
            let t = fade * fade * (3 - 2 * fade)
            layer(ctx, alpha: 1 - t) { outgoing.draw(in: ctx, size: size, style: style) }
            if let scene { layer(ctx, alpha: t) { scene.draw(in: ctx, size: size, style: style) } }
        } else {
            scene?.draw(in: ctx, size: size, style: style)
        }
    }

    private func layer(_ ctx: CGContext, alpha: Double, _ body: () -> Void) {
        guard alpha > 0.002 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// The current frame as an image `size` points across at `scale` pixels per point.
    func image(size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        if canvas == nil || canvas?.width != width || canvas?.height != height {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            canvas = (context, width, height)
        }
        guard let ctx = canvas?.context else { return nil }
        switch effect {
        case .none:
            render(into: ctx, width: width, height: height, size: size)
        case .vhs:
            render(into: ctx, width: width, height: height, size: size)
            applyVHS(ctx, width: width, height: height, scale: CGFloat(width) / size.width)
        case .kaleidoscope:
            if source == nil || source?.width != width || source?.height != height {
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                source = (context, width, height)
            }
            guard let src = source?.context else { return nil }
            render(into: src, width: width, height: height, size: size)
            fold(src, into: ctx, width: width, height: height)
        }
        return ctx.makeImage()
    }

    /// Clears `ctx` and draws the scenes into it in points, top-left origin.
    private func render(into ctx: CGContext, width: Int, height: Int, size: CGSize) {
        ctx.saveGState()
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / size.width, y: -CGFloat(height) / size.height)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        draw(in: ctx, size: size)
        ctx.restoreGState()
    }

    // MARK: Kaleidoscope

    /// Each pixel's distance from the middle and angle round it, for the canvas size (made once).
    private var polar: (width: Int, height: Int, radius: [Float], angle: [Float])?
    private static let turnSteps = 4096
    private static let cosines: [Float] = (0..<turnSteps).map { Float(cos(Double($0) * 2 * .pi / Double(turnSteps))) }
    private static let sines: [Float] = (0..<turnSteps).map { Float(sin(Double($0) * 2 * .pi / Double(turnSteps))) }

    /// Twelve 30° wedges round the middle, alternate ones mirrored so their edges meet, each showing the same wedge of
    /// the scene, and the whole figure turning. The wedge it takes turns towards where the scene is busiest (the
    /// spectrum's foot, the fireworks' sky). Worked a pixel at a time from a table: twelve rotated image draws cost
    /// 0.5 ms a frame at 2x, this about 0.1 ms.
    private func fold(_ src: CGContext, into dst: CGContext, width: Int, height: Int) {
        guard let from = src.data, let to = dst.data else { return }
        if polar?.width != width || polar?.height != height {
            var radius = [Float](repeating: 0, count: width * height), angle = radius
            let cx = Float(width) / 2, cy = Float(height) / 2
            for y in 0..<height {
                for x in 0..<width {
                    let dx = Float(x) + 0.5 - cx, dy = Float(y) + 0.5 - cy
                    radius[y * width + x] = (dx * dx + dy * dy).squareRoot()
                    angle[y * width + x] = atan2(dy, dx)
                }
            }
            polar = (width, height, radius, angle)
        }
        guard let polar else { return }
        let source = from.assumingMemoryBound(to: UInt32.self), target = to.assumingMemoryBound(to: UInt32.self)
        let sourceRow = src.bytesPerRow / 4, targetRow = dst.bytesPerRow / 4
        let wedge = Float.pi / 6, pair = 2 * wedge
        let turn = Float(spin.truncatingRemainder(dividingBy: 2 * .pi))
        let sampled = Float(look.truncatingRemainder(dividingBy: 2 * .pi)) - wedge / 2
        let steps = Float(Self.turnSteps) / (2 * .pi), mask = Self.turnSteps - 1
        let cx = Float(width) / 2, cy = Float(height) / 2
        // How much stands out in each 15° sector round the middle (every fifth pixel, between a sixth and a half of
        // the way out): light drawn on dark artwork, ink on light, so a scene that fills the artwork is judged by its
        // lights (Aurora's curtains, Synthwave's sun) rather than its backdrop. The busiest pair of neighbouring
        // sectors is where to look next.
        let light = style.isLight
        var sectors = [Int](repeating: 0, count: 24)
        let near = Float(min(width, height)) / 6, far = Float(min(width, height)) / 2
        for y in stride(from: 2, to: height, by: 5) {
            for x in stride(from: 2, to: width, by: 5) {
                let i = y * width + x
                let r = polar.radius[i]
                guard r > near, r < far else { continue }
                let sector = min(23, max(0, Int((polar.angle[i] + .pi) / (2 * .pi) * 24)))
                let p = source[y * sourceRow + x]
                let alpha = Int(p >> 24), brightness = (Int(p & 0xFF) + Int((p >> 8) & 0xFF) + Int((p >> 16) & 0xFF)) / 3
                sectors[sector] += light ? max(0, alpha - brightness) : brightness
            }
        }
        var best = 0, most = 0
        for sector in 0..<24 {
            let pair: Int = sectors[sector] + sectors[(sector + 1) % 24]
            if pair > most { best = sector; most = pair }
        }
        if most > 0 {
            let fraction = Double(best + 1) / 24
            busiest = fraction * 2 * Double.pi - Double.pi
        }
        Self.cosines.withUnsafeBufferPointer { cosines in
            Self.sines.withUnsafeBufferPointer { sines in
                polar.radius.withUnsafeBufferPointer { radius in
                    polar.angle.withUnsafeBufferPointer { angle in
                        for y in 0..<height {
                            for x in 0..<width {
                                let i = y * width + x
                                var a = angle[i] - turn
                                a -= (a / pair).rounded(.down) * pair
                                if a > wedge { a = pair - a }
                                let t = Int((a + sampled) * steps) & mask
                                let r = radius[i]
                                let sx = Int((cx + r * cosines[t]).rounded(.down)), sy = Int((cy + r * sines[t]).rounded(.down))
                                target[y * targetRow + x] = sx >= 0 && sx < width && sy >= 0 && sy < height
                                    ? source[sy * sourceRow + sx] : 0
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: VHS

    /// An old tape, worked on the frame's pixels: red and blue pulled a little apart, every other line darkened (over
    /// the artwork too), rows sliding sideways in a tracking band that rolls down the picture and in a wobble on each
    /// kick, a little snow in the band, and the deck's PLAY sign in the corner.
    private func applyVHS(_ ctx: CGContext, width: Int, height: Int, scale: CGFloat) {
        guard let base = ctx.data else { return }
        let stride = ctx.bytesPerRow
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        if row.count != width * 4 { row = [UInt8](repeating: 0, count: width * 4) }
        let fringe = max(1, Int((scale * 0.9).rounded()))
        let line = max(1, Int(scale.rounded()))
        let dark = style.isLight ? 0.07 : 0.16
        // The band: a tenth of the picture, rolling down; rows in it slide by up to 2 pt, more on a kick.
        let bandCentre = (tracking.truncatingRemainder(dividingBy: 1.3) - 0.15) * Double(height)
        let bandHalf = Double(height) * 0.06
        var random = SceneRandom(seed: seed &+ frames &* 0x9E37_79B9)
        let shake = pulse * pulse * 0.55
        row.withUnsafeMutableBufferPointer { saved in
            for y in 0..<height {
                let p = pixels + y * stride
                for i in 0..<(width * 4) { saved[i] = p[i] }
                let fy = Double(y) / Double(height)
                var shift = shake * 3 * Double(scale) * sin(fy * 23 + spin * 9)
                let inBand = abs(Double(y) - bandCentre) < bandHalf
                if inBand { shift += activity * Double(scale) * (1.4 + random.next() * 1.2) }
                let dx = Int(shift.rounded())
                let scan = (y / line) % 2 == 1
                for x in 0..<width {
                    func at(_ x: Int) -> Int { min(max(x - dx, 0), width - 1) * 4 }
                    var r = Double(saved[at(x + fringe)])
                    let g = Double(saved[at(x) + 1])
                    var b = Double(saved[at(x - fringe) + 2])
                    var a = max(Double(saved[at(x) + 3]), r, b)
                    if inBand, activity > 0.5, random.next() < 0.012 {
                        let snow = 160 + random.next() * 95
                        r = snow; b = snow; a = max(a, snow)
                        let o = x * 4
                        p[o] = UInt8(r); p[o + 1] = UInt8(snow); p[o + 2] = UInt8(b); p[o + 3] = UInt8(a)
                        continue
                    }
                    var gg = g
                    if scan {
                        // Darkened: the pixel over a faint black line (premultiplied).
                        r *= 1 - dark; gg *= 1 - dark; b *= 1 - dark
                        a = a + 255 * dark * (1 - a / 255)
                    }
                    let o = x * 4
                    p[o] = UInt8(min(r, a)); p[o + 1] = UInt8(min(gg, a)); p[o + 2] = UInt8(min(b, a)); p[o + 3] = UInt8(a)
                }
            }
        }
        // The deck's sign, top left inside the rounded corner: PLAY and its arrow, or PAUSE and its bars in silence.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setFill(style.isLight ? RGB(0.1, 0.1, 0.12) : RGB(1, 1, 1), 0.82)
        let playing = activity > 0.3
        let word = playing ? "PLAY" : "PAUSE"
        let top: CGFloat = 11, left: CGFloat = 12
        PixelFont.fill(word, in: ctx, at: CGPoint(x: left, y: top), pixel: 1)
        let x = left + CGFloat(PixelFont.width(word) + 2)
        if playing {
            ctx.move(to: CGPoint(x: x, y: top))
            ctx.addLine(to: CGPoint(x: x + 3, y: top + 2.5))
            ctx.addLine(to: CGPoint(x: x, y: top + 5))
            ctx.closePath()
            ctx.fillPath()
        } else {
            ctx.fill([CGRect(x: x, y: top, width: 1, height: 5), CGRect(x: x + 2, y: top, width: 1, height: 5)])
        }
        ctx.restoreGState()
    }
}

/// When the rotation moves on, and to what: every `interval` seconds of music to the next scene in the rotation's
/// order; and with the music, once a scene has had a fair turn: a breakdown hands a lively scene over to the next calm
/// one (and the timer keeps to calm scenes until it ends), and the drop hands a calm scene over to the next lively one.
/// A genre with scenes that suit it (`Visualizer.suited(toGenre:)`) gets those first when the music asks for a mood.
nonisolated struct VisualizerRotation: Equatable {
    typealias Mode = ModernPlayerState.Visualizer

    var interval: Double
    /// The genre playing (its suited scenes come first for a mood).
    var genre: String?
    /// Seconds the current scene has shown.
    private(set) var elapsed: Double = 0
    /// In a breakdown, as the rotation hears it (with some hysteresis).
    private(set) var inBreakdown = false

    /// A scene shows at least this long before the music moves it on.
    static let fairTurn = 4.0

    init(interval: Double, genre: String? = nil) {
        self.interval = interval
        self.genre = genre
    }

    /// Advances by `dt`; true when it is time for the next scene (and the clock starts again).
    mutating func advance(_ dt: Double) -> Bool {
        elapsed += max(0, dt.isFinite ? dt : 0)
        guard elapsed >= max(interval, 1) else { return false }
        elapsed = 0
        return true
    }

    /// Advances by `dt` with the music while `showing` shows; the scene to change to, if it is time.
    mutating func advance(_ dt: Double, input: VisualizerInput, showing: Mode?) -> Mode? {
        let wasInBreakdown = inBreakdown
        if input.breakdown > 0.6 { inBreakdown = true } else if input.breakdown < 0.2 { inBreakdown = false }
        if advance(dt) { return next(after: showing, calm: inBreakdown ? true : nil) }
        guard let showing, elapsed >= Self.fairTurn else { return nil }
        if inBreakdown, !wasInBreakdown, !showing.isCalm {
            elapsed = 0
            return next(after: showing, calm: true)
        }
        if input.drop, showing.isCalm {
            elapsed = 0
            return next(after: showing, calm: false)
        }
        return nil
    }

    mutating func restart() { elapsed = 0 }

    /// The scene after `mode` in the rotation; with `calm`, the next of that mood, one that suits the genre if any
    /// does.
    func next(after mode: Mode?, calm: Bool?) -> Mode {
        guard let calm else { return Self.next(after: mode) }
        let suited = Set(Mode.suited(toGenre: genre).filter { $0.isCalm == calm })
        var order: [Mode] = []
        var candidate = Self.next(after: mode)
        for _ in Mode.rotation {
            order.append(candidate)
            candidate = candidate.nextScene
        }
        return order.first { suited.contains($0) && $0 != mode } ?? order.first { $0.isCalm == calm && $0 != mode }
            ?? Self.next(after: mode)
    }

    /// The scene after `mode` in the rotation.
    static func next(after mode: ModernPlayerState.Visualizer?) -> ModernPlayerState.Visualizer {
        (mode ?? .off).nextScene
    }

    /// The scene to open a genre with: the first that suits it, or nil to carry on (a genre with none, or the scene
    /// showing suits it already).
    static func opening(forGenre genre: String?, showing: Mode?) -> Mode? {
        let suited = Mode.suited(toGenre: genre)
        if let showing, suited.contains(showing) { return nil }
        return suited.first
    }
}
