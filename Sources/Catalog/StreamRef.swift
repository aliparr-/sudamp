// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How a stream plays: a finite mix (seekable VOD), a 24/7 live stream, or an internet-radio station.
public enum StreamKind: String, Sendable, Codable, CaseIterable {
    case mix
    case live
    case station

    /// The kind a source implies when the feed omits it or names one this build doesn't know.
    public static func `default`(for source: SourceKind) -> StreamKind {
        switch source {
        case .youtubeLive: .live
        case .radio: .station
        case .youtube, .soundcloud, .mixcloud: .mix
        }
    }

    public var isLive: Bool { self != .mix }
}

/// A curated stream: what the Picker picks and the Resolver resolves (DESIGN §4's `StreamRef`).
public struct StreamRef: Sendable, Hashable, Identifiable {
    public let id: StreamID
    public let source: SourceKind
    /// The canonical ref (radio: the normalised stream URL).
    public let ref: String
    public let kind: StreamKind
    public let title: String
    public let creator: String
    public let genres: [GenreID]
    public let durationSec: Int?
    /// Relative pick weight in its genre's bag (0 < weight ≤ 100, default 1).
    public let weight: Double
    /// The station's site (required for radio, to credit the broadcaster).
    public let homepage: URL?

    /// `ref` must already be canonical for `source` (the feed decoder guarantees it); anything else is a
    /// programming error, caught here rather than when the URL is first needed.
    public init(id: StreamID, source: SourceKind, ref: String, kind: StreamKind, title: String, creator: String,
                genres: [GenreID], durationSec: Int? = nil, weight: Double = 1, homepage: URL? = nil) {
        precondition(Canonicaliser.url(source: source, ref: ref) != nil, "non-canonical \(source.rawValue) ref \(ref)")
        precondition(id.source == source, "stream id \(id) does not match source \(source.rawValue)")
        self.id = id
        self.source = source
        self.ref = ref
        self.kind = kind
        self.title = title
        self.creator = creator
        self.genres = genres
        self.durationSec = durationSec
        self.weight = weight
        self.homepage = homepage
    }

    /// The URL rebuilt from the ref: what yt-dlp (or, for radio, mpv) receives.
    public var url: URL { Canonicaliser.url(source: source, ref: ref)! }

    /// Radio needs no resolve, so it can start at once.
    public var isRadio: Bool { source == .radio }
}

/// A genre in the menu, ordered by `order`, then name.
public struct Genre: Sendable, Hashable, Identifiable {
    public let id: GenreID
    public let name: String
    public let order: Int

    public init(id: GenreID, name: String, order: Int) {
        self.id = id
        self.name = name
        self.order = order
    }
}

/// The feed's `catalog` section after validation.
public struct FeedCatalog: Sendable, Equatable {
    /// Sorted by `order`, then name.
    public let genres: [Genre]
    /// In feed order.
    public let streams: [StreamRef]
    private let byID: [StreamID: StreamRef]

    public init(genres: [Genre], streams: [StreamRef]) {
        self.genres = genres.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
        self.streams = streams
        byID = Dictionary(streams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public subscript(id: StreamID) -> StreamRef? { byID[id] }

    public func genre(_ id: GenreID) -> Genre? { genres.first { $0.id == id } }

    /// A genre's streams in feed order.
    public func streams(in genre: GenreID) -> [StreamRef] { streams.filter { $0.genres.contains(genre) } }

    public static func == (a: FeedCatalog, b: FeedCatalog) -> Bool { a.genres == b.genres && a.streams == b.streams }
}
