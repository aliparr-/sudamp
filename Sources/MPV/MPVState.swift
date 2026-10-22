// SPDX-License-Identifier: GPL-3.0-or-later

/// `audio-params` / `audio-out-params` as reported by mpv.
public struct AudioParams: Sendable, Codable, Equatable {
    public var format: String
    public var samplerate: Int
    public var channels: String
    public var channelCount: Int

    public init(format: String, samplerate: Int, channels: String, channelCount: Int) {
        self.format = format
        self.samplerate = samplerate
        self.channels = channels
        self.channelCount = channelCount
    }

    /// Parses mpv's node map (`format`, `samplerate`, `channels`, `channel-count`).
    public init?(node: MPVNode) {
        guard let map = node.map, let format = map["format"]?.string, let rate = map["samplerate"]?.int else { return nil }
        self.format = format
        samplerate = Int(rate)
        channels = map["channels"]?.string ?? map["hr-channels"]?.string ?? ""
        channelCount = Int(map["channel-count"]?.int ?? 0)
    }

    /// What the pull AO must be fed (DESIGN §5.3 "First file").
    public var isPullAOFormat: Bool {
        format == "floatp" && samplerate == 48000 && (channels == "stereo" || channelCount == 2)
    }
}

/// The latest values of the observed properties, kept by the event thread (no mpv call needed to read them).
public struct PlaybackSnapshot: Sendable, Codable, Equatable {
    public var pause: Bool?
    public var timePos: Double?
    public var duration: Double?
    public var seekable: Bool?
    public var mediaTitle: String?
    public var metadata: [String: String] = [:]
    public var audioParams: AudioParams?
    public var audioOutParams: AudioParams?
    public var audioBitrate: Double?
    public var pausedForCache: Bool?
    public var idleActive: Bool?
    public var filesLoaded = 0
    public var playbackRestarts = 0
    public var lastEndFile: MPVEndFile?

    public init() {}

    /// The ICY stream title (radio), if any.
    public var icyTitle: String? { metadata["icy-title"] }

    mutating func apply(property name: String, value: MPVNode) {
        switch name {
        case "pause": pause = value.bool
        case "time-pos": timePos = value.double
        case "duration": duration = value.double
        case "seekable": seekable = value.bool
        case "media-title": mediaTitle = value.string
        case "metadata":
            var out: [String: String] = [:]
            for (k, v) in value.map ?? [:] { if let s = v.string { out[k.lowercased()] = s } }
            metadata = out
        case "audio-params": audioParams = AudioParams(node: value)
        case "audio-out-params": audioOutParams = AudioParams(node: value)
        case "audio-bitrate": audioBitrate = value.double
        case "paused-for-cache": pausedForCache = value.bool
        case "idle-active": idleActive = value.bool
        default: break
        }
    }
}

/// Runtime engine guards (DESIGN §5.3). A failure is logged, shows `AUDIO ENGINE ERROR` and blocks playback.
public struct EngineGuards: Sendable, Codable, Equatable {
    public static let versionPrefix = "mpv v0.41."

    public var mpvVersion: String?
    public var aoInitCount: Int64
    public var aoErrorCount: Int64
    public var audioOutParams: AudioParams?

    public init(mpvVersion: String?, aoInitCount: Int64, aoErrorCount: Int64, audioOutParams: AudioParams?) {
        self.mpvVersion = mpvVersion
        self.aoInitCount = aoInitCount
        self.aoErrorCount = aoErrorCount
        self.audioOutParams = audioOutParams
    }

    /// Startup: the linked libmpv is the one the AO was compiled against.
    public var versionOK: Bool { mpvVersion?.hasPrefix(Self.versionPrefix) ?? false }
    /// First file: mpv opened our AO and feeds it floatp/48000/stereo.
    public var firstFileOK: Bool { aoInitCount > 0 && (audioOutParams?.isPullAOFormat ?? false) }
    /// Every read: the AO never refused a read for a format mismatch.
    public var readsOK: Bool { aoErrorCount == 0 }

    public var failures: [String] {
        var out: [String] = []
        if !versionOK { out.append("mpv-version \(mpvVersion ?? "nil") does not start with \(Self.versionPrefix)") }
        if aoInitCount <= 0 { out.append("pull AO never initialised (sudamp_ao_init_count == 0)") }
        if !(audioOutParams?.isPullAOFormat ?? false) {
            let p = audioOutParams.map { "\($0.format)/\($0.samplerate)/\($0.channels)" } ?? "nil"
            out.append("audio-out-params \(p), expected floatp/48000/stereo")
        }
        if aoErrorCount != 0 { out.append("pull AO refused \(aoErrorCount) read(s)") }
        return out
    }

    public var ok: Bool { failures.isEmpty }
}
