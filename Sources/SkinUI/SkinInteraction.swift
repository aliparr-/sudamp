// SPDX-License-Identifier: GPL-3.0-or-later
// The pointer state machine behind every skinned window, pure so it is tested without windows (DESIGN §8.1,
// §3). SkinKit's Layout.hitTest names the control under the pointer; this decides what that means:
//
// - buttons show their pressed sprite while the pointer stays inside and act on release inside;
// - menu buttons (options, EQ presets, playlist menus) act on press, as native pop-up buttons do;
// - sliders follow the pointer (volume, balance, EQ bands, preamp, playlist scrollbar send values while
//   dragging; the position slider previews and seeks on release, and only when a duration is known);
// - the marquee is a click when the pointer moved less than 3 points, otherwise a drag scrubs the title;
// - the title bar and empty background drag the window (WindowManager moves the docked cluster), and a
//   double-click on the title bar toggles shade;
// - a right-click (or control-click) anywhere asks for the context menu.

import CoreGraphics
import SkinKit

/// One pointer sample.
nonisolated public struct SkinPointer: Equatable, Sendable {
    /// Fractional skin pixels from the window's top-left corner (outside the window while dragging out).
    public var skin: CGPoint
    /// AppKit global screen coordinates (y up).
    public var screen: CGPoint
    public var clickCount: Int

    public init(skin: CGPoint, screen: CGPoint, clickCount: Int = 1) {
        self.skin = skin
        self.screen = screen
        self.clickCount = clickCount
    }
}

/// What the view does with a pointer sample.
nonisolated public enum SkinInteractionOutput: Equatable, Sendable {
    case event(SkinControlEvent)
    case beginWindowDrag(screen: CGPoint)
    case dragWindow(screen: CGPoint)
    case endWindowDrag
    /// Marquee scrubbing started or ended (the view pauses and later resumes the scroll clock).
    case marqueeScrubBegan
    case marqueeScrubEnded
}

/// How a control reacts to the pointer in a given window.
nonisolated public enum ControlBehaviour: Equatable, Sendable {
    /// Acts on release inside.
    case button
    /// Acts on press (opens a menu).
    case menu
    case slider(SliderTrack)
    case marquee
    case rows
    /// Drags the window.
    case drag
    /// Takes the click and does nothing (e.g. the position slider of a live stream).
    case inert
}

