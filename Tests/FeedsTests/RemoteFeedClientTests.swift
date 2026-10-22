// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Feeds

@Test func feedURLPolicy() {
    func ok(_ s: String, debug: Bool = false) -> Bool { FeedURLPolicy.isAllowed(URL(string: s)!, allowLoopbackHTTP: debug) }
    #expect(ok("https://example.github.io/sudamp/feed.json"))
    #expect(ok("https://feeds.example.com:8443/feed.json"))
    #expect(!ok("http://example.github.io/feed.json"), "HTTPS only")
    #expect(!ok("http://example.github.io/feed.json", debug: true), "the debug allowance is loopback only")
    #expect(!ok("http://127.0.0.1:8000/feed.json"), "release builds: no HTTP at all")
    #expect(ok("http://127.0.0.1:8000/feed.json", debug: true))
    #expect(ok("http://localhost:8000/feed.json", debug: true))
    #expect(ok("http://[::1]:8000/feed.json", debug: true))
    #expect(!ok("http://127.0.0.2:8000/feed.json", debug: true))
    #expect(!ok("https://user:pw@example.com/feed.json"), "no userinfo")
    #expect(!ok("file:///etc/feed.json", debug: true))
    #expect(!ok("ftp://example.com/feed.json"))
    #expect(throws: RemoteFeedError.self) { try RemoteFeedClient(feedURL: URL(string: "http://example.com/feed.json")!) }
}

@Test func signatureURLIsNextToTheFeed() {
    #expect(FeedEndpoint.signatureURL(for: URL(string: "https://a.github.io/sudamp/feed.json")!)?.absoluteString
            == "https://a.github.io/sudamp/feed.json.sig")
    #expect(FeedEndpoint.signatureURL(for: URL(string: "http://127.0.0.1:8000/feed.json?x=1")!)?.absoluteString
            == "http://127.0.0.1:8000/feed.json.sig")
    #expect(FeedEndpoint.signatureURL(for: URL(string: "https://a.github.io/")!) == nil)
    #expect(FeedEndpoint.production == nil, "no published feed yet: release builds stay bundled-only")
    #if DEBUG
    #expect(FeedEndpoint.resolve(environment: ["SUDAMP_FEED_URL": "http://127.0.0.1:1/feed.json"])?.port == 1)
    #endif
    #expect(FeedEndpoint.resolve(environment: [:]) == FeedEndpoint.production)
}

@Test func fetchSendsConditionalRequestsWithoutIdentifiers() async throws {
    let server = StubFeedServer()
    let (body, sig) = try signed(doc(revision: 3))
    server.publish(body, signature: sig, etag: "\"v3\"")
    let client = try server.client()

    let first = try await client.fetch(ifNoneMatch: nil)
    #expect(first == .fetched(RemoteFeedResponse(body: body, signature: sig, etag: "\"v3\"")))
    let second = try await client.fetch(ifNoneMatch: "\"v3\"")
    #expect(second == .notModified)
    let stale = try await client.fetch(ifNoneMatch: "\"v2\"")
    #expect(stale == .fetched(RemoteFeedResponse(body: body, signature: sig, etag: "\"v3\"")))

    let log = server.requests
    #expect(log.map(\.path) == ["/sudamp/feed.json", "/sudamp/feed.json.sig", "/sudamp/feed.json",
                                "/sudamp/feed.json", "/sudamp/feed.json.sig"], "304 skips the signature")
    #expect(log[0].headers["If-None-Match"] == nil)
    #expect(log[2].headers["If-None-Match"] == "\"v3\"")
    for r in log {
        #expect(r.headers["User-Agent"] == "sudamp/9.9.9-test")
        #expect(r.headers["Accept-Language"] == "*", "not the user's locale")
        for h in ["Cookie", "Authorization", "X-Client-ID", "Referer"] { #expect(r.headers[h] == nil, "\(h)") }
    }
}

@Test func fetchFailuresAreTyped() async throws {
    let server = StubFeedServer()
    let (body, sig) = try signed(doc(revision: 3))
    server.publish(body, signature: sig)
    let client = try server.client(timeout: 1, maxBytes: 4096)

    server.set(.status(500))
    await #expect(throws: RemoteFeedError.httpStatus(500, url: server.feedURL.absoluteString)) {
        try await client.fetch(ifNoneMatch: nil)
    }
    server.set(.status(404))
    await #expect(throws: RemoteFeedError.httpStatus(404, url: server.feedURL.absoluteString)) {
        try await client.fetch(ifNoneMatch: nil)
    }
    // Oversized with Content-Length (refused before reading) and without it (reading stops at the cap).
    server.set(.oversized(bytes: 10_000, contentLength: true))
    await #expect(throws: RemoteFeedError.tooLarge(limit: 4096)) { try await client.fetch(ifNoneMatch: nil) }
    server.set(.oversized(bytes: 10_000, contentLength: false))
    await #expect(throws: RemoteFeedError.tooLarge(limit: 4096)) { try await client.fetch(ifNoneMatch: nil) }
    // A redirect to plain HTTP is not followed: the fetch fails and the HTTP URL is never requested. (Over the
    // network the refused 302 surfaces as `.httpStatus(302)`; through a URLProtocol stub it is a transport error.)
    let before = server.requests.count
    server.set(.redirect(URL(string: "http://\(server.host)/sudamp/feed.json")!))
    await #expect(throws: RemoteFeedError.self) { try await client.fetch(ifNoneMatch: nil) }
    #expect(server.requests.count == before + 1, "only the HTTPS request was made")
    // A host that never answers ends at the client's timeout.
    server.set(.hang)
    let started = ContinuousClock.now
    await #expect(throws: RemoteFeedError.self) { try await client.fetch(ifNoneMatch: nil) }
    #expect(ContinuousClock.now - started < .seconds(4))
    // A 304 to an unconditional request is an error, not "unchanged".
    server.set(.normal)
    let unconditional = try await client.fetch(ifNoneMatch: nil)
    #expect(unconditional != .notModified)
}

@Test func redirectToHTTPSIsFollowed() async throws {
    let target = StubFeedServer()
    let (body, sig) = try signed(doc(revision: 4))
    target.publish(body, signature: sig, etag: "\"r4\"")
    let origin = StubFeedServer()
    origin.publish(body, signature: sig)
    origin.set(.redirect(target.feedURL))
    let result = try await origin.client().fetch(ifNoneMatch: nil)
    #expect(result == .fetched(RemoteFeedResponse(body: body, signature: sig, etag: "\"r4\"")))
    #expect(target.feedRequests.count == 1)
}
