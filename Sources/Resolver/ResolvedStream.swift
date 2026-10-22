// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation

/// A playable media URL and what mpv needs to open it (DESIGN §6.3 "fields used"). Times are Unix seconds so
/// the JSON form (`sudamp-dev resolve --save`) reads the same with any decoder date strategy and with `jq`.
public struct ResolvedStream: Sendable, Codable, Equatable {
    public var source: SourceKind
    public var tier: Int
    /// Media URL (progressive file or HLS manifest).
    public var url: URL
    /// yt-dlp's `http_headers` for the chosen format, including `User-Agent`; mpv gets them as-is.
    public var httpHeaders: [String: String]
    public var userAgent: String?
    /// yt-dlp protocol: `https`, `m3u8_native`, `http_dash_segments`, …
    public var `protocol`: String?
    public var formatID: String?
    public var ext: String?
    public var acodec: String?
    /// Average audio bitrate, kbit/s.
    public var abr: Double?
    /// `downloader_options.http_chunk_size` → mpv `stream-lavf-o=request_size` (DESIGN §5.2).
    public var httpChunkSize: Int?
    /// Never load before this (pre-roll ad wait; equals "now" without ads).
    public var availableAt: Double?
    /// From the URL's `expire`/`expires` (query or `/expire/<t>/` path segment); nil when absent.
    public var expiresAt: Double?
    public var resolvedAt: Double
    public var duration: Double?
    /// `is_live`, `not_live`, `was_live`, `post_live`, `is_upcoming`.
    public var liveStatus: String?
    public var title: String?
    public var uploader: String?
    public var webpageURL: URL?
    public var thumbnail: URL?
    public var id: String?

    public var isLive: Bool { liveStatus == "is_live" }
    public var isHLS: Bool { (`protocol` ?? "").hasPrefix("m3u8") || url.path.hasSuffix(".m3u8") }

    /// Seconds to wait before loading, relative to `now`.
    public func wait(now: Date) -> TimeInterval { max(0, (availableAt ?? 0) - now.timeIntervalSince1970) }
}

public enum ResolvedStreamError: Error, Sendable, Equatable {
    case notJSON
    case noMediaURL
}

extension ResolvedStream {
    /// Builds from yt-dlp `-J` output. With a single-format `-f`, the chosen format's fields are merged into the
    /// top level; a merged selection (`requested_formats`) contributes its first audio-bearing format.
    public static func parse(json data: Data, source: SourceKind, tier: Int, now: Date) throws -> ResolvedStream {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ResolvedStreamError.notJSON
        }
        var format = root
        if root["url"] == nil, let requested = root["requested_formats"] as? [[String: Any]] {
            format = requested.first { ($0["acodec"] as? String).map { $0 != "none" } ?? false } ?? requested.first ?? [:]
        }
        guard let urlString = format["url"] as? String, let url = URL(string: urlString) else {
            throw ResolvedStreamError.noMediaURL
        }
        var headers: [String: String] = [:]
        for (k, v) in (format["http_headers"] as? [String: Any]) ?? [:] {
            if let s = v as? String { headers[k] = s }
        }
        let downloader = format["downloader_options"] as? [String: Any]
        return ResolvedStream(
            source: source, tier: tier, url: url, httpHeaders: headers,
            userAgent: headers.first { $0.key.lowercased() == "user-agent" }?.value,
            protocol: format["protocol"] as? String,
            formatID: format["format_id"] as? String,
            ext: format["ext"] as? String,
            acodec: format["acodec"] as? String,
            abr: number(format["abr"]),
            httpChunkSize: number(downloader?["http_chunk_size"]).map { Int($0) },
            availableAt: number(format["available_at"]) ?? number(root["available_at"]),
            expiresAt: expiry(of: url),
            resolvedAt: now.timeIntervalSince1970,
            duration: number(root["duration"]),
            liveStatus: root["live_status"] as? String,
            title: root["title"] as? String,
            uploader: (root["uploader"] as? String) ?? (root["channel"] as? String) ?? (root["uploader_id"] as? String),
            webpageURL: (root["webpage_url"] as? String).flatMap(URL.init(string:)),
            thumbnail: (root["thumbnail"] as? String).flatMap(URL.init(string:)),
            id: root["id"] as? String)
    }

    /// `expire=`/`expires=` in the query (YouTube progressive, SoundCloud) or `/expire/<t>/` in the path
    /// (YouTube HLS manifests). Values that aren't plausible Unix times are ignored.
    public static func expiry(of url: URL) -> Double? {
        var candidates: [String] = []
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            candidates += items.filter { $0.name == "expire" || $0.name == "expires" }.compactMap(\.value)
        }
        let parts = url.path.split(separator: "/")
        if let i = parts.firstIndex(where: { $0 == "expire" || $0 == "expires" }), i + 1 < parts.count {
            candidates.append(String(parts[i + 1]))
        }
        return candidates.compactMap(Double.init).first { $0 > 1_000_000_000 && $0 < 100_000_000_000 }
    }

    /// HTTPS on an allowlisted DNS suffix (DESIGN §6.3).
    public static func isAllowedMediaHost(_ url: URL, suffixes: [String]) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.user == nil else { return false }
        return suffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func number(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }
}
