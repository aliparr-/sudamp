// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Synchronization

public enum InstanceLockError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Another process (or another open of the same file) holds the profile. `holder` is the pid it recorded.
    case inUse(path: String, holder: Int32?)
    case cannotOpen(path: String, errno: Int32)

    public var description: String {
        switch self {
        case let .inUse(path, holder):
            "profile in use (\(path) is locked\(holder.map { " by pid \($0)" } ?? ""))"
        case let .cannotOpen(path, e):
            "cannot open \(path): \(String(cString: strerror(e)))"
        }
    }
}

/// The single-instance lock (DESIGN §4): an exclusive, non-blocking `flock` on `<profile>/instance.lock`. The kernel
/// drops it when the process exits, however it exits; `release()` and deinit drop it earlier. `flock` locks belong
/// to the open file description, so a second `acquire` in the same process fails too (which the tests rely on).
/// The holder writes its pid into the file, for the error message only.
public final class InstanceLock: Sendable {
    public let url: URL
    private let descriptor: Mutex<Int32>

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = Mutex(descriptor)
    }

    deinit { release() }

    /// Takes the profile's lock (`paths.instanceLock`), creating the profile directory if needed.
    public static func acquire(paths: Paths) throws(InstanceLockError) -> InstanceLock {
        try acquire(at: paths.instanceLock)
    }

    public static func acquire(at url: URL) throws(InstanceLockError) -> InstanceLock {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw .cannotOpen(path: url.path, errno: errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let e = errno
            close(fd)
            if e == EWOULDBLOCK { throw .inUse(path: url.path, holder: holderPID(at: url)) }
            throw .cannotOpen(path: url.path, errno: e)
        }
        let pid = Array("\(getpid())\n".utf8)
        if ftruncate(fd, 0) == 0 {
            _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        }
        return InstanceLock(url: url, descriptor: fd)
    }

    public var isHeld: Bool { descriptor.withLock { $0 >= 0 } }

    /// Drops the lock (idempotent). The file stays, so the next holder reuses it.
    public func release() {
        descriptor.withLock { fd in
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    /// The pid the current holder wrote, if readable.
    static func holderPID(at url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
