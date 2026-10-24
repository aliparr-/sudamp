// SPDX-License-Identifier: GPL-3.0-or-later
// Rally: a retro two-paddle table-tennis video game in bold pixels, on the same 46-pixel grid as Pixel DJ. A square
// ball crosses the court in exactly one beat, so it meets a paddle on every kick, left and right in turn, bouncing
// off the top and bottom walls at an angle picked afresh for each return (steeper and bouncier with the treble). The
// paddles watch the ball and move to meet it a moment before it lands, and every return flashes the paddle, nudges
// it and throws a few sparks. Every so often (a phrase of returns) a paddle lunges and just misses: the other side
// scores, and a new ball is served from the net on the same kick. Through a breakdown the rally drops to half time (a
// crossing every two beats) with a faint trail behind the ball. The drop flashes the screen and serves two more balls
// for four bars of multiball (one of them on the off-beats); when it ends the extra balls slip past and score. In
// silence the game rests in attract mode: the ball on the centre line, paddles centred, the score showing. Each seed
// changes who serves first, how often the players go for bank shots, how quickly each one reacts and how long a
// phrase of returns lasts.
//
// The rally runs on its own clock, in beats, that follows the beat clock: each crossing is a straight line from one
// paddle's face to the other's, landing on a whole beat, folded at the walls (so a bank shot lands exactly where it
// was aimed). The paddles' moves are worked out from the same clock, so they always arrive in time.

import CoreGraphics
import Foundation

