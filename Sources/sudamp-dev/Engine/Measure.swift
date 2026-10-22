// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Darwin
import Foundation
import MPV
import Synchronization

/// Small measurement helpers shared by the engine tools.
enum Measure {
    /// Nearest-rank percentile (p in 0...100) of `values`; NaN if empty.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    static func ms(_ nanos: UInt64) -> Double { Double(nanos) / 1e6 }

    static func ms(from start: UInt64, to end: UInt64) -> Double { (Double(end) - Double(start)) / 1e6 }

    /// Rounds for JSON readability.
    static func round(_ v: Double, _ places: Int = 3) -> Double {
        guard v.isFinite else { return v }
        let f = pow(10, Double(places))
        return (v * f).rounded() / f
    }

    /// Sleeps until the monotonic clock reaches `nanos` (coarse 2 ms steps, then fine).
    static func sleep(until nanos: UInt64) {
        while true {
            let now = monotonicNanos()
            if now >= nanos { return }
            let left = nanos - now
            usleep(UInt32(min(left / 1000, 2000)))
        }
    }

    static func sleep(seconds: Double) { sleep(until: monotonicNanos() + UInt64(max(0, seconds) * 1e9)) }

    /// Polls `condition` every 5 ms until it holds or `timeout` passes.
    @discardableResult
    static func wait(timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = monotonicNanos() + UInt64(timeout * 1e9)
        while monotonicNanos() < deadline {
            if condition() { return true }
            usleep(5000)
        }
        return condition()
    }

    /// Process CPU time (user + system) in seconds.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec)
            + Double(usage.ru_stime.tv_usec) / 1e6
    }

    /// Resident memory and thread count of this process.
    static func processInfo() -> (residentMB: Double, threads: Int) {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size else { return (0, 0) }
        return (Double(info.pti_resident_size) / 1_048_576, Int(info.pti_threadnum))
    }
}

/// Polls a synchronous mpv property on its own thread and records each call's latency (getPropertyP99Ms).
final class PropertyMonitor: Sendable {
    private let latencies = Mutex<[Double]>([])
    private let running = Atomic<Bool>(true)
    private let done = DispatchSemaphore(value: 0)

    init(mpv: MPVClient, property: String = "time-pos", intervalMs: Double = 20) {
        let thread = Thread { [self] in
            while running.load(ordering: .acquiring) {
                let t0 = monotonicNanos()
                _ = mpv.getDouble(property)
                let dt = Measure.ms(from: t0, to: monotonicNanos())
                latencies.withLock { $0.append(dt) }
                usleep(UInt32(intervalMs * 1000))
            }
            done.signal()
        }
        thread.name = "sudamp-dev.property-monitor"
        thread.start()
    }

    func stop() -> [Double] {
        if running.exchange(false, ordering: .acquiringAndReleasing) { done.wait() }
        return latencies.withLock { $0 }
    }
}

/// Like `printJSON`, but non-finite numbers (a measurement that never happened) print as the strings "inf",
/// "-inf" and "nan" instead of failing the whole encode.
func printReport<T: Encodable>(_ value: T, pretty: Bool) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf",
                                                                  nan: "nan")
    do {
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    } catch {
        stderr("could not encode report: \(error)")
    }
}
