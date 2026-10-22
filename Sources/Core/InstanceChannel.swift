// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Dispatch
import Foundation
import Synchronization

/// What a second launch forwards to the running instance over `<profile>/instance.sock` (DESIGN §4 "Single
/// instance"): its arguments and the `sudamp:` URLs among them. One JSON object per connection, terminated by a
/// newline; the server answers one line, `ok` or `error <reason>`.
public struct InstanceMessage: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// Larger messages are refused (a second launch's argv is tiny).
    public static let maxBytes = 64 * 1024

    public var version: Int
    public var pid: Int32
    /// The second launch's arguments, without the executable path.
    public var arguments: [String]
    /// `sudamp:` URLs to act on, in order.
    public var urls: [String]
    public var workingDirectory: String?

    public init(arguments: [String], urls: [String]? = nil, pid: Int32 = getpid(),
                workingDirectory: String? = FileManager.default.currentDirectoryPath) {
        version = Self.currentVersion
        self.pid = pid
        self.arguments = arguments
        self.urls = urls ?? RemoteCommand.urls(inArguments: arguments)
        self.workingDirectory = workingDirectory
    }

    /// One line of JSON (no embedded newlines: JSONEncoder escapes them inside strings).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) throws(InstanceChannelError) -> InstanceMessage {
        guard line.count <= maxBytes else { throw .malformed("message over \(maxBytes) bytes") }
        var body = line
        while let last = body.last, last == 0x0A || last == 0x0D { body.removeLast() }
        let message: InstanceMessage
        do {
            message = try JSONDecoder().decode(InstanceMessage.self, from: body)
        } catch {
            throw .malformed("not an instance message: \(error)")
        }
        guard message.version <= currentVersion else { throw .malformed("unsupported version \(message.version)") }
        return message
    }
}

public enum InstanceChannelError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Unix socket paths are limited to 103 bytes (`sun_path` is 104 with the NUL).
    case pathTooLong(String)
    case system(String, errno: Int32)
    case timedOut
    case malformed(String)
    /// The server answered `error <reason>`.
    case refused(String)

    public var description: String {
        switch self {
        case .pathTooLong(let p): "socket path too long (\(p.utf8.count) bytes, max 103): \(p)"
        case let .system(call, e): "\(call): \(String(cString: strerror(e)))"
        case .timedOut: "timed out"
        case .malformed(let m): "malformed: \(m)"
        case .refused(let m): "refused: \(m)"
        }
    }
}

/// Socket plumbing shared by the server and the client.
enum UnixSocket {
    static func address(_ path: String) throws(InstanceChannelError) -> sockaddr_un {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { throw .pathTooLong(path) }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes) }
        return addr
    }

    static func makeSocket() throws(InstanceChannelError) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system("socket", errno: errno) }
        var one: Int32 = 1
        // A peer that hangs up must not kill us with SIGPIPE (the forwarding client runs before mpv ignores it).
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    static func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
        let whole = max(0, seconds)
        var tv = timeval(tv_sec: Int(whole), tv_usec: Int32((whole - Double(Int(whole))) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws(InstanceChannelError) {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN ? .timedOut : .system("write", errno: errno)
            }
            offset += n
        }
    }

    /// Reads until a newline, EOF or `limit` bytes (then one more byte proves the message too long).
    static func readLine(_ fd: Int32, limit: Int) throws(InstanceChannelError) -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while out.count <= limit {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN ? .timedOut : .system("read", errno: errno)
            }
            if n == 0 { break }
            out.append(contentsOf: buffer[0..<n])
            if let nl = out.firstIndex(of: 0x0A) { return out[out.startIndex...nl] }
        }
        guard out.count <= limit else { throw .malformed("message over \(limit) bytes") }
        return out
    }
}

/// The running instance's end of `<profile>/instance.sock` (DESIGN §4). It owns the socket file: any file already
/// at the path is stale (the caller holds the profile's instance lock), so it is replaced. Only the same user may
/// connect (`0600` and a `getpeereid` check). Connections are served one at a time on a private queue; `handler`
/// runs there, so it must hop to the main actor itself. Every accepted message is answered `ok`.
public final class InstanceServer: Sendable {
    public let path: URL
    private let queue = DispatchQueue(label: "app.sudamp.instance-server")
    private let state: Mutex<(fd: Int32, source: (any DispatchSourceRead)?)>
    private let handler: @Sendable (InstanceMessage) -> Void

    public init(path: URL, handler: @escaping @Sendable (InstanceMessage) -> Void) throws(InstanceChannelError) {
        self.path = path
        self.handler = handler
        var addr = try UnixSocket.address(path.path)
        let fd = try UnixSocket.makeSocket()
        unlink(path.path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let e = errno
            Darwin.close(fd)
            throw .system("bind \(path.path)", errno: e)
        }
        chmod(path.path, 0o600)
        guard listen(fd, 8) == 0 else {
            let e = errno
            Darwin.close(fd)
            unlink(path.path)
            throw .system("listen", errno: e)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        state = Mutex((fd, source))
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
    }

    deinit { close() }

    /// Stops listening and removes the socket file (idempotent).
    public func close() {
        let (fd, source) = state.withLock { s -> (Int32, (any DispatchSourceRead)?) in
            defer { s = (-1, nil) }
            return (s.fd, s.source)
        }
        guard fd >= 0 else { return }
        source?.cancel()
        Darwin.close(fd)
        unlink(path.path)
    }

    private func acceptPending() {
        let listener = state.withLock { $0.fd }
        guard listener >= 0 else { return }
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { return }  // EAGAIN: drained
            serve(client)
        }
    }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        UnixSocket.setTimeouts(fd, seconds: 2)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            try? UnixSocket.writeAll(fd, Data("error forbidden\n".utf8))
            return
        }
        let reply: String
        do {
            let line = try UnixSocket.readLine(fd, limit: InstanceMessage.maxBytes)
            let message = try InstanceMessage.decode(line)
            handler(message)
            reply = "ok"
        } catch {
            reply = "error \(error)"
        }
        try? UnixSocket.writeAll(fd, Data((reply.replacingOccurrences(of: "\n", with: " ") + "\n").utf8))
    }
}

/// The second launch's end: connect, send one message, read the answer.
public enum InstanceClient {
    /// Sends `message` to the instance listening at `path`. While the socket is missing or refusing (the running
    /// instance may still be starting), it retries every 100 ms until `timeout`. Returns normally on `ok`.
    public static func send(_ message: InstanceMessage, to path: URL, timeout: TimeInterval = 3)
        throws(InstanceChannelError) {
        var addr = try UnixSocket.address(path.path)
        let data: Data
        do { data = try message.encoded() } catch { throw .malformed("\(error)") }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let fd = try UnixSocket.makeSocket()
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if connected != 0 {
                let e = errno
                close(fd)
                guard [ENOENT, ECONNREFUSED].contains(e), Date() < deadline else {
                    throw e == ENOENT || e == ECONNREFUSED ? .timedOut : .system("connect \(path.path)", errno: e)
                }
                usleep(100_000)
                continue
            }
            defer { close(fd) }
            UnixSocket.setTimeouts(fd, seconds: max(0.5, deadline.timeIntervalSinceNow))
            try UnixSocket.writeAll(fd, data)
            let answer = String(decoding: try UnixSocket.readLine(fd, limit: 4096), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard answer == "ok" else {
                throw answer.isEmpty ? .timedOut : .refused(String(answer.drop(while: { $0 != " " }).dropFirst()))
            }
            return
        }
    }
}
