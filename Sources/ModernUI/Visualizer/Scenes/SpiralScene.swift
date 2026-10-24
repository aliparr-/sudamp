// SPDX-License-Identifier: GPL-3.0-or-later
// Spiral: a ride down a glass helter-skelter. A frosted glass tube winds down round an open shaft in a tall round hall,
// and the camera rides along just above it, looking in across the shaft and down: the tube beside it sweeps up and
// arches over, the turns below ring the shaft one inside another, and the hall's honeycomb wall, with lights in some
// of its cells, streaks past through the glass. The glass is drawn as fine strands round the tube that crowd towards
// its bright edges, with light streaking along them and rings round it, blurring as they rush by. The ride goes faster
// when the music is loud, surges on every kick and hurtles after the drop (the picture rushing in on itself); it slows
// through a breakdown and stops in silence. Each kick lights a band round the tube ahead in the artwork's spark
// colours, the drop a white one, and the hall's lights flicker with the treble. On light artwork the hall is pale and
// the glass smoked. A seed varies where along the tube the ride starts and the hall's lights.
//
// The spiral is the same at every turn and the camera keeps its place beside it, so what each pixel sees is worked
// out once for a size (`Geometry`): where its ray passes each turn of the tube, and how close to the tube's middle,
// which says how much glass it looks through; and where it meets the hall. Each frame then only shades that, moving
// the textures along. The tube's height is a smooth function of the angle round the shaft, so a ray's passes come
// from one equation along it, with no stepping through the scene. It asks for 60 frames a second, where other scenes
// draw 30, and works on bands of rows side by side; on a Retina screen it works at 1.5 pixels a point and is
// smoothed up.

import CoreGraphics
import Foundation

