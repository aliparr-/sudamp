// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Catalog

/// Builds a feed document around the given stream JSON objects.
func feedJSON(schema: String = "1", streams: [String], genres: String? = nil, engine: String = "{}",
              extra: String = "") -> Data {
    let g = genres ?? #"[{"id":"deep-house","name":"Deep House","order":10},{"id":"techno","name":"Techno","order":20}]"#
    return Data("""
    {"schema": \(schema), "revision": 3, "generatedAt": "2026-10-22T10:00:00Z", "expiresAt": "2027-04-22T00:00:00Z", \(extra)
     "catalog": {"genres": \(g), "streams": [\(streams.joined(separator: ","))]}, "engine": \(engine)}
    """.utf8)
}

let goodYT = #"{"id":"yt:bk6Xst6euQk","source":"youtube","ref":"bk6Xst6euQk","kind":"mix","title":"Boiler Room: Tulum","creator":"Solomun","genres":["deep-house"],"durationSec":7231,"weight":1.0}"#
let goodRadio = #"{"id":"radio:1fm-deep-house","source":"radio","ref":"https://strm112.1.fm/deephouse_mobile_mp3","title":"Deep House Radio","creator":"1.FM","genres":["deep-house"],"homepage":"https://www.1.fm/"}"#

@Test func decodesAMinimalDocument() throws {
    let r = try FeedDecoder.decode(feedJSON(streams: [goodYT, goodRadio]))
    #expect(r.isClean)
    let d = r.document
    #expect(d.schema == 1 && d.revision == 3)
    #expect(d.generatedAt == Date(timeIntervalSince1970: 1_792_663_200))
    #expect(d.expiresAt != nil)
    #expect(d.catalog.genres.map(\.id.rawValue) == ["deep-house", "techno"])
    #expect(d.catalog.streams.count == 2)
    let radio = try #require(d.catalog[StreamID(rawValue: "radio:1fm-deep-house")!])
    #expect(radio.kind == .station && radio.isRadio && radio.weight == 1)
    #expect(radio.url.absoluteString == "https://strm112.1.fm/deephouse_mobile_mp3")
    #expect(radio.homepage?.absoluteString == "https://www.1.fm/")
    let yt = try #require(d.catalog.streams.first)
    #expect(yt.url.absoluteString == "https://www.youtube.com/watch?v=bk6Xst6euQk")
    #expect(yt.durationSec == 7231)
    #expect(d.catalog.streams(in: GenreID(rawValue: "techno")!).isEmpty)
    #expect(d.engine == .defaults)
}

