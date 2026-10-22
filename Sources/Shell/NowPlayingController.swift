// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Core
import MediaPlayer
import Playback

/// The system's Now Playing and media keys (DESIGN §5.5): sudamp owns `MPNowPlayingInfoCenter` and
/// `MPRemoteCommandCenter`. `playbackState` follows every phase change; live streams are `IsLiveStream`; nothing is
/// suggested (`ExcludeFromSuggestions`); Next is a random pick and Previous is history; the position can be changed
/// on mixes only (DESIGN §5.5: "seek is VOD-only"). What was published is reported back for `state.json`
/// `.nowPlaying`.
final class NowPlayingController {
    private let context: AppContext
    private var published: NowPlayingInfo?
    private var publishedAt = Date.distantPast
    private var targets: [(MPRemoteCommand, Any)] = []
    private var isShutDown = false

    init(context: AppContext) {
        self.context = context
        registerCommands()
        context.observeSnapshots { [weak self] s in self?.update(s) }
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        let map: [(MPRemoteCommand, RemoteCommand)] = [
            (center.playCommand, .play), (center.pauseCommand, .pause), (center.togglePlayPauseCommand, .toggle),
            (center.stopCommand, .stop), (center.nextTrackCommand, .next), (center.previousTrackCommand, .previous),
        ]
        for (command, action) in map {
            command.isEnabled = true
            // MediaPlayer may call handlers off the main thread: the handler is nonisolated and hops (DESIGN §5.5).
            let token = command.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in self?.context.perform(action, origin: "mediaKey") }
                return .success
            }
            targets.append((command, token))
        }
        for command in [center.skipForwardCommand, center.skipBackwardCommand,
                        center.seekForwardCommand, center.seekBackwardCommand] as [MPRemoteCommand] {
            command.isEnabled = false
        }
        let position = center.changePlaybackPositionCommand
        position.isEnabled = false
        let token = position.addTarget { @Sendable [weak self] event in
            guard let seconds = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in self?.context.controller.seek(toSeconds: seconds) }
            return .success
        }
        targets.append((position, token))
    }

    /// Drops the command targets and clears Now Playing (quit path).
    func shutdown() {
        isShutDown = true
        for (command, token) in targets { command.removeTarget(token) }
        targets = []
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    private func update(_ s: PlayerSnapshot) {
        guard !isShutDown else { return }
        let seekable = MPRemoteCommandCenter.shared().changePlaybackPositionCommand
        if seekable.isEnabled != s.canSeek { seekable.isEnabled = s.canSeek }
        let info = NowPlayingInfo.from(s)
        if let published, published.sameExceptElapsed(info) {
            // The system extrapolates elapsed time from the rate; only correct drift.
            let expected = (published.elapsed ?? 0) + (published.rate > 0 ? Date().timeIntervalSince(publishedAt) : 0)
            guard let elapsed = info.elapsed, abs(elapsed - expected) > 2 else { return }
        }
        apply(info)
    }

    private func apply(_ info: NowPlayingInfo) {
        let center = MPNowPlayingInfoCenter.default()
        if info.playbackState == .stopped, info.streamId == nil {
            center.nowPlayingInfo = nil
        } else {
            var d: [String: Any] = [
                MPNowPlayingInfoPropertyIsLiveStream: info.isLiveStream,
                MPNowPlayingInfoPropertyExcludeFromSuggestions: info.excludeFromSuggestions,
                MPNowPlayingInfoPropertyPlaybackRate: info.rate,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            ]
            if let v = info.title { d[MPMediaItemPropertyTitle] = v }
            if let v = info.artist { d[MPMediaItemPropertyArtist] = v }
            if let v = info.albumTitle { d[MPMediaItemPropertyAlbumTitle] = v }
            if let v = info.duration { d[MPMediaItemPropertyPlaybackDuration] = v }
            if let v = info.elapsed { d[MPNowPlayingInfoPropertyElapsedPlaybackTime] = v }
            center.nowPlayingInfo = d
        }
        center.playbackState = switch info.playbackState {
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        case .interrupted: .interrupted
        case .unknown: .unknown
        }
        published = info
        publishedAt = Date()
        context.controller.recordPublishedNowPlaying(info)
    }
}
