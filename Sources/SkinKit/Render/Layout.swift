// SPDX-License-Identifier: GPL-3.0-or-later
//
// Draw rects (where sprites land, not CSS hit boxes) and hit rects for the Main, Main shade, EQ, EQ shade and
// fixed-size Playlist windows, in 1x skin pixels.
//
// Started from Bitamp's Layout.swift (https://github.com/ryanromanov/Bitamp @ 91952819, MIT © 2026 Ryan
// Romanosky and Bitamp contributors) and cross-checked against Webamp's css/*.css @ 7734cd3 (MIT © 2015 Jordan
// Eldredge) and the Strider skin spec. Where they differ, the effective Webamp draw rect wins, since museum
// screenshots are Webamp renders: shade transport at x=169 (Bitamp 168), shade mini-time glyphs at
// 128/134/139/147/152 (Bitamp 126/132/137), shuffle drawn 46 wide (Webamp draws 47 and repeat covers the last
// column), next 22 wide (the sprite is 23). Values are listed in docs/spikes/M4-progress.md.
//
// Bitamp's notice:
//
// MIT License
//
// Copyright (c) 2026 Ryan Romanosky and Bitamp contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

/// The windows SkinKit composes.
public enum WindowKind: String, CaseIterable, Codable, Sendable {
    case main
    /// Main window in windowshade mode.
    case shade
    case eq
    case eqShade = "eq-shade"
    /// Fixed 275x232 playlist (resizing is after v1).
    case playlist

    public var size: IntSize {
        switch self {
        case .main, .eq: return IntSize(275, 116)
        case .shade, .eqShade: return IntSize(275, 14)
        case .playlist: return IntSize(275, 232)
        }
    }

    /// The region.txt section that shapes this window, if any.
    public var regionSection: String? {
        switch self {
        case .main: return "normal"
        case .shade: return "windowshade"
        case .eq: return "equalizer"
        case .eqShade: return "equalizerws"
        case .playlist: return nil
        }
    }
}

/// Everything that reacts to the mouse. Raw values name controls in state fixtures (`"pressed": "play"`).
public enum Control: String, CaseIterable, Codable, Sendable {
    // Shared title-bar parts
    case titleBar, options, minimize, shade, close
    // Main window
    case clutterO, clutterA, clutterI, clutterD, clutterV
    case time, visualizer, marquee, volume, balance, position, eqToggle, playlistToggle
    case previous, play, pause, stop, next, eject, shuffle, `repeat`, about
    // Equalizer
    case eqOn, eqAuto, eqPresets, eqGraph, preamp
    case band0, band1, band2, band3, band4, band5, band6, band7, band8, band9
    case eqMax, eqZero, eqMin
    // Playlist
    case playlistList, playlistScrollbar, playlistAdd, playlistRemove, playlistSelect, playlistMisc, playlistListMenu
    case playlistRunningTime, playlistMiniTime, playlistResize, playlistScrollUp, playlistScrollDown
    case playlistPrevious, playlistPlay, playlistPause, playlistStop, playlistNext, playlistEject

    public static let bands: [Control] = [.band0, .band1, .band2, .band3, .band4, .band5, .band6, .band7, .band8, .band9]
}

public enum MainLayout {
    public static let size = IntSize(275, 116)
    public static let titleBar = IntRect(0, 0, 275, 14)
    public static let options = IntRect(6, 3, 9, 9)
    public static let minimize = IntRect(244, 3, 9, 9)
    public static let shade = IntRect(254, 3, 9, 9)
    public static let close = IntRect(264, 3, 9, 9)
    public static let clutterBar = IntRect(10, 22, 8, 43)
    /// Clutter bar buttons (Webamp #button-o … #button-v), in window pixels.
    public static let clutter: [(Control, IntRect)] = [
        (.clutterO, IntRect(10, 25, 8, 8)), (.clutterA, IntRect(10, 33, 8, 7)), (.clutterI, IntRect(10, 40, 8, 7)),
        (.clutterD, IntRect(10, 47, 8, 8)), (.clutterV, IntRect(10, 55, 8, 7)),
    ]
    public static let playPause = IntRect(26, 28, 9, 9)
    /// The 3 px "working"/"buffering" strip left of the play state (Strider: 24,28 11x9 together).
    public static let workIndicator = IntRect(24, 28, 3, 9)
    public static let time = IntRect(39, 26, 59, 13)
    /// numbers.bmp's minus is a 5x1 bar; nums_ex.bmp's is a full 9x13 cell (Webamp's NUMS_EX rule).
    public static let minusNumbers = IntRect(38, 32, 5, 1)
    public static let minusNumsEx = IntRect(38, 26, 9, 13)
    public static let digitX = [48, 60, 78, 90]
    public static let digitY = 26
    public static let digitSize = IntSize(9, 13)
    public static let visualizer = IntRect(24, 43, 76, 16)
    /// Where the marquee text is drawn (Webamp #marquee 111,24 154x6 plus its 3 px top padding).
    public static let marqueeText = IntRect(111, 27, 154, 6)
    public static let marquee = IntRect(111, 24, 154, 12)
    public static let kbps = IntRect(111, 43, 15, 6)
    public static let khz = IntRect(156, 43, 10, 6)
    public static let mono = IntRect(212, 41, 27, 12)
    public static let stereo = IntRect(239, 41, 29, 12)
    public static let volume = IntRect(107, 57, 68, 13)
    public static let balance = IntRect(177, 57, 38, 13)
    public static let sliderThumb = IntSize(14, 11)
    /// Volume's range input is 65 px wide (3 px shorter than its background), so the thumb travels 51 px.
    public static let volumeTravel = 51
    public static let balanceTravel = 24
    public static let eqToggle = IntRect(219, 58, 23, 12)
    public static let playlistToggle = IntRect(242, 58, 23, 12)
    public static let position = IntRect(16, 72, 248, 10)
    public static let positionThumb = IntSize(29, 10)
    public static let positionTravel = 219
    public static let previous = IntRect(16, 88, 23, 18)
    public static let play = IntRect(39, 88, 23, 18)
    public static let pause = IntRect(62, 88, 23, 18)
    public static let stop = IntRect(85, 88, 23, 18)
    public static let next = IntRect(108, 88, 22, 18)
    public static let eject = IntRect(136, 89, 22, 16)
    public static let shuffle = IntRect(164, 89, 46, 15)
    public static let `repeat` = IntRect(210, 89, 28, 15)
    public static let about = IntRect(253, 91, 13, 15)

