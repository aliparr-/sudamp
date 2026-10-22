// SPDX-License-Identifier: GPL-3.0-or-later

/// Where a stream comes from (DESIGN §7.1). Shared by Catalog, Picker, Resolver and the UI tags.
public enum SourceKind: String, Codable, Sendable, CaseIterable, Hashable {
    case youtube
    case youtubeLive = "youtube-live"
    case soundcloud
    case mixcloud
    case radio

    /// Two-letter tag shown in the Playlist window (DESIGN §3).
    public var tag: String {
        switch self {
        case .youtube, .youtubeLive: "YT"
        case .soundcloud: "SC"
        case .mixcloud: "MC"
        case .radio: "FM"
        }
    }

    /// Whether this source is resolved through yt-dlp (radio is played directly by mpv).
    public var needsResolver: Bool { self != .radio }
}
