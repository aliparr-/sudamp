// SPDX-License-Identifier: GPL-3.0-or-later
// Campfire: a cosy pixel-art fire on two crossed logs in a ring of stones, the classic demoscene fire effect on the
// same 46-pixel grid as Pixel DJ. A heat buffer burns upwards: its bottom row is fed by the spectrum (the bars spread
// out from the middle, bass at the heart of the fire and treble at its edges), so the flames dance with the music,
// and the heat rises, cools through a drifting pattern that tears it into tongues, and flickers sideways. Each kick
// lifts the flames and throws sparks up, more of them with more treble. Through a breakdown the fire burns lower,
// slower and gentler; the drop is a whoosh of flame and a burst of sparks. In silence the flames die down within half
// a second to embers glowing on the logs, with a wisp of smoke. Each seed lays a different fire: the logs (oak, birch
// or charred), the stones, and the pattern the flames tear into.
//
// The heat steps at a fixed rate (sub-stepped, so a long frame doesn't change the fire), and is coloured through a
// ramp made once per palette: a natural fire tinted a little towards the artwork, up to a near-white core on dark
// artwork; on light artwork a deeper ramp with a dark red rim so the flames read without adding light.

import CoreGraphics
import Foundation

nonisolated final class CampfireScene: VisualizerScene {
    /// 46 pixels across: 2 points a pixel on the 92-point artwork, whole pixels at 1x and 2x.
    private static let side = 46
    /// The heat buffer: 28 columns centred on the artwork, rows 6...39 (its two bottom rows are the fuel, behind the
    /// logs).
    private static let fireWidth = 28, fireHeight = 34
    private static let fireX = 9, fireY = 6
    /// Heat steps a second (fewer through a breakdown), and the rows of the drifting cooling pattern.
    private static let stepRate = 30.0
    private static let noiseRows = 64
    private static let rampSize = 64

    private var canvas = PixelCanvas(width: CampfireScene.side, height: CampfireScene.side)
    private var mask = [Bool](repeating: false, count: CampfireScene.side * CampfireScene.side)
    private var random: SceneRandom
    private var heat = [Float](repeating: 0, count: CampfireScene.fireWidth * CampfireScene.fireHeight)
    /// How much each cell cools as the heat rises through it: a smooth seeded noise, scrolled up a row a step.
    private let coolNoise: [Float]
    /// Extra cooling towards the sides, so the fire burns to a point, and towards the top, so it breaks into tongues.
    private let edgeCool: [Float]
    private let heightCool: [Float]
    private var scroll = 0
    private var clock = 0.0
    private let wood: Wood
    private let stones: [Stone]
    private let embers: [Ember]
    /// The little flames left on the embers in silence.
    private let licks: [Lick]
    private var sparks: [Spark] = []
    private var ramp: [(color: RGB, alpha: Double)] = []
    private var paints = Paints()
    private var styled: SceneStyle?

    // What the music is doing.
    /// The fuel: 0 in silence (embers only), up to about 1 while playing loud.
    private var fuel = 0.0
    private var bars = [Float](repeating: 0, count: VisualizerInput.barCount)
    private var calm = 0.0
    private var pulse = 0.0
    private var whoosh = 0.0
    private var silentFor = 10.0
    private var time = 0.0

    /// None: a halo would blur the pixels.
    var glow: Double { 0 }

    init(seed: UInt64) {
        random = SceneRandom(seed: seed)
        for _ in 0..<4 { _ = random.next() }
        wood = Wood(&random)
        coolNoise = Self.noise(&random, width: Self.fireWidth, height: Self.noiseRows)
        edgeCool = (0..<Self.fireWidth).map { x in
            let u = abs((Double(x) + 0.5) / Double(Self.fireWidth) * 2 - 1)
            return Float(0.08 * pow(max(0, u - 0.45) / 0.55, 2))
        }
        heightCool = (0..<Self.fireHeight).map { row in
            let up = 1 - Double(row) / Double(Self.fireHeight)
            return Float(0.03 * pow(max(0, up - 0.35) / 0.65, 2))
        }
        stones = Stone.ring(&random)
        embers = Ember.scatter(&random)
        licks = Lick.scatter(&random)
    }

    // MARK: - Update

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let silent = input.isSilent
        silentFor = silent ? silentFor + dt : 0
        time += dt
        let loud = silent ? 0 : min(1, 0.35 + Double(input.level) * 1.2)
        fuel += (loud - fuel) * (1 - exp(-dt * (silent ? 14 : 4)))
        calm = silent ? 0 : Double(input.breakdown)
        pulse = silent ? 0 : Double(input.pulse)
        whoosh *= exp(-dt * 2.2)
        if silent { whoosh = 0 }
        bars = input.bars

        if !silent, input.beat {
            let count = Int((2 + Double(input.treble) * 9) * (1 - 0.6 * calm))
            for _ in 0..<count { launchSpark(speed: 1, spread: 1) }
        }
        if !silent, input.drop {
            whoosh = 1
            // A rush of heat up through the fire, narrowing as it rises.
            for k in 0..<18 {
                let row = Self.fireHeight - 1 - k
                let narrow = 1 - Double(k) / 22
                for x in 0..<Self.fireWidth {
                    let u = abs((Double(x) + 0.5) / Double(Self.fireWidth) * 2 - 1) / narrow
                    let i = row * Self.fireWidth + x
                    heat[i] = min(1.2, heat[i] + Float(0.55 * max(0, 1 - u * u) * random.range(0.6, 1)))
                }
            }
            for _ in 0..<32 { launchSpark(speed: 1.4, spread: 2.6) }
        }

        // The fire steps at its own rate, slower through a breakdown.
        clock += dt * Self.stepRate * (1 - 0.4 * calm)
        var steps = 0
        while clock >= 1, steps < 8 {
            clock -= 1
            steps += 1
            step(silent: silent)
        }
        if steps == 8 { clock = 0 }

        for i in sparks.indices {
            sparks[i].vx += sin(time * 5 + sparks[i].wobble) * 30 * dt
            sparks[i].vx *= exp(-dt * 2)
            sparks[i].vy += 10 * dt
            sparks[i].x += sparks[i].vx * dt
            sparks[i].y += sparks[i].vy * dt
            sparks[i].life -= dt * (silent ? 6 : 1)
        }
        sparks.removeAll { $0.life <= 0 || $0.y < 0 }
    }

    /// How hot the fuel row burns at column `x`: most in the middle, none at the edges.
    private func sourceShape(_ x: Int) -> Double {
        let u = abs((Double(x) + 0.5) / Double(Self.fireWidth) * 2 - 1)
        let k = u / 0.86
        return max(0, 1 - k * k * k * k)
    }

    /// One step of the fire: the fuel rows from the spectrum, then every cell takes the heat from below it (from a
    /// column jittered sideways), less the cooling.
    private func step(silent: Bool) {
        let w = Self.fireWidth, h = Self.fireHeight
        scroll = (scroll + 1) % Self.noiseRows
        let gain = 1 - 0.3 * calm
        // As the fuel drops a little heat stays at the heart, so a quiet track still burns.
        let ember = 0.5
        for x in 0..<w {
            let shape = sourceShape(x)
            let u = abs((Double(x) + 0.5) / Double(w) * 2 - 1)
            let band = Double(bars.isEmpty ? 0 : barLevel(at: u))
            let flicker = random.range(0.72, 1.05)
            let hot = fuel * gain * (0.55 + 0.7 * band) + 0.3 * pulse * (1 - calm) + 0.45 * whoosh
            let heart = max(0, 1 - u / 0.45)
            let value = Float((shape * hot + heart * ember * (1 - fuel)) * flicker)
            heat[(h - 1) * w + x] = value
            heat[(h - 2) * w + x] = value * Float(random.range(0.85, 1))
        }
        // Silent, the flames are snuffed fast.
        let base: Float = silent ? 0.1 : Float(0.03 - 0.012 * whoosh)
        // Through a breakdown the cooling pattern is smoother, so the low flames stay whole.
        let tear = Float(2.2 - 1.1 * calm)
        let jitter = 0.36 * (1 - 0.6 * calm)
        for row in 0..<(h - 2) {
            let noiseRow = ((row + scroll) % Self.noiseRows) * w
            let below = (row + 1) * w, below2 = (row + 2) * w
            for x in 0..<w {
                var sx = x
                let r = random.next()
                if r < jitter / 2 { sx = max(0, x - 1) } else if r < jitter { sx = min(w - 1, x + 1) }
                let sum = heat[below + max(sx - 1, 0)] + heat[below + sx] + heat[below + min(sx + 1, w - 1)]
                    + heat[below2 + sx]
                let n = coolNoise[noiseRow + x]
                let cool = base * (0.35 + tear * n * n) + edgeCool[x] + heightCool[row]
                heat[row * w + x] = max(0, sum * 0.25 - cool)
            }
        }
    }

    /// The bars spread out from the middle: bass at `u` 0 (the heart), treble at 1 (the edges).
    private func barLevel(at u: Double) -> Float {
        let x = min(max(u, 0), 1) * Double(bars.count - 1)
        let i = Int(x)
        let f = Float(x - Double(i))
        return bars[i] + (bars[min(i + 1, bars.count - 1)] - bars[i]) * f
    }

    /// A spark from the heart of the fire, flying up (`spread` widens the fan it flies in).
    private func launchSpark(speed: Double, spread: Double) {
        guard sparks.count < 60 else { return }
        let life = random.range(0.6, 1.3)
        sparks.append(Spark(x: 23 + random.range(-6, 6), y: 30 + random.range(-4, 3),
                            vx: random.range(-10, 10) * spread, vy: -random.range(22, 40) * speed, life: life,
                            span: life, wobble: random.range(0, 2 * .pi), color: random.int(4)))
    }

    // MARK: - Draw

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        if styled != style {
            ramp = Self.makeRamp(style)
            paints = Paints(style)
            styled = style
        }
        canvas.clear()
        // How brightly the fire lights its surroundings: the flames, or the embers' glow.
        let light = 0.45 + 0.55 * fuel + 0.3 * whoosh
        paintGlow(style, light: light)
        paintFire()
        paintLogs(style, light: light)
        paintEmbers()
        for stone in stones { paintStone(stone, style: style, light: light) }
        paintSmoke()
        paintSparks(style)
        canvas.draw(in: ctx, rect: CGRect(origin: .zero, size: size))
    }

    /// Firelight round the fire on dark artwork (in bands, like the pixels), a lit patch of ground under it; on light
    /// artwork just a soft shadow on the ground.
    private func paintGlow(_ style: SceneStyle, light: Double) {
        if !style.isLight {
            let strength = 0.055 * light
            for y in 4..<44 {
                for x in 2..<44 {
                    let dx = Double(x) + 0.5 - 23, dy = (Double(y) + 0.5 - 31) * 1.1
                    let d = dx * dx + dy * dy
                    let bands = (d < 100 ? 1.0 : 0) + (d < 210 ? 1 : 0) + (d < 380 ? 1 : 0)
                    if bands > 0 { canvas.set(x, y, paints.glow, strength * bands) }
                }
            }
        }
        for y in 38..<46 {
            for x in 4..<42 {
                let dx = (Double(x) + 0.5 - 23) / 17, dy = (Double(y) + 0.5 - 41.5) / 3.6
                let d = dx * dx + dy * dy
                guard d <= 1 else { continue }
                if style.isLight {
                    canvas.set(x, y, paints.shadow, d < 0.5 ? 0.16 : 0.09)
                } else {
                    canvas.set(x, y, paints.glow, (d < 0.5 ? 0.22 : 0.12) * light)
                }
            }
        }
    }

    private func paintFire() {
        let w = Self.fireWidth
        let top = Float(Self.rampSize - 1)
        // The fuel rows stay hidden behind the logs.
        for row in 0..<(Self.fireHeight - 2) {
            for x in 0..<w {
                let v = heat[row * w + x]
                guard v > 0.06 else { continue }
                let entry = ramp[Int(min(v / 0.95, 1) * top)]
                guard entry.alpha > 0.01 else { continue }
                canvas.set(Self.fireX + x, Self.fireY + row, entry.color, entry.alpha)
            }
        }
    }

    /// Two logs crossed under the fire, the back one first; their cut ends face us.
    private func paintLogs(_ style: SceneStyle, light: Double) {
        // Their upper sides catch the firelight (on dark artwork).
        let lit = style.isLight ? 0 : 0.3 * light
        let logs = [(SIMD2(35, 40.2), SIMD2(14.5, 33.6)), (SIMD2(11, 40.2), SIMD2(31.5, 33.6))]
        for (near, far) in logs {
            let axis = far - near
            let len2 = (axis * axis).sum()
            let r = 2.05
            shape(x0: Int(min(near.x, far.x) - 4), y0: Int(min(near.y, far.y) - 4), x1: Int(max(near.x, far.x) + 4),
                  y1: Int(max(near.y, far.y) + 4), outline: paints.outline, inside: { x, y in
                      let q = SIMD2(x, y) - near
                      let t = min(max((q * axis).sum() / len2, 0), 1)
                      let d = q - axis * t
                      return (d * d).sum() <= r * r
                  }, fill: { [wood, paints] x, y in
                      let q = SIMD2(Double(x) + 0.5, Double(y) + 0.5) - near
                      let t = (q * axis).sum() / len2
                      let d = q - axis * t
                      // Across the log: -1 its top edge, 1 its underside.
                      let across = (d.y >= 0 ? 1.0 : -1) * (d * d).sum().squareRoot() / r
                      let bark = wood.bark(across: across, x: x, y: y)
                      return across < -0.45 ? bark.mixed(with: paints.glow, lit) : bark
                  })
            // The cut end: pale end grain with a ring.
            shape(x0: Int(near.x) - 3, y0: Int(near.y) - 3, x1: Int(near.x) + 3, y1: Int(near.y) + 3,
                  outline: paints.outline, inside: { x, y in
                      let dx = (x - near.x) / 1.7, dy = (y - near.y) / 2.15
                      return dx * dx + dy * dy <= 1
                  }, fill: { [wood] x, y in
                      let dx = Double(x) + 0.5 - near.x, dy = Double(y) + 0.5 - near.y
                      return dx * dx + dy * dy < 0.8 ? wood.ring : wood.end
                  })
        }
    }

    /// A bed of coals where the logs cross, each breathing slowly; in silence they're what's left glowing, with a few
    /// small flames licking up from them.
    private func paintEmbers() {
        for ember in embers {
            let breathe = 0.5 + 0.5 * sin(time * ember.speed + ember.phase)
            let hotness = ember.heat * (0.75 + 0.3 * breathe)
            let entry = ramp[min(Self.rampSize - 1, Int(hotness * Double(Self.rampSize - 1)))]
            canvas.set(ember.x, ember.y, entry.color, 1)
        }
        let low = 1 - min(1, fuel * 2.5)
        guard low > 0.02 else { return }
        // Each a little teardrop: two pixels wide at its foot, a darker point at its tip that leans.
        for lick in licks {
            let height = lick.height + (sin(time * lick.speed + lick.phase) > 0.4 ? 1 : 0)
            for k in 0..<height {
                let t = Double(k) / Double(max(height - 1, 1))
                let entry = ramp[Int((0.62 - 0.4 * t) * Double(Self.rampSize - 1))]
                let tip = k == height - 1
                let x = lick.x + (tip ? lick.lean : 0)
                canvas.set(x, 34 - k, entry.color, low)
                if !tip { canvas.set(x + 1, 34 - k, entry.color, low * (k == 0 ? 1 : 0.85)) }
            }
        }
    }

    private func paintStone(_ stone: Stone, style: SceneStyle, light: Double) {
        let warm = style.isLight ? 0 : 0.35 * light
        shape(x0: Int(stone.x - stone.rx) - 1, y0: Int(stone.y - stone.ry) - 1, x1: Int(stone.x + stone.rx) + 1,
              y1: Int(stone.y + stone.ry) + 1, outline: paints.outline, inside: { x, y in
                  let dx = (x - stone.x) / stone.rx, dy = (y - stone.y) / stone.ry
                  return dx * dx + dy * dy <= 1
              }, fill: { [paints] x, y in
                  let dy = (Double(y) + 0.5 - stone.y) / stone.ry
                  let base = paints.stone.mixed(with: .white, stone.tone)
                  if dy < -0.35 { return base.mixed(with: paints.glow, warm).mixed(with: .white, 0.18) }
                  return dy > 0.45 ? base.scaled(0.72) : base
              })
    }

    /// A thin wisp of smoke curling up from the embers once the flames are out.
    private func paintSmoke() {
        let amount = min(1, max(0, (silentFor - 0.12) / 0.3)) * (1 - fuel)
        guard amount > 0.02 else { return }
        let drift = max(0, silentFor - 0.4)
        for k in 0..<22 {
            let t = Double(k) / 21
            let x = 23 + sin(t * 4.2 + drift * 0.9) * (0.4 + 3.2 * t) + t * 2
            canvas.set(Int(x.rounded(.down)), 30 - k, paints.smoke, amount * 0.4 * (1 - t * 0.85))
        }
    }

    private func paintSparks(_ style: SceneStyle) {
        for spark in sparks {
            let t = spark.life / spark.span
            // Hot and yellow at first, cooling into one of the artwork's colours (darker, on light artwork).
            let entry = ramp[min(Self.rampSize - 1, Int((0.3 + 0.55 * t) * Double(Self.rampSize - 1)))]
            let cooled = style.isLight ? style.spark(spark.color).mixed(with: style.ink, 0.4) : style.spark(spark.color)
            let color = t > 0.45 ? entry.color : cooled
            let x = Int(spark.x.rounded(.down)), y = Int(spark.y.rounded(.down))
            canvas.set(x, y, color, min(1, t * 3))
            // Young sparks trail a dimmer pixel below.
            if t > 0.6 { canvas.set(x, y + 1, color, 0.45) }
        }
    }

    // MARK: - Pixel helpers

    /// Paints an outlined shape: every pixel whose centre is `inside` (within the box) in `fill`'s colour, and the
    /// pixels around them in `outline`.
    private func shape(x0 rawX0: Int, y0 rawY0: Int, x1 rawX1: Int, y1 rawY1: Int, outline: RGB,
                       inside: (Double, Double) -> Bool, fill: (Int, Int) -> RGB) {
        let n = Self.side
        let x0 = max(rawX0, 0), y0 = max(rawY0, 0), x1 = min(rawX1, n - 1), y1 = min(rawY1, n - 1)
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 {
            for x in x0...x1 { mask[y * n + x] = inside(Double(x) + 0.5, Double(y) + 0.5) }
        }
        func at(_ x: Int, _ y: Int) -> Bool { x >= x0 && x <= x1 && y >= y0 && y <= y1 && mask[y * n + x] }
        for y in (y0 - 1)...(y1 + 1) {
            for x in (x0 - 1)...(x1 + 1) where !at(x, y) {
                if at(x - 1, y) || at(x + 1, y) || at(x, y - 1) || at(x, y + 1) { canvas.set(x, y, outline) }
            }
        }
        for y in y0...y1 {
            for x in x0...x1 where mask[y * n + x] { canvas.set(x, y, fill(x, y)) }
        }
    }

    // MARK: - Making things

    /// The fire's colours from cold to white hot, as (colour, alpha). Dark artwork: transparent deep red through
    /// orange and yellow to a near-white core, a little of the artwork's accent in the middle. Light artwork: an opaque
    /// dark red rim (an outline, in effect) up to a deep golden core, no white.
    static func makeRamp(_ style: SceneStyle) -> [(color: RGB, alpha: Double)] {
        let tint = style.accent
        let stops: [(Double, RGB, Double)]
        if style.isLight {
            stops = [(0, RGB(hex: 0x3A0A06), 0), (0.06, RGB(hex: 0x4A0D08), 0.9), (0.2, RGB(hex: 0x9A1C0C), 1),
                     (0.42, RGB(hex: 0xD8420E), 1), (0.65, RGB(hex: 0xF07A14), 1), (0.85, RGB(hex: 0xF7A41E), 1),
                     (1, RGB(hex: 0xFBC22E), 1)]
        } else {
            stops = [(0, RGB(hex: 0x5A0A06), 0), (0.08, RGB(hex: 0x7A1208), 0.55), (0.22, RGB(hex: 0xC0260C), 0.95),
                     (0.42, RGB(hex: 0xF0601A).mixed(with: tint, 0.1), 1),
                     (0.62, RGB(hex: 0xFFA02A).mixed(with: tint, 0.12), 1),
                     (0.8, RGB(hex: 0xFFD860).mixed(with: tint, 0.08), 1), (1, RGB(hex: 0xFFF6DA), 1)]
        }
        return (0..<rampSize).map { i in
            let t = Double(i) / Double(rampSize - 1)
            var k = 0
            while k < stops.count - 2, t > stops[k + 1].0 { k += 1 }
            let a = stops[k], b = stops[k + 1]
            let f = min(max((t - a.0) / max(b.0 - a.0, 0.0001), 0), 1)
            return (a.1.mixed(with: b.1, f), a.2 + (b.2 - a.2) * f)
        }
    }

    /// A smooth seeded noise, 0...1, wrapping vertically: random values on a coarse grid, smoothly interpolated.
    static func noise(_ random: inout SceneRandom, width: Int, height: Int) -> [Float] {
        let gx = 7, gy = 12
        let grid = (0..<(gx * gy)).map { _ in random.next() }
        func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let fy = Double(y) / Double(height) * Double(gy)
            let y0 = Int(fy) % gy, y1 = (y0 + 1) % gy, ty = smooth(fy - fy.rounded(.down))
            for x in 0..<width {
                let fx = Double(x) / Double(width - 1) * Double(gx - 1)
                let x0 = min(Int(fx), gx - 2), tx = smooth(fx - Double(x0))
                let top = grid[y0 * gx + x0] + (grid[y0 * gx + x0 + 1] - grid[y0 * gx + x0]) * tx
                let bottom = grid[y1 * gx + x0] + (grid[y1 * gx + x0 + 1] - grid[y1 * gx + x0]) * tx
                out[y * width + x] = Float(top + (bottom - top) * ty)
            }
        }
        return out
    }
}