    /// Hit-test order: first match wins.
    public static let hitRects: [(Control, IntRect)] = [
        (.options, options), (.minimize, minimize), (.shade, shade), (.close, close),
    ] + clutter + [
        (.time, time), (.visualizer, visualizer), (.marquee, marquee),
        (.volume, volume), (.balance, balance), (.eqToggle, eqToggle), (.playlistToggle, playlistToggle),
        (.position, position),
        (.previous, previous), (.play, play), (.pause, pause), (.stop, stop), (.next, next), (.eject, eject),
        (.shuffle, shuffle), (.repeat, `repeat`), (.about, about),
        (.titleBar, titleBar),
    ]
}

public enum ShadeLayout {
    public static let size = IntSize(275, 14)
    public static let visualizer = IntRect(79, 5, 38, 5)
    public static let previous = IntRect(169, 2, 7, 10)
    public static let play = IntRect(176, 2, 10, 10)
    public static let pause = IntRect(186, 2, 9, 10)
    public static let stop = IntRect(195, 2, 9, 10)
    public static let next = IntRect(204, 2, 10, 10)
    public static let eject = IntRect(215, 2, 10, 10)
    public static let position = IntRect(226, 4, 17, 7)
    public static let positionThumb = IntSize(3, 7)
    public static let positionTravel = 14
    /// Mini time: Webamp .mini-time at 127,4 with characters at +1, +7, +12, +20, +25.
    public static let miniTimeX = [128, 134, 139, 147, 152]
    public static let miniTimeY = 4
    public static let miniTime = IntRect(127, 4, 30, 6)

    public static let hitRects: [(Control, IntRect)] = [
        (.options, MainLayout.options), (.minimize, MainLayout.minimize), (.shade, MainLayout.shade),
        (.close, MainLayout.close), (.visualizer, visualizer), (.time, miniTime),
        (.previous, previous), (.play, play), (.pause, pause), (.stop, stop), (.next, next), (.eject, eject),
        (.position, position), (.titleBar, IntRect(0, 0, 275, 14)),
    ]
}

public enum EQLayout {
    public static let size = IntSize(275, 116)
    public static let titleBar = IntRect(0, 0, 275, 14)
    public static let close = IntRect(264, 3, 9, 9)
    public static let shade = IntRect(254, 3, 9, 9)
    public static let on = IntRect(14, 18, 26, 12)
    public static let auto = IntRect(40, 18, 32, 12)
    public static let presets = IntRect(217, 18, 44, 12)
    public static let graph = IntRect(86, 17, 113, 19)
    /// The curve starts 2 px into the graph (Webamp: "TODO: This should be 1.5").
    public static let graphPaddingLeft = 2
    public static let preamp = IntRect(21, 38, 14, 63)
    public static let sliderSize = IntSize(14, 63)
    public static let thumb = IntSize(11, 11)
    /// The slider is 62 px tall (one less than its background) with an 11 px thumb: 51 px of travel.
    public static let thumbTravel = 51
    public static let plus12 = IntRect(45, 36, 22, 8)
    public static let zero = IntRect(45, 64, 22, 8)
    public static let minus12 = IntRect(45, 95, 22, 8)

    public static func band(_ index: Int) -> IntRect {
        IntRect(78 + 18 * index, 38, 14, 63)
    }

    public static let hitRects: [(Control, IntRect)] = [
        (.close, close), (.shade, shade), (.eqOn, on), (.eqAuto, auto), (.eqPresets, presets), (.eqGraph, graph),
        (.preamp, preamp), (.eqMax, plus12), (.eqZero, zero), (.eqMin, minus12),
    ] + (0..<10).map { (Control.bands[$0], band($0)) } + [(.titleBar, titleBar)]
}

