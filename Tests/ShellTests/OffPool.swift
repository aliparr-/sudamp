// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch

/// Runs CPU-heavy or blocking test work on a GCD thread instead of one of Swift concurrency's cooperative threads
/// (about one per core). On a 3-core CI runner, long synchronous tests held the pool and every timing-sensitive test
/// in the same process timed out. The work returns what to check; `#expect` stays in the test body.
func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
    }
}
