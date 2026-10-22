// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing
@testable import Core

@Suite struct InstanceLockTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "lock-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func secondAcquireOnTheSameProfileIsInUse() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths.profile(root)
        let first = try InstanceLock.acquire(paths: paths)
        #expect(first.isHeld)
        #expect(FileManager.default.fileExists(atPath: paths.instanceLock.path))
        #expect(InstanceLock.holderPID(at: paths.instanceLock) == getpid())
        #expect(throws: InstanceLockError.inUse(path: paths.instanceLock.path, holder: getpid())) {
            _ = try InstanceLock.acquire(paths: paths)
        }
        let message = "\(InstanceLockError.inUse(path: paths.instanceLock.path, holder: 42))"
        #expect(message.hasPrefix("profile in use"))
    }

    @Test func releaseAndDeinitFreeTheLock() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "instance.lock")
        let a = try InstanceLock.acquire(at: url)
        a.release()
        a.release()  // idempotent
        #expect(!a.isHeld)
        do {
            let b = try InstanceLock.acquire(at: url)
            #expect(b.isHeld)
        }  // b deinitialises here
        let c = try InstanceLock.acquire(at: url)
        #expect(c.isHeld)
    }

    @Test func anotherProcessSeesTheLock() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "instance.lock")
        let lock = try InstanceLock.acquire(at: url)
        // /usr/bin/shlock isn't flock-based; Perl's flock is, and ships with macOS.
        let probe = "use Fcntl ':flock'; open(my $f, '<', $ARGV[0]) or exit 2; exit(flock($f, LOCK_EX|LOCK_NB) ? 0 : 1);"
        let held = try await Subprocess.run(SubprocessSpec(executable: URL(filePath: "/usr/bin/perl"),
                                                           arguments: ["-e", probe, url.path], timeout: .seconds(10)))
        #expect(held.termination == .exited(1), "a second process must not get the lock")
        lock.release()
        let free = try await Subprocess.run(SubprocessSpec(executable: URL(filePath: "/usr/bin/perl"),
                                                           arguments: ["-e", probe, url.path], timeout: .seconds(10)))
        #expect(free.termination == .exited(0))
    }
}
