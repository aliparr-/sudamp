// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import Synchronization
import Testing
@testable import Feeds

private let future = "2027-04-22T00:00:00Z"

@Test func fetchedVerifiedAndCachedThenReadBackAtLaunch() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = StubFeedServer()
    let (body, sig) = try signed(doc(revision: 5, expires: future))
    server.publish(body, signature: sig, etag: "\"r5\"")
    let time = FakeTimeSource(launchDate)
    let metrics = MetricsLog(url: dir.appending(path: "metrics.jsonl"), time: time)
    let service = try makeService(server: server, dir: dir, bundled: try bundledFeed(), time: time, metrics: metrics)
    #expect(service.active.origin == .bundled)

    let result = await service.refresh(budget: .seconds(5))
    #expect(result.outcome == .updated(revision: 5))
    #expect(result.changed)
    #expect(result.active.origin == .fetched && result.active.document.revision == 5)
    #expect(service.active.document.revision == 5)

    let cache = try #require(service.configuration.cache)
    #expect(try Data(contentsOf: cache.feedFile) == body, "the exact fetched bytes")
    #expect(try Data(contentsOf: cache.signatureFile) == sig)
    #expect(cache.readMeta() == FeedCache.Meta(etag: "\"r5\"", fetchedAt: launchDate, revision: 5))

    let fetched = try metricEvents(metrics, "feed.fetched")
    #expect(fetched.count == 1 && fetched[0]["status"] as? Int == 200 && fetched[0]["revision"] as? Int == 5)
    #expect(fetched[0]["keyID"] as? String == testSigningKey.publicKey?.keyID)
    let status = try metricEvents(metrics, "feed.status")
    #expect(status.last?["outcome"] as? String == "updated" && status.last?["activeRevision"] as? Int == 5)

    // Next launch, host unreachable: the verified cached copy is active before any network traffic.
    server.set(.status(503))
    let relaunch = try makeService(server: server, dir: dir, bundled: try bundledFeed(), time: time)
    #expect(relaunch.active.origin == .cached && relaunch.active.document.revision == 5)
    let offline = await relaunch.refresh(budget: .seconds(5))
    #expect(offline.outcome == .failed(.httpStatus(503, url: server.feedURL.absoluteString)))
    #expect(offline.active.origin == .cached && !offline.changed)
}

@Test func notModifiedUpdatesFetchedAtOnly() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = StubFeedServer()
    let (body, sig) = try signed(doc(revision: 5, expires: future))
    server.publish(body, signature: sig, etag: "\"r5\"")
    let time = FakeTimeSource(launchDate)
    let metrics = MetricsLog(url: dir.appending(path: "metrics.jsonl"), time: time)
    let service = try makeService(server: server, dir: dir, bundled: try bundledFeed(), time: time, metrics: metrics)
    _ = await service.refresh(budget: .seconds(5))
    let cache = try #require(service.configuration.cache)
    let feedModified = try FileManager.default.attributesOfItem(atPath: cache.feedFile.path)[.modificationDate] as? Date

    time.advance(by: 13 * 3600)
    let second = await service.refresh(budget: .seconds(5))
    #expect(second.outcome == .notModified)
    #expect(!second.changed)
    #expect(server.feedRequests.last?.headers["If-None-Match"] == "\"r5\"")
    #expect(cache.readMeta() == FeedCache.Meta(etag: "\"r5\"", fetchedAt: launchDate.addingTimeInterval(13 * 3600), revision: 5))
    #expect(try Data(contentsOf: cache.feedFile) == body)
    #expect(try FileManager.default.attributesOfItem(atPath: cache.feedFile.path)[.modificationDate] as? Date == feedModified)
    let statuses = try metricEvents(metrics, "feed.status").compactMap { $0["status"] as? Int }
    #expect(statuses == [200, 304], "jq: select(.event == \"feed.status\") | .status")
    #expect(try metricEvents(metrics, "feed.fetched").last?["status"] as? Int == 304)
}

