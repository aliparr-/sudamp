// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Dispatch
import Synchronization

/// Turns SIGINT/SIGTERM into a callback on a dispatch queue (DESIGN §4 quit path: "a Core DispatchSource … whose
/// handler, installed by Shell, calls NSApp.terminate"). The default action is ignored while watching, so the
/// process isn't killed before the handler runs; `cancel()` restores it.
public final class SignalWatcher: Sendable {
    private let sources: Mutex<[any DispatchSourceSignal]>
    private let signals: [Int32]

    /// - Parameter handler: called on `queue` with the signal number, once per delivery.
    public init(signals: [Int32] = [SIGINT, SIGTERM], queue: DispatchQueue = .main,
                handler: @escaping @Sendable (Int32) -> Void) {
        self.signals = signals
        var made: [any DispatchSourceSignal] = []
        for sig in signals {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { handler(sig) }
            source.resume()
            made.append(source)
        }
        sources = Mutex(made)
    }

    deinit { cancel() }

    /// Stops watching and restores the default actions.
    public func cancel() {
        let active = sources.withLock { s -> [any DispatchSourceSignal] in
            defer { s = [] }
            return s
        }
        guard !active.isEmpty else { return }
        for s in active { s.cancel() }
        for sig in signals { signal(sig, SIG_DFL) }
    }
}
