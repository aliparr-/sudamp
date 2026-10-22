// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why a ref or URL was refused. Every refusal is final: nothing is "fixed up" into a different target.
public enum CanonicalError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidRef(SourceKind, String)
    case malformedURL
    case unsupportedScheme(String)
    case userinfo
    case ipLiteral
    case forbiddenHost(String)
    case singleLabelHost
    case invalidHost
    case invalidPort(Int)
    case notDirectStream
    case unrecognisedURL
    case unresolvable
    case nonPublicAddress(String)

    public var description: String {
        switch self {
        case .invalidRef(let s, let r): "invalid \(s.rawValue) ref '\(r)'"
        case .malformedURL: "malformed URL"
        case .unsupportedScheme(let s): "unsupported scheme '\(s)'"
        case .userinfo: "URL contains userinfo"
        case .ipLiteral: "IP-literal host"
        case .forbiddenHost(let h): "forbidden host '\(h)'"
        case .singleLabelHost: "single-label host"
        case .invalidHost: "invalid host name"
        case .invalidPort(let p): "port \(p) not allowed"
        case .notDirectStream: "playlist file, not a direct stream"
        case .unrecognisedURL: "not a recognised stream URL"
        case .unresolvable: "host did not resolve"
        case .nonPublicAddress(let a): "host resolves to non-public address \(a)"
        }
    }
}

/// A pasted URL turned into a source and canonical ref (DESIGN §7.1: "pasted URLs follow the same rules").
public struct PastedRef: Equatable, Sendable {
    public let source: SourceKind
    /// The canonical ref; for radio, the normalised stream URL.
    public let ref: String
    /// A start offset taken from `t=` (YouTube) or `#t=` (SoundCloud), if any.
    public let startSeconds: Int?

    public init(source: SourceKind, ref: String, startSeconds: Int? = nil) {
        self.source = source
        self.ref = ref
        self.startSeconds = startSeconds
    }

    /// The stream ID for non-radio refs (radio IDs are curator-chosen slugs).
    public var streamID: StreamID? { source == .radio ? nil : StreamID.make(source: source, ref: ref) }
}