nonisolated final class SpiralScene: VisualizerScene {
    /// A band of light round the tube, lit by a kick.
    private struct Glow {
        /// Where it lies along the tube (radians of the ride), how bright, its colour's place along the sparks
        /// (negative: white), and how long since it lit.
        var along: Double
        var strength: Double
        var hue: Double
        var age: Double
    }

    /// The frame's buffers, shared by the bands of rows worked on side by side. The pointers don't outlive the
    /// `withUnsafe…` calls `concurrentPerform` runs inside, which returns once every band is done.
    // SAFETY: each band writes only its own rows of `out`, and the other buffers are only read while bands run.
    private struct Buffers: @unchecked Sendable {
        let out: UnsafeMutablePointer<UInt32>
        let glows: UnsafePointer<Float>
        let flow: UnsafePointer<Float>
        let geometry: UnsafePointer<Float>
    }

    /// The colours, as floats for the pixel loop.
    private struct Paints {
        var style: SceneStyle
        var glass: Shade
        var rim: Shade
        /// The hall's colours, a quarter of the way round each, and how bright its cells and their edges are.
        var hall: Hall
        var cell: Float
        var line: Float
        var lamp: Shade
        var abyss: Shade
        var light: Bool
    }

    // MARK: The world (lengths in units of the radius the tube's middle winds at)

    /// The tube: the radius its middle winds round the shaft at (1), how thick it is, how far it drops in a turn, and
    /// which way it turns going down (-1: clockwise seen from above).
    private static let tube: Float = 0.24
    private static let pitch: Float = 0.95
    private static let turning: Float = -1
    /// The camera rides just above the tube, this far from the spiral's middle.
    private static let flight = 0.95
    /// The hall's wall, and how many hexagons go round it.
    private static let hall: Float = 2.6
    private static let columns = 36
    /// The camera's height above the middle of the tube beneath it.
    private static let eye = 0.4
    /// How far it looks.
    private static let reach: Float = 16
    /// Fine strands round the tube's half that shows, and rings round a turn.
    private static let strands: Float = 12
    private static let ribs: Float = 36
    /// Pixels per point it works at, at most.
    private static let maxScale: CGFloat = 1.5
    /// The kick table: entries per radian along the tube, from a turn behind the camera to six ahead.
    private static let glowSteps: Float = 40
    private static let glowFrom: Float = -2 * .pi
    private static let glowCount = Int(14 * Float.pi * 40)

    private var along: Double
    private var speed = 0.0
    private var activity = 0.0
    private var pulse = 0.0
    private var calm = 0.0
    private var sinceDrop = 10.0
    private var treble = 0.0
    private var frameTime = 1.0 / 60
    private var glows: [Glow] = []
    private var glowCount = 0
    private let hueStep: Double
    private let lightSeed: UInt32
    /// Smooth noise, 0...1, wrapping: the light running along the strands.
    private let flow: [Float]
    private static let flowCount = 256
    /// Its features per turn of the tube.
    private static let flowPerTurn: Double = 40

    private var paints: Paints?
    private var pixels: [UInt32] = []
    /// Per step along the tube from `glowFrom`: the kicks' light (r, g, b).
    private var glowTable = [Float](repeating: 0, count: glowCount * 3)

    var glow: Double { 0 }
    var framesPerSecond: Int { 60 }

    init(seed: UInt64) {
        var random = SceneRandom(seed: seed)
        along = random.range(0, 2 * .pi)
        hueStep = random.chance(0.5) ? 0.38 : -0.38
        glowCount = random.int(8)
        lightSeed = UInt32(random.int(1 << 30))
        let lattice = (0..<Self.flowCount).map { _ in Float(random.next()) }
        // Every fourth entry a random height, smoothly between (so a feature spans about four entries).
        flow = (0..<Self.flowCount).map { i in
            let a = lattice[(i / 4 * 4) % Self.flowCount], b = lattice[(i / 4 * 4 + 4) % Self.flowCount]
            let t = Float(i % 4) / 4
            return a + (b - a) * t * t * (3 - 2 * t)
        }
    }

    // MARK: Update

    func update(_ input: VisualizerInput, dt: Double) {
        let dt = min(max(dt.isFinite ? dt : 0, 0), 0.1)
        frameTime = dt
        let level = Double(input.level), bass = Double(input.bass)
        let target = input.isSilent ? 0 : smoothstep(0.02, 0.1, level)
        activity += (target - activity) * (1 - exp(-dt / (target > activity ? 0.12 : 0.06)))
        if target == 0, activity < 0.02 { activity = 0 }
        pulse = Double(input.pulse) * activity
        calm += (Double(input.breakdown) - calm) * (1 - exp(-dt / 0.4))
        treble += (Double(input.treble) * activity - treble) * (1 - exp(-dt / 0.05))
        if activity == 0 { treble = 0 }
        if input.drop { sinceDrop = 0 } else { sinceDrop += dt }

        // Radians of the spiral a second: a turn in about two and a half seconds, faster when loud, a surge on each
        // kick, slow through a breakdown, and a rush after the drop.
        let rush = sinceDrop < 5 ? exp(-sinceDrop / 1.3) : 0
        let cruise = (1.5 + 1.6 * level + 1.2 * bass) * (1 + 0.6 * pulse) * (1 - 0.55 * calm) * (1 + 1.6 * rush)
        let wanted = activity * cruise
        // In silence it comes to a stop in about half a second.
        speed += (wanted - speed) * (1 - exp(-dt / (wanted > speed ? 0.15 : wanted == 0 ? 0.04 : 0.1)))
        if wanted == 0, speed < 0.03 { speed = 0 }
        along += speed * dt

        for i in glows.indices {
            glows[i].age += dt
            if activity < 0.05 { glows[i].strength *= exp(-dt / 0.04) }
        }
        glows.removeAll { $0.along < along - 1 || $0.strength < 0.03 }
        guard activity > 0.4, glows.count < 12 else { return }
        if input.drop {
            glowCount += 1
            glows.append(Glow(along: along + 1.6, strength: 1.5, hue: -1, age: 0))
        } else if input.beat {
            glowCount += 1
            let strength = (0.6 + 0.6 * bass) * (1 - 0.5 * calm)
            glows.append(Glow(along: along + 2.2 + 0.3 * speed, strength: strength, hue: Double(glowCount) * hueStep,
                              age: 0))
        }
    }

    // MARK: Draw

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let w = size.width, h = size.height
        guard w >= 1, h >= 1 else { return }
        // Worked out a pixel at a time and drawn one to one; on a Retina screen, at a lower resolution and smoothed up
        // (much of what shows is blurred by its motion, and four times the pixels would cost four times the work).
        let screen = min(max(abs(ctx.userSpaceToDeviceSpaceTransform.a), 1), 3)
        let scale = min(screen, Self.maxScale)
        let smoothed = scale < screen
        let cols = Int((w * scale).rounded()), rows = Int((h * scale).rounded())
        guard cols > 0, rows > 0, cols <= 1024, rows <= 1024 else { return }
        if paints?.style != style { paints = Self.paints(style) }
        guard let paints else { return }
        if pixels.count != cols * rows { pixels = [UInt32](repeating: 0, count: cols * rows) }
        prepareGlows(paints.style)
        render(cols: cols, rows: rows, paints: paints)

        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: cols * 4, space: sceneColorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: smoothed, intent: .defaultIntent)
        else { return }
        // After the drop, the picture rushes in on itself.
        let rush = sinceDrop < 4 ? CGFloat(exp(-sinceDrop / 1.1)) * 0.14 : 0
        ctx.saveGState()
        ctx.interpolationQuality = smoothed || rush > 0.002 ? .medium : .none
        ctx.translateBy(x: w / 2, y: h / 2)
        ctx.scaleBy(x: 1 + rush, y: -(1 + rush))
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    /// The kicks' bands of light along the tube, as a table from a turn behind the camera.
    private func prepareGlows(_ style: SceneStyle) {
        let lit = glows.map { glow -> (Double, Double, Double, Double) in
            let colour = glow.hue < 0 ? RGB.white : colourAt(glow.hue, style)
            // Each band brightens over a moment as it appears.
            let s = glow.strength * min(1, glow.age / 0.12)
            return (colour.r * s, colour.g * s, colour.b * s, glow.along - along)
        }
        for i in 0..<Self.glowCount {
            let x = Double(Self.glowFrom) + Double(i) / Double(Self.glowSteps)
            var r = 0.0, g = 0.0, b = 0.0
            for glow in lit {
                let t = (x - glow.3) / 0.12
                guard abs(t) < 3 else { continue }
                let k = exp(-t * t)
                r += glow.0 * k
                g += glow.1 * k
                b += glow.2 * k
            }
            glowTable[i * 3] = Float(r)
            glowTable[i * 3 + 1] = Float(g)
            glowTable[i * 3 + 2] = Float(b)
        }
    }

    // MARK: Geometry

    /// What each pixel sees, worked out once for a size. The camera rides the spiral at a fixed place and angle to
    /// it, and the spiral is the same at every turn, so the picture's geometry never changes: only the textures move
    /// past (light along the strands, the rings, the hall's honeycomb, the kicks), shaded afresh each frame.
    private struct Geometry {
        var cols: Int
        var rows: Int
        /// Per pixel, `stride` floats: the hall's wall (where on it, in hexagons round and rows up from the camera's
        /// level, the pixel's width on it, and its light, 0 for none), how many passes of the tube, then per pass
        /// (`passStride` floats): along the spiral from the camera (radians), its light, how much of the pixel it
        /// covers, how much glass the eye looks through at its edge, its rim, its strands, which strand, and the
        /// pixel's width in rings.
        var data: [Float]

        static let wallFloats = 5
        static let passStride = 8
        static let stride = wallFloats + passStride * Passes.capacity
    }

    private var geometry: Geometry?

    /// The camera, at the start of the ride (the geometry is the same anywhere along it): its position, and its
    /// forward, right and up (right and up scaled to one pixel).
    private typealias Vector = (Float, Float, Float)

    private static func camera(cols: Int, rows: Int) -> (position: Vector, f: Vector, r: Vector, u: Vector) {
        let sigma = Double(turning), pitch = Double(pitch), radius = flight
        // Just above the tube, looking in across the shaft and down (steeper this far in, as the spiral is).
        let yaw = 0.9, tilt = 0.65 + atan(pitch / (2 * .pi * radius)), bank = 0.16
        let tangent = (0.0, sigma), inward = (-1.0, 0.0)
        let hx = tangent.0 * cos(yaw) + inward.0 * sin(yaw), hy = tangent.1 * cos(yaw) + inward.1 * sin(yaw)
        let f = (hx * cos(tilt), hy * cos(tilt), -sin(tilt))
        // Right is forward × up; up is right × forward.
        var r = (f.1, -f.0, 0.0)
        let rl = (r.0 * r.0 + r.1 * r.1).squareRoot()
        r = (r.0 / rl, r.1 / rl, 0)
        var u = (r.1 * f.2 - r.2 * f.1, r.2 * f.0 - r.0 * f.2, r.0 * f.1 - r.1 * f.0)
        // Banked into the turn.
        let (cb, sb) = (cos(bank * sigma), sin(bank * sigma))
        (r, u) = ((r.0 * cb + u.0 * sb, r.1 * cb + u.1 * sb, r.2 * cb + u.2 * sb),
                  (u.0 * cb - r.0 * sb, u.1 * cb - r.1 * sb, u.2 * cb - r.2 * sb))
        // A wide lens.
        let perPixel = 1 / (Double(min(cols, rows)) * 0.34)
        func v(_ t: (Double, Double, Double), _ k: Double = 1) -> (Float, Float, Float) {
            (Float(t.0 * k), Float(t.1 * k), Float(t.2 * k))
        }
        return ((Float(radius), 0, Float(eye)), v(f), v(r, perPixel), v(u, perPixel))
    }

    /// Works out what every pixel sees.
    private static func makeGeometry(cols: Int, rows: Int) -> Geometry {
        let cam = camera(cols: cols, rows: rows)
        let (ox, oy, oz) = cam.position
        let pitch = pitch, tube = tube, hall = hall, reach = reach
        // The slope of the tube's middle, and how far either side of a turn (in turns) the tube reaches.
        let lean = 1 / (1 + (pitch / (2 * .pi)) * (pitch / (2 * .pi))).squareRoot()
        let tubeTurns = tube / (pitch * lean)
        let c0 = ox * ox + oy * oy
        // The camera's place in the spiral's turns: 0 level with the tube's middle, 1 with the turn above.
        let hCam = oz / pitch
        let turnPerRadian = turning / (2 * .pi)
        let pixelSize = (cam.r.0 * cam.r.0 + cam.r.1 * cam.r.1 + cam.r.2 * cam.r.2).squareRoot()
        let hexWorld = 2 * .pi * hall / Float(columns), hexRow: Float = 0.866_025_4
        let stride = Geometry.stride, passStride = Geometry.passStride
        var data = [Float](repeating: 0, count: cols * rows * stride)
        data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for py in 0..<rows {
                let sy = Float(rows) / 2 - Float(py) - 0.5
                for px in 0..<cols {
                    let out = base + (py * cols + px) * stride
                    let sx = Float(px) + 0.5 - Float(cols) / 2
                    var dx = cam.f.0 + sx * cam.r.0 + sy * cam.u.0
                    var dy = cam.f.1 + sx * cam.r.1 + sy * cam.u.1
                    var dz = cam.f.2 + sx * cam.r.2 + sy * cam.u.2
                    let norm = 1 / (dx * dx + dy * dy + dz * dz).squareRoot()
                    dx *= norm
                    dy *= norm
                    dz *= norm
                    // Seen from above, the ray is at a distance from the shaft's middle of sqrt(c0 + 2bs + as^2).
                    let a = dx * dx + dy * dy, b = ox * dx + oy * dy, cr = ox * dy - oy * dx
                    let ray = Ray(a: a, b: b, cr: cr, c0: c0, rise: dz / pitch, hCam: hCam, turn: turnPerRadian)

                    // The hall behind: its wall, or the dark of the shaft far below (or above).
                    if let sWall = ray.leaves(radius: hall), sWall < reach {
                        let depth = -sWall * dz
                        let lit = 1 / (1 + greater(depth, 0) * 0.2 + greater(-depth, 0) * 0.08)
                        // Fading out well before the furthest it looks, so the shaft's depths go smoothly dark.
                        let fade = lesser(1, greater(0, (reach - sWall) / (0.4 * reach)))
                        let fog = fade * fade / (1 + sWall * sWall * 0.012)
                        out[0] = fastAtan2(sWall * cr, c0 + sWall * b) * Float(columns) / (2 * .pi)
                        out[1] = (oz + sWall * dz) / (hexWorld * hexRow)
                        out[2] = sWall * pixelSize * norm / (greater(a.squareRoot(), 0.05) * hexWorld)
                        out[3] = lit * lit * fog
                    }

                    // Where the ray passes near the tube's turns, inside the band of radii the tube fills.
                    var passes = Passes()
                    let band = ray.band(1 - tube, 1 + tube, reach: reach)
                    if band.0 < band.1 {
                        ray.passes(from: band.0, to: band.1, near: tubeTurns, tube: tube, lean: lean, pitch: pitch,
                                   into: &passes)
                    }
                    if band.2 < band.3 {
                        ray.passes(from: band.2, to: band.3, near: tubeTurns, tube: tube, lean: lean, pitch: pitch,
                                   into: &passes)
                    }
                    // A hollow tube shows most at its edges, where the eye looks through the most glass, and least
                    // across its middle.
                    var count = 0
                    for i in 0..<passes.count {
                        let pass = passes[i]
                        let s = pass.s, q = pass.q
                        let foot = s * pixelSize * norm / tube
                        let cover = lesser(1, greater(0, 0.5 + (1 - q) / greater(foot, 1e-4)))
                        guard cover > 0 else { continue }
                        let face = (greater(0, 1 - q * q)).squareRoot()
                        // Strands evenly round the tube, so they crowd towards its edges.
                        let round = asinApprox(lesser(q, 1)) * strands * 0.636_62
                        let o = out + Geometry.wallFloats + count * passStride
                        o[0] = 2 * .pi * (pass.dh * pitch - oz - s * dz) / pitch
                        // Light: from above, fading with depth below the camera and with distance.
                        let fade = lesser(1, greater(0, (reach - s) / (0.4 * reach)))
                        o[1] = fade * fade / (1 + greater(-s * dz, 0) * 0.15 + s * 0.05)
                        o[2] = cover * fade
                        o[3] = (1 - face) * (1 - face)
                        o[4] = line(1 - q, foot: foot, width: 0.09)
                        o[5] = lines(round, foot: foot * strands * 0.636_62 / greater(face, 0.2), width: 0.1)
                        o[6] = floorf(round)
                        o[7] = foot * tube * ribs / 6
                        count += 1
                    }
                    out[4] = Float(count)
                }
            }
        }
        return Geometry(cols: cols, rows: rows, data: data)
    }

    private func render(cols: Int, rows: Int, paints: Paints) {
        if geometry?.cols != cols || geometry?.rows != rows { geometry = Self.makeGeometry(cols: cols, rows: rows) }
        guard let geometry else { return }
        let pitch = Double(Self.pitch)
        // Where the camera has got to: round the hall (in hexagons) and down it (in rows of them, wrapped).
        let columns = Double(Self.columns)
        let angle = Double(Self.turning) * along
        let hexColumn = Float((angle / (2 * .pi) * columns).truncatingRemainder(dividingBy: columns))
        let hexWorld = 2 * .pi * Double(Self.hall) / columns
        let rowsDown = -pitch * along / (2 * .pi) / (hexWorld * 0.866_025_4)
        let hexDown = Float(rowsDown.truncatingRemainder(dividingBy: 1024))
        // Motion while the shutter is open (the whole frame, as the video's camera blurs): radians along the tube.
        let travel = Float(speed * frameTime)
        let ribBlur = travel * Self.ribs / (2 * .pi)
        let hexBlur = travel * Float(Self.columns) / (2 * .pi)
        let light = paints.light
        let glass = paints.glass, rimColour = paints.rim, hallPaint = paints.hall
        let cellLevel = paints.cell, lineLevel = paints.line
        let lamp = paints.lamp, abyss = paints.abyss
        let glowFrom = Self.glowFrom, glowSteps = Self.glowSteps, glowLast = Float(Self.glowCount - 1)
        let ribs = Self.ribs
        let flicker = Float(treble), beat = Float(pulse)
        let seed = lightSeed
        let ribStart = Float(along.truncatingRemainder(dividingBy: 2 * .pi))
        let flowPerRadian = Float(Self.flowPerTurn / (2 * .pi)) * 4
        let flowBase = Float((along * Self.flowPerTurn / (2 * .pi) * 4)
            .truncatingRemainder(dividingBy: Double(Self.flowCount)))
        let flowBlur = travel * flowPerRadian / 4
        let stride = Geometry.stride, passStride = Geometry.passStride, wallFloats = Geometry.wallFloats

        pixels.withUnsafeMutableBufferPointer { pixels in
        glowTable.withUnsafeBufferPointer { glowTable in
        flow.withUnsafeBufferPointer { flowTable in
        geometry.data.withUnsafeBufferPointer { data in
            guard let out = pixels.baseAddress, let G = glowTable.baseAddress, let F = flowTable.baseAddress,
                  let D = data.baseAddress else { return }
            // Rows are independent: bands of them are worked on side by side, each writing only its own rows.
            let buffers = Buffers(out: out, glows: G, flow: F, geometry: D)
            let bands = Swift.min(4, Swift.max(1, rows / 16))
            DispatchQueue.concurrentPerform(iterations: bands) { band in
            let out = buffers.out, G = buffers.glows, F = buffers.flow, D = buffers.geometry
            for py in (rows * band / bands)..<(rows * (band + 1) / bands) {
                for px in 0..<cols {
                    let at = py * cols + px
                    let g = D + at * stride
                    // The hall behind, turning past.
                    var colour = abyss
                    if g[3] > 0 {
                        let wall = Self.wall(g[0] + hexColumn, g[1] + hexDown, foot: g[2], blur: hexBlur,
                                             hall: hallPaint, cell: cellLevel, line: lineLevel, lamp: lamp,
                                             flicker: flicker, seed: seed, columns: Int32(Self.columns))
                        colour = abyss + (wall - abyss) * g[3]
                    }
                    // The glass, furthest first.
                    var i = Int(g[4]) - 1
                    while i >= 0 {
                        let p = g + wallFloats + i * passStride
                        i -= 1
                        let ahead = p[0], lit = p[1]
                        // Light streaks along the strands, flowing past and blurring with the speed.
                        let streak = Self.flow(F, flowBase + ahead * flowPerRadian + p[6] * 37, blur: flowBlur)
                        let strand = p[5] * (0.3 + 1.4 * streak * streak)
                        // Rings round the tube, blurred by the motion.
                        let rib = Self.ribs((ahead + ribStart) * ribs / (2 * .pi), width: ribBlur + p[7])
                        let k = Int(lesser(greater((ahead - glowFrom) * glowSteps, 0), glowLast)) * 3
                        let kick = Shade(G[k], G[k + 1], G[k + 2])
                        let edge = p[3], rim = p[4]
                        let alpha = p[2] * lesser(1, 0.2 + 0.5 * edge + 0.6 * rim + 0.45 * strand + 0.1 * rib)
                        if light {
                            let ink = glass * (0.6 + 0.4 * lit)
                            colour = colour + (ink - colour) * lesser(1, alpha * 1.2)
                        } else {
                            let shine = glass * (lit * (0.5 + 0.6 * edge + 0.9 * strand + 0.35 * rib + 0.25 * beat))
                                + rimColour * (lit * rim) + kick * (0.6 + rim + strand)
                            colour = colour * (1 - 0.55 * alpha) + shine * alpha
                        }
                    }
                    out[at] = Self.pack(colour)
                }
            }
            }
        }}}}
    }

    // MARK: Ray

    /// A ray from the camera, seen from above (the a, b, cr and c0 terms) and in the spiral's turns.
    private struct Ray {
        var a: Float, b: Float, cr: Float, c0: Float
        /// Turns climbed per unit along the ray, and the camera's place in the turns.
        var rise: Float, hCam: Float
        /// Turns per radian round the shaft (signed by the way the spiral turns).
        var turn: Float

        /// Where it gets `radius` from the shaft's middle going out (nil if it never does).
        @inline(__always)
        func leaves(radius: Float) -> Float? {
            guard a > 1e-7 else { return nil }
            let disc = b * b - a * (c0 - radius * radius)
            guard disc > 0 else { return nil }
            return (-b + disc.squareRoot()) / a
        }

        /// The stretches of the ray (up to two, empty when start ≥ end) between `inner` and `outer` from the shaft's
        /// middle, out to `reach`.
        @inline(__always)
        func band(_ inner: Float, _ outer: Float, reach: Float) -> (Float, Float, Float, Float) {
            let none = (Float(0), Float(0), Float(0), Float(0))
            let out = lesser(leaves(radius: outer) ?? reach, reach)
            // Starting inside the inner circle: out through it, then on to the outer one.
            if c0 < inner * inner {
                guard let s0 = leaves(radius: inner) else { return none }
                return (s0, out, 0, 0)
            }
            // Starting in the band: on until it heads in through the inner circle (if it does), and from where it
            // comes out of it again.
            guard a > 1e-7, b < 0 else { return (0, out, 0, 0) }
            let disc = b * b - a * (c0 - inner * inner)
            guard disc > 0 else { return (0, out, 0, 0) }
            let q = disc.squareRoot()
            return (0, lesser((-b - q) / a, out), (-b + q) / a, out)
        }

        /// Its place in the spiral's turns at `s`: a whole number level with the middle of a turn of the tube.
        @inline(__always)
        func phase(_ s: Float) -> Float { hCam + s * rise + turn * fastAtan2(s * cr, c0 + s * b) }

        @inline(__always)
        func slope(_ s: Float) -> Float { rise + turn * cr / greater(c0 + (2 * b + a * s) * s, 1e-6) }

        /// Where the phase reaches `target` between `p0` and `p1` (phases `h0`, `h1`, the phase monotonic between).
        @inline(__always)
        func solve(_ target: Float, _ p0: Float, _ h0: Float, _ p1: Float, _ h1: Float) -> Float {
            if target == h0 { return p0 }
            if target == h1 { return p1 }
            var s = p0 + (target - h0) / (h1 - h0) * (p1 - p0)
            s -= (phase(s) - target) / slope(s)
            return lesser(greater(s, lesser(p0, p1)), greater(p0, p1))
        }

        /// How far from the shaft's middle it is at `s`.
        @inline(__always)
        func radius(_ s: Float) -> Float { greater(c0 + (2 * b + a * s) * s, 0).squareRoot() }

        /// The tube's turns the ray passes near between `sa` and `sb` (where it is within the band of radii the tube
        /// fills), nearest first: where it comes closest to each turn's middle, and how close.
        @inline(__always)
        func passes(from sa: Float, to sb: Float, near reach: Float, tube: Float, lean: Float, pitch: Float,
                    into passes: inout Passes) {
            guard sb > sa else { return }
            // The phase turns back where the climb and the turning cancel, at one distance from the middle.
            var cuts = (sa, sb, sb, sb)
            var n = 2
            if rise != 0, a > 1e-7 {
                let r2 = -turn * cr / rise
                if r2 > 0 {
                    let disc = b * b - a * (c0 - r2)
                    if disc > 0 {
                        let q = disc.squareRoot()
                        let e1 = (-b - q) / a, e2 = (-b + q) / a
                        if e1 > sa, e1 < sb {
                            cuts = (sa, e1, sb, sb)
                            n = 3
                        }
                        if e2 > sa, e2 < sb {
                            if n == 3 {
                                cuts = (sa, e1, e2, sb)
                                n = 4
                            } else {
                                cuts = (sa, e2, sb, sb)
                                n = 3
                            }
                        }
                    }
                }
            }
            var p0 = cuts.0, h0 = phase(p0)
            var lastK: Float = .nan
            for piece in 1..<n {
                let p1 = piece == 1 ? cuts.1 : piece == 2 ? cuts.2 : cuts.3
                let h1 = phase(p1)
                let up = h1 > h0
                let lo = lesser(h0, h1), hi = greater(h0, h1)
                // Each turn within reach of the phases here: the stretch of the ray near it, and the closest point
                // of that stretch to the turn's middle, in the tube's cross-section (out from the shaft, and up
                // square to the tube's slope), taking the stretch as two straight pieces through its middle.
                var k = up ? (lo - reach).rounded(.up) : (hi + reach).rounded(.down)
                while up ? k <= hi + reach : k >= lo - reach {
                    defer { k += up ? 1 : -1 }
                    let enter = up ? greater(k - reach, lo) : lesser(k + reach, hi)
                    let leave = up ? lesser(k + reach, hi) : greater(k - reach, lo)
                    guard up ? enter < leave : enter > leave else { continue }
                    let sA = solve(enter, p0, h0, p1, h1), sB = solve(leave, p0, h0, p1, h1)
                    let scale = pitch * lean
                    let a0 = (radius(sA) - 1, (enter - k) * scale), a2 = (radius(sB) - 1, (leave - k) * scale)
                    let near: (Float, Float, Float)
                    if sB - sA < 0.2 {
                        // A short stretch is straight enough.
                        let only = closest(a0, a2)
                        near = (only.d, sA + (sB - sA) * only.t, enter + (leave - enter) * only.t)
                    } else {
                        let sM = 0.5 * (sA + sB), hM = phase(sM)
                        let a1 = (radius(sM) - 1, (hM - k) * scale)
                        let first = closest(a0, a1), second = closest(a1, a2)
                        near = first.d <= second.d
                            ? (first.d, sA + (sM - sA) * first.t, enter + (hM - enter) * first.t)
                            : (second.d, sM + (sB - sM) * second.t, hM + (leave - hM) * second.t)
                    }
                    let q = near.0 / tube
                    guard q < 1.2 else { continue }
                    let dh = near.2 - k
                    // The same turn carried on from the piece before (the phase turned back inside it): keep the
                    // closer of the two.
                    if k == lastK, passes.count > 0, passes.last.q <= q { continue }
                    if k == lastK, passes.count > 0 {
                        passes.replaceLast(Pass(s: near.1, q: q, dh: dh))
                    } else {
                        passes.add(Pass(s: near.1, q: q, dh: dh))
                        if passes.count == Passes.capacity { return }
                    }
                    lastK = k
                }
                p0 = p1
                h0 = h1
            }
        }
    }

    /// The point of the segment from `p` to `q` nearest the origin: its distance, and how far along.
    @inline(__always)
    private static func closest(_ p: (Float, Float), _ q: (Float, Float)) -> (d: Float, t: Float) {
        let ex = q.0 - p.0, ey = q.1 - p.1
        let len = ex * ex + ey * ey
        let t = len > 1e-12 ? lesser(1, greater(0, -(p.0 * ex + p.1 * ey) / len)) : 0
        let x = p.0 + ex * t, y = p.1 + ey * t
        return ((x * x + y * y).squareRoot(), t)
    }

    /// Where a ray comes closest to a turn of the tube: how far along, how far from the tube's middle (in tube
    /// radii), and how far in turns from the turn's middle line.
    private struct Pass {
        var s: Float
        var q: Float
        var dh: Float
    }

    /// The nearest few passes along a ray.
    private struct Passes {
        static let capacity = 4
        private var p = (Pass(s: 0, q: 0, dh: 0), Pass(s: 0, q: 0, dh: 0), Pass(s: 0, q: 0, dh: 0),
                         Pass(s: 0, q: 0, dh: 0))
        private(set) var count = 0

        var last: Pass { self[count - 1] }

        @inline(__always)
        mutating func add(_ value: Pass) {
            count += 1
            replaceLast(value)
        }

        @inline(__always)
        mutating func replaceLast(_ value: Pass) {
            switch count {
            case 1: p.0 = value
            case 2: p.1 = value
            case 3: p.2 = value
            default: p.3 = value
            }
        }

        @inline(__always)
        subscript(_ i: Int) -> Pass { i == 0 ? p.0 : i == 1 ? p.1 : i == 2 ? p.2 : p.3 }
    }

    // MARK: Patterns

    /// A thin line at distance `d` (world units), `width` wide, over a pixel `foot` across: 1 on it, its light spread
    /// as the pixel grows.
    @inline(__always)
    private static func line(_ d: Float, foot: Float, width: Float) -> Float {
        let reach = width + foot
        return greater(0, 1 - d / reach) * lesser(1, 2 * width / reach)
    }

    /// Evenly spaced lines halfway between whole numbers of `x`, `width` of a spacing wide.
    @inline(__always)
    private static func lines(_ x: Float, foot: Float, width: Float) -> Float {
        let d = (x - floorf(x) - 0.5).magnitude
        return line(d, foot: foot, width: width)
    }

    /// Ribs at whole numbers of `x`, box-filtered over `width` (the pixel and the motion).
    @inline(__always)
    private static func ribs(_ x: Float, width: Float) -> Float {
        let duty: Float = 0.12
        let half = 0.5 * width + 1e-4
        let hi = x + half, lo = x - half
        let fh = floorf(hi), fl = floorf(lo)
        return ((fh * duty + lesser(hi - fh, duty)) - (fl * duty + lesser(lo - fl, duty))) / (2 * half)
    }

    /// The flow noise at `x` (entries, wrapping), its swing eased towards the middle as `blur` (features) grows.
    @inline(__always)
    private static func flow(_ table: UnsafePointer<Float>, _ x: Float, blur: Float) -> Float {
        let base = floorf(x), t = x - base
        let i = Int(base) & (flowCount - 1)
        let a = table[i], b = table[(i + 1) & (flowCount - 1)]
        return 0.5 + (a + (b - a) * t - 0.5) / (1 + 4 * blur * blur)
    }

    /// The hall's wall at (x, y) in hexagon widths: dark cells, their edges lit, and lights in some, streaked by the
    /// motion (`blur`, in hexagon widths).
    @inline(__always)
    private static func wall(_ x: Float, _ y: Float, foot: Float, blur: Float, hall: Hall, cell: Float, line: Float,
                             lamp: Shade, flicker: Float, seed: UInt32, columns: Int32) -> Shade {
        guard x.magnitude < 1e6, y.magnitude < 1e6 else { return Shade(0, 0, 0) }
        // Pointy-topped hexagons a unit wide, rows 0.866 apart, odd rows shifted half a hexagon. A cell reaches two
        // thirds of the way to the next row, so the nearest centre is in one of the two rows either side.
        let below = floorf(y)
        let odd: Float = Int32(below) & 1 == 0 ? 0 : 0.5
        let c0 = floorf(x - odd + 0.5) + odd, c1 = floorf(x - (0.5 - odd) + 0.5) + 0.5 - odd
        let e0 = x - c0, e1 = x - c1, f = (y - below) * 0.866_025_4, g = f - 0.866_025_4
        let upper = e1 * e1 + g * g < e0 * e0 + f * f
        let cx = upper ? c1 : c0, cy = upper ? below + 1 : below
        let lx = upper ? e1 : e0, ly = upper ? g : f
        // Distance in from the cell's edge (0.5 at the middle).
        let edge = 0.5 - greater(lx.magnitude, 0.5 * lx.magnitude + 0.866_025_4 * ly.magnitude)
        let column = (Int32(floorf(cx)) % columns + columns) % columns
        let hash = mix(UInt32(bitPattern: column), UInt32(bitPattern: Int32(cy)), seed)
        let shade = 0.55 + 0.45 * Float(hash & 0xFF) / 255
        // The edges' light, smoothed into horizontal streaks as the hall turns past.
        let sharp = greater(0, 1 - edge / (0.06 + foot)) * lesser(1, 0.12 / (0.06 + foot))
        let streak = lesser(1, blur * 1.5)
        let edgeLight = sharp + (0.22 - sharp) * streak
        let paint = hall.at(cx / Float(columns) * 4)
        var colour = paint * (cell * shade + line * edgeLight)
        // A light in about one cell in five, flickering with the treble, drawn out into a dash by the motion.
        if (hash >> 8) % 5 == 0 {
            let dash = 0.14 + blur + foot
            let along = greater(0, lesser(1, (dash - lx.magnitude) / (foot + 0.02)))
            let up = greater(0, 1 - ly.magnitude / (0.12 + foot))
            let level = 0.5 + 0.5 * Float((hash >> 16) & 0xFF) / 255 * (0.4 + flicker)
            colour += lamp * (along * up * level * 0.28 / dash)
        }
        return colour
    }

    // MARK: Helpers

    /// The colour `hue` of the way along the sparks (wrapping), blending between neighbours.
    private func colourAt(_ hue: Double, _ style: SceneStyle) -> RGB {
        let base = hue.rounded(.down)
        let i = Int(base)
        let colour = style.spark(i).mixed(with: style.spark(i + 1), hue - base)
        return style.isLight ? colour.scaled(0.8) : colour
    }

    private static func paints(_ style: SceneStyle) -> Paints {
        func v(_ c: RGB) -> Shade { Shade(Float(c.r), Float(c.g), Float(c.b)) }
        if style.isLight {
            let hall = Hall(v(style.mid.mixed(with: .white, 0.5)), v(style.mid.mixed(with: style.spark(1), 0.3)),
                            v(style.mid.mixed(with: .white, 0.3)), v(style.mid.mixed(with: style.spark(2), 0.3)))
            return Paints(style: style, glass: v(style.ink.mixed(with: style.deep, 0.2)), rim: v(style.ink.scaled(0.7)),
                          hall: hall, cell: 1, line: 0.7, lamp: v(style.accent.scaled(0.6)),
                          abyss: v(style.mid.mixed(with: .white, 0.2)), light: true)
        }
        let hall = Hall(v(style.spark(0).mixed(with: style.deep, 0.3)), v(style.spark(1).mixed(with: style.deep, 0.3)),
                        v(style.mid.mixed(with: style.ink, 0.25)), v(style.spark(2).mixed(with: style.deep, 0.3)))
        return Paints(style: style, glass: v(style.ink.mixed(with: style.glow, 0.15)),
                      rim: v(RGB.white.mixed(with: style.ink, 0.25)), hall: hall, cell: 0.25,
                      line: 0.8, lamp: v(.white), abyss: v(style.deep.scaled(0.08)), light: false)
    }

    /// Four colours round the hall, blended between.
    private struct Hall {
        var c0: Shade, c1: Shade, c2: Shade, c3: Shade

        init(_ c0: Shade, _ c1: Shade, _ c2: Shade, _ c3: Shade) {
            self.c0 = c0
            self.c1 = c1
            self.c2 = c2
            self.c3 = c3
        }

        /// The colour `t` of the way round (in quarters, wrapping).
        @inline(__always)
        func at(_ t: Float) -> Shade {
            let base = floorf(t), f = t - base
            let i = (Int(base) % 4 + 4) % 4
            let a = i == 0 ? c0 : i == 1 ? c1 : i == 2 ? c2 : c3
            let b = i == 0 ? c1 : i == 1 ? c2 : i == 2 ? c3 : c0
            let k = f * f * (3 - 2 * f)
            return a + (b - a) * k
        }
    }

    /// A colour as a pixel, its highlights eased off rather than clipped.
    @inline(__always)
    private static func pack(_ c: Shade) -> UInt32 {
        @inline(__always) func byte(_ x: Float) -> UInt32 {
            let knee: Float = 0.72
            let y = x < knee ? x : knee + (x - knee) / (1 + (x - knee) / (1 - knee))
            return UInt32(lesser(greater(y, 0), 1) * 255 + 0.5)
        }
        return byte(c.r) | byte(c.g) << 8 | byte(c.b) << 16 | 0xFF00_0000
    }
}

