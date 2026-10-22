// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Synchronization
import Testing
@testable import Core

@Suite(.serialized) struct InstanceChannelTests {
    /// Short paths: `sun_path` holds 103 bytes, and the test temp directory can be long.
    private func socketPath() -> URL { URL(filePath: "/tmp/sa-test-\(UUID().uuidString.prefix(8)).sock") }

    @Test func messageEncodingIsOneLineAndRoundTrips() throws {
        let m = InstanceMessage(arguments: ["--profile", "/tmp/p", "sudamp://next", "line\nbreak"], pid: 42,
                                workingDirectory: "/Users/x")
        #expect(m.urls == ["sudamp://next"])
        let data = try m.encoded()
        #expect(data.last == 0x0A)
        #expect(data.dropLast().firstIndex(of: 0x0A) == nil, "newlines inside strings are escaped")
        #expect(try InstanceMessage.decode(data) == m)
    }

    @Test func decodeRejectsGarbageFutureVersionsAndOversize() {
        #expect(throws: InstanceChannelError.self) { try InstanceMessage.decode(Data("hello\n".utf8)) }
        let future = #"{"version":99,"pid":1,"arguments":[],"urls":[]}"#
        #expect(throws: InstanceChannelError.malformed("unsupported version 99")) {
            try InstanceMessage.decode(Data(future.utf8))
        }
        #expect(throws: InstanceChannelError.self) {
            try InstanceMessage.decode(Data(repeating: 0x20, count: InstanceMessage.maxBytes + 1))
        }
    }

    @Test func serverReceivesAForwardedLaunch() async throws {
        let path = socketPath()
        let received = Mutex<[InstanceMessage]>([])
        let server = try InstanceServer(path: path) { m in received.withLock { $0.append(m) } }
        defer { server.close() }
        var mode = stat()
        #expect(stat(path.path, &mode) == 0 && (mode.st_mode & 0o777) == 0o600, "only the owner may connect")
        let sent = InstanceMessage(arguments: ["sudamp://genre/deep-house"])
        try InstanceClient.send(sent, to: path, timeout: 2)
        #expect(received.withLock { $0 } == [sent], "the reply comes after the handler ran")
        try InstanceClient.send(InstanceMessage(arguments: []), to: path, timeout: 2)
        #expect(received.withLock { $0.count } == 2)
    }

    @Test func closeRemovesTheSocketAndAStaleFileIsReplaced() throws {
        let path = socketPath()
        FileManager.default.createFile(atPath: path.path, contents: Data("stale".utf8))
        let server = try InstanceServer(path: path) { _ in }
        #expect(FileManager.default.fileExists(atPath: path.path))
        server.close()
        server.close()  // idempotent
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func clientTimesOutWhenNobodyListens() {
        let started = Date()
        #expect(throws: InstanceChannelError.timedOut) {
            try InstanceClient.send(InstanceMessage(arguments: []), to: socketPath(), timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func clientWaitsForAServerThatIsStillStarting() async throws {
        let path = socketPath()
        let received = Mutex(0)
        let starter = Task.detached {
            try await Task.sleep(for: .milliseconds(300))
            return try InstanceServer(path: path) { _ in received.withLock { $0 += 1 } }
        }
        try InstanceClient.send(InstanceMessage(arguments: ["sudamp://next"]), to: path, timeout: 3)
        let server = try await starter.value
        server.close()
        #expect(received.withLock { $0 } == 1)
    }

    @Test func malformedMessagesAreAnsweredWithAnError() throws {
        let path = socketPath()
        let server = try InstanceServer(path: path) { _ in Issue.record("garbage must not reach the handler") }
        defer { server.close() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = try UnixSocket.address(path.path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(ok == 0)
        UnixSocket.setTimeouts(fd, seconds: 2)
        try UnixSocket.writeAll(fd, Data("{nope}\n".utf8))
        let reply = String(decoding: try UnixSocket.readLine(fd, limit: 4096), as: UTF8.self)
        #expect(reply.hasPrefix("error "))
    }

    @Test func overlongSocketPathsAreRefused() {
        let long = URL(filePath: "/tmp/" + String(repeating: "x", count: 120) + ".sock")
        #expect(throws: InstanceChannelError.pathTooLong(long.path)) { _ = try InstanceServer(path: long) { _ in } }
    }
}
