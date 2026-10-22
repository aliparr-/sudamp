// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Picker
import Playback
import SkinUI

/// Where the genre menu was opened from (DESIGN §3 "One NSMenu builder"): every anchor shows the same menu.
nonisolated enum GenreMenuAnchor: String, CaseIterable, Sendable {
    /// The first launch opens it by itself, under the marquee.
    case auto
    /// A click on the marquee (under 3 px of movement).
    case marquee
    /// Main's options button (top left of the title bar).
    case options
    /// Right-click: the context menu's `Genre ▸`.
    case contextMenu
    /// The menu bar's Genre menu (⌘1–⌘9, ⌘0 Surprise Me).
    case menuBar
    case statusItem
    case dock

    /// The anchors DESIGN §3 lists (the auto-open is the marquee anchor's first-launch use).
    static let entryPoints: [GenreMenuAnchor] = [.marquee, .options, .contextMenu, .menuBar, .statusItem, .dock]
}

/// What a skinned-window event asks the app to do. `SkinActions.action(for:…)` is pure, so the event mapping is
/// tested without windows; `SkinnedPlayerUI` executes the result.
nonisolated enum SkinAction: Equatable, Sendable {
    case play, pause, resume, stop, next, previous, retry
    case seek(fraction: Double)
    /// 0...100.
    case volume(Double)
    case balance(Double)
    case eqBand(index: Int, decibels: Double)
    case preamp(decibels: Double)
    case eqToggle, eqAuto
    case eqSetAll(decibels: Double)
    case genreMenu(GenreMenuAnchor)
    case contextMenu(CGPoint)
    case presetsMenu(CGPoint)
    case visualizerMenu(CGPoint)
    case streamInfoMenu(CGPoint)
    case playlistMenu(PlaylistMenuButton, CGPoint)
    case toggleShuffle, toggleRepeat
    /// Eject / ⌘L.
    case openStreamURL
    case playRow(Int)
    case toggleTimeDisplay, cycleVisualizer
    case about
    case quit
    /// Applied by WindowManager (shade, scale, EQ/PL windows, always on top, minimise) or by the view itself.
    case none
}

nonisolated enum SkinActions {
    /// - Parameter canPlayWithoutPick: Play has something to play (a genre, or the remembered one); otherwise
    ///   Play means "pick a genre" and opens the menu under the marquee.
    static func action(for event: SkinControlEvent, snapshot s: PlayerSnapshot, canPlayWithoutPick: Bool) -> SkinAction {
        switch event {
        case .play:
            if s.phase == .paused { return .resume }
            if s.phase == .failed { return .retry }
            if [.idle].contains(s.phase), s.genre == nil, !canPlayWithoutPick { return .genreMenu(.marquee) }
            return .play
        case .pause:
            // Winamp's pause toggles.
            switch s.phase {
            case .paused: return .resume
            case .playing: return .pause
            default: return .none
            }
        case .stop: return .stop
        case .next: return .next
        case .previous: return .previous
        case .eject: return .openStreamURL
        case .seek(let fraction): return s.canSeek ? .seek(fraction: fraction) : .none
        case .volume(let v): return .volume(min(max(v, 0), 1) * 100)
        case .balance(let b): return .balance(min(max(b, -1), 1))
        case let .eqBand(index, db): return (0..<10).contains(index) ? .eqBand(index: index, decibels: db) : .none
        case .preamp(let db): return .preamp(decibels: db)
        case .eqToggle: return .eqToggle
        case .eqAuto: return .eqAuto
        case .eqSetAll(let db): return .eqSetAll(decibels: db)
        case .presetsMenu(let p): return .presetsMenu(p)
        case .shuffle: return .toggleShuffle
        case .repeat: return .toggleRepeat
        case .timeModeToggle: return .toggleTimeDisplay
        case .visualizerModeToggle: return .cycleVisualizer
        case .clutter(.options, let p): return .contextMenu(p)
        case .clutter(.visualizer, let p): return .visualizerMenu(p)
        case .clutter(.info, let p): return .streamInfoMenu(p)
        case .clutter(.alwaysOnTop, _), .clutter(.doubleSize, _): return .none
        case .about: return .about
        case .marqueeClick:
            // DESIGN §3: "CAN'T REACH STREAMS - CLICK TO RETRY".
            return s.phase == .failed ? .retry : .genreMenu(.marquee)
        case .optionsMenu: return .genreMenu(.options)
        case .contextMenu(let p): return .contextMenu(p)
        case let .playlistMenu(button, p): return .playlistMenu(button, p)
        case .playlistRowActivated(let index): return .playRow(index)
        case .close(.main): return .quit
        case .plToggle, .eqWindowToggle, .minimize, .shade, .close, .playlistRowSelected, .playlistScroll:
            return .none
        }
    }
}
