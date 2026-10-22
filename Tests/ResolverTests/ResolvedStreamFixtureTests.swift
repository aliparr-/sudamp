// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation
import Testing
@testable import Resolver

/// Parses real (trimmed, scrubbed) yt-dlp 2026.10.21 `-J` output captured in R1, one per source.
@Suite struct ResolvedStreamFixtureTests {
    let now = Date(timeIntervalSince1970: 1_792_671_650)

    private func parse(_ name: String, _ source: SourceKind) throws -> ResolvedStream {
        try ResolvedStream.parse(json: Fixture.data("json/\(name).json"), source: source, tier: 1, now: now)
    }

    private func allowed(_ s: ResolvedStream) -> Bool {
        ResolvedStream.isAllowedMediaHost(s.url, suffixes: ResolverSettings.defaultMediaHosts[s.source] ?? [])
    }

    @Test func youtubeVOD() throws {
        let s = try parse("youtube", .youtube)
        #expect(s.formatID == "251")
        #expect(s.protocol == "https")
        #expect(s.ext == "webm")
        #expect(s.acodec == "opus")
        #expect(s.abr == 106.853)
        #expect(s.httpChunkSize == 10_485_760)
        #expect(s.availableAt == 1_792_671_644)
        #expect(s.wait(now: now) == 0)
        #expect(s.expiresAt == 1_792_693_244)
        #expect(s.duration == 7231)
        #expect(s.liveStatus == "not_live")
        #expect(!s.isLive && !s.isHLS)
        #expect(s.title == "Solomun | Boiler Room: Tulum")
        #expect(s.uploader == "Boiler Room")
        #expect(s.webpageURL?.absoluteString == "https://www.youtube.com/watch?v=bk6Xst6euQk")
        #expect(s.userAgent?.hasPrefix("Mozilla/5.0") == true)
        #expect(s.httpHeaders["User-Agent"] == s.userAgent)
        #expect(allowed(s))
    }

    @Test func youtubeLive() throws {
        let s = try parse("youtube-live", .youtubeLive)
        #expect(s.formatID == "234")
        #expect(s.protocol == "m3u8_native")
        #expect(s.isLive && s.isHLS)
        #expect(s.url.host == "manifest.googlevideo.com")
        #expect(s.expiresAt == 1_792_693_250, "from the /expire/<t>/ path segment")
        #expect(s.availableAt == nil, "live HLS formats carry no available_at")
        #expect(s.duration == nil)
        #expect(s.uploader == "Lofi Girl")
        #expect(s.webpageURL?.absoluteString.hasPrefix("https://www.youtube.com/watch?v=") == true)
        #expect(allowed(s))
    }

    @Test func soundcloud() throws {
        let s = try parse("soundcloud", .soundcloud)
        #expect(s.formatID == "hls_aac_160k")
        #expect(s.acodec == "mp4a.40.2")
        #expect(s.abr == 160)
        #expect(s.isHLS)
        #expect(s.expiresAt == 1_792_681_791)
        #expect(s.duration == 2940.862)
        #expect(s.uploader == "Boiler Room")
        #expect(allowed(s))
    }

    @Test func mixcloudProgressive() throws {
        let s = try parse("mixcloud", .mixcloud)
        #expect(s.formatID == "http")
        #expect(s.protocol == "https")
        #expect(s.httpChunkSize == 5_242_880)
        #expect(s.expiresAt == nil)
        #expect(s.url.host == "dl.mixcloud.stream")
        #expect(allowed(s))
    }

    @Test func mixcloudHLS() throws {
        let s = try parse("mixcloud-hls", .mixcloud)
        #expect(s.formatID == "hls-192")
        #expect(s.abr == 192.002)
        #expect(s.isHLS)
        #expect(s.url.host == "aod.mixcloud.stream")
        #expect(allowed(s))
    }

    @Test func crossSourceHostsAreRejected() throws {
        // A YouTube URL is not an allowed SoundCloud media host and vice versa.
        let yt = try parse("youtube", .youtube)
        #expect(!ResolvedStream.isAllowedMediaHost(yt.url, suffixes: ResolverSettings.defaultMediaHosts[.soundcloud]!))
        let sc = try parse("soundcloud", .soundcloud)
        #expect(!ResolvedStream.isAllowedMediaHost(sc.url, suffixes: ResolverSettings.defaultMediaHosts[.mixcloud]!))
    }
}
