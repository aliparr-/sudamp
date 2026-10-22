// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import Synchronization

/// One network path as the app cares about it (DESIGN §4: `networkLost`/`networkRestored`; §6.3: YouTube URLs are
/// IP-bound, so their cached resolutions are dropped when the path changes).
public struct NetworkPathStatus: Sendable, Equatable, Codable {
    public var isSatisfied: Bool
    /// Interfaces in preference order, e.g. `en0/wifi`.
    public var interfaces: [String]
    /// Gateway endpoints (a new gateway on the same interface usually means a new network and address).
    public var gateways: [String]
    public var isExpensive: Bool
    public var isConstrained: Bool

    public init(isSatisfied: Bool, interfaces: [String] = [], gateways: [String] = [], isExpensive: Bool = false,
                isConstrained: Bool = false) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
        self.gateways = gateways
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    /// What identifies the route: equal signatures mean the public address most likely did not change.
    public var signature: String { "\(isSatisfied)|\(interfaces.joined(separator: ","))|\(gateways.joined(separator: ","))" }
}

/// How one path update relates to the previous one.
public enum NetworkPathChange: String, Sendable, Equatable, Codable {
    /// The first update (nothing to compare with).
    case initial
    case lost
    case restored
    /// Still connected, but over a different route (Wi-Fi ↔ Ethernet, a new Wi-Fi network, VPN up or down).
    case changed
    case unchanged

    /// Pure classification of consecutive updates.
    public static func between(_ previous: NetworkPathStatus?, _ current: NetworkPathStatus) -> NetworkPathChange {
        guard let previous else { return .initial }
        switch (previous.isSatisfied, current.isSatisfied) {
        case (true, false): return .lost
        case (false, true): return .restored
        case (false, false): return .unchanged
        case (true, true): return previous.signature == current.signature ? .unchanged : .changed
        }
    }
}

/// The NWPathMonitor seam: the current path first, then every change, until the stream's consumer goes away.
public protocol NetworkPathObserving: Sendable {
    func updates() -> AsyncStream<NetworkPathStatus>
}

/// NWPathMonitor on a private queue (DESIGN §5.5: system callbacks are registered from nonisolated modules only).
public struct SystemNetworkPathMonitor: NetworkPathObserving {
    public init() {}

    public func updates() -> AsyncStream<NetworkPathStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: NetworkPathStatus.self, bufferingPolicy: .bufferingNewest(8))
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in continuation.yield(Self.status(of: path)) }
        let box = MonitorBox(monitor)
        continuation.onTermination = { _ in box.cancel() }
        monitor.start(queue: DispatchQueue(label: "sudamp.network.path", qos: .utility))
        return stream
    }

    static func status(of path: NWPath) -> NetworkPathStatus {
        var seen = Set<String>()
        let interfaces = path.availableInterfaces.map { "\($0.name)/\(Self.name(of: $0.type))" }.filter { seen.insert($0).inserted }
        return NetworkPathStatus(
            isSatisfied: path.status == .satisfied,
            interfaces: interfaces,
            gateways: path.gateways.map { "\($0)" },
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained)
    }

    static func name(of type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: "wifi"
        case .wiredEthernet: "ethernet"
        case .cellular: "cellular"
        case .loopback: "loopback"
        case .other: "other"
        @unknown default: "unknown"
        }
    }

    /// Keeps the monitor alive until the stream terminates, then cancels it.
    private final class MonitorBox: Sendable {
        private let monitor: Mutex<NWPathMonitor?>
        init(_ monitor: NWPathMonitor) { self.monitor = Mutex(monitor) }
        func cancel() { monitor.withLock { $0?.cancel(); $0 = nil } }
    }
}

/// A hand-driven path source for tests and fault injection (`SUDAMP_FAULT=net:offline`, M6).
public final class ManualNetworkPath: NetworkPathObserving {
    private let state = Mutex<(current: NetworkPathStatus?, listeners: [UUID: AsyncStream<NetworkPathStatus>.Continuation])>(
        (nil, [:]))

    public init(initial: NetworkPathStatus? = NetworkPathStatus(isSatisfied: true, interfaces: ["en0/wifi"])) {
        state.withLock { $0.current = initial }
    }

    public func updates() -> AsyncStream<NetworkPathStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: NetworkPathStatus.self)
        let id = UUID()
        let current = state.withLock { s -> NetworkPathStatus? in
            s.listeners[id] = continuation
            return s.current
        }
        if let current { continuation.yield(current) }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.listeners.removeValue(forKey: id) } }
        return stream
    }

    /// Publishes a new path to every listener.
    public func send(_ status: NetworkPathStatus) {
        let listeners = state.withLock { s -> [AsyncStream<NetworkPathStatus>.Continuation] in
            s.current = status
            return Array(s.listeners.values)
        }
        for l in listeners { l.yield(status) }
    }
}