// MARK: - Pieces

/// The logs: oak, birch or charred.
nonisolated private struct Wood {
    let bark: RGB
    let barkShade: RGB
    let barkLight: RGB
    let mark: RGB
    let end: RGB
    let ring: RGB
    let birch: Bool

    init(_ r: inout SceneRandom) {
        switch r.int(3) {
        case 0:
            (bark, barkShade, barkLight, mark) = (RGB(hex: 0x6E4428), RGB(hex: 0x4A2C18), RGB(hex: 0x8E5E38),
                                                  RGB(hex: 0x3E2414))
            (end, ring, birch) = (RGB(hex: 0xDDB47E), RGB(hex: 0xA77A47), false)
        case 1:
            (bark, barkShade, barkLight, mark) = (RGB(hex: 0xE6E0D2), RGB(hex: 0xBDB4A2), RGB(hex: 0xF6F2EA),
                                                  RGB(hex: 0x3A3430))
            (end, ring, birch) = (RGB(hex: 0xEACB9C), RGB(hex: 0xB89464), true)
        default:
            (bark, barkShade, barkLight, mark) = (RGB(hex: 0x4E3E34), RGB(hex: 0x33281F), RGB(hex: 0x6A5646),
                                                  RGB(hex: 0x231A14))
            (end, ring, birch) = (RGB(hex: 0xC99A66), RGB(hex: 0x8E6638), false)
        }
    }

    /// The bark at pixel (x, y), `across` the log from -1 (its top edge) to 1 (its underside): knots or birch marks.
    func bark(across: Double, x: Int, y: Int) -> RGB {
        if birch, (x * 7 + y * 3) % 11 == 0 { return mark }
        if !birch, (x * 5 + y * 2) % 9 == 0, abs(across) < 0.6 { return mark }
        if across < -0.45 { return barkLight }
        return across > 0.4 ? barkShade : bark
    }
}

