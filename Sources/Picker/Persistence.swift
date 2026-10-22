// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation

/// Where the last session stopped, for the returning-launch auto-resume (DESIGN §3).
public struct LastSession: Codable, Sendable, Equatable {
    public var genre: GenreID
    public var stream: StreamID?
    /// Playback position of a VOD, in seconds.
    public var positionSec: Double?
    public var wasPlaying: Bool
    public var savedAt: Date

    public init(genre: GenreID, stream: StreamID? = nil, positionSec: Double? = nil, wasPlaying: Bool, savedAt: Date) {
        self.genre = genre
        self.stream = stream
        self.positionSec = positionSec
        self.wasPlaying = wasPlaying
        self.savedAt = savedAt
    }
}

/// `session.json` (DESIGN §7.3): bags, health, the source breakers (M6) and the last session.
public struct SessionFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var picker: PickerState
    public var last: LastSession?
    /// Absent in files written before M6 (decoded as nil, i.e. every breaker closed).
    public var breakers: SourceBreakers?
    /// How many HTTP redirects each radio station took last time (M6: the controller follows them itself).
    public var radioRedirectHops: [StreamID: Int]?

    public init(picker: PickerState, last: LastSession? = nil, breakers: SourceBreakers? = nil,
                radioRedirectHops: [StreamID: Int]? = nil) {
        version = SessionFile.currentVersion
        self.picker = picker
        self.last = last
        self.breakers = breakers
        self.radioRedirectHops = radioRedirectHops
    }
}

/// `library.json` (DESIGN §7.3): favourites, bans and the last 200 plays.
public struct Library: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let historyLimit = 200

    public struct Entry: Codable, Sendable, Equatable {
        public var stream: StreamID
        public var genre: GenreID?
        public var playedAt: Date

        public init(stream: StreamID, genre: GenreID?, playedAt: Date) {
            self.stream = stream
            self.genre = genre
            self.playedAt = playedAt
        }
    }

    public var version = Library.currentVersion
    public private(set) var favourites: [StreamID] = []
    /// Ordered, newest last, so ⌘⌫ can be undone.
    public private(set) var banned: [StreamID] = []
    /// Newest last, at most `historyLimit`.
    public private(set) var history: [Entry] = []

    public init() {}

    public var bannedSet: Set<StreamID> { Set(banned) }

    public mutating func toggleFavourite(_ id: StreamID) {
        if let i = favourites.firstIndex(of: id) { favourites.remove(at: i) } else { favourites.append(id) }
    }

    public mutating func ban(_ id: StreamID) {
        banned.removeAll { $0 == id }
        banned.append(id)
    }

    /// Undoes the newest ban, or a specific one.
    @discardableResult
    public mutating func unban(_ id: StreamID? = nil) -> StreamID? {
        if let id {
            guard let i = banned.firstIndex(of: id) else { return nil }
            return banned.remove(at: i)
        }
        return banned.popLast()
    }

    public mutating func recordPlay(_ id: StreamID, genre: GenreID?, at date: Date) {
        history.append(Entry(stream: id, genre: genre, playedAt: date))
        if history.count > Library.historyLimit { history.removeFirst(history.count - Library.historyLimit) }
    }
}

/// Atomic JSON files for session.json and library.json. Unreadable or future-version files load as nil, so a
/// corrupt state file costs the shuffle position, never a launch.
public enum StateFile {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL, maxVersion: Int = 1) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let probe = try? decoder.decode(VersionProbe.self, from: data), probe.version > maxVersion { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    /// Writes via a temporary file and rename, so a crash mid-write leaves the previous file intact.
    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private struct VersionProbe: Decodable { let version: Int }
}