@Test func unknownMajorSchemaRejectsTheDocument() {
    #expect(throws: FeedError.unsupportedSchema(2)) { try FeedDecoder.decode(feedJSON(schema: "2", streams: [goodYT])) }
    #expect(throws: FeedError.unsupportedSchema(0)) { try FeedDecoder.decode(feedJSON(schema: "0", streams: [goodYT])) }
    #expect(throws: FeedError.invalidField("schema")) { try FeedDecoder.decode(feedJSON(schema: #""1""#, streams: [goodYT])) }
    #expect(throws: FeedError.invalidField("schema")) { try FeedDecoder.decode(feedJSON(schema: "1.5", streams: [goodYT])) }
    #expect(throws: FeedError.invalidJSON) { try FeedDecoder.decode(Data("{not json".utf8)) }
    #expect(throws: FeedError.invalidJSON) { try FeedDecoder.decode(Data("[1,2]".utf8)) }
    #expect(throws: FeedError.missingField("schema")) {
        try FeedDecoder.decode(Data(#"{"revision":1,"generatedAt":"2026-10-22T10:00:00Z","catalog":{}}"#.utf8))
    }
    #expect(throws: FeedError.invalidField("revision")) {
        try FeedDecoder.decode(Data(#"{"schema":1,"revision":-1,"generatedAt":"2026-10-22T10:00:00Z","catalog":{}}"#.utf8))
    }
    #expect(throws: FeedError.invalidField("generatedAt")) {
        try FeedDecoder.decode(Data(#"{"schema":1,"revision":1,"generatedAt":"yesterday","catalog":{}}"#.utf8))
    }
}

@Test func badItemsAreDroppedWithReasonsAndTheRestKept() throws {
    let bad: [(String, String)] = [
        (#"{"id":"vm:1","source":"vimeo","ref":"1","title":"t","creator":"c","genres":["deep-house"]}"#, "unknown source"),
        (#"{"id":"yt:short","source":"youtube","ref":"short","title":"t","creator":"c","genres":["deep-house"]}"#, "invalid youtube ref"),
        (#"{"id":"yt:AAAAAAAAAAA","source":"youtube","ref":"BBBBBBBBBBB","title":"t","creator":"c","genres":["deep-house"]}"#, "id does not match ref"),
        (#"{"source":"soundcloud","ref":"a/b","creator":"c","genres":["deep-house"]}"#, "missing title"),
        (#"{"source":"soundcloud","ref":"a/c","title":"t","creator":"  ","genres":["deep-house"]}"#, "missing creator"),
        (#"{"source":"soundcloud","ref":"a/d","title":"t","creator":"c","genres":["ambient"]}"#, "no known genre"),
        (#"{"source":"soundcloud","ref":"a/e","title":"t","creator":"c","genres":["deep-house"],"weight":0}"#, "weight"),
        (#"{"source":"soundcloud","ref":"a/f","title":"t","creator":"c","genres":["deep-house"],"weight":"heavy"}"#, "weight"),
        (#"{"source":"soundcloud","ref":"a/g","title":"t","creator":"c","genres":["deep-house"],"durationSec":-5}"#, "durationSec"),
        (#"{"id":"radio:x","source":"radio","ref":"https://radio.example.com/s","title":"t","creator":"c","genres":["deep-house"]}"#, "homepage"),
        (#"{"id":"radio:y","source":"radio","ref":"http://127.0.0.1:8000/","title":"t","creator":"c","genres":["deep-house"],"homepage":"https://x.example.com/"}"#, "IP-literal"),
        (#"{"id":"radio:z","source":"radio","ref":"file:///etc/hosts","title":"t","creator":"c","genres":["deep-house"],"homepage":"https://x.example.com/"}"#, "scheme"),
        (#"{"source":"radio","ref":"https://radio.example.com/s","title":"t","creator":"c","genres":["deep-house"],"homepage":"https://x.example.com/"}"#, "radio needs an id"),
        (#"{"id":"radio:h","source":"radio","ref":"https://radio.example.com/s","title":"t","creator":"c","genres":["deep-house"],"homepage":"javascript:alert(1)"}"#, "homepage"),
        (#"["not","an","object"]"#, "not an object"),
        (goodYT, "duplicate id"),
    ]
    let r = try FeedDecoder.decode(feedJSON(streams: [goodYT] + bad.map(\.0) + [goodRadio]))
    #expect(r.document.catalog.streams.map(\.id.rawValue) == ["yt:bk6Xst6euQk", "radio:1fm-deep-house"])
    #expect(r.dropped.count == bad.count)
    for (dropped, (_, expected)) in zip(r.dropped, bad) {
        #expect(dropped.section == .stream)
        #expect(dropped.reason.contains(expected), "\(dropped) should mention \(expected)")
    }
    #expect(r.dropped.map(\.index) == Array(1...bad.count))
}

@Test func badGenresAreDroppedAndStreamsLoseOnlyUnknownGenres() throws {
    let genres = #"[{"id":"deep-house","name":"Deep House","order":10},{"id":"Bad Genre","name":"x"},{"id":"techno"},{"id":"deep-house","name":"Dup"},{"id":"lo-fi","name":"Lo-fi","order":5}]"#
    let s = #"{"source":"mixcloud","ref":"CarlCox/global-447","title":"Global 447","creator":"Carl Cox","genres":["techno","deep-house","deep-house","lo-fi"]}"#
    let r = try FeedDecoder.decode(feedJSON(streams: [s], genres: genres))
    #expect(r.document.catalog.genres.map(\.id.rawValue) == ["lo-fi", "deep-house"])
    #expect(r.dropped.map(\.reason) == ["invalid or missing id", "invalid or missing name", "duplicate id"])
    #expect(r.document.catalog.streams.first?.genres.map(\.rawValue) == ["deep-house", "lo-fi"])
    #expect(r.document.catalog.streams.first?.id.rawValue == "mc:CarlCox/global-447")
}

@Test func kindsDefaultBySourceAndUnknownKindsFallBack() throws {
    let a = #"{"source":"soundcloud","ref":"a/b","title":"t","creator":"c","genres":["techno"]}"#
    let b = #"{"source":"youtube","ref":"bk6Xst6euQk","kind":"hologram","title":"t","creator":"c","genres":["techno"]}"#
    let c = #"{"source":"youtube-live","ref":"@LofiGirl","kind":"mix","title":"t","creator":"c","genres":["techno"]}"#
    let r = try FeedDecoder.decode(feedJSON(streams: [a, b, c]))
    #expect(r.document.catalog.streams.map(\.kind) == [.mix, .mix, .live])
    #expect(r.document.catalog.streams[2].url.absoluteString == "https://www.youtube.com/@LofiGirl/live")
}

@Test func titlesAreCleaned() throws {
    let s = #"{"source":"soundcloud","ref":"a/b","title":"  Line\u0000One\nTwo\u001b[31m ","creator":"c","genres":["techno"]}"#
    let r = try FeedDecoder.decode(feedJSON(streams: [s]))
    #expect(r.document.catalog.streams.first?.title == "LineOneTwo[31m")
    let long = String(repeating: "x", count: 500)
    let s2 = #"{"source":"soundcloud","ref":"a/c","title":"\#(long)","creator":"c","genres":["techno"]}"#
    #expect(try FeedDecoder.decode(feedJSON(streams: [s2])).document.catalog.streams.first?.title.count == FeedDecoder.maxTitleLength)
}

@Test func nonListSectionsAreReportedNotFatal() throws {
    let data = Data(#"{"schema":1,"revision":1,"generatedAt":"2026-10-22T10:00:00Z","catalog":{"genres":{},"streams":7}}"#.utf8)
    let r = try FeedDecoder.decode(data)
    #expect(r.document.catalog.streams.isEmpty && r.document.catalog.genres.isEmpty)
    #expect(r.dropped.count == 2)
    #expect(r.document.expiresAt == nil)
}
