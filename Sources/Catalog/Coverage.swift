// SPDX-License-Identifier: GPL-3.0-or-later

/// The per-genre coverage rule (DESIGN §7.3, PLAN M1/M7): enough streams, at least two radio stations from at least
/// two broadcasters (instant start, and a fallback when every resolver source fails), and at least two source types
/// so no single source outage silences a genre.
public struct CoverageRule: Sendable, Equatable {
    public var minStreams: Int
    public var minRadioStations: Int
    public var minRadioBroadcasters: Int
    public var minSourceTypes: Int

    public init(minStreams: Int, minRadioStations: Int = 2, minRadioBroadcasters: Int = 2, minSourceTypes: Int = 2) {
        self.minStreams = minStreams
        self.minRadioStations = minRadioStations
        self.minRadioBroadcasters = minRadioBroadcasters
        self.minSourceTypes = minSourceTypes
    }

    /// M1: 3 genres with at least 8 streams each.
    public static let m1 = CoverageRule(minStreams: 8)
    /// 1.0 (PLAN M7 `catalog-tool lint`): at least 15 streams each.
    public static let release = CoverageRule(minStreams: 15)
}

/// One genre falling short of a rule.
public struct CoverageViolation: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case tooFewStreams(have: Int, need: Int)
        case tooFewRadioStations(have: Int, need: Int)
        case tooFewRadioBroadcasters(have: Int, need: Int)
        case tooFewSourceTypes(have: Int, need: Int)
    }

    public let genre: GenreID
    public let kind: Kind

    public var description: String {
        switch kind {
        case .tooFewStreams(let h, let n): "\(genre): \(h) active streams, needs \(n)"
        case .tooFewRadioStations(let h, let n): "\(genre): \(h) radio stations, needs \(n)"
        case .tooFewRadioBroadcasters(let h, let n): "\(genre): \(h) radio broadcasters, needs \(n)"
        case .tooFewSourceTypes(let h, let n): "\(genre): \(h) source types, needs \(n)"
        }
    }
}

public enum CoverageValidator {
    /// Checks every genre. Only streams whose source is switched on count ("active"). Source types are counted by
    /// platform (YouTube VOD and `/live` share one breaker, so they are one type); radio counts as a type. A radio
    /// station's broadcaster is its `creator`, compared case-insensitively.
    public static func check(_ catalog: FeedCatalog, engine: EngineConfig = .defaults,
                             rule: CoverageRule) -> [CoverageViolation] {
        var out: [CoverageViolation] = []
        for genre in catalog.genres {
            let active = catalog.streams(in: genre.id).filter { engine.isSourceEnabled($0.source) }
            let radio = active.filter(\.isRadio)
            let broadcasters = Set(radio.map { $0.creator.lowercased() })
            let types = Set(active.map(\.source.platform))
            func add(_ k: CoverageViolation.Kind) { out.append(CoverageViolation(genre: genre.id, kind: k)) }
            if active.count < rule.minStreams { add(.tooFewStreams(have: active.count, need: rule.minStreams)) }
            if radio.count < rule.minRadioStations {
                add(.tooFewRadioStations(have: radio.count, need: rule.minRadioStations))
            }
            if broadcasters.count < rule.minRadioBroadcasters {
                add(.tooFewRadioBroadcasters(have: broadcasters.count, need: rule.minRadioBroadcasters))
            }
            if types.count < rule.minSourceTypes { add(.tooFewSourceTypes(have: types.count, need: rule.minSourceTypes)) }
        }
        return out
    }

    /// Curation warnings that don't block playback: canary items missing from the catalog or of the wrong source,
    /// and genres with no streams at all.
    public static func lint(_ document: FeedDocument) -> [String] {
        var out: [String] = []
        let canary = document.engine.canary
        if !canary.contains(where: { $0.source == .youtube }) { out.append("canary has no YouTube VOD item") }
        if !canary.contains(where: { $0.source == .soundcloud }) { out.append("canary has no SoundCloud item") }
        for id in canary where document.catalog[id] == nil { out.append("canary \(id) is not in the catalog") }
        for g in document.catalog.genres where document.catalog.streams(in: g.id).isEmpty {
            out.append("genre \(g.id) has no streams")
        }
        return out
    }
}
