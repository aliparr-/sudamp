// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization

/// Debug-only network faults (`SUDAMP_FAULT`, PLAN M6): `net:offline[=<seconds>[@<after>]]` makes the network path
/// read unsatisfied for `seconds` (default 30), starting `after` seconds (default 20) after the controller starts
/// listening, then hands back the real path. Nothing is actually disconnected: the app must react to the path.
public struct NetworkFaults: Sendable, Equatable {
    public var offlineFor: TimeInterval?
    public var offlineAfter: TimeInterval

    public init(offlineFor: TimeInterval? = nil, offlineAfter: TimeInterval = 20) {
        self.offlineFor = offlineFor
        self.offlineAfter = offlineAfter
    }

    public static let none = NetworkFaults()
    public var isActive: Bool { offlineFor != nil }

    /// Parses `SUDAMP_FAULT` (comma-separated) in debug builds; always `.none` in release.
    public static func from(environment: [String: String] = ProcessInfo.processInfo.environment) -> NetworkFaults {
        #if DEBUG
        parse(environment["SUDAMP_FAULT"] ?? "")
        #else
        .none
        #endif
    }

    public static func parse(_ value: String) -> NetworkFaults {
        var f = NetworkFaults()
        for item in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard item == "net:offline" || item.hasPrefix("net:offline=") else { continue }
            f.offlineFor = 30
            guard let eq = item.firstIndex(of: "=") else { continue }
            let spec = item[item.index(after: eq)...]
            let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
            if let d = parts.first.flatMap(TimeInterval.init), d.isFinite, d > 0, d <= 3600 { f.offlineFor = d }
            if parts.count == 2, let a = TimeInterval(parts[1]), a.isFinite, a >= 0, a <= 3600 { f.offlineAfter = a }
        }
        return f
    }

    /// The path source with the fault applied (the base source itself when inactive).
    public func observer(_ base: any NetworkPathObserving) -> any NetworkPathObserving {
        guard let offlineFor else { return base }
        return OfflineWindowPath(base: base, after: offlineAfter, duration: offlineFor)
    }
}

/// Forwards a real path source, except inside one window where it reports the path as unsatisfied.
public final class OfflineWindowPath: NetworkPathObserving {
    public static let offline = NetworkPathStatus(isSatisfied: false)

    private let base: any NetworkPathObserving
    private let after: TimeInterval
    private let duration: TimeInterval

    public init(base: any NetworkPathObserving, after: TimeInterval, duration: TimeInterval) {
        self.base = base
        self.after = after
        self.duration = duration
    }

    public func updates() -> AsyncStream<NetworkPathStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: NetworkPathStatus.self, bufferingPolicy: .bufferingNewest(8))
        let state = WindowState()
        let upstream = base.updates()
        let forward = Task {
            for await status in upstream {
                let emit = state.lock.withLock { s -> Bool in
                    s.latest = status
                    return !s.offline
                }
                if emit { continuation.yield(status) }
            }
        }
        let (after, duration) = (self.after, self.duration)
        let window = Task {
            try? await Task.sleep(for: .seconds(after), tolerance: .milliseconds(20))
            guard !Task.isCancelled else { return }
            state.lock.withLock { $0.offline = true }
            continuation.yield(Self.offline)
            try? await Task.sleep(for: .seconds(duration), tolerance: .milliseconds(20))
            guard !Task.isCancelled else { return }
            let latest = state.lock.withLock { s -> NetworkPathStatus? in
                s.offline = false
                return s.latest
            }
            continuation.yield(latest ?? NetworkPathStatus(isSatisfied: true, interfaces: ["fault/restored"]))
        }
        continuation.onTermination = { _ in
            forward.cancel()
            window.cancel()
        }
        return stream
    }

    /// The latest real status and whether the window is open, shared by the forwarding and window tasks. A class
    /// rather than a local `Mutex`: Swift 6.2 and 6.3 reject sending two task closures that capture one local
    /// noncopyable value (SendingRisksDataRace); 6.4 accepts it.
    private final class WindowState: Sendable {
        let lock = Mutex<(latest: NetworkPathStatus?, offline: Bool)>((nil, false))
    }
}
