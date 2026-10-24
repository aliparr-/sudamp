// SPDX-License-Identifier: GPL-3.0-or-later
// Cells: Conway's rules (a cell with two or three neighbours lives on, an empty one with exactly three comes alive) on
// a wrapping board of 23 × 23 rounded dots, one generation per beat. On every kick the music plants small patterns
// (gliders, R-pentominoes, acorns, spaceships) where the spectrum stands out, more of them when it's loud, each in the
// colour of its band; cells born later take the colour most of their parents share, so the bands' colours spread and
// mix. Newborn cells flash bright and settle, and dying ones leave an afterglow that fades through the beat. When the
// board thins out or gets stuck, something new is planted. Through a breakdown it slows to a generation every two
// beats in softer colours. The drop wipes the board in a flash (its cells fading out as afterglow) and fires a ring of
// eight gliders outwards from the middle, left to fly for a bar or so before the kicks plant again. In silence the
// board stops and the glow fades, leaving a still picture of the cells; a fresh board is a few still lifes (blocks,
// beehives, loaves, boats, tubs) laid out by the seed, which also picks the colours' order.

import CoreGraphics
import Foundation

nonisolated final class CellsScene: VisualizerScene {
    /// Cells across and down: 4 points a cell on the 92-point artwork, whole pixels at 1x and 2x.
    private static let n = 23
    private static let count = n * n
    /// Colours: four bands of the spectrum, each a spark colour.
    private static let hues = 4
    /// The afterglow is drawn in three steps of brightness (one fill each), from these levels up; below the first it
    /// is gone.
    private static let glowSteps: [Float] = [0.08, 0.35, 0.68]

    private var alive = [UInt8](repeating: 0, count: count)
    private var hue = [UInt8](repeating: 0, count: count)
    /// Generations each live cell has lived (0: born this one).
    private var age = [UInt8](repeating: 0, count: count)
    /// What's left of each dead cell's light, 0...1.
    private var afterglow = [Float](repeating: 0, count: count)
    private var nextAlive = [UInt8](repeating: 0, count: count)
    private var nextHue = [UInt8](repeating: 0, count: count)
    /// Each cell's eight neighbours on the wrapping board, worked out once.
    private let neighbours: [Int]
    private var random: SceneRandom
    private let hueBase: Int

    // The music.
    private var activity = 0.0
    private var calm = 0.0
    private var halfTime = false
    private var dropLock = false
    private var lastGroove = 0.0
    private var beatIndex = 0
    /// Seconds since the last generation: newborn cells shine while it's short.
    private var sinceStep = 10.0
    private var flash = 0.0
    /// Each band's usual level, so a band standing out from its own norm counts as a peak (the bass is always loud).
    private var usual = [Float](repeating: 0.3, count: VisualizerInput.barCount)
    private var level = 0.0

    // Keeping it alive.
    private var population = 0
    private var history: [UInt64] = []
    private var stuck = 0
    /// Beats left with nothing planted on the kicks (after the drop, so its ring of gliders reads).
    private var quiet = 0

    var glow: Double { 0.5 }

    init(seed: UInt64) {
        random = SceneRandom(seed: seed)
        hueBase = random.int(4)
        var table = [Int](repeating: 0, count: Self.count * 8)
        let n = Self.n
        for y in 0..<n {
            for x in 0..<n {
                var k = 0
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        table[(y * n + x) * 8 + k] = ((y + dy + n) % n) * n + (x + dx + n) % n
                        k += 1
                    }
                }
            }
        }
        neighbours = table
        layOutStillLifes()
        for i in 0..<Self.count where alive[i] != 0 { age[i] = 9 }
        population = alive.reduce(0) { $0 + Int($1) }
    }

    /// A fresh board: a few still lifes, apart from each other, clear of the rounded corners and the window's buttons
    /// at the top left.
    private func layOutStillLifes() {
        var boxes: [(x: Int, y: Int, w: Int, h: Int)] = []
        var placed = 0, tries = 0
        let wanted = 6 + random.int(3)
        while placed < wanted, tries < 200 {
            tries += 1
            let shape = Shape.stillLifes[random.int(Shape.stillLifes.count)]
            let orientation = random.int(8)
            let cells = Shape.oriented(shape, orientation)
            let w = (cells.map(\.0).max() ?? 0) + 1, h = (cells.map(\.1).max() ?? 0) + 1
            let x = random.int(Self.n - 4 - w) + 2, y = random.int(Self.n - 4 - h) + 2
            // Clear of the corners (and the buttons), and two cells from every other one.
            let corner = (x < 5 || x + w > Self.n - 5) && (y < 5 || y + h > Self.n - 5)
            if corner || (x < 8 && y < 6) { continue }
            let near = boxes.contains { box in
                x < box.x + box.w + 2 && box.x < x + w + 2 && y < box.y + box.h + 2 && box.y < y + h + 2
            }
            if near { continue }
            boxes.append((x, y, w, h))
            let colour = UInt8(placed % Self.hues)
            for (dx, dy) in cells { set(x + dx, y + dy, hue: colour) }
            placed += 1
        }
    }

    // MARK: - Update

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let silent = input.isSilent
        activity += ((silent ? 0 : 1) - activity) * (1 - exp(-dt * (silent ? 12 : 5)))
        if silent, activity < 0.02 { activity = 0 }
        level += (Double(input.level) - level) * min(1, dt * 8)
        sinceStep += dt
        flash *= exp(-dt * (silent ? 20 : 4))

        // The afterglow fades through about a beat (quickly in silence, so the still frame is clean).
        let fade = Float(exp(-dt / (silent ? 0.07 : 0.38 + 0.3 * calm)))
        for i in 0..<Self.count where afterglow[i] > 0 {
            afterglow[i] *= fade
            if afterglow[i] < Self.glowSteps[0] { afterglow[i] = 0 }
        }

        // Each band's usual level, followed over a few seconds.
        let follow = Float(min(1, dt / 3))
        for b in 0..<min(usual.count, input.bars.count) { usual[b] += (input.bars[b] - usual[b]) * follow }

        // Half time through a breakdown, but not straight after a drop (the breakdown takes a second to ease off).
        let breakdown = Double(input.breakdown)
        if dropLock, breakdown < 0.25 { dropLock = false }
        if dropLock || breakdown < 0.3 {
            halfTime = false
        } else if breakdown > 0.6 {
            halfTime = true
        }
        calm += ((dropLock ? 0 : breakdown) - calm) * min(1, dt * 4)

        let wrapped = input.groove < lastGroove - 0.5
        lastGroove = input.groove
        guard !silent else { return }

        if input.drop { drop() }
        if wrapped {
            beatIndex += 1
            quiet = max(0, quiet - 1)
            if !halfTime || beatIndex % 2 == 0 {
                step()
                // In half time the generation itself plants (the breakdown's kicks fall between the beats).
                if halfTime { plantFromSpectrum(input, most: 1) }
            }
        }
        if input.beat, !halfTime, quiet == 0 { plantFromSpectrum(input, most: 2) }
    }

    /// One generation, by Conway's rules. A newborn takes the colour most of its three parents share.
    private func step() {
        sinceStep = 0
        var count = 0
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for i in 0..<Self.count {
            let base = i * 8
            var live = 0
            for k in 0..<8 { live += Int(alive[neighbours[base + k]]) }
            let lives = alive[i] != 0 ? (live == 2 || live == 3) : live == 3
            nextAlive[i] = lives ? 1 : 0
            if lives {
                count += 1
                hash = (hash ^ UInt64(i)) &* 0x100_0000_01B3
                nextHue[i] = alive[i] != 0 ? hue[i] : parentsHue(base)
            }
        }
        for i in 0..<Self.count {
            if nextAlive[i] != 0 {
                age[i] = alive[i] != 0 ? min(age[i] &+ 1, 200) : 0
                hue[i] = nextHue[i]
                afterglow[i] = 0
            } else if alive[i] != 0 {
                afterglow[i] = 0.9
            }
            alive[i] = nextAlive[i]
        }
        population = count

        // Stuck: the board repeats itself (still lifes and blinkers only) or has nearly emptied.
        if history.contains(hash) || count < 18 { stuck += 1 } else { stuck = 0 }
        history.append(hash)
        if history.count > 4 { history.removeFirst() }
        if stuck >= 3 {
            stuck = 0
            let shape = random.chance(0.5) ? Shape.rPentomino : Shape.acorn
            plant(shape, x: random.int(Self.n), y: random.int(Self.n), hue: UInt8(random.int(Self.hues)),
                  orientation: random.int(8))
        }
    }

    /// The colour shared by most of a newborn's three live neighbours (the first one's if they all differ).
    private func parentsHue(_ base: Int) -> UInt8 {
        var seen: (UInt8, UInt8, UInt8) = (255, 255, 255)
        var k = 0
        for j in 0..<8 {
            let c = neighbours[base + j]
            guard alive[c] != 0 else { continue }
            switch k {
            case 0: seen.0 = hue[c]
            case 1: seen.1 = hue[c]
            default: seen.2 = hue[c]
            }
            k += 1
            if k == 3 { break }
        }
        return seen.1 == seen.2 ? seen.1 : seen.0
    }

    /// Plants up to `most` patterns where the spectrum stands out most from its usual shape: across the board by
    /// frequency, each in its band's colour. Fewer when the board is crowded.
    private func plantFromSpectrum(_ input: VisualizerInput, most: Int) {
        let bars = input.bars
        guard !bars.isEmpty else { return }
        var wanted = min(most, 1 + (level > 0.55 ? 1 : 0))
        // A busy board is left to work itself out: Life thins a crowd by itself.
        if population > Self.count * 3 / 20 {
            wanted = 0
        } else if population > Self.count / 10 {
            wanted = min(wanted, 1)
        }
        var picked: [Int] = []
        for _ in 0..<wanted {
            var best = -1
            var bestScore: Float = 0
            for b in 0..<bars.count where !picked.contains(where: { abs($0 - b) < 4 }) {
                let score = bars[b] / max(usual[min(b, usual.count - 1)], 0.12)
                if score > bestScore {
                    best = b
                    bestScore = score
                }
            }
            guard best >= 0, bars[best] > 0.05 else { break }
            picked.append(best)
            let x = Int((Double(best) + 0.5) / Double(bars.count) * Double(Self.n)) + random.int(5) - 2
            let y = 2 + random.int(Self.n - 4)
            let colour = UInt8(min(Self.hues - 1, best * Self.hues / bars.count))
            plant(pickShape(), x: x, y: y, hue: colour, orientation: random.int(8))
        }
    }

    /// Mostly gliders; more of the patterns that explode when the board is thin, small ones when it's busy.
    private func pickShape() -> [(Int, Int)] {
        let roll = random.next()
        if population < Self.count / 8 {
            return roll < 0.35 ? Shape.rPentomino : roll < 0.55 ? Shape.acorn : Shape.glider
        }
        if roll < 0.5 { return Shape.glider }
        if roll < 0.65 { return Shape.rPentomino }
        if roll < 0.78 { return Shape.spaceship }
        if roll < 0.9 { return Shape.blinker }
        return Shape.boat
    }

    /// The bass came back: the board is wiped (its cells fading out as afterglow) and a ring of gliders flies outwards
    /// from the middle, in every colour, left to itself for six beats.
    private func drop() {
        flash = 1
        dropLock = true
        halfTime = false
        quiet = 6
        let n = Self.n, c = Double(n - 1) / 2
        for i in 0..<Self.count where alive[i] != 0 {
            afterglow[i] = 1
            alive[i] = 0
        }
        population = 0
        history.removeAll()
        // Eight gliders seven cells out, just off the axes and diagonals (so each one's way out is clear): they fly
        // apart for about twenty generations before any of them meet.
        let gliders = 8
        let turn = (random.chance(0.5) ? 0.05 : -0.05) + Double(random.int(4)) * .pi / 2
        for k in 0..<gliders {
            let angle = turn + Double(k) / Double(gliders) * 2 * .pi
            let cx = c + cos(angle) * 7, cy = c + sin(angle) * 7
            // A glider runs diagonally: flipped to head away from the middle.
            let orientation = (cos(angle) < 0 ? 1 : 0) | (sin(angle) < 0 ? 2 : 0)
            plant(Shape.glider, x: Int(cx.rounded()) - 1, y: Int(cy.rounded()) - 1, hue: UInt8(k % Self.hues),
                  orientation: orientation)
        }
        sinceStep = 0
    }

    /// Plants `shape` (turned and flipped by `orientation`, 0..<8) with its corner at (x, y), wrapping.
    private func plant(_ shape: [(Int, Int)], x: Int, y: Int, hue colour: UInt8, orientation: Int) {
        for (dx, dy) in Shape.oriented(shape, orientation) { set(x + dx, y + dy, hue: colour) }
        sinceStep = min(sinceStep, 0.04)
    }

    private func set(_ x: Int, _ y: Int, hue colour: UInt8) {
        let n = Self.n
        let i = ((y % n + n) % n) * n + (x % n + n) % n
        if alive[i] == 0 {
            population += 1
            age[i] = 0
        }
        alive[i] = 1
        hue[i] = colour
        afterglow[i] = 0
    }

    // MARK: - Draw

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let light = style.isLight
        let pitch = size.width / CGFloat(Self.n)
        let dot = pitch * 0.75
        let radius = dot * 0.3
        // Paths per colour: the grown-up cells, the newborn, and three steps of afterglow.
        let kinds = 2 + Self.glowSteps.count
        let paths = (0..<(Self.hues * kinds)).map { _ in CGMutablePath() }
        let n = Self.n
        let newborn = activity > 0 && sinceStep < 0.6
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
                let kind: Int
                if alive[i] != 0 {
                    kind = newborn && age[i] == 0 ? 1 : 0
                } else if afterglow[i] > 0 {
                    let g = afterglow[i]
                    kind = g > Self.glowSteps[2] ? 4 : g > Self.glowSteps[1] ? 3 : 2
                } else {
                    continue
                }
                let rect = CGRect(x: CGFloat(x) * pitch, y: CGFloat(y) * pitch, width: dot, height: dot)
                paths[Int(hue[i]) * kinds + kind].addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
            }
        }

        let soft = 1 - 0.3 * calm
        let shine = newborn ? exp(-sinceStep / 0.2) * (1 - 0.5 * calm) : 0
        for h in 0..<Self.hues {
            let spark = style.spark(h + hueBase)
            let colour = light ? spark.mixed(with: style.ink, 0.5) : spark.mixed(with: style.ink, 0.2)
            let bright = light ? style.ink : colour.mixed(with: .white, 0.75)
            let base = h * kinds
            for (k, alpha) in [(2, 0.12), (3, 0.24), (4, 0.4)] where !paths[base + k].isEmpty {
                ctx.addPath(paths[base + k])
                ctx.setFill(colour, alpha * soft)
                ctx.fillPath()
            }
            if !paths[base].isEmpty {
                ctx.addPath(paths[base])
                ctx.setFill(colour, 0.9 * soft)
                ctx.fillPath()
            }
            if !paths[base + 1].isEmpty {
                ctx.addPath(paths[base + 1])
                ctx.setFill(colour.mixed(with: bright, shine), (0.9 + 0.1 * shine) * soft)
                ctx.fillPath()
            }
        }
        if flash > 0.02 {
            ctx.setFill(light ? style.ink : style.ink.mixed(with: .white, 0.5), flash * (light ? 0.15 : 0.25))
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Patterns

/// Patterns as live cells from their top-left corner.
private nonisolated enum Shape {
    static let glider = [(1, 0), (2, 1), (0, 2), (1, 2), (2, 2)]
    static let rPentomino = [(1, 0), (2, 0), (0, 1), (1, 1), (1, 2)]
    static let acorn = [(1, 0), (3, 1), (0, 2), (1, 2), (4, 2), (5, 2), (6, 2)]
    /// The lightweight spaceship.
    static let spaceship = [(1, 0), (4, 0), (0, 1), (0, 2), (4, 2), (0, 3), (1, 3), (2, 3), (3, 3)]
    static let blinker = [(0, 0), (1, 0), (2, 0)]
    static let boat = [(0, 0), (1, 0), (0, 1), (2, 1), (1, 2)]

    static let block = [(0, 0), (1, 0), (0, 1), (1, 1)]
    static let beehive = [(1, 0), (2, 0), (0, 1), (3, 1), (1, 2), (2, 2)]
    static let loaf = [(1, 0), (2, 0), (0, 1), (3, 1), (1, 2), (3, 2), (2, 3)]
    static let tub = [(1, 0), (0, 1), (2, 1), (1, 2)]
    static let stillLifes = [block, beehive, loaf, boat, tub, block]

    /// `shape` flipped across (bit 0), flipped down (bit 1) and turned on its side (bit 2), moved back to start at
    /// (0, 0).
    static func oriented(_ shape: [(Int, Int)], _ orientation: Int) -> [(Int, Int)] {
        let w = (shape.map(\.0).max() ?? 0), h = (shape.map(\.1).max() ?? 0)
        return shape.map { cell in
            var (x, y) = cell
            if orientation & 1 != 0 { x = w - x }
            if orientation & 2 != 0 { y = h - y }
            if orientation & 4 != 0 { swap(&x, &y) }
            return (x, y)
        }
    }
}
