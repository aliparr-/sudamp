// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Catalog

private let g = GenreID(rawValue: "techno")!

private func stream(_ source: SourceKind, _ n: Int, creator: String = "c") -> StreamRef {
    let ref: String, id: StreamID
    switch source {
    case .youtube: ref = String(format: "AAAAAAAA%03d", n); id = StreamID.make(source: source, ref: ref)!
    case .youtubeLive: ref = "@chan\(n)"; id = StreamID.make(source: source, ref: ref)!
    case .soundcloud: ref = "u/s\(n)"; id = StreamID.make(source: source, ref: ref)!
    case .mixcloud: ref = "u/m\(n)"; id = StreamID.make(source: source, ref: ref)!
    case .radio: ref = "https://r\(n).example.com/s"; id = StreamID(rawValue: "radio:r\(n)")!
    }
    return StreamRef(id: id, source: source, ref: ref, kind: .default(for: source), title: "t", creator: creator, genres: [g],
                     homepage: source == .radio ? URL(string: "https://example.com/") : nil)
}

private func catalog(_ s: [StreamRef]) -> FeedCatalog { FeedCatalog(genres: [Genre(id: g, name: "Techno", order: 1)], streams: s) }

@Test func coveragePassesWithEnoughVariety() {
    let s = (0..<3).map { stream(.youtube, $0) } + (0..<3).map { stream(.soundcloud, $0) }
        + [stream(.radio, 1, creator: "A"), stream(.radio, 2, creator: "B")]
    #expect(CoverageValidator.check(catalog(s), rule: .m1).isEmpty)
    #expect(CoverageValidator.check(catalog(s), rule: .release) == [CoverageViolation(genre: g, kind: .tooFewStreams(have: 8, need: 15))])
}

@Test func coverageReportsEachShortfall() {
    // YouTube VOD and /live are one platform; two stations from one broadcaster count as one.
    let s = (0..<4).map { stream(.youtube, $0) } + [stream(.youtubeLive, 1)]
        + [stream(.radio, 1, creator: "1.FM"), stream(.radio, 2, creator: "1.fm")]
    let v = CoverageValidator.check(catalog(s), rule: .m1)
    #expect(v.map(\.kind) == [.tooFewStreams(have: 7, need: 8), .tooFewRadioBroadcasters(have: 1, need: 2)])
    let onlyYT = (0..<9).map { stream(.youtube, $0) }
    #expect(CoverageValidator.check(catalog(onlyYT), rule: .m1).map(\.kind)
            == [.tooFewRadioStations(have: 0, need: 2), .tooFewRadioBroadcasters(have: 0, need: 2), .tooFewSourceTypes(have: 1, need: 2)])
}

@Test func disabledSourcesDoNotCount() {
    let s = (0..<6).map { stream(.mixcloud, $0) } + [stream(.radio, 1, creator: "A"), stream(.radio, 2, creator: "B")]
    #expect(CoverageValidator.check(catalog(s), rule: .m1).isEmpty)
    var engine = EngineConfig.defaults
    engine.sources[.mixcloud] = false
    #expect(CoverageValidator.check(catalog(s), engine: engine, rule: .m1).map(\.kind)
            == [.tooFewStreams(have: 2, need: 8), .tooFewSourceTypes(have: 1, need: 2)])
}
