// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation
import Testing
@testable import Resolver

let cacheT0: Double = 1_800_000_000

/// A resolved stream for tests (only the fields the cache and availability rules read are interesting).
func resolvedStream(_ source: SourceKind, resolvedAt: Double = cacheT0, expires: Double? = nil, availableAt: Double? = nil,
                    hls: Bool = false, url: String? = nil, tier: Int = 1) -> ResolvedStream {
    let host: String = switch source {
    case .youtube, .youtubeLive: "rr1---sn-abc.googlevideo.com"
    case .soundcloud: "playback.media-streaming.soundcloud.cloud"
    case .mixcloud: "aod.mixcloud.stream"
    case .radio: "radio.example.com"
    }
    return ResolvedStream(source: source, tier: tier, url: URL(string: url ?? "https://\(host)/media\(hls ? ".m3u8" : "")")!,
                          httpHeaders: ["User-Agent": "UA"], userAgent: "UA", protocol: hls ? "m3u8_native" : "https",
                          httpChunkSize: hls ? nil : 10_485_760, availableAt: availableAt, expiresAt: expires,
                          resolvedAt: resolvedAt, title: "T", uploader: "U")
}

func sid(_ raw: String) -> StreamID { StreamID(rawValue: raw)! }

@Suite struct ResolutionCacheTests {
    let now = Date(timeIntervalSince1970: cacheT0)

    @Test func validUntilExpiryMinusFifteenMinutes() {
        let yt = resolvedStream(.youtube, expires: cacheT0 + 6 * 3600)
        #expect(ResolutionCache.validUntil(yt) == Date(timeIntervalSince1970: cacheT0 + 6 * 3600 - 900))
        let sc = resolvedStream(.soundcloud, expires: cacheT0 + 10_080)
        #expect(ResolutionCache.validUntil(sc) == Date(timeIntervalSince1970: cacheT0 + 10_080 - 900))
        let mc = resolvedStream(.mixcloud, resolvedAt: cacheT0 - 60)
        #expect(ResolutionCache.validUntil(mc) == Date(timeIntervalSince1970: cacheT0 - 60 + 3600), "no expiry: 1 h")
    }

