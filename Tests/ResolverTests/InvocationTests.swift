// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import Testing
@testable import Resolver

/// Argv goldens per source and tier (PLAN M1), against DESIGN §6.2.
@Suite struct InvocationTests {
    let layout = EngineLayout(paths: .profile(URL(filePath: "/P", directoryHint: .isDirectory)))
    let engine = URL(filePath: "/P/engines/yt-dlp/2026.10.21/yt-dlp_macos")
    let qjs = URL(filePath: "/Applications/sudamp.app/Contents/Helpers/qjs")

    private func argv(_ source: SourceKind, _ url: String, tier: ResolveTier = .jsless, proxy: URL? = nil,
                      settings: ResolverSettings = .standard, cache: URL? = nil) throws -> [String] {
        try EngineInvocation.make(request: ResolveRequest(source: source, url: URL(string: url)!), tier: tier,
                                  settings: settings, layout: layout, engine: engine, qjs: qjs, proxy: proxy,
                                  cacheDirectory: cache).arguments
    }

    let head = ["--ignore-config", "--no-plugin-dirs", "--no-update", "--no-js-runtimes"]
    let common = ["--cache-dir", "/P/Caches/yt-dlp", "--no-playlist", "--socket-timeout", "10", "-J"]

    @Test func youtubeVODTier1() throws {
        #expect(try argv(.youtube, "https://www.youtube.com/watch?v=AAAAAAAAAAA") == head + common + [
            "--extractor-args", "youtube:player_client=visionos",
            "-f", "bestaudio[ext=webm][format_id!*=drc]/bestaudio[format_id!*=drc]/bestaudio",
            "--", "https://www.youtube.com/watch?v=AAAAAAAAAAA",
        ])
    }

    @Test func youtubeVODTier2AddsQuickJSAfterNoJSRuntimes() throws {
        #expect(try argv(.youtube, "https://www.youtube.com/watch?v=AAAAAAAAAAA", tier: .quickjs) == head + [
            "--js-runtimes", "quickjs:/Applications/sudamp.app/Contents/Helpers/qjs",
        ] + common + [
            "--extractor-args", "youtube:player_client=visionos,tv_samsung",
            "-f", "bestaudio[ext=webm][format_id!*=drc]/bestaudio[format_id!*=drc]/bestaudio",
            "--", "https://www.youtube.com/watch?v=AAAAAAAAAAA",
        ])
    }

    @Test func youtubeLive() throws {
        #expect(try argv(.youtubeLive, "https://www.youtube.com/@LofiGirl/live") == head + common + [
            "--extractor-args", "youtube:player_client=visionos",
            "-f", "bestaudio[protocol^=m3u8]/worst[protocol^=m3u8]",
            "--", "https://www.youtube.com/@LofiGirl/live",
        ])
    }

    @Test func soundcloud() throws {
        #expect(try argv(.soundcloud, "https://soundcloud.com/someone/some-mix") == head + common + [
            "--extractor-args", "soundcloud:formats=hls_aac",
            "-f", "hls_aac_160k/hls_aac_96k/bestaudio",
            "--", "https://soundcloud.com/someone/some-mix",
        ])
    }

    @Test func mixcloud() throws {
        #expect(try argv(.mixcloud, "https://www.mixcloud.com/someone/some-mix/") == head + common + [
            "-f", "hls-192/http/bestaudio",
            "--", "https://www.mixcloud.com/someone/some-mix/",
        ])
    }

    @Test func proxyAndCanaryCacheDir() throws {
        let a = try argv(.soundcloud, "https://soundcloud.com/a/b", proxy: URL(string: "http://proxy.lan:3128"),
                         cache: layout.canaryCacheDir)
        #expect(a.prefix(6) == ["--ignore-config", "--no-plugin-dirs", "--no-update", "--no-js-runtimes",
                                "--proxy", "http://proxy.lan:3128"])
        #expect(a.contains("/P/Caches/yt-dlp-canary"))
        #expect(throws: ResolverError.self) {
            try argv(.soundcloud, "https://soundcloud.com/a/b", proxy: URL(string: "socks5://proxy.lan:1080"))
        }
    }

    @Test func environmentIsScrubbedAndPrivate() throws {
        let inv = try EngineInvocation.make(request: ResolveRequest(source: .mixcloud,
                                                                    url: URL(string: "https://www.mixcloud.com/a/b/")!),
                                            tier: .jsless, settings: .standard, layout: layout, engine: engine, qjs: nil)
        #expect(inv.environment == [
            "HOME": "/P/engine-home",
            "XDG_CONFIG_HOME": "/P/engine-home/.config",
            "XDG_CACHE_HOME": "/P/Caches/xdg",
            "TMPDIR": "/P/Caches/tmp",
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "YTDLP_NO_PLUGINS": "1",
        ])
        #expect(inv.workingDirectory.path == "/P/engine-home")
        #expect(inv.timeout == .seconds(10))
        #expect(inv.executable == engine)
    }

    @Test func tier2TimeoutAndMissingQuickJS() throws {
        let r = ResolveRequest(source: .youtube, url: URL(string: "https://www.youtube.com/watch?v=AAAAAAAAAAA")!)
        let inv = try EngineInvocation.make(request: r, tier: .quickjs, settings: .standard, layout: layout,
                                            engine: engine, qjs: qjs)
        #expect(inv.timeout == .seconds(12))
        #expect(throws: ResolverError.tierUnavailable(.quickjs)) {
            try EngineInvocation.make(request: r, tier: .quickjs, settings: .standard, layout: layout, engine: engine, qjs: nil)
        }
    }

    @Test(arguments: [
        (SourceKind.radio, "https://radio.example.com/stream"),
        (.youtube, "http://www.youtube.com/watch?v=AAAAAAAAAAA"),
        (.youtube, "https://www.youtube.com.evil.example/watch?v=AAAAAAAAAAA"),
        (.youtube, "https://user@www.youtube.com/watch?v=AAAAAAAAAAA"),
        (.youtube, "https://www.youtube.com:8443/watch?v=AAAAAAAAAAA"),
        (.soundcloud, "https://www.youtube.com/watch?v=AAAAAAAAAAA"),
        (.mixcloud, "file:///etc/passwd"),
    ])
    func refusesBadRequests(_ source: SourceKind, _ url: String) {
        #expect(throws: ResolverError.self) { try argv(source, url) }
    }

    @Test func urlStartingWithDashCannotBecomeAFlag() throws {
        // `--` always precedes the URL; and the host check refuses anything that isn't the source's page host.
        let a = try argv(.soundcloud, "https://soundcloud.com/-x/--exec")
        #expect(a.suffix(2) == ["--", "https://soundcloud.com/-x/--exec"])
    }

    @Test func invalidFeedStringsFallBackToDefaults() throws {
        var s = ResolverSettings.standard
        s.clients = ["visionos;rm -rf /", "tv"]
        s.formats[.mixcloud] = "--exec=evil"
        s.extractorArgs[.soundcloud] = ["soundcloud:formats=hls_aac;x"]
        s.mediaHosts[.mixcloud] = ["Mixcloud.STREAM"]
        let (valid, rejected) = s.validated()
        #expect(valid == .standard)
        #expect(rejected.count == 4)
        let a = try argv(.mixcloud, "https://www.mixcloud.com/a/b/", settings: s)
        #expect(a.contains("hls-192/http/bestaudio"))
        #expect(!a.contains("--exec=evil"))
    }

    @Test func feedOverridesThatPassValidationAreUsed() throws {
        var s = ResolverSettings.standard
        s.clients = ["tv_simply", "tv_simply,web_embedded"]
        s.formats[.mixcloud] = "http/bestaudio[ext=m4a]"
        s.extractorArgs[.youtube] = ["youtube:skip=translated_subs"]
        let a = try argv(.youtube, "https://www.youtube.com/watch?v=AAAAAAAAAAA", tier: .quickjs, settings: s)
        #expect(a.contains("youtube:player_client=tv_simply,web_embedded"))
        #expect(a.contains("youtube:skip=translated_subs"))
        #expect(try argv(.mixcloud, "https://www.mixcloud.com/a/b/", settings: s).contains("http/bestaudio[ext=m4a]"))
    }
}

