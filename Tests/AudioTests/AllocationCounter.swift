// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Synchronization

/// Counts heap allocations made by the calling thread while `body` runs, through libmalloc's `malloc_logger` hook
/// (the one allocation tracers use; it sees every malloc-family call). Tests only; calls are serialised.
enum AllocationCounter {
    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    private static let count = Atomic<Int>(0)
    private static let target = Atomic<UInt>(0)
    private static let serial = Mutex(())
    /// MALLOC_LOG_TYPE_ALLOCATE.
    private static let allocateFlag: UInt32 = 2

    private static let logger: Logger = { type, _, _, _, _, _ in
        guard type & AllocationCounter.allocateFlag != 0,
              UInt(bitPattern: pthread_self()) == AllocationCounter.target.load(ordering: .relaxed) else { return }
        AllocationCounter.count.add(1, ordering: .relaxed)
    }

    /// nil if the hook isn't available (then the caller should not assert).
    static func allocations(in body: () -> Void) -> Int? {
        serial.withLock { _ -> Int? in
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
            let slot = symbol.assumingMemoryBound(to: Optional<Logger>.self)
            guard slot.pointee == nil else { return nil } // someone else (stack logging) owns it
            count.store(0, ordering: .relaxed)
            target.store(UInt(bitPattern: pthread_self()), ordering: .relaxed)
            slot.pointee = logger
            body()
            slot.pointee = nil
            target.store(0, ordering: .relaxed)
            return count.load(ordering: .relaxed)
        }
    }
}