@Test func rejectedDocumentsKeepThePreviousActiveDocument() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = StubFeedServer()
    let time = FakeTimeSource(launchDate)
    let metrics = MetricsLog(url: dir.appending(path: "metrics.jsonl"), time: time)
    let service = try makeService(server: server, dir: dir, bundled: try bundledFeed(revision: 2), time: time,
                                  appVersion: "0.1.0-dev", metrics: metrics)
    // A good r6 first, so "previous" is a cached copy.
    let good = try signed(doc(revision: 6, expires: future))
    server.publish(good.body, signature: good.signature, etag: "\"r6\"")
    #expect(await service.refresh(budget: .seconds(5)).outcome == .updated(revision: 6))

    func attempt(_ body: Data, _ sig: Data) async -> FeedRefreshOutcome {
        server.publish(body, signature: sig)
        return await service.refresh(budget: .seconds(5)).outcome
    }
    // One tampered byte (the signature is over the original bytes).
    var tampered = try signed(doc(revision: 7, expires: future))
    tampered.body = Data(String(decoding: tampered.body, as: UTF8.self)
        .replacingOccurrences(of: #""title":"T""#, with: #""title":"U""#).utf8)
    #expect(await attempt(tampered.body, tampered.signature) == .rejected(.signature))
    // The wrong key.
    let wrong = try signed(doc(revision: 7, expires: future), with: FeedSigningKey())
    #expect(await attempt(wrong.body, wrong.signature) == .rejected(.signature))
    // A lower revision than the cached one (anti-rollback), even though it beats the bundled r2.
    let lower = try signed(doc(revision: 4, expires: future))
    #expect(await attempt(lower.body, lower.signature) == .rejected(.rollback(revision: 4, minimum: 6)))
    // Expired.
    let expired = try signed(doc(revision: 8, expires: "2026-10-01T00:00:00Z"))
    if case .rejected(.expired) = await attempt(expired.body, expired.signature) {} else { Issue.record("expired doc accepted") }
    // minAppVersion above this app's.
    let tooNew = try signed(doc(revision: 9, expires: future, minApp: "0.2.0"))
    #expect(await attempt(tooNew.body, tooNew.signature) == .rejected(.minAppVersion("0.2.0")))
    // Signed but not a feed (bad JSON, unknown major schema).
    let junk = try signed("{\"schema\":1,")
    if case .rejected(.invalid) = await attempt(junk.body, junk.signature) {} else { Issue.record("bad JSON accepted") }
    let schema2 = try signed(doc(revision: 10).replacingOccurrences(of: #""schema":1"#, with: #""schema":2"#))
    if case .rejected(.invalid) = await attempt(schema2.body, schema2.signature) {} else { Issue.record("schema 2 accepted") }

    #expect(service.active.document.revision == 6, "nothing replaced the verified r6")
    let cache = try #require(service.configuration.cache)
    #expect(try Data(contentsOf: cache.feedFile) == good.body)
    #expect(cache.readMeta()?.revision == 6)
    let reasons = try metricEvents(metrics, "feed.rejected").compactMap { $0["reason"] as? String }
    #expect(reasons == ["signature", "signature", "rollback", "expired", "minAppVersion", "invalid", "invalid"])
    #expect(try metricEvents(metrics, "feed.rejected").first?["revision"] as? Int == 7)
}

@Test func expiredFetchedFallsBackToCachedThenBundled() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = StubFeedServer()
    let time = FakeTimeSource(launchDate)
    let bundled = try bundledFeed(revision: 2)
    let service = try makeService(server: server, dir: dir, bundled: bundled, time: time)
    // Cached r5 expires 2026-11-01; a fetched r6 that is already expired is refused, so r5 (cached) stays.
    let r5 = try signed(doc(revision: 5, expires: "2026-11-01T00:00:00Z"))
    server.publish(r5.body, signature: r5.signature)
    #expect(await service.refresh(budget: .seconds(5)).outcome == .updated(revision: 5))
    let r6 = try signed(doc(revision: 6, expires: "2026-10-20T00:00:00Z"))
    server.publish(r6.body, signature: r6.signature)
    let refused = await service.refresh(budget: .seconds(5))
    #expect(refused.active.document.revision == 5, "expired fetched → cached")

    // Weeks later the cached copy has expired too: the next launch plays the bundled snapshot.
    time.set(Date(timeIntervalSince1970: 1_794_000_000))   // 2026-11-06
    server.set(.status(503))
    let relaunch = try makeService(server: server, dir: dir, bundled: bundled, time: time)
    #expect(relaunch.cached?.document.revision == 5)
    #expect(relaunch.active.origin == .bundled, "expired cached → bundled")
    let r = await relaunch.refresh(budget: .seconds(5))
    #expect(r.active.origin == .bundled && r.active.document.revision == 2)
}

@Test func cachedCopyExpiringWhileOfflineFallsBackToBundled() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = StubFeedServer()
    let time = FakeTimeSource(launchDate)
    let r5 = try signed(doc(revision: 5, expires: "2026-10-23T00:00:00Z"))
    server.publish(r5.body, signature: r5.signature)
    let service = try makeService(server: server, dir: dir, bundled: try bundledFeed(revision: 2), time: time)
    let changes = Mutex<[Int]>([])
    service.setOnChange { feed in changes.withLock { $0.append(feed.document.revision) } }
    #expect(await service.refresh(budget: .seconds(5)).active.document.revision == 5)
    // The host goes away; a day later the periodic refresh fails, and the expired r5 must not stay active.
    server.set(.status(503))
    time.advance(by: 86_400)
    let r = await service.refresh(budget: .seconds(5))
    if case .failed = r.outcome {} else { Issue.record("expected a failure, got \(r.outcome)") }
    #expect(r.active.origin == .bundled && r.changed)
    #expect(changes.withLock { $0 } == [5, 2])
}

@Test func bundledFeedPastExpiresAtStillPlays() async throws {
    let expiredBundle = try bundledFeed(revision: 2, expires: "2020-01-01T00:00:00Z")
    let time = FakeTimeSource(launchDate)
    #expect(ActiveFeedSelector.select(bundled: expiredBundle, candidates: [], appVersion: "0.1.0", now: launchDate)
        .document.revision == 2)
    let offline = FeedService(bundled: expiredBundle, configuration: FeedServiceConfiguration(trust: testTrust), time: time)
    #expect(offline.active.origin == .bundled)
    let r = await offline.refresh(budget: .seconds(1))
    #expect(r.outcome == .disabled("no feed URL"))
    #expect(r.active.document.revision == 2 && r.active.document.expiresAt! < launchDate)
}

