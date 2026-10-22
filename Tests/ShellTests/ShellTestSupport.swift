// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation
import Picker
import Playback
@testable import Shell

/// Paths inside the repository, located from this file so tests run from any working directory.
enum ShellRepo {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func url(_ relative: String) -> URL { root.appending(path: relative) }
}

/// A temporary directory removed when the guard goes away.
final class ShellTempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "shell-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

let deepHouseID = GenreID(rawValue: "deep-house")!
let technoID = GenreID(rawValue: "techno")!

func mix(_ n: Int, source: SourceKind = .youtube, duration: Int? = 3720, genre: GenreID = deepHouseID) -> StreamRef {
    switch source {
    case .youtube:
        let ref = String(format: "VID%08d", n)
        return StreamRef(id: .make(source: .youtube, ref: ref)!, source: .youtube, ref: ref, kind: .mix,
                         title: "Mix \(n)", creator: "Creator \(n)", genres: [genre], durationSec: duration)
    case .soundcloud:
        let ref = "user\(n)/track-\(n)"
        return StreamRef(id: .make(source: .soundcloud, ref: ref)!, source: .soundcloud, ref: ref, kind: .mix,
                         title: "Track \(n)", creator: "User \(n)", genres: [genre], durationSec: duration)
    case .mixcloud:
        let ref = "User\(n)/show-\(n)"
        return StreamRef(id: .make(source: .mixcloud, ref: ref)!, source: .mixcloud, ref: ref, kind: .mix,
                         title: "Show \(n)", creator: "Host \(n)", genres: [genre], durationSec: duration)
    case .youtubeLive:
        let ref = "@live\(n)xx"
        return StreamRef(id: .make(source: .youtubeLive, ref: ref)!, source: .youtubeLive, ref: ref, kind: .live,
                         title: "Live \(n)", creator: "Channel \(n)", genres: [genre])
    case .radio:
        return StreamRef(id: StreamID(rawValue: "radio:station-\(n)")!, source: .radio,
                         ref: "https://stream\(n).radiostation.fm/live", kind: .station, title: "Station \(n)",
                         creator: "Station \(n)", genres: [genre], homepage: URL(string: "https://radiostation.fm/\(n)"))
    }
}

func catalogOf(_ streams: [StreamRef]) -> FeedCatalog {
    FeedCatalog(genres: [Genre(id: deepHouseID, name: "Deep House", order: 1), Genre(id: technoID, name: "Techno", order: 2)],
                streams: streams)
}

/// A snapshot as PlaybackController would publish it.
func snapshot(_ phase: PlaybackPhase, stream s: StreamRef? = nil, genre: GenreID? = deepHouseID,
              status: String? = nil) -> PlayerSnapshot {
    var snap = PlayerSnapshot(phase: phase, genre: genre, genreName: genre.map { $0 == deepHouseID ? "Deep House" : "Techno" },
                              stream: s.map(StreamInfo.init), engine: EngineStatus(state: .ready), radioOnly: false,
                              statusText: status ?? PlayerSnapshot.idleText, volume: 80)
    if [.playing, .paused].contains(phase), let s, !s.kind.isLive { snap.canSeek = true }
    return snap
}
