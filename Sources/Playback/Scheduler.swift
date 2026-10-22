// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation

/// A cancellable piece of scheduled main-actor work.
public final class ScheduledWork {
    public private(set) var isCancelled = false
    private var onCancel: (() -> Void)?

    init(onCancel: (() -> Void)? = nil) { self.onCancel = onCancel }

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel?()
        onCancel = nil
    }

    func setOnCancel(_ f: @escaping () -> Void) { onCancel = f }
}

/// Timers for the controller (resolve and first-audio timeouts, prefetch delay, debounced saves, the live-pause
/// window), behind a seam so tests advance time by hand instead of sleeping.
public protocol PlaybackScheduler: AnyObject {
    @discardableResult
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledWork
}

/// Real time, on the main actor.
public final class TaskScheduler: PlaybackScheduler {
    public init() {}

    @discardableResult
    public func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledWork {
        let work = ScheduledWork()
        let task = Task { @MainActor in
            // An explicit leeway: the default lets a 45 s timer slip by seconds, and these timers are few.
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds), tolerance: .milliseconds(50)) }
            guard !Task.isCancelled, !work.isCancelled else { return }
            action()
        }
        work.setOnCancel { task.cancel() }
        return work
    }
}

/// Hand-driven time for tests (and `--automation` scripts later): `advance(by:)` runs due work in order and moves
/// the linked `FakeTimeSource` along, so wall-clock decisions (the 30 s live-pause window) agree with the timers.
public final class ManualScheduler: PlaybackScheduler {
    private struct Item {
        let due: TimeInterval
        let seq: Int
        let work: ScheduledWork
        let action: @MainActor () -> Void
    }

    public private(set) var elapsed: TimeInterval = 0
    public let time: FakeTimeSource?
    private var items: [Item] = []
    private var seq = 0

    public init(time: FakeTimeSource? = nil) { self.time = time }

    @discardableResult
    public func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledWork {
        let work = ScheduledWork()
        seq += 1
        items.append(Item(due: elapsed + max(0, seconds), seq: seq, work: work, action: action))
        return work
    }

    /// Work still waiting (cancelled items excluded).
    public var pending: Int { items.filter { !$0.work.isCancelled }.count }

    /// Runs everything due within `seconds`, earliest first; work scheduled by that work runs too if it falls due.
    public func advance(by seconds: TimeInterval) {
        let target = elapsed + seconds
        while true {
            items.removeAll { $0.work.isCancelled }
            guard let next = items.filter({ $0.due <= target }).min(by: { ($0.due, $0.seq) < ($1.due, $1.seq) }) else { break }
            items.removeAll { $0.seq == next.seq }
            move(to: next.due)
            next.action()
        }
        move(to: target)
    }

    private func move(to t: TimeInterval) {
        guard t > elapsed else { return }
        time?.advance(by: t - elapsed)
        elapsed = t
    }
}