nonisolated public struct SkinInteraction: Equatable, Sendable {
    public enum Gesture: Equatable, Sendable {
        case button(Control, inside: Bool)
        /// A menu button held down while its menu is open.
        case held(Control)
        case slider(Control, grab: Double)
        case marquee(startScreen: CGPoint, startSkinX: Double, baseDrag: Int, scrubbing: Bool)
        case windowDrag
    }

    /// Movement (in points) below which a marquee press is a click (DESIGN §3: under 3 px).
    public static let clickSlop: Double = 3

    public let role: SkinWindowRole
    public private(set) var gesture: Gesture?
    /// Slider values shown until the app's state catches up.
    public var overrides = SliderOverrides()
    /// Pixels the user has scrubbed the marquee by (WindowState.marqueeDrag).
    public var marqueeDrag = 0

    public init(role: SkinWindowRole) {
        self.role = role
    }

    /// The control drawn pressed.
    public var pressed: Control? {
        switch gesture {
        case .button(let control, true)?, .held(let control)?, .slider(let control, _)?: return control
        default: return nil
        }
    }

    public var isScrubbingMarquee: Bool {
        if case .marquee(_, _, _, true)? = gesture { return true }
        return false
    }

    /// The control currently being dragged (its override must survive state updates).
    public var activeSlider: Control? {
        if case .slider(let control, _)? = gesture { return control }
        return nil
    }

    // MARK: Classification

    public static func behaviour(of control: Control, in kind: WindowKind, state: WindowState) -> ControlBehaviour {
        if let track = SliderTrack.track(for: control, in: kind) {
            if control == .position {
                let seekable = state.playback != .stopped && state.duration != nil && state.effectivePosition != nil
                return seekable ? .slider(track) : .inert
            }
            return .slider(track)
        }
        switch control {
        case .titleBar, .eqGraph, .playlistRunningTime, .playlistResize: return .drag
        case .options, .eqPresets, .playlistAdd, .playlistRemove, .playlistSelect, .playlistMisc, .playlistListMenu:
            return .menu
        case .marquee: return kind == .main ? .marquee : .drag
        case .playlistList: return .rows
        default: return .button
        }
    }

    /// The event a button sends when released inside (nil: none).
    public static func buttonEvent(_ control: Control, role: SkinWindowRole, kind: WindowKind, state: WindowState,
                                   screen: CGPoint) -> SkinControlEvent? {
        if let clutter = ClutterButton(control) { return .clutter(clutter, screenPoint: screen) }
        switch control {
        case .minimize: return .minimize
        case .shade: return .shade(role)
        case .close: return .close(role)
        case .time, .playlistMiniTime: return .timeModeToggle
        case .visualizer: return .visualizerModeToggle
        case .eqToggle: return .eqWindowToggle
        case .playlistToggle: return .plToggle
        case .previous, .playlistPrevious: return .previous
        case .play, .playlistPlay: return .play
        case .pause, .playlistPause: return .pause
        case .stop, .playlistStop: return .stop
        case .next, .playlistNext: return .next
        case .eject, .playlistEject: return .eject
        case .shuffle: return .shuffle
        case .repeat: return .repeat
        case .about: return .about
        case .eqOn: return .eqToggle
        case .eqAuto: return .eqAuto
        case .eqMax: return .eqSetAll(decibels: 12)
        case .eqZero: return .eqSetAll(decibels: 0)
        case .eqMin: return .eqSetAll(decibels: -12)
        case .playlistScrollUp, .playlistScrollDown:
            let rows = state.playlist.rows.count
            let first = state.playlist.firstRow + (control == .playlistScrollUp ? -1 : 1)
            let clamped = min(max(first, 0), SkinStateMapper.maxFirstRow(rowCount: rows))
            return clamped == state.playlist.firstRow ? nil : .playlistScroll(firstRow: clamped)
        default: return nil
        }
    }

    public static func menuEvent(_ control: Control, screen: CGPoint) -> SkinControlEvent? {
        switch control {
        case .options: return .optionsMenu(screenPoint: screen)
        case .eqPresets: return .presetsMenu(screenPoint: screen)
        case .playlistAdd: return .playlistMenu(.add, screenPoint: screen)
        case .playlistRemove: return .playlistMenu(.remove, screenPoint: screen)
        case .playlistSelect: return .playlistMenu(.select, screenPoint: screen)
        case .playlistMisc: return .playlistMenu(.misc, screenPoint: screen)
        case .playlistListMenu: return .playlistMenu(.list, screenPoint: screen)
        default: return nil
        }
    }

    /// The playlist row under a skin point, if it shows a row.
    public static func rowIndex(at skin: CGPoint, state: WindowState) -> Int? {
        let list = PlaylistLayout.list
        let pixel = SkinScale.skinPixel(skin)
        guard list.contains(pixel), pixel.y >= PlaylistLayout.firstRowY else { return nil }
        let visible = (pixel.y - PlaylistLayout.firstRowY) / PlaylistLayout.rowHeight
        guard visible < PlaylistLayout.visibleRows else { return nil }
        let index = state.playlist.firstRow + visible
        return index < state.playlist.rows.count ? index : nil
    }

    // MARK: Pointer input

    public mutating func mouseDown(_ p: SkinPointer, kind: WindowKind, state: WindowState) -> [SkinInteractionOutput] {
        gesture = nil
        let control = Layout.hitTest(kind, SkinScale.skinPixel(p.skin))
        guard let control else {
            gesture = .windowDrag
            return [.beginWindowDrag(screen: p.screen)]
        }
        switch Self.behaviour(of: control, in: kind, state: state) {
        case .drag:
            if control == .titleBar, p.clickCount >= 2 { return [.event(.shade(role))] }
            gesture = .windowDrag
            return [.beginWindowDrag(screen: p.screen)]
        case .button:
            gesture = .button(control, inside: true)
            return []
        case .menu:
            gesture = .held(control)
            return Self.menuEvent(control, screen: p.screen).map { [.event($0)] } ?? []
        case .slider(let track):
            let grab = track.grabOffset(at: track.coordinate(p.skin), currentFraction: currentFraction(control, state: state))
            gesture = .slider(control, grab: grab)
            return slide(control, track: track, fraction: track.fraction(at: track.coordinate(p.skin), grab: grab),
                         kind: kind, state: state)
        case .marquee:
            gesture = .marquee(startScreen: p.screen, startSkinX: Double(p.skin.x), baseDrag: marqueeDrag, scrubbing: false)
            return []
        case .rows:
            guard let index = Self.rowIndex(at: p.skin, state: state) else { return [] }
            return [.event(p.clickCount >= 2 ? .playlistRowActivated(index: index) : .playlistRowSelected(index: index))]
        case .inert:
            return []
        }
    }

    public mutating func mouseDragged(_ p: SkinPointer, kind: WindowKind, state: WindowState) -> [SkinInteractionOutput] {
        switch gesture {
        case .windowDrag?:
            return [.dragWindow(screen: p.screen)]
        case .button(let control, _)?:
            let inside = Layout.rect(of: control, in: kind)?.contains(SkinScale.skinPixel(p.skin)) ?? false
            gesture = .button(control, inside: inside)
            return []
        case .slider(let control, let grab)?:
            guard let track = SliderTrack.track(for: control, in: kind) else { return [] }
            return slide(control, track: track, fraction: track.fraction(at: track.coordinate(p.skin), grab: grab),
                         kind: kind, state: state)
        case .marquee(let start, let startX, let base, let scrubbing)?:
            var outputs: [SkinInteractionOutput] = []
            var nowScrubbing = scrubbing
            if !scrubbing, hypot(Double(p.screen.x - start.x), Double(p.screen.y - start.y)) >= Self.clickSlop {
                nowScrubbing = true
                outputs.append(.marqueeScrubBegan)
            }
            if nowScrubbing {
                // Text follows the pointer: dragging right shows earlier text (Webamp: offset = -diff).
                marqueeDrag = base - Int((Double(p.skin.x) - startX).rounded())
            }
            gesture = .marquee(startScreen: start, startSkinX: startX, baseDrag: base, scrubbing: nowScrubbing)
            return outputs
        case .held?, nil:
            return []
        }
    }

    public mutating func mouseUp(_ p: SkinPointer, kind: WindowKind, state: WindowState) -> [SkinInteractionOutput] {
        defer { gesture = nil }
        switch gesture {
        case .windowDrag?:
            return [.endWindowDrag]
        case .button(let control, _)?:
            let inside = Layout.rect(of: control, in: kind)?.contains(SkinScale.skinPixel(p.skin)) ?? false
            guard inside, let event = Self.buttonEvent(control, role: role, kind: kind, state: state, screen: p.screen)
            else { return [] }
            return [.event(event)]
        case .slider(let control, let grab)?:
            if control == .playlistScrollbar {
                // The thumb settles on the row it scrolled to; the view's first row is authoritative again.
                overrides.scroll = nil
                return []
            }
            guard control == .position, let track = SliderTrack.track(for: control, in: kind) else { return [] }
            let fraction = track.fraction(at: track.coordinate(p.skin), grab: grab)
            overrides.position = fraction
            return [.event(.seek(fraction: fraction))]
        case .marquee(_, _, _, let scrubbing)?:
            return scrubbing ? [.marqueeScrubEnded] : [.event(.marqueeClick(screenPoint: p.screen))]
        case .held?, nil:
            return []
        }
    }

    public mutating func rightMouseDown(_ p: SkinPointer) -> [SkinInteractionOutput] {
        let ending = endGestureOutputs()
        gesture = nil
        return ending + [.event(.contextMenu(screenPoint: p.screen))]
    }

    /// Wheel steps (positive = up/away). Playlist: scrolls rows; main window and shade: volume ±2 % per step.
    public mutating func scroll(steps: Int, kind: WindowKind, state: WindowState) -> [SkinInteractionOutput] {
        guard steps != 0 else { return [] }
        switch kind {
        case .playlist:
            let maxFirst = SkinStateMapper.maxFirstRow(rowCount: state.playlist.rows.count)
            let first = min(max(state.playlist.firstRow - steps, 0), maxFirst)
            guard first != state.playlist.firstRow else { return [] }
            return [.event(.playlistScroll(firstRow: first))]
        case .main, .shade:
            let current = overrides.volume ?? Double(state.volume) / 100
            let volume = min(max(current + Double(steps) * 0.02, 0), 1)
            guard volume != current else { return [] }
            overrides.volume = volume
            return [.event(.volume(volume))]
        case .eq, .eqShade:
            return []
        }
    }

    /// Ends whatever is in progress without acting (a menu took over the mouse, the window closed, …).
    public mutating func cancel() -> [SkinInteractionOutput] {
        let ending = endGestureOutputs()
        gesture = nil
        return ending
    }

    private func endGestureOutputs() -> [SkinInteractionOutput] {
        switch gesture {
        case .windowDrag?: return [.endWindowDrag]
        case .marquee(_, _, _, true)?: return [.marqueeScrubEnded]
        default: return []
        }
    }

    // MARK: Sliders

    /// The slider's current position as drawn, 0...1 along its axis.
    func currentFraction(_ control: Control, state: WindowState) -> Double {
        switch control {
        case .volume: return Double(state.volume) / 100
        case .balance: return SliderValues.balanceFraction(Double(state.balance) / 100)
        case .position: return state.effectivePosition ?? 0
        case .preamp: return 1 - state.eq.preamp / 100
        case .playlistScrollbar: return state.playlist.scroll
        default:
            if let index = Control.bands.firstIndex(of: control), index < state.eq.bands.count {
                return 1 - state.eq.bands[index] / 100
            }
            return 0
        }
    }

    private mutating func slide(_ control: Control, track: SliderTrack, fraction: Double, kind: WindowKind,
                                state: WindowState) -> [SkinInteractionOutput] {
        switch control {
        case .volume:
            guard overrides.volume != fraction else { return [] }
            overrides.volume = fraction
            return [.event(.volume(fraction))]
        case .balance:
            let balance = SliderValues.balance(fraction: fraction)
            guard overrides.balance != balance else { return [] }
            overrides.balance = balance
            return [.event(.balance(balance))]
        case .position:
            overrides.position = fraction
            return []
        case .preamp:
            let db = SliderValues.decibels(eqFraction: fraction)
            guard overrides.preamp != db else { return [] }
            overrides.preamp = db
            return [.event(.preamp(decibels: db))]
        case .playlistScrollbar:
            let rows = state.playlist.rows.count
            let before = overrides.scroll.map { SkinStateMapper.firstRow(forScroll: $0, rowCount: rows) } ?? state.playlist.firstRow
            overrides.scroll = fraction
            let first = SkinStateMapper.firstRow(forScroll: fraction, rowCount: rows)
            return first == before ? [] : [.event(.playlistScroll(firstRow: first))]
        default:
            guard let index = Control.bands.firstIndex(of: control) else { return [] }
            let db = SliderValues.decibels(eqFraction: fraction)
            guard overrides.bands[index] != db else { return [] }
            overrides.bands[index] = db
            return [.event(.eqBand(index: index, decibels: db))]
        }
    }
}
