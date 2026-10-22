// SPDX-License-Identifier: GPL-3.0-or-later
// PLAN M6 `make test`: a crafted m3u8 pointing at file:///etc/hosts fails to load (DESIGN §7.1: "mpv gets
// config=no, load-scripts=no, load-unsafe-playlists=no and array commands only; a test proves a crafted file://
// m3u8 fails"). The playlists are served over real HTTP from 127.0.0.1, as a hostile station would serve them,
// and also point at a playable local WAV, so a refusal can't be mistaken for "/etc/hosts isn't audio".
import Darwin
import Foundation
import Synchronization
import Testing
@testable import MPV

/// A tiny HTTP/1.0 server on 127.0.0.1 for fixed bodies (one thread, one request per connection).
final class TinyHTTPServer: Sendable {
    let port: UInt16
    private let fd: Int32
    private let bodies: [String: (type: String, body: Data)]
    let requests = Mutex<[String]>([])

    init(_ bodies: [String: (type: String, body: Data)]) throws {
        self.bodies = bodies
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(s, 8) == 0 else { close(s); throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        fd = s
        port = UInt16(bigEndian: addr.sin_port)
        let thread = Thread { [self] in serve() }
        thread.name = "tiny-http"
        thread.start()
    }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func serve() {
        while true {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(c, &buf, buf.count)
            let head = n > 0 ? String(decoding: buf.prefix(n), as: UTF8.self) : ""
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            requests.withLock { $0.append(path) }
            let reply: Data
            if let (type, body) = bodies[path] {
                reply = Data("HTTP/1.0 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
            } else {
                reply = Data("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
            reply.withUnsafeBytes { _ = write(c, $0.baseAddress, $0.count) }
            close(c)
        }
    }
}

extension MPVPlaybackTests {
    /// Loads `url` and pulls the AO until mpv is idle again after an end-file (or `seconds` pass). Returns the
    /// end-files seen (a playlist's own entry ends as `redirect`), whether any audio came out, and mpv's log lines.
    func loadAndWatch(_ url: String, seconds: Double = 6) async throws -> (ends: [MPVEndFile], audible: Bool, logs: [String]) {
        let client = try MPVClient(options: MPVOptions.defaults, logLevel: "v")
        defer { client.shutdown() }
        let events = client.events
        let watcher = Task { () -> ([MPVEndFile], [String]) in
            var logs: [String] = []
            var ends: [MPVEndFile] = []
            for await e in events {
                switch e {
                case .log(let m): logs.append("[\(m.prefix)] \(m.text)")
                case .endFile(let end): ends.append(end)
                case .shutdown: return (ends, logs)
                default: break
                }
            }
            return (ends, logs)
        }
        try client.loadfile(url)
        let puller = Puller()
        var audible = false
        let started = Date()
        var idleSince: Date?
        while Date().timeIntervalSince(started) < seconds, !audible {
            if puller.pull().audible { audible = true }
            let snap = client.snapshot
            if snap.lastEndFile != nil, snap.idleActive == true {
                idleSince = idleSince ?? Date()
                if Date().timeIntervalSince(idleSince!) > 0.5 { break }
            } else {
                idleSince = nil
            }
        }
        client.shutdown()
        let (ends, logs) = await watcher.value
        return (ends, audible, logs)
    }

    @Test func craftedM3U8PointingAtLocalFilesFailsToLoad() async throws {
        let wav = Fixture.ramp.path
        let hls = { (target: String) in
            Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:10.0,\n\(target)\n#EXT-X-ENDLIST\n".utf8)
        }
        let server = try TinyHTTPServer([
            "/hosts.m3u8": ("application/vnd.apple.mpegurl", hls("file:///etc/hosts")),
            "/wav.m3u8": ("application/vnd.apple.mpegurl", hls("file://\(wav)")),
            // A plain (non-HLS) playlist goes through mpv's own playlist parser instead of FFmpeg's HLS demuxer.
            "/wav.m3u": ("audio/x-mpegurl", Data("#EXTM3U\n#EXTINF:-1,x\nfile://\(wav)\n".utf8)),
            "/hosts.m3u": ("audio/x-mpegurl", Data("#EXTM3U\nfile:///etc/hosts\n".utf8)),
        ])
        defer { server.stop() }
        let initsBefore = PullAO.initCount
        // Each refusal is a safety layer, not an accident of format: FFmpeg's HLS demuxer blocks local files by
        // extension and its protocol whitelist (inherited from the http: playlist) has no `file`; mpv's own playlist
        // parser marks entries from a network playlist as network-origin, which may not open local files
        // (`load-unsafe-playlists=no`), reported as "No protocol handler found".
        let expected: [String: [String]] = [
            "/hosts.m3u8": ["blocked for security reasons", "not on whitelist"],
            "/wav.m3u8": ["not on whitelist", "blocked for security reasons"],
            "/wav.m3u": ["No protocol handler found"],
            "/hosts.m3u": ["No protocol handler found"],
        ]
        for (path, needles) in expected.sorted(by: { $0.key < $1.key }) {
            let r = try await loadAndWatch(server.url(path))
            #expect(!r.audible, "\(path): the local file played")
            #expect(r.ends.contains { $0.reason == .error }, "\(path): \(r.ends.map(\.reason.rawValue))")
            let refused = r.logs.filter { line in needles.contains { line.localizedCaseInsensitiveContains($0) } }
            #expect(!refused.isEmpty, "\(path): no refusal logged: \(r.logs.suffix(12))")
        }
        #expect(PullAO.initCount == initsBefore, "an audio output was opened for a crafted playlist")
        #expect(server.requests.withLock { $0 }.count >= 4)
    }

    /// The control: the same plain playlist opened from a local file (local origin) does play the WAV, so the
    /// refusal above is the network-origin rule, not the playlist format.
    @Test func localPlaylistMayOpenLocalFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sudamp-mpvtests")
        let m3u = dir.appending(path: "local-\(UUID().uuidString).m3u")
        try Data("#EXTM3U\n#EXTINF:-1,x\nfile://\(Fixture.ramp.path)\n".utf8).write(to: m3u)
        defer { try? FileManager.default.removeItem(at: m3u) }
        let r = try await loadAndWatch(m3u.path)
        #expect(r.audible, "a local playlist's local entry should play: \(r.logs.suffix(8))")
    }
}
