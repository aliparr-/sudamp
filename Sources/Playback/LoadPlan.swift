// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation
import MPV
import Resolver

/// Per-file mpv options for a stream (DESIGN §5.2 "Per file"): yt-dlp's headers and user agent, the feed title, the
/// system proxy, and for progressive HTTP the ranged-request size yt-dlp reports (`request_size` =
/// `downloader_options.http_chunk_size`, like mpv's ytdl_hook; YouTube throttles unbounded ranges to 32 KiB/s) plus
/// reconnects. HLS needs neither. Radio gets `reconnect_streamed=1` only (E1: the progressive options slowed radio
/// to 2.5 s).
nonisolated public enum LoadPlan {
    public static func options(for stream: ResolvedStream, title: String?, proxy: URL?, start: Double? = nil)
        -> LoadFileOptions {
        var options: LoadFileOptions
        if stream.isHLS {
            options = LoadFileOptions()
        } else if let chunk = stream.httpChunkSize, chunk > 0 {
            options = .progressive(requestSize: chunk)
        } else {
            options = LoadFileOptions(lavf: [LavfOption("reconnect", "1"), LavfOption("reconnect_streamed", "1"),
                                             LavfOption("reconnect_delay_max", "10")])
        }
        options.httpHeaders = stream.httpHeaders
        options.userAgent = stream.userAgent
        options.mediaTitle = title
        options.start = start
        options.httpProxy = mpvProxy(proxy)
        options.extra += cacheBounds(live: stream.isLive) + (stream.isHLS ? hlsExperiment : []) + loadExperiment
        return options
    }

    /// The demuxer cache's bounds (PLAN M6 soak, measured in docs/spikes/M6.md):
    /// - forward: `cache-secs=30`. With `cache=yes`, mpv's `cache-secs` (default: practically unlimited) overrides
    ///   `demuxer-readahead-secs=30`, so a VOD was read ahead up to `demuxer-max-bytes` (64 MiB): a whole Mixcloud
    ///   mix, ~120 MB of footprint within seconds of every pick. 30 s is what DESIGN §5.2's readahead meant.
    /// - back: played packets are kept for backward seeks, by default up to 50 MiB *plus* whatever the forward cache
    ///   doesn't use (`demuxer-donate-buffer=yes`), so a live station's footprint grew ~3 MB a minute until the next
    ///   file. Radio and live can't seek (DESIGN §3) and keep 1 MiB; a VOD keeps 8 MiB so seeking back a little stays
    ///   instant.
    static func cacheBounds(live: Bool) -> [MPVOption] {
        [MPVOption("cache-secs", "30"), MPVOption("demuxer-donate-buffer", "no"),
         MPVOption("demuxer-max-back-bytes", live ? "1MiB" : "8MiB")]
    }

    /// Debug-only experiment knobs (PLAN M6 performance items): `SUDAMP_HLS_OPTS` (HLS loads) and `SUDAMP_LOAD_OPTS`
    /// (every load), each `name=value;name=value`, add per-file mpv options so they can be A/B-measured through the
    /// real path. Release builds ignore them.
    static let hlsExperiment = experiment("SUDAMP_HLS_OPTS")
    static let loadExperiment = experiment("SUDAMP_LOAD_OPTS")

    private static func experiment(_ name: String) -> [MPVOption] {
        #if DEBUG
        let raw = ProcessInfo.processInfo.environment[name] ?? ""
        return raw.split(separator: ";").compactMap { item in
            let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? MPVOption(kv[0], kv[1]) : nil
        }
        #else
        return []
        #endif
    }

    public static func radio(title: String?, proxy: URL?) -> LoadFileOptions {
        var options = LoadFileOptions.radio()
        options.mediaTitle = title
        options.httpProxy = mpvProxy(proxy)
        options.extra += cacheBounds(live: true) + loadExperiment
        return options
    }

    /// mpv's `http-proxy` takes `http://host:port` only.
    static func mpvProxy(_ proxy: URL?) -> String? {
        guard let proxy, proxy.scheme?.lowercased() == "http", proxy.host != nil else { return nil }
        return proxy.absoluteString
    }

    /// `CREATOR - TITLE`, the marquee and `force-media-title` form.
    public static func displayTitle(_ s: StreamRef) -> String { "\(s.creator) - \(s.title)" }
}