/// A hash of a cell and a seed.
@inline(__always)
nonisolated private func mix(_ a: UInt32, _ b: UInt32, _ seed: UInt32) -> UInt32 {
    var h = (a &* 0x9E37_79B1) ^ (b &* 0x85EB_CA77) ^ seed
    h ^= h >> 15
    h = h &* 0x2C1B_3C6D
    h ^= h >> 12
    h = h &* 0x297A_2D39
    h ^= h >> 15
    return h
}

/// The lesser and greater of two floats (Swift's generic `min` and `max` are slow in debug builds).
@inline(__always)
nonisolated private func lesser(_ a: Float, _ b: Float) -> Float { a < b ? a : b }

@inline(__always)
nonisolated private func greater(_ a: Float, _ b: Float) -> Float { a > b ? a : b }

/// asin for 0...1, to about 7e-5 radians.
@inline(__always)
nonisolated private func asinApprox(_ x: Float) -> Float {
    let t = (1 - x).squareRoot()
    return 1.570_796_3 - t * (1.570_728_8 + x * (-0.212_114_4 + x * (0.074_261_0 - 0.018_729_3 * x)))
}

/// atan2, to about 1e-5 radians.
@inline(__always)
nonisolated private func fastAtan2(_ y: Float, _ x: Float) -> Float {
    let ax = x.magnitude, ay = y.magnitude
    let a = lesser(ax, ay) / greater(greater(ax, ay), 1e-20)
    let s = a * a
    var r = ((-0.046_496_475 * s + 0.159_314_22) * s - 0.327_622_76) * s * a + a
    if ay > ax { r = 1.570_796_3 - r }
    if x < 0 { r = 3.141_592_7 - r }
    return y < 0 ? -r : r
}

/// 0 below `lo`, 1 above `hi`, smooth between.
nonisolated private func smoothstep(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
    let t = min(max((x - lo) / (hi - lo), 0), 1)
    return t * t * (3 - 2 * t)
}

/// A colour in the pixel loop: plain floats, which stay quick in debug builds, where SIMD types are slow.
nonisolated private struct Shade {
    var r: Float
    var g: Float
    var b: Float

    @inline(__always) init(_ r: Float, _ g: Float, _ b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }

    @inline(__always) static func + (a: Shade, b: Shade) -> Shade { Shade(a.r + b.r, a.g + b.g, a.b + b.b) }
    @inline(__always) static func - (a: Shade, b: Shade) -> Shade { Shade(a.r - b.r, a.g - b.g, a.b - b.b) }
    @inline(__always) static func * (a: Shade, k: Float) -> Shade { Shade(a.r * k, a.g * k, a.b * k) }
    @inline(__always) static func += (a: inout Shade, b: Shade) { a = a + b }
}