@Suite struct EngineStringsTests {
    @Test func clientLists() {
        #expect(EngineStrings.isClientList("visionos"))
        #expect(EngineStrings.isClientList("visionos,tv_samsung"))
        for bad in ["", "visionos,", ",tv", "Visionos", "tv-samsung", "a b", "tv;x"] {
            #expect(!EngineStrings.isClientList(bad), "\(bad)")
        }
    }

    @Test func formats() {
        for good in ResolverSettings.defaultFormats.values { #expect(EngineStrings.isFormat(good)) }
        for bad in ["", "-f", "--exec", "best audio", "best;rm", "best$(x)", "best\"", "best'"] {
            #expect(!EngineStrings.isFormat(bad), "\(bad)")
        }
    }

    @Test func extractorArgs() {
        #expect(EngineStrings.isExtractorArg("soundcloud:formats=hls_aac"))
        #expect(EngineStrings.isExtractorArg("youtube:player_client=visionos,tv_samsung"))
        for bad in ["soundcloud", "soundcloud:formats", "Soundcloud:formats=x", "sc:formats=hls-aac", ":a=b", "a:=b",
                    "a:b=", "a:b=c;d", "a:b=C"] {
            #expect(!EngineStrings.isExtractorArg(bad), "\(bad)")
        }
    }

    @Test func hostSuffixes() {
        #expect(EngineStrings.isHostSuffix("googlevideo.com"))
        #expect(EngineStrings.isHostSuffix("media-streaming.soundcloud.cloud"))
        for bad in ["com", "Googlevideo.com", "-a.com", "a-.com", "a..com", "a.com.", "*.a.com", "a_b.com"] {
            #expect(!EngineStrings.isHostSuffix(bad), "\(bad)")
        }
    }
}