@Test func highestValidRevisionWinsAndBundledWinsTies() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = StubFeedServer()
    let time = FakeTimeSource(launchDate)
    // A fresh app release bundles r8; the host still serves r7: valid and cached, but the bundled r8 stays active.
    let service = try makeService(server: server, dir: dir, bundled: try bundledFeed(revision: 8), time: time)
    let r7 = try signed(doc(revision: 7, expires: future))
    server.publish(r7.body, signature: r7.signature)
    let r = await service.refresh(budget: .seconds(5))
    #expect(r.outcome == .updated(revision: 7))
    #expect(r.active.origin == .bundled && r.active.document.revision == 8 && !r.changed)
    // Same revision as the bundled copy: the bundled copy wins the tie.
    let r8 = try signed(doc(revision: 8, expires: future))
    server.publish(r8.body, signature: r8.signature)
    #expect(await service.refresh(budget: .seconds(5)).active.origin == .bundled)
    // A newer one wins.
    let r9 = try signed(doc(revision: 9, expires: future))
    server.publish(r9.body, signature: r9.signature)
    #expect(await service.refresh(budget: .seconds(5)).active.document.revision == 9)
}

@Test func engineStringsFailingValidationKeepTheirPreviousValues() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = StubFeedServer()
    let time = FakeTimeSource(launchDate)
    let bundledEngine = #"{"clients":["visionos","tv_simply"],"formats":{"youtube":"ba/b"},"mediaHosts":["googlevideo.com"]}"#
    let service = try makeService(server: server, dir: dir, bundled: try bundledFeed(revision: 2, engine: bundledEngine),
                                  time: time)
    let hostile = #"{"clients":["visionos;rm -rf ~"],"formats":{"youtube":"-o/tmp/x","soundcloud":"hls_aac_160k"},"#
        + #""extractorArgs":{"youtube":["youtube:player_skip=webpage --exec x"]},"mediaHosts":["evil.example.com/x"],"#
        + #""pin":{"version":"latest","sha256":"zz"},"block":["2026.10.21; rm"]}"#
    let doc3 = try signed(doc(revision: 3, expires: future, engine: hostile))
    server.publish(doc3.body, signature: doc3.signature)
    let r = await service.refresh(budget: .seconds(5))
    #expect(r.outcome == .updated(revision: 3))
    let engine = r.active.document.engine
    #expect(engine.clients == ["visionos", "tv_simply"], "a client list with ';' keeps the previous list")
    #expect(engine.formats[.youtube] == "ba/b", "a format starting with '-' keeps the previous selector")
    #expect(engine.formats[.soundcloud] == "hls_aac_160k", "valid values in the same document still apply")
    #expect(engine.extractorArgs[.youtube] == EngineConfig.defaults.extractorArgs[.youtube])
    #expect(engine.mediaHosts == ["googlevideo.com"])
    #expect(engine.pin == nil && engine.block.isEmpty)
    #expect(Set(r.active.engineIssues.map(\.field)) == ["clients", "formats.youtube", "extractorArgs.youtube", "mediaHosts", "pin", "block"])
}

