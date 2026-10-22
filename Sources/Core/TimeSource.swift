import Foundation
import Synchronization

/// Wall-clock source. Named to avoid clashing with the standard library's `Clock` protocol.
/// Production code takes a `TimeSource` so breakers, backoff and the token bucket are testable (PLAN conventions).
public protocol TimeSource: Sendable {
    var now: Date { get }
}

/// The real clock. In debug builds `SUDAMP_CLOCK_OFFSET=<seconds>` shifts it forward, so terminal checks can
/// observe hour-scale behaviour (breaker reopen times, 24 h adaptations) without waiting.
public struct SystemTimeSource: TimeSource {
    public let offset: TimeInterval

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG
        offset = environment["SUDAMP_CLOCK_OFFSET"].flatMap(TimeInterval.init) ?? 0
        #else
        offset = 0
        #endif
    }

    public var now: Date { Date().addingTimeInterval(offset) }
}

/// Manually advanced clock for tests.
public final class FakeTimeSource: TimeSource {
    private let current: Mutex<Date>

    public init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = Mutex(start)
    }

    public var now: Date { current.withLock { $0 } }

    public func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    public func set(_ date: Date) {
        current.withLock { $0 = date }
    }
}

/// Monotonic nanoseconds (CLOCK_UPTIME_RAW), for latency measurements such as TTFA.
@inline(__always) public func monotonicNanos() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}
