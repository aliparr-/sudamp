// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Catalog

private let catalogDir = bundledFeedURL.deletingLastPathComponent()
private let now = Date(timeIntervalSince1970: 1_792_670_400)   // 2026-10-22T12:00:00Z

// MARK: Build

@Test func buildReproducesTheShippedFeedByteForByte() throws {
    let source = try CatalogSource.load(directory: catalogDir)
    let first = try CatalogBuilder.build(source)
    let second = try CatalogBuilder.build(try CatalogSource.load(directory: catalogDir))
    #expect(first == second, "deterministic: two builds, identical bytes")
    #expect(first == (try Data(contentsOf: bundledFeedURL)), "catalog/feed.json is exactly what catalog/ builds")
    #expect(CatalogBuilder.missingPins(source).isEmpty, "the pin's SHA-256 is in pins.json, so builds are offline")
}

@Test func splitAndBuildRoundTrip() throws {
    let feed = try Data(contentsOf: bundledFeedURL)
    let source = try CatalogBuilder.split(feed: feed)
    #expect(source.genres.map(\.name) == ["genres/ambient.json", "genres/deep-house.json", "genres/drum-and-bass.json",
                                         "genres/house.json", "genres/lo-fi.json", "genres/techno.json"])
    #expect(source.engine.json["pin"] == .object([.init("version", .string("2026.10.21"))]), "the checksum moves to pins.json")
    #expect(source.pins.sha256 == ["2026.10.21": "2b5251788b36fcbc476568b4eea8cb239f0a775759456f2ff9344a437c52f000"])
    #expect(try CatalogBuilder.build(source) == feed)
    // Writing and re-reading the files gives the same sources.
    let dir = FileManager.default.temporaryDirectory.appending(path: "split-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: dir) }
    try source.write(to: dir)
    #expect(try CatalogSource.load(directory: dir) == source)
    #expect(try Data(contentsOf: dir.appending(path: "genres/techno.json")) == (try Data(contentsOf: catalogDir.appending(path: "genres/techno.json"))))
}

@Test func buildNormalisesKeyOrderAndFillsThePin() throws {
    var source = try fixture()
    // Curators may write keys in any order; the build writes the canonical order and the implied genre.
    source.genres[0] = try genreFile("techno", order: 10, streams: [
        #"{"weight": 0.5, "homepage": "https://a.example.com/", "creator": "A", "title": "A FM", "kind": "station", "ref": "https://a.radio.com/s", "source": "radio", "id": "radio:a"}"#,
    ] + defaultStreams(skipRadio: 1))
    let text = try CatalogBuilder.buildText(source)
    #expect(text.contains(#"{"id": "radio:a", "source": "radio", "ref": "https://a.radio.com/s", "kind": "station", "title": "A FM", "creator": "A", "genres": ["techno"], "homepage": "https://a.example.com/", "weight": 0.5}"#))
    #expect(text.contains(#""sha256": "\#(String(repeating: "ab", count: 32))""#))
    #expect(text.hasSuffix("  }\n}\n"))
    // Genres come out by order, then id, whatever the file names.
    source.genres.append(try genreFile("ambient", order: 5, streams: defaultStreams()))
    let doc = try FeedDecoder.decode(try CatalogBuilder.build(source)).document
    #expect(doc.catalog.genres.map(\.id.rawValue) == ["ambient", "techno"])
    // A pin missing from pins.json is a build error naming the version.
    source.pins = PinLock()
    #expect(throws: CatalogBuildError.missingPin("2026.10.21")) { try CatalogBuilder.build(source) }
    #expect(CatalogBuilder.missingPins(source) == ["2026.10.21"])
}

// MARK: Lint

@Test func lintPassesOnTheShippedCatalog() throws {
    let source = try CatalogSource.load(directory: catalogDir)
    let issues = CatalogLint.lint(source: source, existingFeed: try Data(contentsOf: bundledFeedURL), now: now)
    #expect(issues.isEmpty, "\(issues.map(\.description))")
    #expect(CatalogLint.lint(feed: try Data(contentsOf: bundledFeedURL), location: "feed.json", now: now).isEmpty)
}

@Test func lintFixturePassesCleanly() throws {
    let issues = CatalogLint.lint(source: try fixture(), existingFeed: nil, now: now)
    #expect(issues.isEmpty, "\(issues.map(\.description))")
}