@Test func launchBudgetFallsBackAndALateFetchStillLands() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = StubFeedServer()
    let time = FakeTimeSource(launchDate)
    let metrics = MetricsLog(url: dir.appending(path: "metrics.jsonl"), time: time)
    let r5 = try signed(doc(revision: 5, expires: future))
    server.publish(r5.body, signature: r5.signature)
    server.set(.delay(0.8))
    let service = try makeService(server: server, dir: dir, bundled: try bundledFeed(), time: time, metrics: metrics)
    let changes = Mutex<[Int]>([])
    service.setOnChange { feed in changes.withLock { $0.append(feed.document.revision) } }

    let started = ContinuousClock.now
    let r = await service.refresh(budget: .milliseconds(200))
    #expect(ContinuousClock.now - started < .milliseconds(700), "the budget bounds the wait")
    #expect(r.outcome == .timedOut)
    #expect(r.active.origin == .bundled)
    // The fetch carried on: a second caller joins it (single flight) and sees it land.
    let joined = await service.refresh(budget: .seconds(5))
    #expect(joined.outcome == .updated(revision: 5))
    #expect(server.feedRequests.count == 1)
    #expect(changes.withLock { $0 } == [5])
    let outcomes = try metricEvents(metrics, "feed.status").compactMap { $0["outcome"] as? String }
    #expect(outcomes == ["timedOut", "updated"])
}

@Test func launchRefreshRunsOnceAndItsBudgetCountsFromTheFirstCaller() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = StubFeedServer()
    let r5 = try signed(doc(revision: 5, expires: future))
    server.publish(r5.body, signature: r5.signature)
    server.set(.delay(0.8))
    let metrics = MetricsLog(url: dir.appending(path: "metrics.jsonl"))
    let service = try makeService(server: server, dir: dir, bundled: try bundledFeed(), time: FakeTimeSource(launchDate),
                                  metrics: metrics)
    // The app's launch task.
    let first = await service.launchRefresh(budget: .milliseconds(300))
    #expect(first.outcome == .timedOut)
    // The engine gate asks later with the same budget: it is already spent, so it returns at once.
    let started = ContinuousClock.now
    let gate = await service.launchRefresh(budget: .milliseconds(300))
    #expect(gate.outcome == .timedOut && ContinuousClock.now - started < .milliseconds(100))
    // Once the fetch lands, every later caller gets its result without another request.
    try await Task.sleep(for: .milliseconds(700))
    let late = await service.launchRefresh(budget: .seconds(5))
    #expect(late.outcome == .updated(revision: 5))
    #expect(service.active.document.revision == 5)
    #expect(server.feedRequests.count == 1)
    let outcomes = try metricEvents(metrics, "feed.status").compactMap { $0["outcome"] as? String }
    #expect(outcomes == ["timedOut", "updated"], "one timedOut line for the launch, however many callers waited")
    // A plain refresh afterwards is a new conditional request.
    server.set(.normal)
    #expect(await service.refresh(budget: .seconds(5)).outcome == .notModified)
    #expect(server.feedRequests.count == 2)
}

@Test func hostThatNeverAnswersFallsBackWithinTheBudget() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = StubFeedServer()
    server.set(.hang)
    let time = FakeTimeSource(launchDate)
    let service = try makeService(server: server, dir: dir, bundled: try bundledFeed(), time: time, timeout: 1.5)
    let started = ContinuousClock.now
    let r = await service.refresh(budget: .milliseconds(500))
    #expect(ContinuousClock.now - started < .milliseconds(1000))
    #expect(r.outcome == .timedOut && r.active.origin == .bundled)
    // The background attempt ends at the client's timeout and schedules a retry in 1 h.
    let late = await service.refresh(budget: .seconds(5))
    if case .failed = late.outcome {} else { Issue.record("expected the hung fetch to fail, got \(late.outcome)") }
    #expect(service.nextRefresh() == launchDate.addingTimeInterval(3600))
}

@Test func concurrentRefreshesShareOneFetch() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = StubFeedServer()
    let r5 = try signed(doc(revision: 5, expires: future))
    server.publish(r5.body, signature: r5.signature)
    server.set(.delay(0.3))
    let service = try makeService(server: server, dir: dir, bundled: try bundledFeed(), time: FakeTimeSource(launchDate))
    async let a = service.refresh(budget: .seconds(5))
    async let b = service.refresh(budget: .seconds(5))
    let (x, y) = await (a, b)
    #expect(x.outcome == .updated(revision: 5) && y.outcome == .updated(revision: 5))
    #expect(server.feedRequests.count == 1)
}

