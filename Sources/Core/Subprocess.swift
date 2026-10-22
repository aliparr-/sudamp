// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Dispatch
import Foundation
import Synchronization

/// How a child process ended.
public enum Termination: Sendable, Equatable, CustomStringConvertible {
    case exited(Int32)
    case signaled(Int32)

    public var description: String {
        switch self {
        case .exited(let code): "exit \(code)"
        case .signaled(let sig): "signal \(sig)"
        }
    }
}

/// What to run. argv only (no shell), an explicit environment (nothing is inherited) and an optional timeout.
public struct SubprocessSpec: Sendable, Equatable {
    /// Absolute path; there is no PATH search.
    public var executable: URL
    /// Arguments after argv[0] (argv[0] is the executable path).
    public var arguments: [String]
    /// The complete environment of the child. Empty means an empty environment, not the parent's.
    public var environment: [String: String]
    /// Working directory of the child; nil inherits the parent's.
    public var workingDirectory: URL?
    /// Wall-clock limit; when it passes the whole process group is killed and the result is marked `timedOut`.
    public var timeout: Duration?
    /// Bytes kept per output stream; the rest is drained and dropped (the `*Truncated` flags are set).
    public var outputLimit: Int

    public init(executable: URL, arguments: [String] = [], environment: [String: String] = [:],
                workingDirectory: URL? = nil, timeout: Duration? = nil, outputLimit: Int = 32 << 20) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.outputLimit = outputLimit
    }
}

/// The outcome of a finished child.
public struct SubprocessResult: Sendable, Equatable {
    public var pid: pid_t
    public var termination: Termination
    public var stdout: Data
    public var stderr: Data
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool
    /// True when the timeout killed the process group.
    public var timedOut: Bool
    /// Monotonic time from spawn to reaping.
    public var elapsed: Duration

    public init(pid: pid_t = 0, termination: Termination, stdout: Data = Data(), stderr: Data = Data(),
                stdoutTruncated: Bool = false, stderrTruncated: Bool = false, timedOut: Bool = false,
                elapsed: Duration = .zero) {
        self.pid = pid
        self.termination = termination
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.timedOut = timedOut
        self.elapsed = elapsed
    }

    /// Exit status 0 and not killed by the timeout.
    public var succeeded: Bool { termination == .exited(0) && !timedOut }
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    public var elapsedSeconds: Double {
        Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    }
}

public enum SubprocessError: Error, Sendable, Equatable {
    case pipeFailed(errno: Int32)
    case spawnFailed(errno: Int32)
}

/// Runs child processes with `posix_spawn` (DESIGN §4 Core, §6.2 process rules).
///
/// Each child gets its own process group (`POSIX_SPAWN_SETPGROUP`), default signal dispositions and an empty
/// signal mask (the parent ignores SIGPIPE for mpv; children must not inherit that), stdin from /dev/null and
/// no inherited file descriptors except stdout/stderr pipes (`POSIX_SPAWN_CLOEXEC_DEFAULT`). Timeout and task
/// cancellation `killpg` the whole group, so helpers such as yt-dlp's `qjs` die with it. When the leader exits
/// normally, stragglers left in its group are killed too, before the leader is reaped (so the group ID can't
/// have been reused).
public enum Subprocess {
    /// Spawns, collects output and waits. Throws `CancellationError` (after killing and reaping) if the calling
    /// task is cancelled.
    public static func run(_ spec: SubprocessSpec) async throws -> SubprocessResult {
        try Task.checkCancellation()
        let child = try spawn(spec)
        return try await withTaskCancellationHandler {
            let result = await child.waitForCompletion(timeout: spec.timeout)
            if child.killReason == .cancelled { throw CancellationError() }
            return result
        } onCancel: {
            child.kill(.cancelled)
        }
    }

