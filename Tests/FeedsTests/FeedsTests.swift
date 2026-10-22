// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation
import Testing
@testable import Feeds

@Test func loadsTheRepositoryFeedCleanly() throws {
    let feed = try BundledFeed.load(from: repoFeed)
    #expect(feed.origin == .bundled)
    #expect(feed.warnings.isEmpty, "\(feed.warnings)")
    #expect(feed.document.catalog.genres.count == 6)
    #expect(feed.document.engine.pin?.version == "2026.10.21")
    #expect(FeedService(bundled: feed).active.document == feed.document)
    #expect(!FeedService(bundled: feed).isFetching, "no client: bundled only")
}

@Test func candidateOrderAndDevCheckoutDiscovery() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let feedURL = root.appending(path: "repo/catalog/feed.json")
    try write(doc(revision: 1), to: feedURL)
    let deep = root.appending(path: "repo/.build/arm64-apple-macosx/debug", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    let override = root.appending(path: "x.json"), resources = root.appending(path: "App.app/Contents/Resources")
    let c = BundledFeed.candidates(override: override, resourceURL: resources, executableURL: deep.appending(path: "sudamp-dev"),
                                   currentDirectory: root.appending(path: "elsewhere"))
    #expect(c[0] == override)
    #expect(c[1] == resources.appending(path: "feed.json"))
    // Walking up from the executable finds the checkout's catalog/feed.json.
    let found = c.first { FileManager.default.fileExists(atPath: $0.path) }
    #expect(found?.standardizedFileURL.path == feedURL.standardizedFileURL.path)
    #expect(Set(c.map(\.path)).count == c.count, "no duplicates")
}

@Test func envelopeErrorsThrowAndItemErrorsDoNot() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let bad = root.appending(path: "bad.json")
    try write(doc(revision: 1).replacingOccurrences(of: #""schema":1"#, with: #""schema":2"#), to: bad)
    #expect(throws: FeedLoadError.invalid(bad.path, .unsupportedSchema(2))) { try BundledFeed.load(from: bad) }
    #expect(throws: FeedLoadError.unreadable(root.appending(path: "missing.json").path)) {
        try BundledFeed.load(from: root.appending(path: "missing.json"))
    }
    // One genre with one stream: loads, with coverage reported rather than fatal.
    let thin = root.appending(path: "thin.json")
    try write(doc(revision: 1), to: thin)
    let feed = try BundledFeed.load(from: thin)
    #expect(feed.document.catalog.streams.count == 1)
    #expect(!feed.coverage.isEmpty && feed.warnings.count == feed.coverage.count)
}

@Test func activeFeedSelectionSeam() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    func loaded(_ json: String, _ origin: FeedOrigin, _ name: String) throws -> LoadedFeed {
        let u = root.appending(path: name)
        try write(json, to: u)
        return try BundledFeed.load(from: u, origin: origin)
    }
    let now = Date(timeIntervalSince1970: 1_792_663_200)
    let bundled = try loaded(doc(revision: 2), .bundled, "b.json")
    let newer = try loaded(doc(revision: 5), .fetched, "f.json")
    let newest = try loaded(doc(revision: 7), .cached, "c.json")
    let older = try loaded(doc(revision: 1), .fetched, "o.json")
    let expired = try loaded(doc(revision: 9, expires: "2026-01-01T00:00:00Z"), .fetched, "e.json")
    let tooNew = try loaded(doc(revision: 9, minApp: "9.0.0"), .fetched, "m.json")
    func pick(_ c: [FeedCandidate]) -> Int {
        ActiveFeedSelector.select(bundled: bundled, candidates: c, appVersion: "0.1.0-dev", now: now).document.revision
    }
    #expect(pick([]) == 2)
    #expect(pick([FeedCandidate(feed: newer, signatureVerified: true)]) == 5)
    #expect(pick([FeedCandidate(feed: newer, signatureVerified: false)]) == 2, "unverified documents are never used")
    #expect(pick([FeedCandidate(feed: older, signatureVerified: true)]) == 2, "anti-rollback")
    #expect(pick([FeedCandidate(feed: expired, signatureVerified: true)]) == 2, "expired fetched documents fall back")
    #expect(pick([FeedCandidate(feed: tooNew, signatureVerified: true)]) == 2, "minAppVersion above the app")
    #expect(pick([FeedCandidate(feed: newer, signatureVerified: true), FeedCandidate(feed: newest, signatureVerified: true)]) == 7)
    #expect(pick([FeedCandidate(feed: newest, signatureVerified: true), FeedCandidate(feed: newer, signatureVerified: true)]) == 7)
}

@Test func appVersionComparison() {
    #expect(AppVersion.compare("0.1.0-dev", "0.1.0") == .orderedSame)
    #expect(AppVersion.compare("0.1.0", "0.2.0") == .orderedAscending)
    #expect(AppVersion.compare("1.10.0", "1.9.9") == .orderedDescending)
    #expect(AppVersion.compare("1.0", "1.0.0") == .orderedSame)
}