nonisolated private struct Stone {
    let x: Double
    let y: Double
    let rx: Double
    let ry: Double
    /// How much lighter than the palette's stone colour.
    let tone: Double

    /// A row of stones along the front of the fire, gaps between them jittered.
    static func ring(_ r: inout SceneRandom) -> [Stone] {
        var stones: [Stone] = []
        var x = 12.5 + r.range(0, 1.5)
        while x < 34 {
            let rx = r.range(2.1, 2.9)
            let centre = x + rx
            guard centre + rx < 35.5 else { break }
            stones.append(Stone(x: centre, y: 43.4 + r.range(-0.3, 0.2), rx: rx, ry: r.range(1.5, 1.8),
                                tone: r.range(0, 0.18)))
            x = centre + rx + r.range(0.5, 1.2)
        }
        return stones
    }
}

nonisolated private struct Ember {
    let x: Int
    let y: Int
    /// How hot it glows, 0...1 on the fire's ramp.
    let heat: Double
    let phase: Double
    let speed: Double

    /// A low mound of coals in the crossing of the logs: dark red at its rim, glowing orange and a few yellow inside.
    static func scatter(_ r: inout SceneRandom) -> [Ember] {
        var embers: [Ember] = []
        let rows: [(y: Int, half: Int)] = [(34, 2), (35, 4), (36, 5), (37, 6)]
        for (y, half) in rows {
            for x in (23 - half)..<(23 + half) {
                let edge = x == 23 - half || x == 22 + half || y == 34
                let heat = edge ? r.range(0.22, 0.34) : r.chance(0.2) ? r.range(0.62, 0.78) : r.range(0.36, 0.56)
                embers.append(Ember(x: x, y: y, heat: heat, phase: r.range(0, 2 * .pi), speed: r.range(1.2, 2.8)))
            }
        }
        return embers
    }
}

