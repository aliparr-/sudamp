// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing
@testable import Core

/// Subprocess behaviour, driven by /bin/sh fixtures.
@Suite struct SubprocessTests {
    /// A SIGKILLed orphan stays a zombie until launchd reaps it, so poll briefly for ESRCH.
    private func gone(_ pid: pid_t) async -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func sh(_ script: String, env: [String: String] = [:], timeout: Duration? = nil,
                    limit: Int = 32 << 20) async throws -> SubprocessResult {
        try await Subprocess.run(SubprocessSpec(executable: URL(filePath: "/bin/sh"), arguments: ["-c", script],
                                                environment: env, timeout: timeout, outputLimit: limit))
    }

    @Test func capturesStdoutStderrAndExitStatus() async throws {
        let r = try await sh("echo out; echo err >&2; exit 3")
        #expect(r.stdoutString == "out\n")
        #expect(r.stderrString == "err\n")
        #expect(r.termination == .exited(3))
        #expect(!r.succeeded)
        #expect(!r.timedOut)
    }

    @Test func argvIsPassedVerbatimWithoutAShell() async throws {
        let tricky = ["a b", "$HOME", "; rm -rf /", "--", "-x", "ünï", ""]
        let r = try await Subprocess.run(SubprocessSpec(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "for a in \"$@\"; do printf '[%s]' \"$a\"; done", "argv0"] + tricky))
        #expect(r.stdoutString == tricky.map { "[\($0)]" }.joined())
    }

    @Test func environmentIsExactlyWhatWasGiven() async throws {
        let r = try await Subprocess.run(SubprocessSpec(executable: URL(filePath: "/usr/bin/env"),
                                                        environment: ["A": "1", "PATH": "/usr/bin:/bin"]))
        let lines = Set(r.stdoutString.split(separator: "\n").map(String.init))
        #expect(lines == ["A=1", "PATH=/usr/bin:/bin"])
    }

    @Test func emptyEnvironmentInheritsNothing() async throws {
        let r = try await Subprocess.run(SubprocessSpec(executable: URL(filePath: "/usr/bin/env")))
        #expect(r.stdoutString.isEmpty)
        #expect(r.succeeded)
    }

    @Test func childLeadsItsOwnProcessGroup() async throws {
        let r = try await sh("echo $$; /bin/ps -o pgid= -p $$")
        let parts = r.stdoutString.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        #expect(parts.count == 2)
        #expect(parts.first == parts.last, "pgid should equal the child's pid")
        #expect(parts.first == r.pid)
        #expect(parts.last != getpgrp())
    }

    @Test func stdinIsDevNullAndParentDescriptorsDoNotLeak() async throws {
        // A descriptor open in the parent without O_CLOEXEC must not reach the child.
        let low = open("/dev/null", O_RDONLY)
        let fd = fcntl(low, F_DUPFD, 200)  // a number no shell or ls would open by itself
        close(low)
        defer { close(fd) }
        #expect(fd >= 200)
        let r = try await sh("cat; ls /dev/fd")
        let fds = Set(r.stdoutString.split(separator: "\n").map(String.init))
        #expect(!fds.contains(String(fd)), "inherited \(fd): \(fds)")
        #expect(fds.allSatisfy { (Int($0) ?? 99) < 10 }, "only stdio and ls's own descriptors: \(fds)")
    }

    @Test func signalDispositionsAreResetToDefault() async throws {
        // The app ignores SIGPIPE for mpv; children must still die from it.
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        let r = try await sh("kill -PIPE $$; echo survived")
        #expect(r.termination == .signaled(SIGPIPE))
        #expect(r.stdoutString.isEmpty)
    }

    @Test func drainsLargeOutputOnBothStreams() async throws {
        // Far beyond the 16–64 KB pipe buffer on both pipes at once: a sequential reader would deadlock.
        let r = try await sh("/usr/bin/yes o | /usr/bin/head -c 3000000; /usr/bin/yes e | /usr/bin/head -c 2000000 >&2")
        #expect(r.stdout.count == 3_000_000)
        #expect(r.stderr.count == 2_000_000)
        #expect(r.succeeded)
    }

    @Test func outputBeyondTheLimitIsDroppedAndFlagged() async throws {
        let r = try await sh("/usr/bin/yes x | /usr/bin/head -c 100000", limit: 1000)
        #expect(r.stdout.count == 1000)
        #expect(r.stdoutTruncated)
        #expect(!r.stderrTruncated)
    }

    @Test func timeoutKillsTheWholeProcessGroup() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "subprocess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appending(path: "grandchild.pid")
        let started = ContinuousClock.now
        let r = try await sh("/bin/sleep 30 & echo $! > '\(pidFile.path)'; /bin/sleep 30", timeout: .milliseconds(300))
        #expect(r.timedOut)
        #expect(r.termination == .signaled(SIGKILL))
        #expect(ContinuousClock.now - started < .seconds(5))
        let grandchild = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await gone(grandchild), "background sleep must be dead")
    }

    @Test func timeoutIsPrecise() async throws {
        // GCD timers may be coalesced by ~10% of their interval; the kqueue deadline must not drift.
        let r = try await sh("/bin/sleep 30", timeout: .seconds(2))
        #expect(r.timedOut)
        #expect(r.elapsedSeconds >= 2.0)
        #expect(r.elapsedSeconds < 2.1, "killed after \(r.elapsedSeconds) s")
    }

    @Test func stragglersAreKilledWhenTheLeaderExitsNormally() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "subprocess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appending(path: "straggler.pid")
        // The straggler's stdout/stderr go to /dev/null so only the group kill can end it.
        let r = try await sh("/bin/sleep 30 >/dev/null 2>&1 & echo $! > '\(pidFile.path)'; exit 0",
                             timeout: .seconds(10))
        #expect(r.succeeded)
        let straggler = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await gone(straggler))
    }

    @Test func cancellationKillsTheGroupAndThrows() async throws {
        let started = ContinuousClock.now
        let task = Task { try await sh("/bin/sleep 30") }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func alreadyCancelledTaskNeverSpawns() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "subprocess-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.path
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await sh("/bin/mkdir '\(marker)'")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func spawnFailureIsReported() async throws {
        await #expect(throws: SubprocessError.spawnFailed(errno: ENOENT)) {
            try await Subprocess.run("/nonexistent/binary")
        }
    }

    @Test func workingDirectoryIsApplied() async throws {
        let r = try await Subprocess.run(SubprocessSpec(executable: URL(filePath: "/bin/pwd"),
                                                        workingDirectory: URL(filePath: "/usr/lib")))
        #expect(r.stdoutString == "/usr/lib\n")
    }

    @Test func elapsedIsMeasured() async throws {
        let r = try await sh("/bin/sleep 0.2")
        #expect(r.elapsedSeconds >= 0.19)
        #expect(r.elapsedSeconds < 3)
    }
}
