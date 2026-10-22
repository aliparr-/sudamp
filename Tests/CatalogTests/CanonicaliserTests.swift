// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Catalog

// MARK: Refs (DESIGN §7.1 table)

@Test(arguments: [
    (SourceKind.youtube, "dQw4w9WgXcQ"), (.youtube, "a-b_c-d_e-f"),
    (.youtubeLive, "@LofiGirl"), (.youtubeLive, "@lofi.girl_2-x"), (.youtubeLive, "UCSJ4gkVC6NrvII8umztf0Ow"),
    (.soundcloud, "platform/misskittin"), (.soundcloud, "user_1/some-slug_2"),
    (.mixcloud, "Defectedrecords/defected-radio-show"), (.mixcloud, "johndigweed/transitions_john-digweed-ian-odonovan"),
])
func acceptsValidRefs(source: SourceKind, ref: String) throws {
    #expect(try Canonicaliser.canonicalRef(ref, for: source) == ref)
    #expect(StreamID.make(source: source, ref: ref) != nil)
}

@Test(arguments: [
    (SourceKind.youtube, "dQw4w9WgXc"), (.youtube, "dQw4w9WgXcQQ"), (.youtube, "dQw4w9WgXc!"), (.youtube, ""),
    (.youtube, "dQw4w9WgXc\n"), (.youtube, "../../etc/pa"),
    (.youtubeLive, "LofiGirl"), (.youtubeLive, "@ab"), (.youtubeLive, "@" + String(repeating: "a", count: 31)),
    (.youtubeLive, "@lofi girl"), (.youtubeLive, "@lofi/../x"), (.youtubeLive, "UCshort"), (.youtubeLive, "UC" + String(repeating: "a", count: 23)),
    (.soundcloud, "Platform/misskittin"), (.soundcloud, "platform"), (.soundcloud, "platform/sets/x"), (.soundcloud, "platform/"),
    (.soundcloud, "/misskittin"), (.soundcloud, "a/b?c"), (.soundcloud, "a/b#t=1"), (.soundcloud, "a/%2e%2e"),
    (.mixcloud, "user"), (.mixcloud, "user/slug/"), (.mixcloud, "user/slug/extra"), (.mixcloud, "user/sl%C3%BCg"),
    (.mixcloud, "user/slüg"), (.mixcloud, "us er/slug"),
])
func rejectsInvalidRefs(source: SourceKind, ref: String) {
    #expect(throws: CanonicalError.self) { try Canonicaliser.canonicalRef(ref, for: source) }
    #expect(StreamID.make(source: source, ref: ref) == nil)
}

@Test func rebuildsURLsFromRefs() {
    #expect(Canonicaliser.url(source: .youtube, ref: "dQw4w9WgXcQ")?.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    #expect(Canonicaliser.url(source: .youtubeLive, ref: "@LofiGirl")?.absoluteString == "https://www.youtube.com/@LofiGirl/live")
    #expect(Canonicaliser.url(source: .youtubeLive, ref: "UCSJ4gkVC6NrvII8umztf0Ow")?.absoluteString
            == "https://www.youtube.com/channel/UCSJ4gkVC6NrvII8umztf0Ow/live")
    #expect(Canonicaliser.url(source: .soundcloud, ref: "platform/misskittin")?.absoluteString == "https://soundcloud.com/platform/misskittin")
    #expect(Canonicaliser.url(source: .mixcloud, ref: "CarlCox/global-447")?.absoluteString == "https://www.mixcloud.com/CarlCox/global-447/")
    #expect(Canonicaliser.url(source: .radio, ref: "HTTPS://Stream.Example.com:443/live?x=1#frag")?.absoluteString
            == "https://stream.example.com/live?x=1")
    #expect(Canonicaliser.url(source: .youtube, ref: "bad") == nil)
}

