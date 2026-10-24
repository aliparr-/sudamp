// SPDX-License-Identifier: GPL-3.0-or-later
// Spiral: a flight down a winding tube of frosted glass ribbons. One ribbon spirals round the tube's wall and a
// narrower one the other way inside it, both with bright edges where they catch the light; through the gaps between
// their turns a dark outer wall streams past, and far ahead the tube glows where it bends out of sight. The camera
// rushes on with the music: faster when it's loud, surging on every kick and hurtling after the drop (with a wider
// lens); it drifts through a breakdown and stops in silence. Each kick hangs a ring of light in the tube ahead for the
// camera to fly through, in the artwork's spark colours, the drop a white one. On light artwork the glass turns to
// smoked ink in a pale tube. A seed varies the tube's bends.
//
// The tube is worked out a pixel at a time, as a ray from the camera finds each ribbon: it steps through slices of the
// tube at growing depths (each slice a circle round the tube's centre at that depth, wandering with its bends) to the
// first one the ray is outside, and closes in between the two. The stripes are box-filtered over the pixel and over the
// frame's motion, so they stay smooth far down the tube and blur as they rush past. It asks for 60 frames a second,
// where other scenes draw 30, and works on bands of rows side by side. On a Retina screen it works at 1.5 pixels a
// point and is smoothed up.

import CoreGraphics
import Foundation

