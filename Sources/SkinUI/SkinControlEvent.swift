// SPDX-License-Identifier: GPL-3.0-or-later
// Everything a user can do to the skinned windows, as plain values (DESIGN §3, §8). SkinUI never acts on the
// player itself: it reports SkinControlEvents and draws the SkinPlayerState it is given.

import CoreGraphics
import SkinKit

/// The three classic windows.
nonisolated public enum SkinWindowRole: String, CaseIterable, Codable, Sendable, CustomStringConvertible {
    case main, equalizer, playlist

    /// The composer window drawn for this role, given its shade state. The playlist has no shade frame in v1.
    public func kind(shaded: Bool) -> WindowKind {
        switch self {
        case .main: return shaded ? .shade : .main
        case .equalizer: return shaded ? .eqShade : .eq
        case .playlist: return .playlist
        }
    }

    /// Whether SkinKit can draw a shaded form of this window.
    public var supportsShade: Bool { self != .playlist }

    /// The window title used for the Window menu, Mission Control and accessibility.
    public var title: String {
        switch self {
        case .main: return "sudamp"
        case .equalizer: return "Equalizer"
        case .playlist: return "Playlist"
        }
    }

    public var description: String { rawValue }
}

/// The five clutter-bar buttons left of the main window's display (Winamp's O, A, I, D, V).
nonisolated public enum ClutterButton: String, CaseIterable, Codable, Sendable {
    case options = "O", alwaysOnTop = "A", info = "I", doubleSize = "D", visualizer = "V"

    init?(_ control: Control) {
        switch control {
        case .clutterO: self = .options
        case .clutterA: self = .alwaysOnTop
        case .clutterI: self = .info
        case .clutterD: self = .doubleSize
        case .clutterV: self = .visualizer
        default: return nil
        }
    }
}

/// The playlist window's bottom-bar menu buttons.
nonisolated public enum PlaylistMenuButton: String, CaseIterable, Codable, Sendable {
    case add, remove, select, misc, list
}

/// One user action on a skinned window. Screen points are AppKit global coordinates (origin bottom-left of the
/// primary display, y up), ready for `NSMenu.popUp(positioning:at:in: nil)`.
nonisolated public enum SkinControlEvent: Equatable, Sendable, CustomStringConvertible {
    // Transport (main window, shade strip and the playlist's mini transport)
    case play, pause, stop, next, previous, eject
    /// Released on the position slider: 0...1 of the track. Only sent while a duration is known (VOD).
    case seek(fraction: Double)

    // Mixer; sent continuously while dragging
    /// 0...1.
    case volume(Double)
    /// -1 (left) ... 1 (right); values within ±0.25 snap to the centre, as Webamp does.
    case balance(Double)

    // Equalizer
    /// Band 0...9 (60 Hz ... 16 kHz) in dB, -12...12, with EQSliderGeometry's 0 dB snap.
    case eqBand(index: Int, decibels: Double)
    case preamp(decibels: Double)
    /// The EQ window's ON button.
    case eqToggle
    case eqAuto
    /// The +12 / 0 / -12 labels beside the preamp: every band to that gain.
    case eqSetAll(decibels: Double)
    case presetsMenu(screenPoint: CGPoint)

    // Toggles
    case shuffle, `repeat`
    /// Main window's PL button.
    case plToggle
    /// Main window's EQ button.
    case eqWindowToggle
    /// Click on the time display (elapsed ↔ remaining).
    case timeModeToggle
    /// Click on the visualiser (spectrum → scope → off).
    case visualizerModeToggle
    case clutter(ClutterButton, screenPoint: CGPoint)
    case about

    // Menu anchors (DESIGN §3: the genre dropdown opens from all of these)
    /// A click on the marquee that moved less than 3 points; a longer drag scrubs the title instead.
    case marqueeClick(screenPoint: CGPoint)
    case optionsMenu(screenPoint: CGPoint)
    case contextMenu(screenPoint: CGPoint)
    case playlistMenu(PlaylistMenuButton, screenPoint: CGPoint)

    // Windows
    case minimize
    case shade(SkinWindowRole)
    case close(SkinWindowRole)

    // Playlist (station list)
    case playlistRowSelected(index: Int)
    /// Double-click on a row.
    case playlistRowActivated(index: Int)
    /// The first visible row after a scrollbar drag, scroll button or wheel.
    case playlistScroll(firstRow: Int)

    /// Whether the event opens a menu at a screen point (the view shows the pressed sprite while it is open).
    public var opensMenu: Bool {
        switch self {
        case .presetsMenu, .marqueeClick, .optionsMenu, .contextMenu, .playlistMenu: return true
        case .clutter(let button, _): return button == .options || button == .visualizer
        default: return false
        }
    }

    public var description: String {
        func p(_ point: CGPoint) -> String { "@\(Int(point.x.rounded())),\(Int(point.y.rounded()))" }
        func f(_ value: Double) -> String { String(format: "%.3f", value) }
        switch self {
        case .play: return "play"
        case .pause: return "pause"
        case .stop: return "stop"
        case .next: return "next"
        case .previous: return "previous"
        case .eject: return "eject"
        case .seek(let fraction): return "seek(\(f(fraction)))"
        case .volume(let v): return "volume(\(f(v)))"
        case .balance(let b): return "balance(\(f(b)))"
        case .eqBand(let index, let db): return "eqBand(\(index), \(f(db)) dB)"
        case .preamp(let db): return "preamp(\(f(db)) dB)"
        case .eqToggle: return "eqToggle"
        case .eqAuto: return "eqAuto"
        case .eqSetAll(let db): return "eqSetAll(\(f(db)) dB)"
        case .presetsMenu(let point): return "presetsMenu\(p(point))"
        case .shuffle: return "shuffle"
        case .repeat: return "repeat"
        case .plToggle: return "plToggle"
        case .eqWindowToggle: return "eqWindowToggle"
        case .timeModeToggle: return "timeModeToggle"
        case .visualizerModeToggle: return "visualizerModeToggle"
        case .clutter(let button, let point): return "clutter(\(button.rawValue))\(p(point))"
        case .about: return "about"
        case .marqueeClick(let point): return "marqueeClick\(p(point))"
        case .optionsMenu(let point): return "optionsMenu\(p(point))"
        case .contextMenu(let point): return "contextMenu\(p(point))"
        case .playlistMenu(let button, let point): return "playlistMenu(\(button.rawValue))\(p(point))"
        case .minimize: return "minimize"
        case .shade(let role): return "shade(\(role))"
        case .close(let role): return "close(\(role))"
        case .playlistRowSelected(let index): return "playlistRowSelected(\(index))"
        case .playlistRowActivated(let index): return "playlistRowActivated(\(index))"
        case .playlistScroll(let first): return "playlistScroll(firstRow: \(first))"
        }
    }
}
