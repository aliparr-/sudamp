// SPDX-License-Identifier: GPL-3.0-or-later
// What the scenes dance to, picked out of the analyser's bars once per frame: the bass, mids and treble, the overall
// level, the kicks (a sharp rise in the bass, well above its recent average) and a beat clock that follows them.
// Kicks land on the clock's downbeat and pull its tempo towards theirs; through a breakdown with no kicks the clock
// keeps the last tempo, so a dancer keeps dancing. It also hears a breakdown (the bass's low points sinking for a
// while) and the drop that ends one. Pure and deterministic: tested with synthetic kicks.

import Foundation

nonisolated struct AudioFeatures {
    private(set) var input = VisualizerInput.silence
    /// The bass's recent average (about a second), for the kick threshold.
    private var slowBass: Float = 0
    private var lastBass: Float = 0
    private var sinceKick: Double = 10
    /// The last kick fell between beats (a bassline's off-beat note): a kick on the downbeat may follow sooner.
    private var lastKickOffbeat = false
    /// The clock's position in beats; its fraction is `groove`.
    private var clock: Double = 0
    private var interval: Double = 0.5
    /// The breakdown: the bass's low points between hits (recovering slowly), what they usually are, and how long they
    /// have sat well below that. Eased into `breakdown`.
    private var trough: Float = 1
    private var usualTrough: Float = 0.6
    private var lowFor: Double = 0
    private var sinceDrop: Double = 10
    private var calm: Float = 0
    /// Seconds of sound since the last silence: the first two learn what the bass's low points usually are.
    private var soundFor: Double = 0
    /// What is playing (`VisualizerInput.caption`).
    var caption = ""

    /// Kicks closer together than this are one kick (200 bpm).
    static let minInterval = 0.3
    /// The slowest tempo the clock follows (60 bpm).
    static let maxInterval = 1.0

    /// The next frame's input (nil frame: silence) after `dt` seconds.
    mutating func next(_ frame: ModernVisualizerFrame?, dt rawDt: Double) -> VisualizerInput {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let bars = frame.map { Self.sanitised($0.bars, count: VisualizerInput.barCount) }
            ?? [Float](repeating: 0, count: VisualizerInput.barCount)
        let peaks = frame.map { Self.sanitised($0.peaks, count: VisualizerInput.barCount) } ?? bars
        let scope = frame.map { Self.sanitised($0.scope, count: VisualizerInput.scopeCount, range: -1...1) }
            ?? [Float](repeating: 0, count: VisualizerInput.scopeCount)
        let bass = Self.mean(bars, 0..<4)
        let mid = Self.mean(bars, 4..<12)
        let treble = Self.mean(bars, 12..<bars.count)
        let level = Self.mean(bars, 0..<bars.count)

        // Kicks: the bass jumps within a frame or two and stands clear of its recent average.
        sinceKick += dt
        // The clock runs at the tempo.
        clock += dt / interval
        let phase = clock - clock.rounded(.down)
        let onDownbeat = phase > 0.7 || phase < 0.3
        // A kick may not follow another within the shortest beat, unless that one was off the beat and this one is
        // on it (a bassline's off-beat note must not hide the kick coming back after a breakdown).
        let ready = sinceKick >= Self.minInterval || (lastKickOffbeat && onDownbeat && sinceKick >= Self.minInterval / 3)
        let rise = bass - lastBass
        let kick = dt > 0 && rise > 0.08 && bass > slowBass + 0.06 && bass > 0.25 && ready
        lastBass = bass
        let follow = Float(1 - exp(-dt / 1.0))
        slowBass += (bass - slowBass) * follow

        // A kick near a downbeat pulls the clock into line, and the gap between two such kicks (or half of one twice
        // as long, a skipped beat) nudges the tempo.
        if kick {
            let gap = sinceKick
            lastKickOffbeat = !onDownbeat && input.beats >= 2
            if onDownbeat {
                clock = clock.rounded()
                var measured = gap
                if measured > Self.maxInterval, measured / 2 >= Self.minInterval { measured /= 2 }
                if (Self.minInterval...Self.maxInterval).contains(measured), abs(measured - interval) < interval * 0.4 {
                    interval += (measured - interval) * 0.35
                } else if (Self.minInterval...Self.maxInterval).contains(measured), input.beats < 3 {
                    interval = measured
                }
            } else if input.beats < 2, (Self.minInterval...Self.maxInterval).contains(gap) {
                // Still finding the beat: take this kick as the downbeat.
                interval = gap
                clock = clock.rounded(.up)
            }
            sinceKick = 0
        }

        // A breakdown: the bass's low points sink well below their usual level for a while. The drop: the first kick
        // on the downbeat after one (a breakdown's bassline hits as hard as a kick, but between the beats).
        let sounding = level >= 0.02
        soundFor = sounding ? soundFor + dt : 0
        trough = min(bass, trough + Float(dt) * 0.5)
        if sounding, soundFor < 2 {
            usualTrough += (trough - usualTrough) * Float(min(1, dt * 3))
            lowFor = 0
        } else if sounding, trough < usualTrough - 0.12 {
            lowFor += dt
        } else {
            if sounding, lowFor < 0.5 { usualTrough += (trough - usualTrough) * Float(min(1, dt * 0.4)) }
            lowFor = 0
        }
        sinceDrop += dt
        var drop = false
        if kick, sounding, onDownbeat, lowFor > 1.5, bass > usualTrough, sinceDrop > 8 {
            drop = true
            sinceDrop = 0
            lowFor = 0
            trough = bass
        }
        calm += ((lowFor > 1 ? 1 : 0) - calm) * Float(min(1, dt * (sounding ? 2.5 : 9)))

        func smooth(_ old: Float, _ new: Float) -> Float {
            let rate = new > old ? 0.6 : 0.18
            return old + (new - old) * Float(1 - pow(1 - rate, dt * 60))
        }
        input = VisualizerInput(
            bars: bars, peaks: peaks, scope: scope, bass: smooth(input.bass, bass), mid: smooth(input.mid, mid),
            treble: smooth(input.treble, treble), level: smooth(input.level, level), beat: kick,
            pulse: kick ? 1 : input.pulse * Float(exp(-dt * 5.5)), groove: clock - clock.rounded(.down),
            beatInterval: interval, beats: input.beats + (kick ? 1 : 0), time: input.time + dt,
            breakdown: calm < 0.001 ? 0 : calm, drop: drop, caption: caption)
        return input
    }

    /// Forgets everything (a new stream, a long pause) but the caption.
    mutating func reset() {
        let caption = caption
        self = AudioFeatures()
        self.caption = caption
    }

    static func mean(_ values: [Float], _ range: Range<Int>) -> Float {
        let r = range.clamped(to: 0..<values.count)
        guard !r.isEmpty else { return 0 }
        var sum: Float = 0
        for i in r { sum += values[i] }
        return sum / Float(r.count)
    }

    /// `count` finite values in `range`, zero-padded or cut.
    static func sanitised(_ values: [Float], count: Int, range: ClosedRange<Float> = 0...1) -> [Float] {
        (0..<count).map { i in
            guard i < values.count, values[i].isFinite else { return 0 }
            return min(max(values[i], range.lowerBound), range.upperBound)
        }
    }
}