nonisolated private struct Lick {
    let x: Int
    let height: Int
    let lean: Int
    let phase: Double
    let speed: Double

    /// Two or three small flames over the coals, a tall one near the middle.
    static func scatter(_ r: inout SceneRandom) -> [Lick] {
        let count = 2 + r.int(2)
        return (0..<count).map { i in
            let x = count == 2 ? [19, 24][i] + r.int(2) : [18, 22, 25][i] + r.int(2)
            let middle = abs(x - 23) <= 2
            return Lick(x: x, height: middle ? 3 : 2 + r.int(2), lean: r.int(3) - 1, phase: r.range(0, 2 * .pi),
                        speed: r.range(1.5, 3))
        }
    }
}

nonisolated private struct Spark {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var life: Double
    let span: Double
    let wobble: Double
    let color: Int
}

/// Colours that depend on the artwork.
nonisolated private struct Paints {
    var outline = RGB(hex: 0x1A1210)
    var glow = RGB(hex: 0xFF8A2A)
    var shadow = RGB.black
    var stone = RGB(hex: 0x7A7880)
    var smoke = RGB.white

    init() {}

    init(_ style: SceneStyle) {
        let light = style.isLight
        outline = light ? style.ink.mixed(with: RGB(hex: 0x1A1210), 0.6).scaled(0.7)
            : RGB(hex: 0x1A1210).mixed(with: style.deep, 0.2)
        glow = RGB(hex: 0xFF8A2A).mixed(with: style.accent, 0.15)
        shadow = style.ink
        stone = (light ? RGB(hex: 0x8C8A90) : RGB(hex: 0x6E6C76)).mixed(with: style.deep, 0.18)
        smoke = light ? style.ink : RGB(hex: 0xC8C4CC)
    }
}