    /// Convenience for tests and tools.
    public static func run(_ executable: String, _ arguments: [String] = [], environment: [String: String] = [:],
                           timeout: Duration? = nil) async throws -> SubprocessResult {
        try await run(SubprocessSpec(executable: URL(filePath: executable), arguments: arguments,
                                     environment: environment, timeout: timeout))
    }

    // MARK: Spawning

    private static func spawn(_ spec: SubprocessSpec) throws -> ChildProcess {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw SubprocessError.pipeFailed(errno: errno) }
        guard pipe(&errPipe) == 0 else {
            let e = errno
            close(outPipe[0]); close(outPipe[1])
            throw SubprocessError.pipeFailed(errno: e)
        }
        // Parent ends must never leak into other children spawned concurrently.
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        if let dir = spec.workingDirectory {
            if #available(macOS 26, *) {
                posix_spawn_file_actions_addchdir(&actions, dir.path)
            } else {
                posix_spawn_file_actions_addchdir_np(&actions, dir.path)
            }
        }

        var noSignals = sigset_t()
        var allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setpgroup(&attributes, 0)  // the child leads a new group whose ID is its PID
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv = [spec.executable.path] + spec.arguments
        let envp = spec.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let cArgv = argv.map { strdup($0) } + [nil]
        let cEnvp = envp.map { strdup($0) } + [nil]
        defer {
            for p in cArgv { free(p) }
            for p in cEnvp { free(p) }
        }

        var pid: pid_t = 0
        let start = ContinuousClock.now
        let rc = posix_spawn(&pid, spec.executable.path, &actions, &attributes, cArgv, cEnvp)
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw SubprocessError.spawnFailed(errno: rc)
        }
        return ChildProcess(pid: pid, start: start, stdoutFD: outPipe[0], stderrFD: errPipe[0],
                            outputLimit: spec.outputLimit)
    }
}

/// One running child: its pipes, its reaper and the kill switch shared by timeout and cancellation.
private final class ChildProcess: Sendable {
    enum KillReason: Sendable, Equatable { case timeout, cancelled }

    private struct State {
        var killReason: KillReason?
        var reaped = false
        /// Set once the leader is reaped: the reader stops at this instant even if a grandchild that left our
        /// group still holds the pipes open.
        var readDeadline: ContinuousClock.Instant?
    }

    private struct Partial {
        var output: (stdout: Data, stdoutTruncated: Bool, stderr: Data, stderrTruncated: Bool)?
        var termination: Termination?
        var end: ContinuousClock.Instant?
    }

    let pid: pid_t
    private let start: ContinuousClock.Instant
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private let outputLimit: Int
    private let state = Mutex(State())

    init(pid: pid_t, start: ContinuousClock.Instant, stdoutFD: Int32, stderrFD: Int32, outputLimit: Int) {
        self.pid = pid
        self.start = start
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
        self.outputLimit = outputLimit
    }

    var killReason: KillReason? { state.withLock { $0.killReason } }

    /// Kills the whole process group unless the leader was already reaped (its group ID could be reused then).
    func kill(_ reason: KillReason) {
        state.withLock { s in
            guard !s.reaped else { return }
            if s.killReason == nil { s.killReason = reason }
            _ = killpg(pid, SIGKILL)
        }
    }

