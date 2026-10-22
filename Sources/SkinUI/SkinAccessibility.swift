// SPDX-License-Identifier: GPL-3.0-or-later
// NSAccessibility for skinned windows (DESIGN §8.1: "every hotspot gets an NSAccessibility element"). Each
// SkinKit hotspot becomes an element with a role, a label, a screen frame and its action: press for buttons,
// menu buttons and the marquee, increment/decrement for sliders. Actions go through the same event path as
// clicks.

import AppKit
import SkinKit

/// One hotspot. NSAccessibilityElement is not main-actor isolated, so the overrides hop onto the main actor
/// with `assumeIsolated`: AppKit calls accessibility on the main thread.
nonisolated public final class SkinAccessibilityElement: NSAccessibilityElement {
    public let control: Control
    public let rect: IntRect
    private weak var view: SkinView?

    init(control: Control, rect: IntRect, view: SkinView, identifier: String) {
        self.control = control
        self.rect = rect
        self.view = view
        super.init()
        setAccessibilityParent(view)
        setAccessibilityRole(Self.role(for: control))
        setAccessibilityLabel(Self.label(for: control))
        setAccessibilityIdentifier(identifier)
    }

    override public func accessibilityFrame() -> NSRect {
        let view = self.view, rect = self.rect
        return MainActor.assumeIsolated { view?.screenRect(forSkinRect: rect) ?? .zero }
    }

    override public func isAccessibilityElement() -> Bool { true }

    override public func accessibilityValue() -> Any? {
        let view = self.view, control = self.control
        let value = MainActor.assumeIsolated { view?.accessibilityValue(for: control) }
        switch value {
        case .number(let n)?: return NSNumber(value: n)
        case .text(let t)?: return t
        case nil: return nil
        }
    }

    override public func accessibilityPerformPress() -> Bool {
        let view = self.view, control = self.control
        return MainActor.assumeIsolated { view?.accessibilityActivate(control) ?? false }
    }

    override public func accessibilityPerformIncrement() -> Bool {
        let view = self.view, control = self.control
        return MainActor.assumeIsolated { view?.accessibilityAdjust(control, steps: 1) ?? false }
    }

    override public func accessibilityPerformDecrement() -> Bool {
        let view = self.view, control = self.control
        return MainActor.assumeIsolated { view?.accessibilityAdjust(control, steps: -1) ?? false }
    }

    override public func accessibilityPerformShowMenu() -> Bool {
        guard Self.role(for: control) == .menuButton else { return false }
        let view = self.view, control = self.control
        return MainActor.assumeIsolated { view?.accessibilityActivate(control) ?? false }
    }

    /// A hotspot's accessibility value, as a Sendable value.
    public enum Value: Equatable, Sendable {
        case number(Double)
        case text(String)
    }

    static func role(for control: Control) -> NSAccessibility.Role {
        switch control {
        case .volume, .balance, .position, .preamp, .playlistScrollbar: return .slider
        case _ where Control.bands.contains(control): return .slider
        case .options, .eqPresets, .playlistAdd, .playlistRemove, .playlistSelect, .playlistMisc, .playlistListMenu, .marquee:
            return .menuButton
        case .shuffle, .repeat, .eqOn, .eqAuto, .eqToggle, .playlistToggle, .clutterA, .clutterD: return .checkBox
        case .time, .playlistMiniTime, .playlistRunningTime: return .button
        case .visualizer: return .button
        case .eqGraph: return .image
        case .playlistList: return .list
        case .playlistResize: return .unknown
        default: return .button
        }
    }

    static let bandNames = ["60 Hz", "170 Hz", "310 Hz", "600 Hz", "1 kHz", "3 kHz", "6 kHz", "12 kHz", "14 kHz", "16 kHz"]

    static func label(for control: Control) -> String {
        if let index = Control.bands.firstIndex(of: control) { return "Equalizer \(bandNames[index])" }
        switch control {
        case .titleBar: return "Title bar"
        case .options: return "Options menu"
        case .minimize: return "Minimize"
        case .shade: return "Window shade"
        case .close: return "Close"
        case .clutterO: return "Options"
        case .clutterA: return "Always on top"
        case .clutterI: return "Stream info"
        case .clutterD: return "Double size"
        case .clutterV: return "Visualization menu"
        case .time: return "Time display"
        case .visualizer: return "Visualizer"
        case .marquee: return "Title and genre menu"
        case .volume: return "Volume"
        case .balance: return "Balance"
        case .position: return "Seek"
        case .eqToggle: return "Equalizer window"
        case .playlistToggle: return "Playlist window"
        case .previous, .playlistPrevious: return "Previous"
        case .play, .playlistPlay: return "Play"
        case .pause, .playlistPause: return "Pause"
        case .stop, .playlistStop: return "Stop"
        case .next, .playlistNext: return "Next"
        case .eject, .playlistEject: return "Open stream URL"
        case .shuffle: return "Shuffle"
        case .repeat: return "Repeat"
        case .about: return "About sudamp"
        case .eqOn: return "Equalizer on"
        case .eqAuto: return "Equalizer auto"
        case .eqPresets: return "Equalizer presets"
        case .eqGraph: return "Equalizer curve"
        case .preamp: return "Preamp"
        case .eqMax: return "All bands +12 dB"
        case .eqZero: return "All bands 0 dB"
        case .eqMin: return "All bands -12 dB"
        case .playlistList: return "Stations"
        case .playlistScrollbar: return "Station list scroll"
        case .playlistAdd: return "Add menu"
        case .playlistRemove: return "Remove menu"
        case .playlistSelect: return "Select menu"
        case .playlistMisc: return "Miscellaneous menu"
        case .playlistListMenu: return "List menu"
        case .playlistRunningTime: return "Running time"
        case .playlistMiniTime: return "Time display"
        case .playlistResize: return "Resize"
        case .playlistScrollUp: return "Scroll up"
        case .playlistScrollDown: return "Scroll down"
        default: return control.rawValue
        }
    }
}