@Test func disabledWithoutURLOrTrustedKeys() async throws {
    let server = StubFeedServer()
    let r5 = try signed(doc(revision: 5, expires: future))
    server.publish(r5.body, signature: r5.signature)
    // A release build has no production key yet: it never fetches, even with a URL.
    let release = FeedService(bundled: try bundledFeed(), configuration: FeedServiceConfiguration(trust: .production),
                              client: try server.client())
    #expect(FeedTrust.production.isEmpty)
    #expect(!release.isFetching)
    #expect(await release.refresh(budget: .seconds(1)).outcome == .disabled("no trusted feed key in this build"))
    #expect(server.requests.isEmpty)
    let noURL = FeedService(bundled: try bundledFeed(), configuration: FeedServiceConfiguration(trust: testTrust))
    #expect(await noURL.refresh(budget: .seconds(1)).outcome == .disabled("no feed URL"))
}

@Test func unverifiableCacheIsIgnoredAndItsETagNotSent() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = StubFeedServer()
    let r5 = try signed(doc(revision: 5, expires: future))
    server.publish(r5.body, signature: r5.signature, etag: "\"r5\"")
    let time = FakeTimeSource(launchDate)
    _ = await (try makeService(server: server, dir: dir, bundled: try bundledFeed(), time: time)).refresh(budget: .seconds(5))
    // Someone edits the cached copy.
    let cache = FeedCache(directory: dir.appending(path: "feed", directoryHint: .isDirectory))
    var edited = try Data(contentsOf: cache.feedFile)
    edited[edited.count - 2] ^= 0x01
    try edited.write(to: cache.feedFile)

    let relaunch = try makeService(server: server, dir: dir, bundled: try bundledFeed(), time: time)
    #expect(relaunch.cached == nil && relaunch.active.origin == .bundled)
    let r = await relaunch.refresh(budget: .seconds(5))
    #expect(server.feedRequests.last?.headers["If-None-Match"] == nil, "a 304 would keep the broken copy")
    #expect(r.outcome == .updated(revision: 5) && r.active.document.revision == 5)
    #expect(try Data(contentsOf: cache.feedFile) == r5.body)
}

@Test func feedScheduleRule() {
    let s = FeedSchedule()
    let t = launchDate
    #expect(s.next(lastSuccess: nil, lastFailure: nil, now: t) == t, "never fetched: due now")
    #expect(s.next(lastSuccess: t, lastFailure: nil, now: t) == t.addingTimeInterval(12 * 3600))
    #expect(s.next(lastSuccess: t, lastFailure: t.addingTimeInterval(60), now: t) == t.addingTimeInterval(3660),
            "a failure after the last success retries in 1 h")
    #expect(s.next(lastSuccess: t.addingTimeInterval(120), lastFailure: t, now: t) == t.addingTimeInterval(120 + 12 * 3600))
}

@Test func periodicRefreshRunsEveryTwelveHours() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = StubFeedServer()
    let r5 = try signed(doc(revision: 5, expires: "2099-01-01T00:00:00Z"))
    server.publish(r5.body, signature: r5.signature, etag: "\"r5\"")
    let time = FakeTimeSource(launchDate)
    let slept = Mutex<[TimeInterval]>([])
    let service = try makeService(server: server, dir: dir, bundled: try bundledFeed(), time: time) { seconds in
        slept.withLock { $0.append(seconds) }
        time.advance(by: seconds)
        await Task.yield()
    }
    // Launch refresh, then the loop: 12 h steps of at most 15 min sleeps.
    #expect(await service.refresh(budget: .seconds(5)).outcome == .updated(revision: 5))
    let loop = Task { await service.runPeriodicRefresh(budget: .seconds(5)) }
    var waited = 0
    while server.feedRequests.count < 3, waited < 2000 {
        try await Task.sleep(for: .milliseconds(5))
        waited += 1
    }
    loop.cancel()
    _ = await loop.value
    #expect(server.feedRequests.count >= 3)
    let total = slept.withLock { $0 }
    #expect(total.allSatisfy { $0 <= 900 })
    // Two periodic refreshes took 2 × 12 h of (fake) sleep.
    let twoCycles: TimeInterval = total.prefix(96).reduce(0, +)
    #expect(twoCycles == 86_400)
    #expect(server.feedRequests.dropFirst().allSatisfy { $0.headers["If-None-Match"] == "\"r5\"" })
}