    @Test func lookupHonoursValidity() {
        var c = ResolutionCache()
        let id = sid("yt:AAAAAAAAAAA")
        do { let v = c.insert(resolvedStream(.youtube, expires: cacheT0 + 3600), for: id, now: now); #expect(v) }
        #expect(c.lookup(id, now: now) != nil)
        #expect(c.lookup(id, now: now.addingTimeInterval(2699)) != nil)
        #expect(c.lookup(id, now: now.addingTimeInterval(2700)) == nil, "within 15 min of expiry")
        c.prune(now: now.addingTimeInterval(2700))
        #expect(c.count == 0)
    }

    @Test func nearlyExpiredAndRadioAreNotCached() {
        var c = ResolutionCache()
        do { let v = c.insert(resolvedStream(.soundcloud, expires: cacheT0 + 600), for: sid("sc:a/b"), now: now); #expect(!v) }
        do { let v = c.insert(resolvedStream(.radio), for: sid("radio:x"), now: now); #expect(!v) }
        #expect(c.count == 0)
    }

    @Test func mixcloudLivesOneHour() {
        var c = ResolutionCache()
        let id = sid("mc:User/mix")
        c.insert(resolvedStream(.mixcloud), for: id, now: now)
        #expect(c.lookup(id, now: now.addingTimeInterval(3599)) != nil)
        #expect(c.lookup(id, now: now.addingTimeInterval(3600)) == nil)
    }

    @Test func networkChangeDropsOnlyYouTube() {
        var c = ResolutionCache()
        let ids = [sid("yt:AAAAAAAAAAA"), sid("ytl:@somelive"), sid("sc:a/b"), sid("mc:User/mix")]
        c.insert(resolvedStream(.youtube, expires: cacheT0 + 6 * 3600), for: ids[0], now: now)
        c.insert(resolvedStream(.youtubeLive, expires: cacheT0 + 6 * 3600, hls: true), for: ids[1], now: now)
        c.insert(resolvedStream(.soundcloud, expires: cacheT0 + 10_000, hls: true), for: ids[2], now: now)
        c.insert(resolvedStream(.mixcloud), for: ids[3], now: now)
        let dropped = c.networkPathChanged()
        #expect(dropped == [ids[0], ids[1]].sorted())
        #expect(c.validIDs(now: now) == [ids[2], ids[3]])
    }

    @Test func readyExcludesFarAvailableAt() {
        var c = ResolutionCache()
        let soon = sid("yt:AAAAAAAAAAA"), far = sid("yt:BBBBBBBBBBB")
        c.insert(resolvedStream(.youtube, expires: cacheT0 + 6 * 3600, availableAt: cacheT0 + 2), for: soon, now: now)
        c.insert(resolvedStream(.youtube, expires: cacheT0 + 6 * 3600, availableAt: cacheT0 + 20), for: far, now: now)
        #expect(c.readyIDs(now: now) == [soon])
        #expect(c.validIDs(now: now) == [soon, far])
        #expect(c.readyIDs(now: now.addingTimeInterval(17)) == [soon, far])
    }

    @Test func availability() {
        #expect(Availability.of(resolvedStream(.youtube), now: now) == .now, "absent available_at means no wait")
        #expect(Availability.of(resolvedStream(.youtube, availableAt: cacheT0 - 5), now: now) == .now)
        #expect(Availability.of(resolvedStream(.youtube, availableAt: cacheT0 + 2.5), now: now) == .wait(2.5))
        #expect(Availability.of(resolvedStream(.youtube, availableAt: cacheT0 + 3), now: now) == .wait(3))
        #expect(Availability.of(resolvedStream(.youtube, availableAt: cacheT0 + 20), now: now) == .deferred(20))
        #expect(Availability.deferred(20).seconds == 20 && Availability.now.seconds == 0)
    }
}

@Suite struct TierAdaptationTests {
    let t0 = Date(timeIntervalSince1970: cacheT0)

    @Test func twoRescuedFailuresPreferTier2For24Hours() {
        var a = TierAdaptation()
        #expect(a.startTier(now: t0) == .jsless)
        do { let ok = a.recordStepUp(tier2Succeeded: true, now: t0); #expect(!ok) }
        #expect(a.startTier(now: t0) == .jsless)
        do { let ok = a.recordStepUp(tier2Succeeded: true, now: t0.addingTimeInterval(60)); #expect(ok) }
        let start = t0.addingTimeInterval(60)
        #expect(a.startTier(now: start) == .quickjs)
        #expect(a.startTier(now: start.addingTimeInterval(24 * 3600 - 1)) == .quickjs)
        #expect(a.startTier(now: start.addingTimeInterval(24 * 3600)) == .jsless)
        a.expire(now: start.addingTimeInterval(24 * 3600))
        #expect(a.preferTier2Until == nil && a.rescuedFailures == 0)
    }

    @Test func tier1SuccessResetsTheCountAndFailedStepUpsDontCount() {
        var a = TierAdaptation()
        a.recordStepUp(tier2Succeeded: true, now: t0)
        a.recordTier1Success()
        do { let ok = a.recordStepUp(tier2Succeeded: true, now: t0); #expect(!ok) }
        do { let ok = a.recordStepUp(tier2Succeeded: false, now: t0); #expect(!ok, "tier 2 not working: no preference") }
        #expect(a.rescuedFailures == 1 && a.startTier(now: t0) == .jsless)
    }

    @Test func roundTripsThroughJSON() throws {
        var a = TierAdaptation()
        a.recordStepUp(tier2Succeeded: true, now: t0)
        a.recordStepUp(tier2Succeeded: true, now: t0)
        let back = try JSONDecoder().decode(TierAdaptation.self, from: JSONEncoder().encode(a))
        #expect(back == a)
    }
}

@Suite struct FeedSettingsTests {
    @Test func settingsFollowTheFeedsEngineSection() {
        var engine = EngineConfig.defaults
        engine.clients = ["visionos", "visionos,tv_samsung"]
        engine.formats[.mixcloud] = "hls-192/bestaudio[protocol^=m3u8]/http/bestaudio"
        engine.extractorArgs[.soundcloud] = []
        let s = ResolverSettings(engine: engine)
        #expect(s.clientList(for: .jsless) == "visionos" && s.clientList(for: .quickjs) == "visionos,tv_samsung")
        #expect(s.formats[.mixcloud] == "hls-192/bestaudio[protocol^=m3u8]/http/bestaudio")
        #expect(s.formats[.youtubeLive] == ResolverSettings.defaultFormats[.youtubeLive])
        #expect(s.extractorArgs[.soundcloud] == [])
        #expect(s.validated().rejected.isEmpty)
        #expect(ResolverSettings(engine: .defaults).mediaHosts == ResolverSettings.defaultMediaHosts)
    }

    @Test func mediaHostsApplyPerSourceAndNewSuffixesEverywhere() {
        let r1 = ResolverSettings.mediaHosts(fromFeed: ["googlevideo.com", "media-streaming.soundcloud.cloud", "mixcloud.stream"])
        #expect(r1[.youtube] == ["googlevideo.com"] && r1[.youtubeLive] == ["googlevideo.com"])
        #expect(r1[.soundcloud] == ["media-streaming.soundcloud.cloud"] && r1[.mixcloud] == ["mixcloud.stream"])
        let moved = ResolverSettings.mediaHosts(fromFeed: ["googlevideo.com", "cdn.example.net"])
        #expect(moved[.youtube] == ["googlevideo.com", "cdn.example.net"])
        #expect(moved[.soundcloud] == ["media-streaming.soundcloud.cloud", "cdn.example.net"], "an unlisted R1 suffix stays")
        #expect(moved[.mixcloud] == ["mixcloud.stream", "cdn.example.net"])
    }

    @Test func theBundledFeedListsTheR1Suffixes() throws {
        // catalog/feed.json engine.mediaHosts (DESIGN §6.3, R1).
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "catalog/feed.json")
        let feed = try FeedDecoder.decode(Data(contentsOf: url))
        #expect(Set(feed.document.engine.mediaHosts) == ["googlevideo.com", "media-streaming.soundcloud.cloud", "mixcloud.stream"])
        #expect(ResolverSettings(engine: feed.document.engine).mediaHosts == ResolverSettings.defaultMediaHosts)
    }
}
