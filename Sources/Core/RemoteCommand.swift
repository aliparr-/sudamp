// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A `sudamp://` URL (DESIGN §3, PLAN M2): what the URL scheme, a forwarded second launch, automation scripts and
/// the menus can ask the running app to do.
///
/// Accepted forms (scheme and command are case-insensitive; a trailing slash, a query and a fragment are ignored):
/// `sudamp://genre/<id>`, `sudamp://surprise`, `sudamp://toggle`, `sudamp://play`, `sudamp://pause`,
/// `sudamp://stop`, `sudamp://next`, `sudamp://previous`, `sudamp://quit`, and a bare `sudamp://` (bring the
/// window forward). The opaque form `sudamp:next` works too. Genre ids are lower-cased, then follow the feed's rule
/// (`^[a-z0-9]+(-[a-z0-9]+)*$`, at most 32 characters); whether the genre exists is the app's business.
public enum RemoteCommand: Equatable, Sendable, CustomStringConvertible {
    case genre(String)
    case surpriseMe
    case toggle
    case play
    case pause
    case stop
    case next
    case previous
    case quit
    /// `sudamp://` with no command: activate the app.
    case show

    public static let scheme = "sudamp"

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        // `sudamp://genre/x` has host "genre" and path "/x"; the opaque `sudamp:genre/x` has no host, so read the
        // part after the scheme ourselves.
        let rest: String
        if let host = url.host(percentEncoded: false), !host.isEmpty {
            rest = host + url.path(percentEncoded: false)
        } else {
            let s = url.absoluteString
            var tail = String(s.dropFirst(Self.scheme.count + 1))
            while tail.hasPrefix("/") { tail.removeFirst() }
            if let cut = tail.firstIndex(where: { $0 == "?" || $0 == "#" }) { tail = String(tail[..<cut]) }
            rest = tail.removingPercentEncoding ?? tail
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first?.lowercased() else {
            self = .show
            return
        }
        if head == "genre" {
            guard parts.count == 2 else { return nil }
            let id = parts[1].lowercased()
            guard Self.isValidGenreID(id) else { return nil }
            self = .genre(id)
            return
        }
        guard parts.count == 1 else { return nil }
        switch head {
        case "surprise", "surprise-me": self = .surpriseMe
        case "toggle", "playpause", "play-pause": self = .toggle
        case "play": self = .play
        case "pause": self = .pause
        case "stop": self = .stop
        case "next": self = .next
        case "previous", "prev": self = .previous
        case "quit": self = .quit
        case "show": self = .show
        default: return nil
        }
    }

    /// The canonical URL for this command.
    public var url: URL {
        URL(string: "\(Self.scheme)://\(path)")!
    }

    private var path: String {
        switch self {
        case .genre(let id): "genre/\(id)"
        case .surpriseMe: "surprise"
        case .toggle: "toggle"
        case .play: "play"
        case .pause: "pause"
        case .stop: "stop"
        case .next: "next"
        case .previous: "previous"
        case .quit: "quit"
        case .show: ""
        }
    }

    public var description: String { url.absoluteString }

    /// The feed's genre id rule (Catalog's `GenreID`), repeated here because Core sits below Catalog.
    public static func isValidGenreID(_ s: String) -> Bool {
        s.count <= 32 && s.wholeMatch(of: #/[a-z0-9]+(-[a-z0-9]+)*/#) != nil
    }

    /// The `sudamp:` URLs among command-line arguments (a second launch forwards them).
    public static func urls(inArguments arguments: [String]) -> [String] {
        arguments.filter { $0.lowercased().hasPrefix("\(scheme):") }
    }
}
