// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization
@testable import Feeds

/// An in-process feed host for unit tests: a `URLProtocol` that routes each request by host name to a
/// `StubFeedServer`, so parallel tests (one host each) never see each other's traffic.
final class StubURLProtocol: URLProtocol {
    private static let servers = Mutex<[String: StubFeedServer]>([:])

    static func register(_ server: StubFeedServer) { servers.withLock { $0[server.host] = server } }
    static func unregister(_ server: StubFeedServer) { _ = servers.withLock { $0.removeValue(forKey: server.host) } }
    static func server(for request: URLRequest) -> StubFeedServer? {
        guard let host = request.url?.host else { return nil }
        return servers.withLock { $0[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool { server(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = server.handle(request)
        // Test-only: URLProtocol clients accept callbacks from any thread, and `self` and its client are used only to
        // deliver this one canned reply, once.
        // SAFETY: `me` is read by one delivery closure, after `startLoading` returned; nothing mutates it.
        nonisolated(unsafe) let me = self
        let deliver: @Sendable () -> Void = {
            let protocolClient = me.client
            guard let reply else { return }   // hang: never answer (the session's timeout ends it)
            if let location = reply.redirect {
                let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": location.absoluteString])!
                var next = URLRequest(url: location)
                next.allHTTPHeaderFields = me.request.allHTTPHeaderFields
                protocolClient?.urlProtocol(me, wasRedirectedTo: next, redirectResponse: response)
                protocolClient?.urlProtocolDidFinishLoading(me)
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: reply.headers)!
            protocolClient?.urlProtocol(me, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.body.isEmpty { protocolClient?.urlProtocol(me, didLoad: reply.body) }
            protocolClient?.urlProtocolDidFinishLoading(me)
        }
        if let delay = reply?.delay {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}

/// One reply from the stub host.
struct StubReply: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    var delay: TimeInterval?
    var redirect: URL?
}

/// A feed host with an ETag'd `feed.json` and `feed.json.sig`, a request log, and failure modes.
final class StubFeedServer: Sendable {
    enum Mode: Sendable {
        case normal
        /// Never answer the feed request.
        case hang
        /// Answer the feed request after a delay.
        case delay(TimeInterval)
        case status(Int)
        /// A body larger than any cap, with or without `Content-Length`.
        case oversized(bytes: Int, contentLength: Bool)
        case redirect(URL)
    }

    struct Logged: Sendable {
        var path: String
        var headers: [String: String]
    }

    private struct State {
        var body = Data()
        var signature = Data()
        var etag: String?
        var mode = Mode.normal
        var log: [Logged] = []
    }

    let host: String
    private let state = Mutex(State())

    init() {
        host = "feed-\(UUID().uuidString.lowercased().prefix(12)).test"
        StubURLProtocol.register(self)
    }

    deinit { StubURLProtocol.unregister(self) }

    var feedURL: URL { URL(string: "https://\(host)/sudamp/feed.json")! }

    /// Publishes a document; the ETag changes with the bytes.
    func publish(_ body: Data, signature: Data, etag: String? = nil) {
        state.withLock {
            $0.body = body
            $0.signature = signature
            $0.etag = etag ?? "\"\(body.count)-\(UInt(bitPattern: body.hashValue))\""
        }
    }

    func set(_ mode: Mode) { state.withLock { $0.mode = mode } }

    var requests: [Logged] { state.withLock { $0.log } }
    var feedRequests: [Logged] { requests.filter { $0.path.hasSuffix("feed.json") } }

    func handle(_ request: URLRequest) -> StubReply? {
        let path = request.url?.path ?? ""
        return state.withLock { s -> StubReply? in
            s.log.append(Logged(path: path, headers: request.allHTTPHeaderFields ?? [:]))
            if path.hasSuffix(".sig") { return StubReply(status: 200, body: s.signature) }
            guard path.hasSuffix("feed.json") else { return StubReply(status: 404) }
            switch s.mode {
            case .hang: return nil
            case .status(let code): return StubReply(status: code)
            case .redirect(let url): return StubReply(status: 302, redirect: url)
            case .oversized(let n, let withLength):
                return StubReply(status: 200, headers: withLength ? ["Content-Length": "\(n)"] : [:],
                                 body: Data(repeating: 0x20, count: n))
            case .normal, .delay:
                var reply: StubReply
                if let etag = s.etag, request.value(forHTTPHeaderField: "If-None-Match") == etag {
                    reply = StubReply(status: 304, headers: ["ETag": etag])
                } else {
                    var headers = ["Content-Type": "application/json"]
                    headers["ETag"] = s.etag
                    reply = StubReply(status: 200, headers: headers, body: s.body)
                }
                if case .delay(let d) = s.mode { reply.delay = d }
                return reply
            }
        }
    }

    /// A client for this host whose session goes through the stub.
    func client(timeout: TimeInterval = 5, maxBytes: Int = RemoteFeedClient.defaultMaxBytes) throws -> RemoteFeedClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return try RemoteFeedClient(feedURL: feedURL, userAgent: "sudamp/9.9.9-test", timeout: timeout, maxBytes: maxBytes,
                                    allowLoopbackHTTP: false, configuration: config)
    }
}