nonisolated final class RallyScene: VisualizerScene {
    /// 46 pixels across: 2 points a pixel, whole pixels at 1x and 2x.
    private static let side = 46
    /// The ball's top row runs between these (the walls are the rows just outside); it is two pixels square.
    private static let ballHighest = 2.0
    private static let ballLowest = 42.0
    /// The ball's left column where it meets each paddle's face, and on the net.
    private static let leftFace = 5.0
    private static let rightFace = 39.0
    private static let netX = 22.0
    /// Each paddle's columns (two wide) and length; its top row runs between these.
    private static let paddleColumns = [3, 41]
    private static let paddleLength = 8.0
    private static let paddleHighest = 2.0
    private static let paddleLowest = 36.0
    /// Attract mode: the ball on the net in a gap between dashes, the paddles level with it.
    private static let restBallY = 22.0
    private static let restPaddleY = 19.0
    /// Beats of multiball after a drop.
    private static let multiballBeats = 16.0

    private var canvas = PixelCanvas(width: RallyScene.side, height: RallyScene.side)
    private var random: SceneRandom

    // What a seed picks.
    private var serveRight: Bool
    /// How often a return is a bank shot (before the treble adds more).
    private let bounciness: Double
    /// How long each player waits before moving, as a fraction of the ball's flight.
    private let reactions: [Double]
    /// Returns in a phrase: after about this many, the next one is missed.
    private let phrase: Int
    private let sparkBase: Int

    // The clock.
    private var lastGroove = 0.0
    private var beatCount = 0
    /// The rally's clock in beats: follows `beatCount + groove`, smoothly.
    private var clock = 0.0
    private var playing = false
    /// 0 in silence, 1 while music plays (smoothed).
    private var activity = 0.0
    /// How deep into a breakdown, for the trail and the softer colours.
    private var calm = 0.0
    private var halfTime = false
    /// Set by a drop, until the breakdown has eased off: no half time meanwhile.
    private var dropLock = false
    private var multiballUntil = -1.0
    private var treble = 0.0
    private var pulse = 0.0

    // The game.
    private var balls: [Ball] = []
    private var paddles = [Paddle(), Paddle()]
    private var scores = [0, 0]
    /// A score just went up: it blinks while this runs down.
    private var scoreFlash = [0.0, 0.0]
    private var returns = 0
    /// This phrase's length in returns: the seed's, give or take one, so either side may miss.
    private var phraseLength = 16
    private var nextID = 0
    private var sparks: [Spark] = []
    /// The whole screen's flash on the drop.
    private var flash = 0.0
    private var styled: SceneStyle?
    private var vivid: [RGB] = [.white]

    /// None: a halo would blur the pixels.
    var glow: Double { 0 }

    init(seed: UInt64) {
        random = SceneRandom(seed: seed)
        serveRight = random.chance(0.5)
        bounciness = random.range(0.25, 0.55)
        reactions = [random.range(0.04, 0.18), random.range(0.04, 0.18)]
        phrase = [12, 16, 16, 20][random.int(4)]
        sparkBase = random.int(4)
        phraseLength = phrase + random.int(2)
        for i in paddles.indices { paddles[i].y = Self.restPaddleY }
    }

    // MARK: - Update

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let silent = input.isSilent
        activity += ((silent ? 0 : 1) - activity) * (1 - exp(-dt * (silent ? 14 : 5)))
        if silent, activity < 0.02 { activity = 0 }
        treble += (Double(input.treble) - treble) * min(1, dt * 6)
        pulse = silent ? 0 : Double(input.pulse)

        // The beat clock's beats, counted as it wraps (it keeps time through a breakdown, and in silence).
        let wrapped = input.groove < lastGroove - 0.5
        if wrapped { beatCount += 1 }
        lastGroove = input.groove
        let target = Double(beatCount) + input.groove

        // Half time through a breakdown, but not straight after a drop (the breakdown takes a second to ease off).
        let breakdown = Double(input.breakdown)
        if dropLock, breakdown < 0.25 { dropLock = false }
        if dropLock || breakdown < 0.3 {
            halfTime = false
        } else if breakdown > 0.6 {
            halfTime = true
        }
        calm += ((dropLock ? 0 : breakdown) - calm) * min(1, dt * 6)

        if silent {
            // The rally freezes where it is while the picture eases into attract mode.
            playing = false
        } else {
            if !playing { startRally(at: target) }
            let interval = min(max(input.beatInterval, 0.3), 1)
            let before = clock
            clock += dt / interval
            let error = target - clock
            if abs(error) > 0.5 {
                // The beat clock jumped (it found the beat afresh): catch up, and send the balls in flight on from
                // where they are to land on the new beats.
                balls.removeAll { $0.out }
                let positions = balls.map { (Self.x(of: $0, at: before), Self.y(of: $0, at: before)) }
                clock = target
                multiballUntil += error
                for i in balls.indices {
                    retime(i, at: positions[i], lane: balls[i].lane, minimum: 0.35, onlyEarlier: false)
                }
            } else {
                clock = max(before, clock + error * min(1, dt * 8))
                // On the beat itself, exactly: a return lands on the frame of the kick, not the one after.
                if wrapped { clock = max(clock, target) }
            }
            if input.drop { drop() }
            var safety = 0
            while safety < 32, let i = nextArrival() {
                arrive(i)
                safety += 1
            }
            balls.removeAll { ball in
                guard ball.out else { return false }
                let x = Self.x(of: ball, at: clock)
                return x < -3 || x > Double(Self.side) + 1
            }
            planPaddles(dt: dt)
        }

        for i in paddles.indices {
            paddles[i].flash *= exp(-dt * 9)
            paddles[i].nudge *= exp(-dt * 12)
            scoreFlash[i] = max(0, scoreFlash[i] - dt * (silent ? 6 : 1.1))
        }
        flash *= exp(-dt * (silent ? 20 : 7))
        for i in sparks.indices {
            sparks[i].x += sparks[i].vx * dt
            sparks[i].y += sparks[i].vy * dt
            sparks[i].life -= dt * (silent ? 6 : 1)
        }
        sparks.removeAll { $0.life <= 0 }
    }

    /// The music started (or came back): serve from the centre line, where attract mode left the ball.
    private func startRally(at target: Double) {
        playing = true
        clock = target
        balls.removeAll()
        multiballUntil = -1
        returns = 0
        for i in paddles.indices {
            // Carry on from where the paddle is drawn, so nothing jumps.
            paddles[i].y = Self.restPaddleY + (paddles[i].y - Self.restPaddleY) * activity
            paddles[i].planID = -1
        }
        var ball = Ball(id: nextID, main: true, colour: -1, x0: Self.netX, y0: Self.restBallY, t0: clock,
                        t1: Self.nextBeat(after: clock + 0.6, lane: 0), toRight: serveRight, lane: 0)
        nextID += 1
        serveRight.toggle()
        aim(&ball, bank: false)
        balls.append(ball)
    }

    /// The ball due at a paddle soonest, if one is due by now.
    private func nextArrival() -> Int? {
        var best: Int?
        for i in balls.indices where !balls[i].out && balls[i].t1 <= clock {
            if let b = best, balls[b].t1 <= balls[i].t1 { continue }
            best = i
        }
        return best
    }

    /// A ball reaches a paddle's face: returned, or (at the end of a phrase or of multiball) missed.
    private func arrive(_ i: Int) {
        var ball = balls[i]
        let side = ball.toRight ? 1 : 0
        let y = Self.fold(ball.u1)
        if ball.miss {
            balls[i].out = true
            balls[i].main = false
            point(for: 1 - side)
            if ball.main { serve(towardsRight: ball.toRight, at: ball.t1) }
            return
        }
        hit(side: side, y: y, colour: ball.colour)
        let multiball = multiballUntil > ball.t1
        let alone = balls.count == 1
        let length = halfTime && alone ? 2.0 : 1.0
        ball.x0 = ball.toRight ? Self.rightFace : Self.leftFace
        ball.y0 = y
        ball.t0 = ball.t1
        ball.t1 += length
        ball.toRight.toggle()
        aim(&ball, bank: true)
        if ball.main {
            if alone {
                returns += 1
                if returns >= phraseLength {
                    returns = 0
                    phraseLength = phrase + random.int(2)
                    ball.miss = true
                }
            }
        } else if !multiball {
            // Multiball is over: the extra balls slip past on their next crossing.
            ball.miss = true
        }
        balls[i] = ball
    }

    /// Picks where the ball lands (and whether it banks off a wall on the way), and where on the paddle it hits.
    private func aim(_ ball: inout Ball, bank: Bool) {
        let landing = random.range(Self.ballHighest, Self.ballLowest)
        ball.u1 = landing
        let chance = min(0.85, bounciness + treble * 0.6) * (halfTime ? 0.6 : 1)
        if bank, random.chance(chance) {
            // Reflected beyond the top or bottom wall: the straight line there folds into one bounce.
            let viaTop = 2 * Self.ballHighest - landing
            let viaBottom = 2 * Self.ballLowest - landing
            let topNearer = abs(viaTop - ball.y0) < abs(viaBottom - ball.y0)
            let pick = topNearer == random.chance(0.75) ? viaTop : viaBottom
            if abs(pick - ball.y0) < 58 { ball.u1 = pick }
        }
        ball.contact = Double(random.int(5) - 2)
    }

    /// A new ball from the net on `t`'s beat, crossing half the court in a beat (a gentle serve).
    private func serve(towardsRight: Bool, at t: Double) {
        var ball = Ball(id: nextID, main: true, colour: -1, x0: Self.netX,
                        y0: random.range(Self.ballHighest + 8, Self.ballLowest - 8), t0: t,
                        t1: Self.nextBeat(after: t + 0.6, lane: 0), toRight: towardsRight, lane: 0)
        nextID += 1
        aim(&ball, bank: false)
        balls.append(ball)
    }

    /// The bass came back: a flash, the ball in play back to full speed, and two more balls served from the centre
    /// spot in a burst of sparks, one of them landing on the off-beats.
    private func drop() {
        flash = 1
        dropLock = true
        halfTime = false
        returns = 0
        multiballUntil = clock + Self.multiballBeats
        for i in paddles.indices { paddles[i].flash = 1 }
        guard let main = balls.firstIndex(where: { $0.main && !$0.out }) else { return }
        // No point is lost on the drop: the ball in play is returned, whatever the phrase.
        balls[main].miss = false
        for i in paddles.indices { paddles[i].planID = -1 }
        retime(main, at: (Self.x(of: balls[main], at: clock), Self.y(of: balls[main], at: clock)), lane: 0,
               minimum: 0.4, onlyEarlier: true)
        let toRight = balls[main].toRight
        let y = Self.restBallY
        for (k, lane) in [0.0, 0.5].enumerated() where balls.count < 4 {
            var ball = Ball(id: nextID, main: false, colour: k, x0: Self.netX, y0: y, t0: clock,
                            t1: Self.nextBeat(after: clock + 0.3, lane: lane),
                            toRight: k == 0 ? !toRight : random.chance(0.5), lane: lane)
            nextID += 1
            aim(&ball, bank: true)
            balls.append(ball)
        }
        for k in 0..<10 {
            let angle = Double(k) / 10 * 2 * .pi + random.range(-0.2, 0.2)
            let speed = random.range(22, 40)
            addSpark(x: Self.netX + 1, y: y + 1, vx: cos(angle) * speed, vy: sin(angle) * speed,
                     life: random.range(0.35, 0.6), colour: sparkBase + k)
        }
    }

    /// Sends ball `i` on from `position` (where it is now) to land on its lane's next beat that it can reach at about
    /// its usual speed (`onlyEarlier`: only if that is sooner than it would have landed).
    private func retime(_ i: Int, at position: (Double, Double), lane: Double, minimum: Double, onlyEarlier: Bool) {
        var ball = balls[i]
        let (x, y) = position
        let face = ball.toRight ? Self.rightFace : Self.leftFace
        let beats = abs(face - x) / (Self.rightFace - Self.leftFace)
        let arrival = Self.nextBeat(after: clock + max(minimum, beats * 0.85), lane: lane)
        if onlyEarlier, arrival >= ball.t1 - 0.01 { return }
        ball.x0 = x
        ball.y0 = y
        ball.t0 = clock
        ball.t1 = arrival
        ball.lane = lane
        ball.u1 = Self.fold(ball.u1)
        balls[i] = ball
    }

    private func hit(side: Int, y: Double, colour: Int) {
        paddles[side].flash = 1
        paddles[side].nudge = 1
        let dir: Double = side == 0 ? 1 : -1
        let x = side == 0 ? Self.leftFace : Self.rightFace + 1
        for k in 0..<3 {
            addSpark(x: x, y: y + 1 + random.range(-1, 1), vx: dir * random.range(16, 34), vy: random.range(-34, 34),
                     life: random.range(0.18, 0.32), colour: colour >= 0 ? colour + k : sparkBase + k)
        }
    }

    private func addSpark(x: Double, y: Double, vx: Double, vy: Double, life: Double, colour: Int) {
        guard sparks.count < 40 else { return }
        sparks.append(Spark(x: x, y: y, vx: vx, vy: vy, life: life, colour: colour))
    }

    private func point(for side: Int) {
        // First to eleven: the next point starts a new game.
        if max(scores[0], scores[1]) >= 11 { scores = [0, 0] }
        scores[side] += 1
        scoreFlash[side] = 1
    }

    /// Each paddle heads for the next ball coming its way, after a moment's reaction, and is there a little before it
    /// lands (or, for a miss, lunges and falls a pixel short). With nothing coming it drifts back towards the middle,
    /// keeping half an eye on the ball.
    private func planPaddles(dt: Double) {
        for side in 0..<2 {
            var next: Ball?
            for ball in balls where !ball.out && ball.toRight == (side == 1) {
                if let n = next, n.t1 <= ball.t1 { continue }
                next = ball
            }
            var paddle = paddles[side]
            if let ball = next {
                if paddle.planID != ball.id || paddle.planT1 != ball.t1 {
                    paddle.planID = ball.id
                    paddle.planT1 = ball.t1
                    paddle.fromY = paddle.y
                    paddle.fromT = clock
                    paddle.toY = Self.paddleTarget(for: ball, from: paddle.y)
                    paddle.lunge = ball.miss
                }
                let span = max(ball.t1 - paddle.fromT, 0.01)
                let q = (clock - paddle.fromT) / span
                let react = reactions[side]
                let end = paddle.lunge ? 1 : 0.85
                let e = Self.smoothstep((q - react) / (end - react))
                paddle.y = paddle.fromY + (paddle.toY - paddle.fromY) * e
            } else {
                paddle.planID = -1
                let watch = balls.first { !$0.out }.map { Self.y(of: $0, at: clock) } ?? Self.restBallY
                let target = Self.clampPaddle((Self.restPaddleY + watch - 3) / 2)
                paddle.y += (target - paddle.y) * (1 - exp(-dt * 3))
            }
            paddles[side] = paddle
        }
    }

    // MARK: - Geometry

    /// The next time on `lane` (0: on the beat, 0.5: off it) at or after `t`.
    private static func nextBeat(after t: Double, lane: Double) -> Double { lane + (t - lane).rounded(.up) }

    /// A height on the unfolded line, folded between the walls.
    private static func fold(_ u: Double) -> Double {
        let h = ballLowest - ballHighest
        var m = (u - ballHighest).truncatingRemainder(dividingBy: 2 * h)
        if m < 0 { m += 2 * h }
        return ballHighest + (m <= h ? m : 2 * h - m)
    }

    private static func x(of ball: Ball, at t: Double) -> Double {
        let face = ball.toRight ? rightFace : leftFace
        let f = (t - ball.t0) / max(ball.t1 - ball.t0, 0.01)
        return ball.x0 + (face - ball.x0) * (ball.out ? f : min(f, 1))
    }

    private static func y(of ball: Ball, at t: Double) -> Double {
        let f = (t - ball.t0) / max(ball.t1 - ball.t0, 0.01)
        return fold(ball.y0 + (ball.u1 - ball.y0) * (ball.out ? f : min(max(f, 0), 1)))
    }

    private static func clampPaddle(_ y: Double) -> Double { min(max(y, paddleHighest), paddleLowest) }

    /// Where a paddle's top should be when `ball` lands: centred on it, give or take the ball's contact point; or
    /// for a miss, a pixel short of it on the side the paddle comes from.
    private static func paddleTarget(for ball: Ball, from y: Double) -> Double {
        let landing = fold(ball.u1)
        guard ball.miss else { return clampPaddle(landing + 1 - paddleLength / 2 + ball.contact) }
        let below = landing + 3, above = landing - 1 - paddleLength
        let fromBelow = y > landing - paddleLength / 2 + 1
        if fromBelow ? below <= paddleLowest : above < paddleHighest { return below }
        return above
    }

    private static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Draw

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        canvas.clear()
        let light = style.isLight
        let ink = style.ink
        let soft = 1 - 0.25 * calm
        if styled != style {
            styled = style
            // The spark colours, most colourful first (some palettes include white).
            let sparks = style.sparks
            vivid = sparks.indices.sorted { a, b in
                let sa = sparks[a].hsb.saturation, sb = sparks[b].hsb.saturation
                return sa != sb ? sa > sb : a < b
            }.map { sparks[$0] }
        }

        // The screen: a dark wash over dark artwork, a pale one over light, so the game reads like a picture tube.
        if light {
            canvas.rect(0, 0, Self.side, Self.side, .white, 0.28)
        } else {
            canvas.rect(0, 0, Self.side, Self.side, style.deep.mixed(with: .black, 0.6), 0.5)
        }

        // Walls and the dashed net.
        canvas.rect(3, 1, 40, 1, ink, 0.55 * soft)
        canvas.rect(3, 44, 40, 1, ink, 0.55 * soft)
        let netAlpha = (0.42 + 0.2 * pulse * activity) * soft
        for row in stride(from: 4, through: 40, by: 4) { canvas.rect(22, row, 2, 2, ink, netAlpha) }

        // The score, a big number in each half.
        for side in 0..<2 {
            let text = String(scores[side])
            let width = text.count * 8 - 2
            let x = side == 0 ? 14 - width / 2 : 32 - width / 2
            let blinking = scoreFlash[side] > 0 && Int(scoreFlash[side] * 9) % 2 == 1
            let colour = blinking ? (light ? ink : style.spark(sparkBase + side).mixed(with: .white, 0.3)) : ink
            drawBig(text, x: x, y: 4, colour: colour, alpha: (blinking ? 1 : 0.62) * soft)
        }

        // A faint trail behind the ball through a breakdown.
        if calm > 0.05, activity > 0, let main = balls.first(where: { $0.main && !$0.out }) {
            for k in 1...4 {
                let t = clock - Double(k) * 0.11
                guard t > main.t0 else { break }
                let (x, y) = drawn(main, at: t)
                canvas.rect(x, y, 2, 2, ink, calm * activity * 0.32 * (1 - Double(k) / 5))
            }
        }

        for spark in sparks {
            let colour = light ? style.spark(spark.colour).mixed(with: ink, 0.4) : style.spark(spark.colour)
            canvas.set(Int(spark.x.rounded(.down)), Int(spark.y.rounded(.down)), colour, min(1, spark.life * 5))
        }

        // The paddles: a flash of colour round them on a return, and a one-pixel lunge at the ball.
        for side in 0..<2 {
            let paddle = paddles[side]
            let y = Int((Self.restPaddleY + (paddle.y - Self.restPaddleY) * activity).rounded())
            let lunge = paddle.nudge > 0.25 && paddle.nudge < 0.85 ? (side == 0 ? 1 : -1) : 0
            let x = Self.paddleColumns[side] + lunge
            if paddle.flash > 0.05 {
                let halo = light ? vivid[side % vivid.count] : vivid[side % vivid.count].mixed(with: .white, 0.3)
                canvas.rect(x - 1, y - 1, 4, Int(Self.paddleLength) + 2, halo, paddle.flash * (light ? 0.5 : 0.7))
            }
            let colour = light ? ink : ink.mixed(with: .white, paddle.flash)
            canvas.rect(x, y, 2, Int(Self.paddleLength), colour, soft)
        }

        // The balls: the one in play in the ink, multiball's extras in the most colourful sparks.
        for ball in balls {
            let (x, y) = drawn(ball, at: clock)
            let extra = vivid[(ball.colour + 1) % vivid.count]
            let colour = ball.colour < 0 ? ink : light ? extra.mixed(with: ink, 0.35) : extra
            let alpha = ball.main ? 1 : activity
            canvas.rect(x, y, 2, 2, colour, alpha)
        }
        // Attract mode before anything has played.
        if balls.isEmpty { canvas.rect(Int(Self.netX), Int(Self.restBallY), 2, 2, ink) }

        if flash > 0.02 {
            let wash = light ? ink : ink.mixed(with: .white, 0.5)
            canvas.rect(0, 0, Self.side, Self.side, wash, flash * (light ? 0.2 : 0.3))
        }
        canvas.draw(in: ctx, rect: CGRect(origin: .zero, size: size))
    }

    /// Where `ball` is drawn at `t`, eased towards attract mode's centre spot as the music fades.
    private func drawn(_ ball: Ball, at t: Double) -> (Int, Int) {
        let x = Self.x(of: ball, at: t), y = Self.y(of: ball, at: t)
        let k = ball.main ? activity : 1
        return (Int((Self.netX + (x - Self.netX) * k).rounded()),
                Int((Self.restBallY + (y - Self.restBallY) * k).rounded()))
    }

    /// `text` in the pixel font at twice its size.
    private func drawBig(_ text: String, x: Int, y: Int, colour: RGB, alpha: Double) {
        var left = x
        for c in text {
            if let rows = PixelFont.glyph(c) {
                for (row, bits) in rows.enumerated() {
                    for col in 0..<PixelFont.glyphWidth where bits & (0b100 >> UInt8(col)) != 0 {
                        canvas.rect(left + col * 2, y + row * 2, 2, 2, colour, alpha)
                    }
                }
            }
            left += (PixelFont.glyphWidth + 1) * 2
        }
    }
}

