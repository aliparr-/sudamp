// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Runs CPU-heavy or blocking test work on a thread of its own, not on one of Swift concurrency's cooperative threads
/// or GCD's global queues (each about one thread per core). On a 3-core CI runner, long synchronous tests held those
/// threads and timing-sensitive tests in the same process timed out. The work returns what to check; `#expect`
/// stays in the test body.
func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread { continuation.resume(with: Result { try work() }) }
        thread.stackSize = 4 << 20
        thread.start()
    }
}
