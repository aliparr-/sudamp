// SPDX-License-Identifier: GPL-3.0-or-later

/// One `name=value` mpv option.
public struct MPVOption: Sendable, Equatable, Codable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// The global option block set before `mpv_initialize` (DESIGN §5.2).
public enum MPVOptions {
    /// Every option that loads one of mpv v0.41.0's built-in Lua scripts, verified against
    /// `player/scripting.c` `mp_load_builtin_scripts` and `options/options.c` (E1, docs/spikes/E1.md):
    /// osc.lua, ytdl_hook.lua, stats.lua, console.lua, auto_profiles.lua, select.lua, positioning.lua,
    /// commands.lua, context_menu.lua. MPVTests also cross-checks the runtime `options` list.
    public static let builtinScriptOptions = [
        "osc", "ytdl", "load-stats-overlay", "load-console", "load-auto-profiles", "load-select",
        "load-positioning", "load-commands", "load-context-menu",
    ]

    public static let defaults: [MPVOption] = [
        MPVOption("config", "no"),
        MPVOption("load-scripts", "no"),
    ] + builtinScriptOptions.map { MPVOption($0, "no") } + [
        MPVOption("vid", "no"),
        MPVOption("vo", "null"),
        MPVOption("audio-display", "no"),
        // Resolves to the linked "sudamp pull AO" (DESIGN §5.1).
        MPVOption("ao", "pcm"),
        MPVOption("audio-samplerate", "48000"),
        MPVOption("audio-channels", "stereo"),
        MPVOption("audio-buffer", "0.2"),
        MPVOption("gapless-audio", "weak"),
        MPVOption("volume", "100"),
        MPVOption("volume-max", "100"),
        MPVOption("af", ""),
        MPVOption("cache", "yes"),
        MPVOption("demuxer-max-bytes", "64MiB"),
        MPVOption("demuxer-readahead-secs", "30"),
        MPVOption("network-timeout", "15"),
        MPVOption("idle", "yes"),
        MPVOption("load-unsafe-playlists", "no"),
        MPVOption("input-media-keys", "no"),
        MPVOption("media-controls", "no"),
        MPVOption("msg-level", "all=warn"),
    ]

    /// Properties observed for the lifetime of the client (DESIGN §5.2 "Observed").
    public static let observedProperties = [
        "pause", "time-pos", "duration", "seekable", "media-title", "metadata", "audio-params",
        "audio-out-params", "audio-bitrate", "paused-for-cache", "idle-active",
    ]

    /// `defaults` with `overrides` replacing same-named entries in place; new names are appended.
    public static func merged(_ base: [MPVOption] = defaults, overrides: [MPVOption]) -> [MPVOption] {
        var out = base
        for o in overrides {
            if let i = out.firstIndex(where: { $0.name == o.name }) { out[i] = o } else { out.append(o) }
        }
        return out
    }
}

/// An FFmpeg AVOption passed through `stream-lavf-o`.
public struct LavfOption: Sendable, Equatable, Codable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

public enum LoadFileOptionsError: Error, Equatable, Sendable {
    case invalidHeaderName(String)
    case invalidValue(String)
    case invalidLavfOption(String)
}

/// Per-file options for `loadfile <url> replace -1 <options>` (DESIGN §5.2 "Per file"). Values are passed as a
/// node map of strings, which mpv parses like command-line values, so list separators are escaped here and
/// anything that could smuggle a header or option (CR, LF, NUL) is rejected.
public struct LoadFileOptions: Sendable, Equatable {
    /// yt-dlp's `http_headers`, sent as `http-header-fields` (sorted by name for determinism).
    public var httpHeaders: [String: String]
    public var userAgent: String?
    public var mediaTitle: String?
    /// Resume position in seconds (`start`).
    public var start: Double?
    /// `http://host:port` when a system proxy is set (DESIGN §6.2).
    public var httpProxy: String?
    /// `stream-lavf-o`, in order.
    public var lavf: [LavfOption]
    /// Anything else (tools only, e.g. `loop-file=inf`).
    public var extra: [MPVOption]

    public init(httpHeaders: [String: String] = [:], userAgent: String? = nil, mediaTitle: String? = nil,
                start: Double? = nil, httpProxy: String? = nil, lavf: [LavfOption] = [], extra: [MPVOption] = []) {
        self.httpHeaders = httpHeaders
        self.userAgent = userAgent
        self.mediaTitle = mediaTitle
        self.start = start
        self.httpProxy = httpProxy
        self.lavf = lavf
        self.extra = extra
    }

    /// Radio: reconnect on dropped streams.
    public static func radio() -> LoadFileOptions {
        LoadFileOptions(lavf: [LavfOption("reconnect_streamed", "1")])
    }

    /// Progressive HTTP (YouTube, Mixcloud `http`): ranged requests of `requestSize` bytes, like mpv's ytdl_hook,
    /// plus reconnects (DESIGN §5.2).
    public static func progressive(requestSize: Int) -> LoadFileOptions {
        LoadFileOptions(lavf: [
            LavfOption("request_size", String(requestSize)), LavfOption("short_seek_size", String(requestSize)),
            LavfOption("reconnect", "1"), LavfOption("reconnect_streamed", "1"),
            LavfOption("reconnect_delay_max", "10"),
        ])
    }

    /// The `options` argument of `loadfile`.
    public func optionMap() throws(LoadFileOptionsError) -> [String: String] {
        var map: [String: String] = [:]
        if !httpHeaders.isEmpty {
            var fields: [String] = []
            for name in httpHeaders.keys.sorted() {
                guard Self.isToken(name) else { throw .invalidHeaderName(name) }
                let value = httpHeaders[name]!
                try Self.checkValue(value)
                fields.append(Self.escapeListItem("\(name): \(value)"))
            }
            map["http-header-fields"] = fields.joined(separator: ",")
        }
        if let userAgent {
            try Self.checkValue(userAgent)
            map["user-agent"] = userAgent
        }
        if let mediaTitle {
            try Self.checkValue(mediaTitle)
            map["force-media-title"] = mediaTitle
        }
        if let start {
            guard start.isFinite, start >= 0 else { throw .invalidValue("start=\(start)") }
            map["start"] = String(start)
        }
        if let httpProxy {
            try Self.checkValue(httpProxy)
            guard httpProxy.hasPrefix("http://") else { throw .invalidValue(httpProxy) }
            map["http-proxy"] = httpProxy
        }
        if !lavf.isEmpty {
            var items: [String] = []
            for o in lavf {
                guard Self.isLavfKey(o.key), Self.isLavfValue(o.value) else { throw .invalidLavfOption("\(o.key)=\(o.value)") }
                items.append("\(o.key)=\(o.value)")
            }
            map["stream-lavf-o"] = items.joined(separator: ",")
        }
        for o in extra {
            try Self.checkValue(o.value)
            map[o.name] = o.value
        }
        return map
    }

    /// mpv string lists split on `,`; a backslash before the comma keeps it literal (m_option.c get_nextsep).
    static func escapeListItem(_ s: String) -> String { s.replacingOccurrences(of: ",", with: "\\,") }

    static func checkValue(_ s: String) throws(LoadFileOptionsError) {
        if s.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) { throw .invalidValue(s) }
    }

    /// RFC 9110 token characters.
    static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || "!#$%&'*+-.^_`|~".unicodeScalars.contains(c)
        }
    }

    static func isLavfKey(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "_" }
    }

    static func isLavfValue(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || "._:/-".unicodeScalars.contains(c)
        }
    }
}