// MARK: - Pieces

/// A ball's crossing: a straight line from (x0, y0) at beat `t0` to a paddle's face at beat `t1`, with its height
/// unfolded (`u1` beyond a wall is a bank shot).
private nonisolated struct Ball {
    var id: Int
    /// The ball in play (not one of multiball's extras, nor one on its way out).
    var main: Bool
    /// -1 for the ink, else multiball's spark colour.
    var colour: Int
    var x0: Double
    var y0: Double
    var t0: Double
    var t1: Double
    var toRight: Bool
    /// The beat phase it lands on: 0 on the beat, 0.5 off it.
    var lane: Double
    var u1 = 0.0
    /// Where on the paddle it lands, in pixels from the middle.
    var contact = 0.0
    /// It will get past the paddle.
    var miss = false
    /// It got past: flying out of the court.
    var out = false
}

private nonisolated struct Paddle {
    /// The top row (fractional; drawn rounded).
    var y = 0.0
    /// The move under way: from `fromY` at `fromT` to `toY` by the ball `planID`'s landing at `planT1`.
    var planID = -1
    var planT1 = 0.0
    var fromY = 0.0
    var fromT = 0.0
    var toY = 0.0
    var lunge = false
    var flash = 0.0
    var nudge = 0.0
}

private nonisolated struct Spark {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var life: Double
    var colour: Int
}