/// Validates refs, rebuilds URLs from them, and turns pasted URLs into refs (DESIGN §7.1). URLs are always rebuilt
/// from the ref, so nothing a feed or a user supplies reaches yt-dlp's argv except a URL this type constructed.
public enum Canonicaliser {
    /// Checks a ref against its source's pattern and returns it unchanged (radio: the normalised URL).
    public static func canonicalRef(_ ref: String, for source: SourceKind) throws(CanonicalError) -> String {
        switch source {
        case .youtube:
            guard isYouTubeVideoID(ref) else { throw .invalidRef(source, ref) }
        case .youtubeLive:
            guard isYouTubeHandle(ref) || isYouTubeChannelID(ref) else { throw .invalidRef(source, ref) }
        case .soundcloud:
            guard ref.wholeMatch(of: #/[a-z0-9_-]+\/[a-z0-9_-]+/#) != nil else { throw .invalidRef(source, ref) }
        case .mixcloud:
            guard ref.wholeMatch(of: #/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+/#) != nil else { throw .invalidRef(source, ref) }
        case .radio:
            return try RadioURLPolicy.validate(ref).absoluteString
        }
        return ref
    }

    /// The URL handed to yt-dlp or mpv, rebuilt from a ref. Nil if the ref is invalid.
    public static func url(source: SourceKind, ref: String) -> URL? {
        guard let ref = try? canonicalRef(ref, for: source) else { return nil }
        switch source {
        case .youtube: return URL(string: "https://www.youtube.com/watch?v=\(ref)")
        case .youtubeLive:
            return isYouTubeHandle(ref)
                ? URL(string: "https://www.youtube.com/\(ref)/live")
                : URL(string: "https://www.youtube.com/channel/\(ref)/live")
        case .soundcloud: return URL(string: "https://soundcloud.com/\(ref)")
        case .mixcloud: return URL(string: "https://www.mixcloud.com/\(ref)/")
        case .radio: return URL(string: ref)
        }
    }

    /// Radio IDs: `radio:<slug>`, lower-case words joined by hyphens, at most 64 characters.
    public static func isValidRadioSlug(_ s: String) -> Bool {
        s.count <= 64 && s.wholeMatch(of: #/[a-z0-9]+(-[a-z0-9]+)*/#) != nil
    }

    static func isYouTubeVideoID(_ s: String) -> Bool { s.wholeMatch(of: #/[A-Za-z0-9_-]{11}/#) != nil }
    static func isYouTubeHandle(_ s: String) -> Bool { s.wholeMatch(of: #/@[A-Za-z0-9._-]{3,30}/#) != nil }
    static func isYouTubeChannelID(_ s: String) -> Bool { s.wholeMatch(of: #/UC[A-Za-z0-9_-]{22}/#) != nil }

    // MARK: Pasted URLs

    static let youTubeHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"]
    static let soundCloudHosts: Set<String> = ["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com"]
    static let mixcloudHosts: Set<String> = ["mixcloud.com", "www.mixcloud.com", "m.mixcloud.com"]
    /// SoundCloud second path components that are listings, not tracks.
    static let soundCloudReserved: Set<String> = [
        "sets", "tracks", "likes", "reposts", "albums", "popular-tracks", "followers", "following", "comments",
        "spotlight", "toptracks",
    ]
    /// Mixcloud first path components that are site pages, and second ones that are listings, not shows.
    static let mixcloudReservedUsers: Set<String> = [
        "discover", "upload", "live", "select", "categories", "search", "settings", "dashboard", "developers",
        "about", "pro", "premium", "tag", "player", "widget", "oauth",
    ]
    static let mixcloudReservedSlugs: Set<String> = [
        "uploads", "favorites", "listens", "followers", "following", "playlists", "stream", "posts", "reposts",
        "activity", "shows", "hosts", "followers-of",
    ]

    /// Parses a URL a user pasted (Eject / ⌘L). Platform URLs become refs; anything else must pass the radio rules.
    public static func parse(_ input: String) throws(CanonicalError) -> PastedRef {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048, !containsUnsafeCharacters(trimmed) else { throw .malformedURL }
        let text = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let c = URLComponents(string: text), let rawScheme = c.scheme else { throw .malformedURL }
        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else { throw .unsupportedScheme(scheme) }
        guard c.percentEncodedUser == nil, c.percentEncodedPassword == nil else { throw .userinfo }
        guard var host = c.percentEncodedHost?.lowercased(), !host.isEmpty else { throw .malformedURL }
        if host.hasSuffix(".") { host.removeLast() }   // `youtube.com.` is still YouTube
        let path = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        if youTubeHosts.contains(host) || host == "youtu.be" {
            try requireDefaultPort(c)
            return try parseYouTube(host: host, path: path, query: c.queryItems ?? [])
        }
        if soundCloudHosts.contains(host) {
            try requireDefaultPort(c)
            guard path.count == 2, !soundCloudReserved.contains(path[1].lowercased()) else { throw .unrecognisedURL }
            let ref = path.joined(separator: "/").lowercased()
            return PastedRef(source: .soundcloud, ref: try canonicalRef(ref, for: .soundcloud),
                             startSeconds: c.fragment.flatMap(soundCloudFragmentSeconds))
        }
        if mixcloudHosts.contains(host) {
            try requireDefaultPort(c)
            guard path.count == 2, !mixcloudReservedUsers.contains(path[0].lowercased()),
                  !mixcloudReservedSlugs.contains(path[1].lowercased()) else { throw .unrecognisedURL }
            return PastedRef(source: .mixcloud, ref: try canonicalRef(path.joined(separator: "/"), for: .mixcloud))
        }
        if host.hasSuffix(".youtube.com") || host.hasSuffix(".soundcloud.com") || host.hasSuffix(".mixcloud.com") {
            throw .unrecognisedURL
        }
        return PastedRef(source: .radio, ref: try RadioURLPolicy.validate(text).absoluteString)
    }

    private static func parseYouTube(host: String, path: [String],
                                     query: [URLQueryItem]) throws(CanonicalError) -> PastedRef {
        let start = query.first(where: { $0.name == "t" || $0.name == "start" })?.value.flatMap(youTubeSeconds)
        func video(_ id: String) throws(CanonicalError) -> PastedRef {
            guard isYouTubeVideoID(id) else { throw .invalidRef(.youtube, id) }
            return PastedRef(source: .youtube, ref: id, startSeconds: start)
        }
        if host == "youtu.be" {
            guard path.count == 1 else { throw .unrecognisedURL }
            return try video(path[0])
        }
        switch path.count {
        case 1 where path[0] == "watch":
            guard let v = query.first(where: { $0.name == "v" })?.value else { throw .unrecognisedURL }
            return try video(v)
        case 1 where path[0].hasPrefix("@"), 2 where path[0].hasPrefix("@") && path[1] == "live":
            guard isYouTubeHandle(path[0]) else { throw .invalidRef(.youtubeLive, path[0]) }
            return PastedRef(source: .youtubeLive, ref: path[0])
        case 2 where ["live", "embed", "shorts", "v"].contains(path[0]):
            return try video(path[1])
        case 2 where path[0] == "channel", 3 where path[0] == "channel" && path[2] == "live":
            guard isYouTubeChannelID(path[1]) else { throw .invalidRef(.youtubeLive, path[1]) }
            return PastedRef(source: .youtubeLive, ref: path[1])
        default:
            throw .unrecognisedURL
        }
    }

    private static func requireDefaultPort(_ c: URLComponents) throws(CanonicalError) {
        if let port = c.port, port != 443, port != 80 { throw .invalidPort(port) }
    }

    /// Whitespace, control characters and backslashes never appear in a URL worth accepting; refusing them up
    /// front avoids parser differentials between Foundation, yt-dlp and FFmpeg.
    static func containsUnsafeCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            u.value < 0x21 || u.value == 0x7F || (0x80...0x9F).contains(u.value) || u == "\\"
                || CharacterSet.whitespacesAndNewlines.contains(u)
        }
    }

    /// `90`, `90s`, `1m30s`, `1h2m3s`.
    static func youTubeSeconds(_ s: String) -> Int? {
        if let n = Int(s), n >= 0 { return n }
        guard let m = s.wholeMatch(of: #/(?:([0-9]+)h)?(?:([0-9]+)m)?(?:([0-9]+)s)?/#), !s.isEmpty else { return nil }
        let h = m.1.flatMap { Int($0) } ?? 0, mi = m.2.flatMap { Int($0) } ?? 0, se = m.3.flatMap { Int($0) } ?? 0
        return h * 3600 + mi * 60 + se
    }

    /// SoundCloud's `#t=1:30` or `#t=1:02:03`.
    static func soundCloudFragmentSeconds(_ fragment: String) -> Int? {
        guard fragment.hasPrefix("t=") else { return nil }
        let parts = fragment.dropFirst(2).split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }
}