@Test func streamIDsRoundTrip() throws {
    let id = try #require(StreamID(rawValue: "mc:CarlCox/global-447"))
    #expect(id.source == .mixcloud && id.ref == "CarlCox/global-447")
    #expect(StreamID(rawValue: "radio:1fm-deep-house")?.source == .radio)
    #expect(StreamID.make(source: .youtubeLive, ref: "@LofiGirl")?.rawValue == "ytl:@LofiGirl")
    for bad in ["yt:short", "sc:Upper/case", "radio:Bad_Slug", "radio:", "xx:abc", "ytdQw4w9WgXcQ", "mc:a/b/c", "radio:-x"] {
        #expect(StreamID(rawValue: bad) == nil, "\(bad)")
    }
    let data = try JSONEncoder().encode([id])
    #expect(try JSONDecoder().decode([StreamID].self, from: data) == [id])
    #expect(throws: DecodingError.self) { try JSONDecoder().decode([StreamID].self, from: Data(#"["yt:nope"]"#.utf8)) }
}

// MARK: Pasted URLs

@Test(arguments: [
    ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", SourceKind.youtube, "dQw4w9WgXcQ", nil as Int?),
    ("https://youtube.com/watch?v=dQw4w9WgXcQ&t=90", .youtube, "dQw4w9WgXcQ", 90),
    ("https://www.youtube.com./watch?v=dQw4w9WgXcQ", .youtube, "dQw4w9WgXcQ", nil),
    ("http://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ&t=1m30s", .youtube, "dQw4w9WgXcQ", 90),
    ("youtu.be/dQw4w9WgXcQ?t=1h2m3s", .youtube, "dQw4w9WgXcQ", 3723),
    ("https://www.youtube.com/live/dQw4w9WgXcQ?si=abc", .youtube, "dQw4w9WgXcQ", nil),
    ("https://www.youtube.com/embed/dQw4w9WgXcQ", .youtube, "dQw4w9WgXcQ", nil),
    ("https://www.youtube.com/@LofiGirl", .youtubeLive, "@LofiGirl", nil),
    ("https://www.youtube.com/@LofiGirl/live", .youtubeLive, "@LofiGirl", nil),
    ("https://www.youtube.com/channel/UCSJ4gkVC6NrvII8umztf0Ow/live", .youtubeLive, "UCSJ4gkVC6NrvII8umztf0Ow", nil),
    ("https://soundcloud.com/platform/misskittin", .soundcloud, "platform/misskittin", nil),
    ("https://SoundCloud.com/Platform/MissKittin#t=1:02:03", .soundcloud, "platform/misskittin", 3723),
    ("https://m.soundcloud.com/platform/misskittin?in=x/sets/y", .soundcloud, "platform/misskittin", nil),
    ("https://www.mixcloud.com/CarlCox/carl-cox-global-447-live-from-ibiza-week-14/", .mixcloud, "CarlCox/carl-cox-global-447-live-from-ibiza-week-14", nil),
    ("https://mixcloud.com/johndigweed/transitions-1135", .mixcloud, "johndigweed/transitions-1135", nil),
    ("https://strm112.1.fm/deephouse_mobile_mp3", .radio, "https://strm112.1.fm/deephouse_mobile_mp3", nil),
    ("http://Stream.Laut.FM:8080/lofi#x", .radio, "http://stream.laut.fm:8080/lofi", nil),
    ("https://radio.example.org:443/live.m3u8", .radio, "https://radio.example.org/live.m3u8", nil),
    ("stream.laut.fm/lofi", .radio, "https://stream.laut.fm/lofi", nil),
])
func parsesPastedURLs(input: String, source: SourceKind, ref: String, start: Int?) throws {
    let p = try Canonicaliser.parse(input)
    #expect(p.source == source)
    #expect(p.ref == ref)
    #expect(p.startSeconds == start)
}