@Test func lintReportsEachRule() throws {
    func rules(_ s: CatalogSource, existing: Data? = nil) -> [LintIssue.Rule: LintIssue.Severity] {
        var out: [LintIssue.Rule: LintIssue.Severity] = [:]
        for i in CatalogLint.lint(source: s, existingFeed: existing, now: now) where out[i.rule] != .error { out[i.rule] = i.severity }
        return out
    }
    func with(_ extra: [String], in genre: String = "techno") throws -> CatalogSource {
        var s = try fixture()
        s.genres = [try genreFile(genre, order: 10, streams: defaultStreams() + extra)]
        return s
    }

    // json: a genre file that is not an object; a built feed with a duplicate key can't happen, a published one can.
    var s = try fixture()
    s.genres.append(.init(name: "genres/x.json", json: .array([])))
    #expect(rules(s)[.json] == .error)
    #expect(CatalogLint.lint(feed: Data(#"{"schema": 1, "schema": 1}"#.utf8), location: "f", now: now).map(\.rule) == [.json])

    // schema: an unknown (typo) key, a bad envelope value.
    #expect(try rules(with([#"{"id": "yt:AAAAAAAAAAA", "source": "youtube", "ref": "AAAAAAAAAAA", "title": "t", "creator": "c", "durationSecs": 3600}"#]))[.schema] == .error)
    s = try fixture()
    s.release = .init(name: "release.json", json: try OrderedJSON.parse(#"{"schema": 2, "revision": 1, "generatedAt": "2026-10-22T10:00:00Z", "expiresAt": "2027-04-22T00:00:00Z"}"#))
    #expect(rules(s)[.schema] == .error)

    // canonical: a pasted URL instead of a ref, an ID that doesn't match its ref, a radio URL not in normal form.
    #expect(try rules(with([#"{"source": "youtube", "ref": "https://youtu.be/AAAAAAAAAAA", "title": "t", "creator": "c", "durationSec": 3600}"#]))[.canonical] == .error)
    #expect(try rules(with([#"{"id": "yt:BBBBBBBBBBB", "source": "youtube", "ref": "AAAAAAAAAAA", "title": "t", "creator": "c", "durationSec": 3600}"#]))[.canonical] == .error)
    #expect(try rules(with([#"{"id": "radio:z", "source": "radio", "ref": "HTTPS://Z.Radio.com:443/live", "title": "Z", "creator": "Z", "homepage": "https://z.radio.com/"}"#]))[.canonical] == .error)

    // duplicate: one stream in two genre files, a genre defined twice, one radio URL under two IDs.
    s = try fixture()
    s.genres.append(try genreFile("house", order: 20, streams: defaultStreams()))
    #expect(rules(s)[.duplicate] == .error)
    s = try fixture()
    s.genres.append(.init(name: "genres/techno-2.json", json: try genreFile("techno", order: 11, streams: []).json))
    #expect(rules(s)[.duplicate] == .error)
    #expect(try rules(with([#"{"id": "radio:copy", "source": "radio", "ref": "https://r1.radio.com/s", "title": "Copy", "creator": "Copy", "homepage": "https://copy.radio.com/"}"#]))[.duplicate] == .error)

    // radioURL: private, IP-literal, playlist-file and odd-port stream URLs.
    for bad in ["https://192.168.1.10/stream", "https://radio.local/stream", "https://r.radio.com/list.pls", "https://r.radio.com:81/s"] {
        let r = try rules(with([#"{"id": "radio:bad", "source": "radio", "ref": "\#(bad)", "title": "B", "creator": "B", "homepage": "https://b.radio.com/"}"#]))
        #expect(r[.radioURL] == .error, "\(bad)")
    }

    // coverage: a genre below the 1.0 rule.
    s = try fixture()
    s.genres = [try genreFile("techno", order: 10, streams: Array(defaultStreams().prefix(6)))]
    #expect(rules(s)[.coverage] == .error)

    // engine: a client list with ';' (DESIGN §7.2) fails lint even though the app would keep its previous value.
    s = try fixture()
    s.engine = .init(name: "engine.json", json: s.engine.json.setting("clients", to: .array([.string("visionos;rm -rf")])))
    #expect(rules(s)[.engine] == .error)
    s = try fixture()
    s.pins = PinLock()
    #expect(rules(s)[.engine] == .error, "pinned version without a checksum")

    // canary: an item that isn't in the catalog.
    s = try fixture()
    s.engine = .init(name: "engine.json", json: s.engine.json.setting("canary", to: .array([.string("yt:ZZZZZZZZZZZ"), .string("sc:u/s1")])))
    #expect(rules(s)[.canary] == .error)

    // expiry: past, missing, soon.
    for (expires, severity) in [("2026-10-01T00:00:00Z", LintIssue.Severity.error), ("2026-11-15T00:00:00Z", .warning)] {
        s = try fixture()
        s.release = .init(name: "release.json", json: s.release.json.setting("expiresAt", to: .string(expires)))
        #expect(rules(s)[.expiry] == severity, "\(expires)")
    }
    s = try fixture()
    s.release = .init(name: "release.json", json: s.release.json.removing("expiresAt"))
    #expect(rules(s)[.expiry] == .error)

    // policy: SomaFM without permission (error), plain-HTTP radio and short mixes (warnings).
    #expect(try rules(with([#"{"id": "radio:soma", "source": "radio", "ref": "https://ice2.somafm.com/groovesalad-128-mp3", "title": "G", "creator": "SomaFM", "homepage": "https://somafm.com/"}"#]))[.policy] == .error)
    #expect(try rules(with([#"{"id": "radio:plain", "source": "radio", "ref": "http://plain.radio.com/s", "title": "P", "creator": "P", "homepage": "https://plain.radio.com/"}"#]))[.policy] == .warning)
    #expect(try rules(with([#"{"id": "mc:u/short", "source": "mixcloud", "ref": "u/short", "title": "t", "creator": "c", "durationSec": 600}"#]))[.policy] == .warning)

    // stale: the committed feed.json differs from a fresh build.
    s = try fixture()
    let built = try CatalogBuilder.build(s)
    #expect(rules(s, existing: built).isEmpty)
    #expect(rules(s, existing: built + Data(" ".utf8))[.stale] == .error)
}

// MARK: OrderedJSON

@Test func orderedJSONKeepsOrderAndSpelling() throws {
    let text = #"{"z": 1.0, "a": [true, false, null], "m": {"k": -0.75e2, "s": "é \"q\" \\ é 🎵 /"}}"#
    let v = try OrderedJSON.parse(text)
    #expect(v.keys == ["z", "a", "m"])
    #expect(v["z"] == .number("1.0"))
    #expect(v["m"]?["k"] == .number("-0.75e2"))
    #expect(v["m"]?["s"]?.stringValue == "é \"q\" \\ é 🎵 /")
    #expect(v.compact == #"{"z": 1.0, "a": [true, false, null], "m": {"k": -0.75e2, "s": "é \"q\" \\ é 🎵 /"}}"#)
    #expect(try OrderedJSON.parse(v.compact) == v)
    #expect(try OrderedJSON.parse(v.pretty()) == v)
    #expect(OrderedJSON.object([]).pretty() == "{}" && OrderedJSON.array([]).pretty() == "[]")
    #expect(OrderedJSON.quote("a\nb\u{01}") == #""a\nb\u0001""#)
    #expect(v["z"]?.intLiteral == nil && OrderedJSON.number("10").intLiteral == 10)
}

@Test func orderedJSONIsStrict() {
    for bad in [#"{"a": 1,}"#, #"[1, 2,]"#, #"{"a": 1, "a": 2}"#, "// c\n{}", #"{"a": 01}"#, #"{"a": .5}"#, #"{"a": "x"#,
                "{\"a\": \"tab\there\"}", #"{"a": "\x"}"#, #"{"a": "\ud83c"}"#, #"{"a": "\u12G4"}"#, "{} {}", "nul", "",
                String(repeating: "[", count: 100) + String(repeating: "]", count: 100), #"{"a": 1e}"#, #"{'a': 1}"#] {
        #expect(throws: OrderedJSON.ParseError.self, "\(bad)") { try OrderedJSON.parse(bad) }
    }
    #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(Data([0x22, 0xFF, 0x22])) }
}

// MARK: AudioSniffer

@Test func audioSnifferFindsChainedFrames() {
    // MPEG-1 Layer III, 128 kbit/s, 44.1 kHz, no padding: 417-byte frames.
    var mp3 = Data([0x12, 0x34, 0xFF, 0x00, 0x99])   // joins mid-frame, with a false sync
    for _ in 0..<12 { mp3 += Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0x55, count: 413) }
    let m = AudioSniffer.sniff(mp3)
    #expect(m?.format == .mpeg && m?.offset == 5 && m?.chained == 12 && m?.sampleRate == 44_100 && m?.kbps == 128)

    // ADTS AAC, 44.1 kHz, 300-byte frames.
    var aac = Data()
    for _ in 0..<8 {
        let len = 300
        aac += Data([0xFF, 0xF1, 0x50, 0x80 | UInt8((len >> 11) & 0x03), UInt8((len >> 3) & 0xFF), UInt8((len & 0x07) << 5) | 0x1F, 0xFC])
        aac += Data(repeating: 0x21, count: len - 7)
    }
    #expect(AudioSniffer.sniff(aac)?.format == .adts)
    #expect(AudioSniffer.sniff(aac)?.chained == 8)

    // Ogg pages: header + 1 segment of 100 bytes.
    var ogg = Data()
    for _ in 0..<5 {
        ogg += Data("OggS".utf8) + Data([0]) + Data(repeating: 0, count: 21) + Data([1, 100]) + Data(repeating: 7, count: 100)
    }
    #expect(AudioSniffer.sniff(ogg)?.format == .ogg)

    // HTML, random bytes and too few frames are not audio.
    #expect(AudioSniffer.sniff(Data("<html><body>Radio is offline</body></html>".utf8)) == nil)
    var rng = SystemRandomNumberGenerator()
    #expect(AudioSniffer.sniff(Data((0..<32_768).map { _ in UInt8.random(in: 0...255, using: &rng) })) == nil)
    #expect(AudioSniffer.sniff(mp3.prefix(5 + 417 * 3)) == nil, "3 frames are not enough")
}

// MARK: Fixtures

/// A genre file with the given streams (JSON object literals).
private func genreFile(_ id: String, order: Int, streams: [String]) throws -> CatalogSource.File {
    let text = #"{"id": "\#(id)", "name": "\#(id.capitalized)", "order": \#(order), "streams": [\#(streams.joined(separator: ", "))]}"#
    return CatalogSource.File(name: "genres/\(id).json", json: try OrderedJSON.parse(text))
}

/// 15 streams meeting the 1.0 rule: 2 radio stations (2 broadcasters), YouTube, SoundCloud and Mixcloud mixes.
private func defaultStreams(skipRadio: Int = 0) -> [String] {
    var out: [String] = []
    for n in 1...2 where n > skipRadio {
        out.append(#"{"id": "radio:r\#(n)", "source": "radio", "ref": "https://r\#(n).radio.com/s", "kind": "station", "title": "R\#(n)", "creator": "Broadcaster \#(n)", "homepage": "https://r\#(n).radio.com/", "weight": 0.5}"#)
    }
    for n in 1...5 {
        let yt = "AAAAAAAA00\(n)"
        out.append(#"{"id": "yt:\#(yt)", "source": "youtube", "ref": "\#(yt)", "kind": "mix", "title": "Y\#(n)", "creator": "C", "durationSec": 3600, "weight": 1.0}"#)
        out.append(#"{"id": "sc:u/s\#(n)", "source": "soundcloud", "ref": "u/s\#(n)", "kind": "mix", "title": "S\#(n)", "creator": "C", "durationSec": 3600, "weight": 1.0}"#)
    }
    for n in 1...3 {
        out.append(#"{"id": "mc:u/m\#(n)", "source": "mixcloud", "ref": "u/m\#(n)", "kind": "mix", "title": "M\#(n)", "creator": "C", "durationSec": 3600, "weight": 1.0}"#)
    }
    return out
}

private func fixture() throws -> CatalogSource {
    let release = try OrderedJSON.parse(#"{"schema": 1, "revision": 3, "generatedAt": "2026-10-22T10:00:00Z", "expiresAt": "2027-04-22T00:00:00Z"}"#)
    let engine = try OrderedJSON.parse(#"{"minAppVersion": "0.1.0", "pin": {"version": "2026.10.21"}, "block": [], "clients": ["visionos"], "canary": ["yt:AAAAAAAA001", "sc:u/s1"]}"#)
    return CatalogSource(release: .init(name: "release.json", json: release), engine: .init(name: "engine.json", json: engine),
                         pins: PinLock(sha256: ["2026.10.21": String(repeating: "ab", count: 32)]),
                         genres: [try genreFile("techno", order: 10, streams: defaultStreams())])
}
