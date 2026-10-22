// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation
@testable import Picker

let deep = GenreID(rawValue: "deep-house")!
let techno = GenreID(rawValue: "techno")!
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A stream of the given source; `n` makes the ref unique.
func stream(_ source: SourceKind, _ n: Int, genre: GenreID = deep, weight: Double = 1, creator: String = "c") -> StreamRef {
    let ref: String
    let id: StreamID
    switch source {
    case .youtube: ref = String(format: "VID%08d", n); id = StreamID.make(source: source, ref: ref)!
    case .youtubeLive: ref = "@live\(n)x"; id = StreamID.make(source: source, ref: ref)!
    case .soundcloud: ref = "user/sc\(n)"; id = StreamID.make(source: source, ref: ref)!
    case .mixcloud: ref = "User/mc\(n)"; id = StreamID.make(source: source, ref: ref)!
    case .radio: ref = "https://r\(n).example.com/s"; id = StreamID(rawValue: "radio:r\(n)")!
    }
    return StreamRef(id: id, source: source, ref: ref, kind: .default(for: source), title: "T\(n)", creator: creator,
                     genres: [genre], durationSec: 3600, weight: weight,
                     homepage: source == .radio ? URL(string: "https://example.com/") : nil)
}

func catalog(_ streams: [StreamRef]) -> FeedCatalog {
    FeedCatalog(genres: [Genre(id: deep, name: "Deep House", order: 1), Genre(id: techno, name: "Techno", order: 2)],
                streams: streams)
}

func members(_ ids: [StreamID], weight: Double = 1) -> [BagMember] { ids.map { BagMember(id: $0, weight: weight) } }

func ids(_ prefix: String, _ n: Int) -> [StreamID] { (0..<n).map { StreamID(rawValue: "radio:\(prefix)\($0)")! } }

/// Chi-square statistic for observed counts against expected probabilities.
func chiSquare(observed: [Int], expected p: [Double]) -> Double {
    let n = Double(observed.reduce(0, +))
    return zip(observed, p).reduce(0) { acc, x in
        let e = n * x.1
        return acc + (Double(x.0) - e) * (Double(x.0) - e) / e
    }
}

/// Upper 1% points of the chi-square distribution: a statistic below the value means p > 0.01.
let chiSquareCritical01: [Int: Double] = [1: 6.635, 2: 9.210, 3: 11.345, 4: 13.277, 5: 15.086, 6: 16.812, 7: 18.475, 9: 21.666]
