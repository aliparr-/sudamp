// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The few `debug/state.json` fields terminal checks wait on (PLAN M2 `sudamp-dev wait`).
public struct DebugStateSample: Sendable, Equatable {
    public var state: String?
    public var genre: String?
    public var streamID: String?
    public var resumed: Bool?
    public var pid: Int32?
    public var nowPlayingState: String?

    public init(state: String? = nil, genre: String? = nil, streamID: String? = nil, resumed: Bool? = nil,
                pid: Int32? = nil, nowPlayingState: String? = nil) {
        self.state = state
        self.genre = genre
        self.streamID = streamID
        self.resumed = resumed
        self.pid = pid
        self.nowPlayingState = nowPlayingState
    }

    /// Nil when `data` isn't a JSON object.
    public init?(json data: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        state = o["state"] as? String
        genre = o["genre"] as? String
        streamID = (o["stream"] as? [String: Any])?["id"] as? String
        resumed = o["resumed"] as? Bool
        pid = (o["pid"] as? NSNumber)?.int32Value
        nowPlayingState = (o["nowPlaying"] as? [String: Any])?["playbackState"] as? String
    }

    public var summary: String {
        "state=\(state ?? "-") genre=\(genre ?? "-") stream=\(streamID ?? "-") resumed=\(resumed.map(String.init) ?? "-")"
    }
}

/// What `sudamp-dev wait` waits for: every given condition must hold at once.
public struct DebugStateQuery: Sendable, Equatable {
    /// `.state` is one of these (empty: any).
    public var states: Set<String> = []
    public var genre: String?
    /// `.stream.id` exists and differs from this (a Next took effect).
    public var streamNot: String?
    public var resumed: Bool?
    public var nowPlayingState: String?

    public init(states: Set<String> = [], genre: String? = nil, streamNot: String? = nil, resumed: Bool? = nil,
                nowPlayingState: String? = nil) {
        self.states = states
        self.genre = genre
        self.streamNot = streamNot
        self.resumed = resumed
        self.nowPlayingState = nowPlayingState
    }

    public func matches(_ s: DebugStateSample) -> Bool {
        if !states.isEmpty, !(s.state.map(states.contains) ?? false) { return false }
        if let genre, s.genre != genre { return false }
        if let streamNot, s.streamID == nil || s.streamID == streamNot { return false }
        if let resumed, s.resumed != resumed { return false }
        if let nowPlayingState, s.nowPlayingState != nowPlayingState { return false }
        return true
    }

    /// Polls `file` every `interval` until a sample matches or `timeout` passes. Returns the matching sample, or nil
    /// with the last one read.
    public func wait(file: URL, timeout: TimeInterval, interval: TimeInterval = 0.05) async
        -> (matched: DebugStateSample?, last: DebugStateSample?) {
        let deadline = Date().addingTimeInterval(timeout)
        var last: DebugStateSample?
        while true {
            if let data = try? Data(contentsOf: file), let s = DebugStateSample(json: data) {
                last = s
                if matches(s) { return (s, s) }
            }
            if Date() >= deadline { return (nil, last) }
            try? await Task.sleep(for: .seconds(interval))
        }
    }
}
