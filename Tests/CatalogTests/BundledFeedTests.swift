// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Catalog

/// `catalog/feed.json`, found relative to this file so the test runs from any working directory.
let bundledFeedURL = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "catalog/feed.json")

@Test func bundledFeedPassesValidationAndM1Coverage() throws {
    let result = try FeedDecoder.decode(Data(contentsOf: bundledFeedURL))
    #expect(result.dropped.isEmpty, "\(result.dropped)")
    #expect(result.engineIssues.isEmpty, "\(result.engineIssues)")
    let doc = result.document
    #expect(doc.schema == FeedDocument.supportedSchema)
    #expect(doc.catalog.genres.map(\.id.rawValue) == ["deep-house", "house", "techno", "drum-and-bass", "lo-fi", "ambient"])
    let violations = CoverageValidator.check(doc.catalog, engine: doc.engine, rule: .m1)
    #expect(violations.isEmpty, "\(violations)")
    #expect(CoverageValidator.lint(doc).isEmpty, "\(CoverageValidator.lint(doc))")
}

@Test func bundledFeedMeetsTheReleaseCoverageRule() throws {
    // Revision 2 already meets the 1.0 rule (>= 15 streams per genre); keep it there while the feed is hand-edited.
    let doc = try FeedDecoder.decode(Data(contentsOf: bundledFeedURL)).document
    let violations = CoverageValidator.check(doc.catalog, engine: doc.engine, rule: .release)
    #expect(violations.isEmpty, "\(violations)")
}

@Test func bundledFeedMeetsTheM1Brief() throws {
    let doc = try FeedDecoder.decode(Data(contentsOf: bundledFeedURL)).document
    // Every genre: YouTube VOD, a 24/7 /live channel, SoundCloud and Mixcloud mixes, and >= 2 radio stations.
    for genre in doc.catalog.genres {
        let s = doc.catalog.streams(in: genre.id)
        let sources = Set(s.map(\.source))
        #expect(sources == Set(SourceKind.allCases), "\(genre.id): \(sources)")
        #expect(s.filter(\.isRadio).count >= 2)
        for item in s where !item.isRadio && item.kind == .mix {
            #expect((item.durationSec ?? 0) >= 40 * 60, "\(item.id) should be a long mix")
        }
    }
    for s in doc.catalog.streams {
        #expect(!s.title.isEmpty && !s.creator.isEmpty)
        if s.isRadio {
            #expect(s.homepage != nil)
            #expect(s.url.scheme == "https", "\(s.id): prefer HTTPS radio")
            #expect(!s.url.absoluteString.contains("somafm"), "no SomaFM until permission is granted")
        }
    }
    let engine = doc.engine
    #expect(engine.pin?.version == "2026.10.21")
    #expect(engine.pin?.sha256 == "2b5251788b36fcbc476568b4eea8cb239f0a775759456f2ff9344a437c52f000")
    #expect(engine.fastStartRank == [.radio, .soundcloud, .mixcloud, .youtube])
    #expect(engine.clients == ["visionos", "visionos,tv_samsung"])
    #expect([SourceKind.youtube, .soundcloud, .mixcloud].allSatisfy(engine.isSourceEnabled))
    #expect(engine.canary.map(\.source) == [.youtube, .soundcloud])
    #expect(engine.formats == EngineConfig.defaults.formats)
}