nonisolated final class SpiralScene: VisualizerScene {
    private struct Ring {
        /// Where it hangs along the tube (radii from where the flight started), how bright, its colour's place along
        /// the sparks (negative: white), and how long since it appeared.
        var z: Double
        var strength: Double
        var hue: Double
        var age: Double
    }

    /// The frame's buffers, shared by the bands of rows worked on side by side. The pointers don't outlive the
    /// `withUnsafe…` calls `concurrentPerform` runs inside, which returns once every band is done.
    // SAFETY: each band writes only its own rows of `out`, and the other buffers are only read while bands run.
    private struct Buffers: @unchecked Sendable {
        let out: UnsafeMutablePointer<UInt32>
        let slices: UnsafePointer<Float>
        let table: UnsafePointer<Float>
        let noise: UnsafePointer<Float>
    }

    /// The colours, as floats for the pixel loop.
    private struct Paints {
        var style: SceneStyle
        var tape: Shade
        var rim: Shade
        var wall: Shade
        var end: Shade
        var light: Bool
    }

    // MARK: The world (lengths in tube radii)

    /// A glass ribbon wound round the tube: the radius it winds at, how far along the tube a turn takes, the share of
    /// each turn it covers, its rims' width (a share of a turn) and how much it hides what's behind.
    private struct Ribbon {
        var radius: Float
        var pitch: Float
        var duty: Float
        var rim: Float
        var opacity: Float

        var invRadius: Float { 1 / radius }
        /// A stripe's footprint on a pixel at depth d, per unit of the image plane: d^2 times this down the tube
        /// (depth changes as d^2 / radius across the image there), d times this round it.
        var footRadial: Float { 1 / (pitch * radius) }
        var footRound: Float { 0.159_154_94 / radius }
    }

    /// The main ribbon, and a narrower one wound the other way inside it.
    private static let ribbons = [
        Ribbon(radius: 1, pitch: 2.4, duty: 0.5, rim: 0.02, opacity: 0.3),
        Ribbon(radius: 0.62, pitch: 1.7, duty: 0.24, rim: 0.03, opacity: 0.2),
    ]
    /// The outer wall's radius.
    private static let wallRadius: Float = 1.75
    /// How quickly the tube fades into the light ahead.
    private static let fogDepth = 10.0
    /// Pixels per point it works at, at most.
    private static let maxScale: CGFloat = 1.5
    /// The search's slices: depths growing geometrically from just in front of the camera to well past the fog.
    private static let sliceCount = 33
    private static let sliceDepths: [Double] = (0..<sliceCount).map { 0.06 * pow(1.25, Double($0)) }
    /// The per-frame light table: entries per radius of depth, and how deep it goes.
    private static let tableSteps = 16
    private static let tableCount = 48 * tableSteps
    private static let noiseSize = 64

    private var distance: Double
    private var speed = 0.0
    private var activity = 0.0
    private var pulse = 0.0
    private var calm = 0.0
    private var sinceDrop = 10.0
    private var roll = 0.0
    /// The inner ribbon's own turning, in turns.
    private var twist = 0.0
    /// Where the camera looks (the slope of its line of sight): it steers into the bends a little late.
    private var look: (x: Double, y: Double)
    private var frameTime = 1.0 / 60
    private var rings: [Ring] = []
    private var ringCount = 0
    private let hueStep: Double
    /// The tube's bends: two sines across and two up and down.
    private let bends: [(amp: Double, freq: Double, phase: Double)]
    private let sway: (Double, Double)
    /// A tiling frost texture, -1...1.
    private let noise: [Float]

    private var paints: Paints?
    private var pixels: [UInt32] = []
    /// Per slice, `stride` floats: depth, the tube's centre in camera space (x, y), and the ray test's terms: depth
    /// squared, twice depth times the centre (x, y), and the centre's distance squared less each radius squared (the
    /// inner ribbon's and the main ribbon's).
    private static let stride = 8
    private var slices = [Float](repeating: 0, count: sliceCount * stride)
    /// Per depth step: fog (1 near, 0 lost in the light ahead), the lamp's light, and the rings' light (r, g, b).
    private var table = [Float](repeating: 0, count: tableCount * 5)

    var glow: Double { 0 }
    var framesPerSecond: Int { 60 }

    init(seed: UInt64) {
        var random = SceneRandom(seed: seed)
        distance = random.range(0, 400)
        hueStep = random.chance(0.5) ? 0.38 : -0.38
        ringCount = random.int(8)
        bends = [
            (random.range(2.6, 3.4), random.range(0.09, 0.12), random.range(0, 2 * .pi)),
            (random.range(0.8, 1.2), random.range(0.17, 0.23), random.range(0, 2 * .pi)),
            (random.range(2.2, 3.0), random.range(0.08, 0.11), random.range(0, 2 * .pi)),
            (random.range(0.8, 1.2), random.range(0.16, 0.22), random.range(0, 2 * .pi)),
        ]
        sway = (random.range(0, 2 * .pi), random.range(0, 2 * .pi))
        noise = Self.makeNoise(&random)
        look = (0, 0)
        look = slope(distance + 1)
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
        if input.drop { sinceDrop = 0 } else { sinceDrop += dt }

        // Radii a second: a brisk cruise, faster when loud, a surge on each kick, slow through a breakdown, and a
        // rush after the drop.
        let rush = sinceDrop < 5 ? exp(-sinceDrop / 1.3) : 0
        let cruise = (3.5 + 6 * level + 4 * bass) * (1 + 0.9 * pulse) * (1 - 0.6 * calm) * (1 + 2.4 * rush)
        let wanted = activity * cruise
        // In silence it comes to a stop in about half a second.
        speed += (wanted - speed) * (1 - exp(-dt / (wanted > speed ? 0.12 : wanted == 0 ? 0.04 : 0.08)))
        if wanted == 0, speed < 0.1 { speed = 0 }
        let step = speed * dt
        distance += step
        // The camera rolls a little as it goes, more in the rush, and steers after the bends.
        roll += step * (0.07 + 0.12 * rush)
        let ahead = slope(distance + 1), steer = 1 - exp(-step / 3.5)
        look = (look.x + (ahead.x - look.x) * steer, look.y + (ahead.y - look.y) * steer)
        // The inner ribbon turns on its own, faster with the mids.
        twist += dt * activity * (0.08 + 0.25 * Double(input.mid))

        // Kicks hang rings of light ahead; the drop a big white one.
        for i in rings.indices {
            rings[i].age += dt
            if activity < 0.05 { rings[i].strength *= exp(-dt / 0.06) }
        }
        rings.removeAll { $0.z < distance - 1.5 || $0.strength < 0.01 }
        guard activity > 0.4, rings.count < 12 else { return }
        if input.drop {
            ringCount += 1
            rings.append(Ring(z: distance + 7, strength: 1.6, hue: -1, age: 0))
        } else if input.beat {
            ringCount += 1
            let strength = (0.6 + 0.7 * bass) * (1 - 0.5 * calm)
            rings.append(Ring(z: distance + 9 + speed * 0.25, strength: strength, hue: Double(ringCount) * hueStep,
                              age: 0))
        }
    }

    // MARK: Path

    /// The tube's centre at `z` along it.
    private func centre(_ z: Double) -> (x: Double, y: Double) {
        func wave(_ i: Int) -> Double { bends[i].amp * sin(bends[i].freq * z + bends[i].phase) }
        return (wave(0) + wave(1), wave(2) + wave(3))
    }

    /// How fast the centre moves sideways per radius along the tube at `z`.
    private func slope(_ z: Double) -> (x: Double, y: Double) {
        func wave(_ i: Int) -> Double { bends[i].amp * bends[i].freq * cos(bends[i].freq * z + bends[i].phase) }
        return (wave(0) + wave(1), wave(2) + wave(3))
    }

    // MARK: Draw

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let w = size.width, h = size.height
        guard w >= 1, h >= 1 else { return }
        // Worked out a pixel at a time and drawn one to one; on a Retina screen, at a lower resolution and smoothed up
        // (most of what shows is blurred by its motion, and four times the pixels would cost four times the work).
        let screen = min(max(abs(ctx.userSpaceToDeviceSpaceTransform.a), 1), 3)
        let scale = min(screen, Self.maxScale)
        let smoothed = scale < screen
        let cols = Int((w * scale).rounded()), rows = Int((h * scale).rounded())
        guard cols > 0, rows > 0, cols <= 1024, rows <= 1024 else { return }
        if paints?.style != style { paints = Self.paints(style) }
        guard let paints else { return }
        if pixels.count != cols * rows { pixels = [UInt32](repeating: 0, count: cols * rows) }
        prepare(paints)
        render(cols: cols, rows: rows, paints: paints)

        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: cols * 4, space: sceneColorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: smoothed, intent: .defaultIntent)
        else { return }
        ctx.saveGState()
        ctx.interpolationQuality = smoothed ? .medium : .none
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }

    /// The frame's slices and light table.
    private func prepare(_ paints: Paints) {
        // The camera rides near the tube's centre, swaying a little, and looks along the tube a few radii ahead.
        let z = distance
        let c = centre(z)
        let camera = (x: c.x + 0.2 * sin(0.37 * z + sway.0), y: c.y + 0.17 * sin(0.29 * z + sway.1))
        let inner = Double(Self.ribbons[1].radius)
        for j in 0..<Self.sliceCount {
            let d = Self.sliceDepths[j]
            let p = centre(z + d)
            let x = p.x - camera.x - look.x * d, y = p.y - camera.y - look.y * d
            let o = j * Self.stride
            slices[o] = Float(d)
            slices[o + 1] = Float(x)
            slices[o + 2] = Float(y)
            slices[o + 3] = Float(d * d)
            slices[o + 4] = Float(2 * d * x)
            slices[o + 5] = Float(2 * d * y)
            slices[o + 6] = Float(x * x + y * y - inner * inner)
            slices[o + 7] = Float(x * x + y * y - 1)
        }

        // Light: a lamp just ahead of the camera lighting the nearest turns, more on a kick (the very nearest, a blur
        // rushing past, stay dim); the rings ahead.
        let ahead = rings.filter { $0.z > z - 1.5 && $0.z < z + 60 }
        let colours = ahead.map { ring -> (Double, Double, Double, Double) in
            let colour = ring.hue < 0 ? RGB.white : colourAt(ring.hue, paints.style)
            // Each ring brightens over a moment as it appears.
            let s = ring.strength * min(1, ring.age / 0.12)
            return (colour.r * s, colour.g * s, colour.b * s, ring.z)
        }
        let lamp = 0.75 + 0.35 * pulse
        for i in 0..<Self.tableCount {
            let d = Double(i) / Double(Self.tableSteps)
            // Nearest the camera, a lamp or ring would light a blur filling the picture: they ease off there.
            let near = d * d / (d * d + 0.6)
            var r = 0.0, g = 0.0, b = 0.0
            for ring in colours {
                let x = (z + d - ring.3) / 0.3
                guard abs(x) < 3 else { continue }
                let k = exp(-x * x) * (0.25 + 0.75 * near)
                r += ring.0 * k
                g += ring.1 * k
                b += ring.2 * k
            }
            table[i * 5] = Float(exp(-d / Self.fogDepth))
            table[i * 5 + 1] = Float(0.12 + lamp * (0.35 + 0.65 * near) / (1 + d * d / 6))
            table[i * 5 + 2] = Float(r)
            table[i * 5 + 3] = Float(g)
            table[i * 5 + 4] = Float(b)
        }
    }

    private func render(cols: Int, rows: Int, paints: Paints) {
        let n = Self.sliceCount
        // Pixels per unit of the image plane at depth 1: a wide lens, wider in the rush.
        let rush = Float(sinceDrop < 5 ? exp(-sinceDrop / 1.3) : 0)
        let focal = Float(Swift.min(cols, rows)) * 0.4 * (1 - 0.2 * rush)
        let invF = 1 / focal
        let cr = Float(cos(roll)), sr = Float(sin(roll))
        let halfW = Float(cols) / 2, halfH = Float(rows) / 2
        let mainRibbon = Self.ribbons[0], innerRibbon = Self.ribbons[1]
        // Where the ribbons' stripes and the frost start, from the distance flown (kept small for Float).
        let mainBase = Float((distance / Double(mainRibbon.pitch)).truncatingRemainder(dividingBy: 1))
        let innerBase = Float((distance / Double(innerRibbon.pitch) + twist).truncatingRemainder(dividingBy: 1))
        let size = Self.noiseSize
        let frostBase = Float((distance * 8).truncatingRemainder(dividingBy: Double(size)))
        let streakBase = Float((distance * 0.7).truncatingRemainder(dividingBy: Double(size)))
        // How far the stripes move while the shutter is open (half the frame), in turns of each ribbon: the blur.
        let travel = 0.5 * speed * frameTime
        let mainBlur = Float(travel) / mainRibbon.pitch, innerBlur = Float(travel) / innerRibbon.pitch
        let frostBlur = Float(travel * 8)
        let light = paints.light
        let tape = paints.tape, rimColour = paints.rim, wall = paints.wall
        let end = paints.end * Float(light ? 1 : 0.55 + 0.35 * activity + 0.4 * pulse)
        let endPacked = Self.pack(end)
        let tableLast = Float(Self.tableCount - 1)
        let steps = Float(Self.tableSteps)
        let mask = size - 1
        let wallRadius = Self.wallRadius
        let streakContrast: Float = light ? 0.25 : 0.6

        pixels.withUnsafeMutableBufferPointer { pixels in
        slices.withUnsafeBufferPointer { slices in
        table.withUnsafeBufferPointer { table in
        noise.withUnsafeBufferPointer { noise in
            // Plain pointers: a buffer's checked subscript is slow in debug builds, and these are read ~80 times a
            // pixel.
            guard let out = pixels.baseAddress, let S = slices.baseAddress, let T = table.baseAddress,
                  let N = noise.baseAddress else { return }
            // Rows are independent: bands of them are worked on side by side, each writing only its own rows.
            let buffers = Buffers(out: out, slices: S, table: T, noise: N)
            let bands = Swift.min(4, Swift.max(1, rows / 16))
            DispatchQueue.concurrentPerform(iterations: bands) { band in
            let out = buffers.out, S = buffers.slices, T = buffers.table, N = buffers.noise
            for py in (rows * band / bands)..<(rows * (band + 1) / bands) {
                let sy = (Float(py) + 0.5 - halfH) * invF
                let sx0 = (0.5 - halfW) * invF
                var qx = sx0 * cr - sy * sr, qy = sx0 * sr + sy * cr
                let row = py * cols
                // Where the last pixel's ray left the inner tube: this one's leaves within a slice or two of it.
                var hint = 0
                for px in 0..<cols {
                    defer {
                        qx += invF * cr
                        qy += invF * sr
                    }
                    // The ray through this pixel is (qx, qy, 1) at depth 1. It meets the inner ribbon's tube first,
                    // then the main ribbon's, then (further by about the ratio of their radii) the outer wall.
                    let qq = qx * qx + qy * qy
                    // 1 / the ray's length per unit depth.
                    let slant = 1 / (qq + 1).squareRoot()
                    var start = Swift.max(hint - 2, 0)
                    while start > 0, Self.outside(S, start, layer: 6, qx, qy, qq) { start -= 1 }
                    let hitInner = Self.exit(S, n, from: start, layer: 6, radius: innerRibbon.radius, qx, qy, qq)
                    hint = hitInner.j
                    let hitMain = Self.exit(S, n, from: Swift.max(hitInner.j - 1, 0), layer: 7, radius: 1, qx, qy, qq)
                    guard hitMain.j < n else {
                        out[row + px] = endPacked
                        continue
                    }
                    let main = Self.point(S, hitMain, qx, qy)
                    let turn = fastAtan2(main.vy, main.vx) * 0.159_154_94

                    // The outer wall, with fine streaks along the tube: a dim blur behind the glass, so its depth is
                    // taken from the main ribbon's rather than searched for.
                    var colour = end
                    let wallDepth = main.d * wallRadius
                    if wallDepth < S[(n - 1) * Self.stride] {
                        let d = wallDepth
                        let streak = Self.sample(N, (turn + 1) * Float(2 * size), d * 0.7 + streakBase, size, mask)
                        let foot = d * invF * greater(d * 0.7, 20) + frostBlur * 0.1
                        let lit = Self.light(T, d, steps, tableLast)
                        let surface = wall * (lit.lamp * (0.7 + streakContrast * streak / (1 + foot * foot)))
                            + lit.ring * 0.6
                        colour = end + (surface - end) * lit.fog
                    }

                    // The ribbons: frosted glass, the main one then the inner one in front of it.
                    for layer in 0..<2 {
                        let isMain = layer == 0
                        let ribbon = isMain ? mainRibbon : innerRibbon
                        let hit = isMain ? main : Self.point(S, hitInner, qx, qy)
                        let d = hit.d
                        let angle = isMain ? turn : fastAtan2(hit.vy, hit.vx) * 0.159_154_94
                        let s = d / ribbon.pitch + (isMain ? mainBase + angle : innerBase - angle)
                        // The stripe's footprint on the pixel (down the tube and round it), and the motion.
                        let radial = d * d * ribbon.footRadial, round = d * ribbon.footRound
                        let foot = invF * hypot(radial, round)
                        let band = Self.ribbon(s, width: hypot(foot, isMain ? mainBlur : innerBlur) + 1e-4, pixel: foot,
                                               duty: ribbon.duty, rimWidth: ribbon.rim)
                        guard band.body > 0.002 || band.rim > 0.002 else { continue }
                        let frostFoot = d * invF * greater(d * 8, 10) + frostBlur
                        let frost = 1 + 0.4 * Self.sample(N, (angle + 1) * Float(size), d * 8 + frostBase, size, mask)
                            / (1 + frostFoot * frostFoot)
                        let lit = Self.light(T, d, steps, tableLast)
                        // Glass shows more of itself at a glancing angle (far down the tube) than face on.
                        let facing = lesser(greater((qx * hit.vx + qy * hit.vy) * ribbon.invRadius * slant, 0), 1)
                        let glance = (1 - facing) * (1 - facing)
                        let alpha = lesser(1, band.body * (ribbon.opacity + 0.55 * glance * glance) * frost)
                        if light {
                            let ink = tape + (end - tape) * (1 - lit.fog)
                            colour = colour + (ink - colour) * lesser(1, alpha * 1.3)
                            colour = colour + (rimColour - colour) * (band.rim * 0.8 * lit.fog)
                        } else {
                            let glass = (tape * (lit.lamp * frost * band.bevel) + lit.ring) * lit.fog
                                + end * (1 - lit.fog)
                            colour = colour * (1 - 0.6 * alpha) + glass * alpha
                            colour += (rimColour * lit.lamp + lit.ring * 1.5) * (band.rim * lit.fog)
                        }
                    }
                    out[row + px] = Self.pack(colour)
                }
            }
            }
        }}}}
    }

    /// Where a ray (qx, qy, 1) leaves a tube (`layer` picks its radius's term in the slices), searching on from the
    /// slice `start`: the first slice it is outside, and how far from the slice before to that one it crossed the wall
    /// (`j` is the slice count when it never leaves).
    @inline(__always)
    private static func exit(_ S: UnsafePointer<Float>, _ n: Int, from start: Int, layer: Int, radius: Float,
                             _ qx: Float, _ qy: Float, _ qq: Float) -> (j: Int, t: Float) {
        // Inside while |d q - centre(d)|^2 - radius^2 = d^2 q.q - 2d centre.q + |centre|^2 - radius^2 < 0.
        var o = start * stride
        var before = S[o + 3] * qq - S[o + 4] * qx - S[o + 5] * qy + S[o + layer]
        guard before < 0 else { return (Swift.max(start, 1), start == 0 ? 0 : 1) }
        var j = start + 1
        while j < n {
            o += stride
            let h = S[o + 3] * qq - S[o + 4] * qx - S[o + 5] * qy + S[o + layer]
            if h >= 0 {
                // Between the slices the distance from the centre changes nearly in step with depth.
                let r2 = radius * radius
                let r0 = (before + r2).squareRoot(), r1 = (h + r2).squareRoot()
                return (j, lesser(greater((radius - r0) / greater(r1 - r0, 1e-6), 0), 1))
            }
            before = h
            j += 1
        }
        return (n, 0)
    }

    /// Whether a ray is outside a tube at slice `j`.
    @inline(__always)
    private static func outside(_ S: UnsafePointer<Float>, _ j: Int, layer: Int, _ qx: Float, _ qy: Float, _ qq: Float)
        -> Bool {
        let o = j * stride
        return S[o + 3] * qq - S[o + 4] * qx - S[o + 5] * qy + S[o + layer] >= 0
    }

    /// The depth of an exit, and where it is from the tube's centre there.
    @inline(__always)
    private static func point(_ S: UnsafePointer<Float>, _ hit: (j: Int, t: Float), _ qx: Float, _ qy: Float)
        -> (d: Float, vx: Float, vy: Float) {
        let a = (hit.j - 1) * stride, b = hit.j * stride, t = hit.t
        let d = S[a] + (S[b] - S[a]) * t
        return (d, d * qx - (S[a + 1] + (S[b + 1] - S[a + 1]) * t), d * qy - (S[a + 2] + (S[b + 2] - S[a + 2]) * t))
    }

    /// The light table at depth `d`.
    @inline(__always)
    private static func light(_ T: UnsafePointer<Float>, _ d: Float, _ steps: Float, _ last: Float)
        -> (fog: Float, lamp: Float, ring: Shade) {
        // Nearest entry: the table is fine enough that blending between entries doesn't show.
        let o = Int(lesser(d * steps + 0.5, last)) * 5
        return (T[o], T[o + 1], Shade(T[o + 2], T[o + 3], T[o + 4]))
    }

    /// A ribbon at stripe position `s` (whole numbers at an edge), averaged over `width` (the pixel's footprint,
    /// `pixel`, and the motion): how much of it covers the pixel, how much of its bright rims, and the light its bevel
    /// holds.
    @inline(__always)
    private static func ribbon(_ s: Float, width: Float, pixel: Float, duty: Float, rimWidth: Float)
        -> (body: Float, rim: Float, bevel: Float) {
        let half = 0.5 * width, inv = 1 / width
        let body = (stripeIntegral(s + half, duty) - stripeIntegral(s - half, duty)) * inv
        let shifted = s + 0.5 * rimWidth
        let cover = (rimIntegral(shifted + half, duty, rimWidth) - rimIntegral(shifted - half, duty, rimWidth)) * inv
        // A rim thinner than the pixel still shows, as a fainter line; one blurred by motion spreads its light.
        let rim = lesser(1, cover * lesser(greater(pixel / rimWidth, 1), 3))
        // Glass edges hold more light than the middle of the band (smoothed away where the band is small).
        let across = (s - floorf(s)) / duty * 2 - 1
        let bevel = 1 + 0.45 * (across * across - 0.4) / (1 + 16 * width * width)
        return (body, rim, bevel)
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
            return Paints(style: style, tape: v(style.ink.mixed(with: style.deep, 0.2)), rim: v(style.ink.scaled(0.7)),
                          wall: v(style.mid.mixed(with: .white, 0.3)), end: v(style.mid.mixed(with: .white, 0.75)),
                          light: true)
        }
        return Paints(style: style, tape: v(style.ink.mixed(with: style.glow, 0.2)),
                      rim: v(RGB.white.mixed(with: style.ink, 0.25)),
                      wall: v(style.deep.mixed(with: style.mid, 0.25).scaled(0.22)),
                      end: v(style.glow.mixed(with: style.accent, 0.3)), light: false)
    }

    /// A tiling value noise, three octaves, scaled to -1...1.
    private static func makeNoise(_ random: inout SceneRandom) -> [Float] {
        let size = noiseSize
        var out = [Float](repeating: 0, count: size * size)
        var amplitude: Float = 1
        for cells in [8, 16, 32] {
            let lattice = (0..<(cells * cells)).map { _ in Float(random.next() * 2 - 1) }
            let per = Float(cells) / Float(size)
            for y in 0..<size {
                let fy = Float(y) * per
                let iy = Int(fy), ty = fy - Float(iy)
                let sy = ty * ty * (3 - 2 * ty)
                for x in 0..<size {
                    let fx = Float(x) * per
                    let ix = Int(fx), tx = fx - Float(ix)
                    let sx = tx * tx * (3 - 2 * tx)
                    let y0 = (iy % cells) * cells, y1 = ((iy + 1) % cells) * cells
                    let x0 = ix % cells, x1 = (ix + 1) % cells
                    let a = lattice[y0 + x0], b = lattice[y0 + x1], c = lattice[y1 + x0], d = lattice[y1 + x1]
                    out[y * size + x] += amplitude * (a + (b - a) * sx + (c - a + (d - c - b + a) * sx) * sy)
                }
            }
            amplitude *= 0.55
        }
        let peak = out.map(abs).max() ?? 1
        return out.map { $0 / greater(peak, 1e-6) }
    }

    /// The noise at (u, v) in texels, wrapping, bilinear.
    @inline(__always)
    private static func sample(_ n: UnsafePointer<Float>, _ u: Float, _ v: Float, _ size: Int, _ mask: Int) -> Float {
        let fu = floorf(u), fv = floorf(v)
        let tu = u - fu, tv = v - fv
        let iu = Int(fu) & mask, iv = Int(fv) & mask
        let iu1 = (iu + 1) & mask, iv1 = (iv + 1) & mask
        let a = n[iv * size + iu], b = n[iv * size + iu1], c = n[iv1 * size + iu], d = n[iv1 * size + iu1]
        let top = a + (b - a) * tu, bottom = c + (d - c) * tu
        return top + (bottom - top) * tv
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

/// How much of a square wave (1 for the first `duty` of each period, 0 for the rest) lies below `s`.
@inline(__always)
nonisolated private func stripeIntegral(_ s: Float, _ duty: Float) -> Float {
    let f = floorf(s)
    return f * duty + lesser(s - f, duty)
}

/// The same for two thin rims of `width` a period, at 0 and at `duty`.
@inline(__always)
nonisolated private func rimIntegral(_ s: Float, _ duty: Float, _ width: Float) -> Float {
    let f = floorf(s), x = s - f
    return f * 2 * width + lesser(x, width) + lesser(greater(x - duty, 0), width)
}

/// sqrt(a^2 + b^2).
@inline(__always)
nonisolated private func hypot(_ a: Float, _ b: Float) -> Float { (a * a + b * b).squareRoot() }

/// The lesser and greater of two floats (Swift's generic `min` and `max` are slow in debug builds).
@inline(__always)
nonisolated private func lesser(_ a: Float, _ b: Float) -> Float { a < b ? a : b }

@inline(__always)
nonisolated private func greater(_ a: Float, _ b: Float) -> Float { a > b ? a : b }

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