@Test(arguments: [
    "file:///etc/hosts", "FILE:///etc/passwd", "javascript:alert(1)", "data:audio/mp3;base64,AAAA", "ftp://radio.example.com/s",
    "gopher://radio.example.com/", "rtmp://radio.example.com/live", "smb://nas.example.com/x",
    "http://127.0.0.1:8000/stream", "http://[::1]/stream", "http://[fe80::1%25en0]/", "http://10.0.0.1/", "http://2130706433/",
    "http://0x7f.0.0.1/", "http://0x7f000001/", "http://127.1/", "http://017700000001/", "http://192.168.1.10:8000/",
    "http://user:pass@radio.example.com/stream", "http://user@radio.example.com/", "https://youtube.com@evil.example.com/",
    "http://localhost:8000/", "http://LOCALHOST./", "http://foo.localhost/", "http://radio.local/stream", "http://printer.internal/",
    "http://nas.lan/", "http://router.home.arpa/", "http://intranet/", "http://radio/", "http://radio.example.com.:22/",
    "http://radio.example.com:0/", "http://radio.example.com:1023/", "http://radio.example.com:99999/",
    "http://radio.example.com/listen.pls", "http://radio.example.com/a.M3U", "https://radio.example.com/x.asx?y=1",
    "https://radio.example.com/stream\nX-Injected: 1", "https://radio.example.com/ stream", "https://evil.example.com\\@good.com/",
    "https://radio.exa mple.com/", "https://-bad-.example.com/", "https://radio_x.example.com/", "https://radio.example.123/",
    "", "   ", "not a url", "//radio.example.com/",
    "https://www.youtube.com/watch?v=short", "https://www.youtube.com/results?search_query=deep+house",
    "https://www.youtube.com/@ab", "https://www.youtube.com/channel/UCnope/live", "https://www.youtube.com/watch?v=dQw4w9WgXcQ:8080",
    "https://www.youtube.com:8443/watch?v=dQw4w9WgXcQ", "https://youtu.be/", "https://music.youtube.com/playlist?list=PL1",
    "https://soundcloud.com/platform", "https://soundcloud.com/platform/sets/boiler-room", "https://soundcloud.com/platform/likes",
    "https://soundcloud.com/a/b/c", "https://api.soundcloud.com/tracks/123", "https://on.soundcloud.com/AbCd",
    "https://www.mixcloud.com/discover/deep-house/", "https://www.mixcloud.com/CarlCox/uploads/", "https://www.mixcloud.com/CarlCox/",
    "https://www.mixcloud.com/user/sl%C3%BCg/", "https://api.mixcloud.com/CarlCox/x/",
])
func rejectsHostilePastedURLs(input: String) {
    #expect(throws: CanonicalError.self, "\(input)") { try Canonicaliser.parse(input) }
}

@Test func pastedRefsYieldStreamIDs() throws {
    #expect(try Canonicaliser.parse("https://soundcloud.com/platform/misskittin").streamID?.rawValue == "sc:platform/misskittin")
    #expect(try Canonicaliser.parse("https://radio.example.com/live").streamID == nil)
}

@Test func specificErrorsForHostileHosts() {
    func error(_ s: String) -> CanonicalError? {
        do { _ = try RadioURLPolicy.validate(s); return nil } catch { return error }
    }
    #expect(error("http://127.0.0.1/") == .ipLiteral)
    #expect(error("http://[::1]:8000/") == .ipLiteral)
    #expect(error("http://0x7f.0.0.1/") == .ipLiteral)
    #expect(error("http://u:p@radio.example.com/") == .userinfo)
    #expect(error("http://localhost/") == .forbiddenHost("localhost"))
    #expect(error("http://box.local/") == .forbiddenHost("box.local"))
    #expect(error("http://radio/") == .singleLabelHost)
    #expect(error("http://radio.example.com:22/") == .invalidPort(22))
    #expect(error("file:///etc/hosts") == .unsupportedScheme("file"))
    #expect(error("http://radio.example.com/a.pls") == .notDirectStream)
    #expect(error("http://radio.example.com:8000/stream") == nil)
}