public enum EQShadeLayout {
    public static let size = IntSize(275, 14)
    public static let volume = IntRect(61, 4, 97, 6)
    public static let balance = IntRect(164, 4, 43, 6)
    public static let thumb = IntSize(3, 7)
    public static let volumeTravel = 94
    public static let balanceTravel = 40

    public static let hitRects: [(Control, IntRect)] = [
        (.close, EQLayout.close), (.shade, EQLayout.shade), (.volume, volume), (.balance, balance),
        (.titleBar, IntRect(0, 0, 275, 14)),
    ]
}

/// The playlist at its base 275x232 size (Webamp playlist-window.css with size [0, 4]).
public enum PlaylistLayout {
    public static let size = IntSize(275, 232)
    public static let top = 20
    public static let bottom = 38
    public static let leftWidth = 12
    public static let rightWidth = 20
    public static let tileHeight = 29
    public static let topLeft = IntRect(0, 0, 25, 20)
    public static let leftSpacer = IntRect(25, 0, 12, 20)
    public static let leftFill = IntRect(37, 0, 50, 20)
    public static let title = IntRect(87, 0, 100, 20)
    public static let rightSpacer = IntRect(187, 0, 13, 20)
    public static let rightFill = IntRect(200, 0, 50, 20)
    public static let topRight = IntRect(250, 0, 25, 20)
    public static let shadeButton = IntRect(254, 3, 9, 9)
    public static let close = IntRect(264, 3, 9, 9)
    public static let list = IntRect(12, 20, 243, 174)
    /// Track rows start under 3 px of padding and are 13 px tall.
    public static let firstRowY = 23
    public static let rowHeight = 13
    public static let visibleRows = 13
    public static let scrollTrack = IntRect(260, 20, 8, 174)
    public static let scrollThumb = IntSize(8, 18)
    public static let scrollTravel = 156
    public static let bottomLeft = IntRect(0, 194, 125, 38)
    public static let bottomRight = IntRect(125, 194, 150, 38)
    public static let add = IntRect(14, 202, 22, 18)
    public static let remove = IntRect(43, 202, 22, 18)
    public static let select = IntRect(72, 202, 22, 18)
    public static let misc = IntRect(101, 202, 22, 18)
    public static let listMenu = IntRect(231, 202, 22, 18)
    public static let runningTime = IntPoint(132, 204)
    public static let runningTimeRect = IntRect(132, 204, 90, 6)
    public static let runningTimeChars = 18
    public static let miniTimeX = [192, 198, 203, 211, 216]
    public static let miniTimeY = 217
    public static let miniTime = IntRect(191, 217, 30, 6)
    public static let resize = IntRect(255, 212, 20, 20)
    public static let scrollUp = IntRect(260, 196, 8, 5)
    public static let scrollDown = IntRect(260, 202, 8, 5)
    /// Mini transport under the running time (Webamp .playlist-action-buttons at 3,22 of the bottom-right).
    public static let transport: [(Control, IntRect)] = [
        (.playlistPrevious, IntRect(128, 216, 10, 10)), (.playlistPlay, IntRect(138, 216, 10, 10)),
        (.playlistPause, IntRect(148, 216, 10, 10)), (.playlistStop, IntRect(158, 216, 10, 10)),
        (.playlistNext, IntRect(168, 216, 10, 10)), (.playlistEject, IntRect(178, 216, 10, 10)),
    ]

    public static let hitRects: [(Control, IntRect)] = [
        (.close, close), (.shade, shadeButton), (.playlistList, list), (.playlistScrollbar, scrollTrack),
        (.playlistAdd, add), (.playlistRemove, remove), (.playlistSelect, select), (.playlistMisc, misc),
        (.playlistListMenu, listMenu), (.playlistScrollUp, scrollUp), (.playlistScrollDown, scrollDown),
    ] + transport + [
        (.playlistMiniTime, miniTime), (.playlistRunningTime, runningTimeRect), (.playlistResize, resize),
        (.titleBar, IntRect(0, 0, 275, 20)),
    ]
}

public enum Layout {
    public static func hitRects(_ window: WindowKind) -> [(Control, IntRect)] {
        switch window {
        case .main: return MainLayout.hitRects
        case .shade: return ShadeLayout.hitRects
        case .eq: return EQLayout.hitRects
        case .eqShade: return EQShadeLayout.hitRects
        case .playlist: return PlaylistLayout.hitRects
        }
    }

    /// The control under `point`, or nil for empty window background (a drag area). Pure: the caller converts
    /// from view points to skin pixels and handles region transparency.
    public static func hitTest(_ window: WindowKind, _ point: IntPoint) -> Control? {
        guard IntRect(origin: .zero, size: window.size).contains(point) else { return nil }
        return hitRects(window).first { $0.1.contains(point) }?.0
    }

    public static func rect(of control: Control, in window: WindowKind) -> IntRect? {
        hitRects(window).first { $0.0 == control }?.1
    }
}