    func waitForCompletion(timeout: Duration?) async -> SubprocessResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<SubprocessResult, Never>) in
            let partial = Mutex(Partial())
            // Whichever of the reader and the reaper finishes second delivers the result.
            let finish: @Sendable ((inout Partial) -> Void) -> Void = { [self] update in
                let done: SubprocessResult? = partial.withLock { p in
                    update(&p)
                    guard let output = p.output, let termination = p.termination, let end = p.end else { return nil }
                    return SubprocessResult(
                        pid: pid, termination: termination,
                        stdout: output.stdout, stderr: output.stderr,
                        stdoutTruncated: output.stdoutTruncated, stderrTruncated: output.stderrTruncated,
                        timedOut: killReason == .timeout, elapsed: end - start)
                }
                if let done { continuation.resume(returning: done) }
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let output = readPipes()
                finish { $0.output = output }
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                waitForExit(deadline: timeout.map { start + $0 })
                let termination = reap()
                finish { p in
                    p.termination = termination
                    p.end = ContinuousClock.now
                }
            }
        }
    }

    /// Blocks until the leader exits, killing the group at `deadline`. Uses kqueue (`EVFILT_PROC`/`NOTE_EXIT`
    /// with an exact timeout) rather than a GCD timer: `asyncAfter` may coalesce a 10 s deadline by ~1 s.
    private func waitForExit(deadline: ContinuousClock.Instant?) {
        let kq = kqueue()
        guard kq >= 0 else { return }  // reap() still blocks in waitid; only the deadline is lost
        defer { close(kq) }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        // ESRCH: it already exited (a zombie can't be watched), so there is nothing to wait for.
        guard kevent(kq, &change, 1, nil, 0, nil) == 0 else { return }
        var event = kevent()
        var deadline = deadline
        while true {
            let n: Int32
            if let d = deadline {
                let remaining = d - ContinuousClock.now
                if remaining <= .zero {
                    kill(.timeout)
                    deadline = nil
                    continue
                }
                var ts = remaining.timespec
                n = kevent(kq, nil, 0, &event, 1, &ts)
            } else {
                n = kevent(kq, nil, 0, &event, 1, nil)
            }
            if n > 0 { return }  // NOTE_EXIT
            if n < 0, errno != EINTR { return }
        }
    }

    /// Kills stragglers in the exited leader's group, then reaps it.
    private func reap() -> Termination {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0 {
            if errno != EINTR { break }  // fall through to waitpid, which reports the real state
        }
        var status: Int32 = 0
        state.withLock { s in
            _ = killpg(pid, SIGKILL)  // the zombie leader still holds the group ID, so this can't hit a stranger
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            s.reaped = true
            s.readDeadline = ContinuousClock.now + .seconds(2)
        }
        // <sys/wait.h> macros aren't imported into Swift: low 7 bits are the signal, 0 means a normal exit.
        let signal = status & 0x7F
        return signal == 0 ? .exited((status >> 8) & 0xFF) : .signaled(signal)
    }

    /// Drains stdout and stderr together with poll(2) until both reach EOF (or the post-reap deadline).
    private func readPipes() -> (stdout: Data, stdoutTruncated: Bool, stderr: Data, stderrTruncated: Bool) {
        var data = [Data(), Data()]
        var truncated = [false, false]
        var open = [true, true]
        let fds = [stdoutFD, stderrFD]
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        defer { for fd in fds { close(fd) } }

        while open.contains(true) {
            if let deadline = state.withLock({ $0.readDeadline }), ContinuousClock.now >= deadline { break }
            var pollFDs = fds.enumerated().map { i, fd in pollfd(fd: open[i] ? fd : -1, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&pollFDs, nfds_t(pollFDs.count), 100)
            if ready < 0, errno != EINTR { break }
            guard ready > 0 else { continue }
            for i in 0..<2 where open[i] && pollFDs[i].revents != 0 {
                let n = chunk.withUnsafeMutableBytes { read(fds[i], $0.baseAddress, $0.count) }
                if n > 0 {
                    let room = max(0, outputLimit - data[i].count)
                    if room > 0 { data[i].append(contentsOf: chunk[0..<min(n, room)]) }
                    if n > room { truncated[i] = true }
                } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                    open[i] = false  // EOF or a real error
                }
            }
        }
        return (data[0], truncated[0], data[1], truncated[1])
    }
}

private extension Duration {
    var timespec: Darwin.timespec {
        let (seconds, attoseconds) = components
        return Darwin.timespec(tv_sec: Int(seconds), tv_nsec: Int(attoseconds / 1_000_000_000))
    }
}
