// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Catalog
import Foundation
import Playback

/// Copy Link (DESIGN §3): the stream's canonical page, at the current position where the platform supports it
/// (YouTube `&t=<s>s`, SoundCloud `#t=m:ss`), with a line crediting the creator. Live streams, Mixcloud and radio
/// get the plain link (a station's homepage).
nonisolated enum CopyLink {
    struct Link: Equatable {
        var url: URL
        /// What a paste into a message gets: `Creator - Title <url>`.
        var text: String
    }

    static func link(for stream: StreamInfo, position: Double?) -> Link? {
        guard let base = stream.link else { return nil }
        let seconds = position.flatMap { $0.isFinite && $0 >= 1 ? Int($0.rounded(.down)) : nil }
        var url = base
        if let seconds, !stream.isLive {
            switch stream.source {
            case .youtube:
                url = URL(string: base.absoluteString + "&t=\(seconds)s") ?? base
            case .soundcloud:
                url = URL(string: base.absoluteString + "#t=\(soundCloudTime(seconds))") ?? base
            case .youtubeLive, .mixcloud, .radio:
                break
            }
        }
        let credit = stream.source == .radio ? PlainDisplay.stationName(stream) : "\(stream.creator) - \(stream.title)"
        return Link(url: url, text: "\(credit) \(url.absoluteString)")
    }

    /// SoundCloud's `#t=` form: minutes (uncapped) and two-digit seconds.
    static func soundCloudTime(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// Open Stream URL (Eject, ⌘L): a pasted URL goes through `Catalog.Canonicaliser` (DESIGN §7.1: pasted URLs follow
/// the feed's rules, so only URLs sudamp rebuilt itself reach yt-dlp or mpv), then plays the catalog's own entry when
/// it has one, or a one-off stream otherwise.
nonisolated enum StreamURLOpener {
    enum Outcome: Equatable {
        case catalog(StreamID, startAt: Double?)
        case adHoc(StreamRef, startAt: Double?)
    }

    /// - Parameter genre: where Next continues after a one-off stream (the current genre).
    static func resolve(_ text: String, catalog: FeedCatalog, genre: GenreID?) throws(CanonicalError) -> Outcome {
        let pasted = try Canonicaliser.parse(text)
        let start = pasted.startSeconds.map(Double.init)
        if let id = pasted.streamID, catalog[id] != nil { return .catalog(id, startAt: start) }
        if pasted.source == .radio,
           let station = catalog.streams.first(where: { $0.source == .radio && $0.ref == pasted.ref }) {
            return .catalog(station.id, startAt: nil)
        }
        let genres = genre.map { [$0] } ?? []
        let id: StreamID
        let title: String
        let creator: String
        if pasted.source == .radio {
            guard let slug = StreamID(rawValue: "radio:\(radioSlug(pasted.ref))") else { throw .malformedURL }
            id = slug
            let host = URL(string: pasted.ref)?.host() ?? "Internet radio"
            title = host
            creator = host
        } else {
            guard let made = pasted.streamID else { throw .unrecognisedURL }
            id = made
            title = pasted.ref
            creator = PlainDisplay.sourceName(pasted.source)
        }
        let ref = StreamRef(id: id, source: pasted.source, ref: pasted.ref, kind: .default(for: pasted.source),
                            title: title, creator: creator, genres: genres)
        return .adHoc(ref, startAt: start)
    }

    /// A stable ID for a pasted station: `pasted-` and 12 hex digits of the URL's SHA-256.
    static func radioSlug(_ url: String) -> String {
        "pasted-" + SHA256.hash(data: Data(url.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The prompt's error line for a URL it refuses.
    static func explanation(_ error: CanonicalError) -> String {
        switch error {
        case .unrecognisedURL: "That page isn't a single mix, track, live stream or station."
        case .unsupportedScheme: "Only http and https links can be played."
        default: "That link can't be played: \(error.description)."
        }
    }
}
