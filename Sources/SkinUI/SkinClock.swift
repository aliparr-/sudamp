// SPDX-License-Identifier: GPL-3.0-or-later
// Time-driven parts of the main window, pure: the marquee's scroll step (Webamp's model: one 5 px character
// every 220 ms, frozen while the user scrubs and resumed 1 s after the scrub ends, restarted when the title
// changes; SkinView also freezes it while paused) and the paused-time blink (Webamp's `blink 2s step-start 1s infinite`: shown for the first two
// seconds, then hidden on even seconds).

import Foundation
import SkinKit

nonisolated public struct MarqueeClock: Equatable, Sendable {
    /// Steps already taken when the clock last stopped.
    public private(set) var baseStep = 0
    /// When stepping (re)starts counting; nil while frozen.
    public private(set) var runningSince: Double?
    public private(set) var title: String?

    public init() {}

    /// Restarts scrolling from the beginning when the title changes.
    public mutating func setTitle(_ title: String, now: Double) {
        guard title != self.title else { return }
        self.title = title
        baseStep = 0
        runningSince = now
    }

    public func step(at now: Double) -> Int {
        guard let start = runningSince, now > start else { return baseStep }
        return baseStep + MarqueeModel.step(elapsed: now - start)
    }

    public mutating func freeze(now: Double) {
        baseStep = step(at: now)
        runningSince = nil
    }

    /// Continues stepping from where it was frozen, at once (unpausing). No effect while running.
    public mutating func unfreeze(now: Double) {
        guard runningSince == nil else { return }
        runningSince = now
    }

    /// Resumes stepping `MarqueeModel.resumeDelay` seconds after `now`.
    public mutating func resume(now: Double) {
        baseStep = step(at: now)
        runningSince = now + MarqueeModel.resumeDelay
    }
}

nonisolated public enum PauseBlink {
    /// Whether paused time digits are drawn `secondsPaused` after pausing.
    public static func isVisible(secondsPaused: Double) -> Bool {
        guard secondsPaused.isFinite, secondsPaused >= 2 else { return true }
        return Int(secondsPaused.rounded(.down)) % 2 == 1
    }
}
