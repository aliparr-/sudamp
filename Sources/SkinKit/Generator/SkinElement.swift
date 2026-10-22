// SPDX-License-Identifier: GPL-3.0-or-later
//
// The parts of a classic skin the generator paints, one per sprite (or sprite frame).
//
// Ported from Bitamp, Sources/BitampKit/Skin/Skin.swift `SkinElement` and Layout.swift's button enums
// (https://github.com/ryanromanov/Bitamp @ 91952819c9cc0394dd03a961dd27a101a52ee6ef).
// sudamp changes: cases for the Webamp sprites Bitamp did not paint (clutter bar, work indicator, playlist menu
// buttons and bars, playlist visualiser background, unpressed EQ close buttons); sizes come from SkinKit's
// sprite and layout tables; the Orb and gen.bmp parts are dropped.
//
// Original notice:
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

enum PlayStatus: Hashable, CaseIterable {
    case playing, paused, stopped
}

enum TitleButton: Hashable, CaseIterable {
    case options, minimize, shade, close

    var rect: IntRect {
        switch self {
        case .options: return MainLayout.options
        case .minimize: return MainLayout.minimize
        case .shade: return MainLayout.shade
        case .close: return MainLayout.close
        }
    }
}

enum TransportButton: Hashable, CaseIterable {
    case previous, play, pause, stop, next, eject

    var rect: IntRect {
        switch self {
        case .previous: return MainLayout.previous
        case .play: return MainLayout.play
        case .pause: return MainLayout.pause
        case .stop: return MainLayout.stop
        case .next: return MainLayout.next
        case .eject: return MainLayout.eject
        }
    }
}

enum ToggleButton: Hashable, CaseIterable {
    case shuffle, repeatTrack, equalizer, playlist

    var rect: IntRect {
        switch self {
        case .shuffle: return MainLayout.shuffle
        case .repeatTrack: return MainLayout.repeat
        case .equalizer: return MainLayout.eqToggle
        case .playlist: return MainLayout.playlistToggle
        }
    }
}

enum EQButton: Hashable, CaseIterable {
    case on, auto, presets

    var rect: IntRect {
        switch self {
        case .on: return EQLayout.on
        case .auto: return EQLayout.auto
        case .presets: return EQLayout.presets
        }
    }
}

/// Small shade-mode thumbs come in three looks, for the left, middle and right of their track.
enum ShadeThumb: Hashable, CaseIterable {
    case left, center, right
}

/// The playlist's pop-up menu buttons, as Webamp names them (ADD URL, ADD DIR, …).
enum PlaylistMenuButton: Hashable, CaseIterable {
    case addURL, addDir, addFile, removeAll, crop, removeSelected, removeMisc, invertSelection, selectZero,
         selectAll, sortList, fileInfo, miscOptions, newList, saveList, loadList

    var sprites: (normal: Sprite, selected: Sprite) {
        switch self {
        case .addURL: return (.playlistAddUrl, .playlistAddUrlSelected)
        case .addDir: return (.playlistAddDir, .playlistAddDirSelected)
        case .addFile: return (.playlistAddFile, .playlistAddFileSelected)
        case .removeAll: return (.playlistRemoveAll, .playlistRemoveAllSelected)
        case .crop: return (.playlistCrop, .playlistCropSelected)
        case .removeSelected: return (.playlistRemoveSelected, .playlistRemoveSelectedSelected)
        case .removeMisc: return (.playlistRemoveMisc, .playlistRemoveMiscSelected)
        case .invertSelection: return (.playlistInvertSelection, .playlistInvertSelectionSelected)
        case .selectZero: return (.playlistSelectZero, .playlistSelectZeroSelected)
        case .selectAll: return (.playlistSelectAll, .playlistSelectAllSelected)
        case .sortList: return (.playlistSortList, .playlistSortListSelected)
        case .fileInfo: return (.playlistFileInfo, .playlistFileInfoSelected)
        case .miscOptions: return (.playlistMiscOptions, .playlistMiscOptionsSelected)
        case .newList: return (.playlistNewList, .playlistNewListSelected)
        case .saveList: return (.playlistSaveList, .playlistSaveListSelected)
        case .loadList: return (.playlistLoadList, .playlistLoadListSelected)
        }
    }

    var label: String {
        switch self {
        case .addURL: return "URL"
        case .addDir: return "DIR"
        case .addFile: return "FILE"
        case .removeAll: return "ALL"
        case .crop: return "CROP"
        case .removeSelected: return "SEL"
        case .removeMisc: return "MISC"
        case .invertSelection: return "INV"
        case .selectZero: return "NONE"
        case .selectAll: return "ALL"
        case .sortList: return "SORT"
        case .fileInfo: return "INFO"
        case .miscOptions: return "OPTS"
        case .newList: return "NEW"
        case .saveList: return "SAVE"
        case .loadList: return "LOAD"
        }
    }
}

/// One sprite (or one frame of a multi-frame sprite) the generator draws.
enum SkinElement: Hashable {
    case mainBackground
    case titleBar(active: Bool)
    case titleButton(TitleButton, pressed: Bool)
    case transport(TransportButton, pressed: Bool)
    case playStatus(PlayStatus)
    case workIndicator(working: Bool)
    case mono(active: Bool)
    case stereo(active: Bool)
    case volumeBackground(level: Int)
    case volumeThumb(pressed: Bool)
    case balanceBackground(level: Int)
    case balanceThumb(pressed: Bool)
    case positionBackground
    case positionThumb(pressed: Bool)
    case toggle(ToggleButton, on: Bool, pressed: Bool)
    case about(pressed: Bool)
    /// 0-9; 10 is the blank cell.
    case digit(Int)
    case minus
    case clutterBar(enabled: Bool)
    case clutterButton(Int)

    case eqBackground
    case eqTitleBar(active: Bool)
    case eqCloseButton(pressed: Bool)
    case eqButton(EQButton, on: Bool, pressed: Bool)
    /// One of the 28 slider frames; 0 is -12 dB.
    case eqSliderBackground(level: Int)
    case eqSliderThumb(pressed: Bool)
    case eqGraphBackground
    case eqPreampLine

    case playlistTopLeft(active: Bool)
    case playlistTitle(active: Bool)
    case playlistTopTile(active: Bool)
    case playlistTopRight(active: Bool)
    case playlistLeftTile
    case playlistRightTile
    case playlistBottomLeft
    case playlistBottomRight
    case playlistBottomTile
    case playlistVisualizerBackground
    case playlistScrollThumb(pressed: Bool)
    case playlistCloseButton(pressed: Bool)
    case playlistMenu(PlaylistMenuButton, selected: Bool)
    /// The 3 px bars left of the open playlist menus: add, remove, select, misc, list.
    case playlistMenuBar(Int)

    case mainShadeBackground(active: Bool)
    case mainUnshadeButton(pressed: Bool)
    case mainShadePosition
    case mainShadeThumb(ShadeThumb)
    case eqShadeButton(pressed: Bool)
    case eqShadeBackground(active: Bool)
    case eqUnshadeButton(pressed: Bool)
    case eqShadeCloseButton(pressed: Bool)
    case eqShadeVolumeThumb(ShadeThumb)
    case eqShadeBalanceThumb(ShadeThumb)
    case playlistShadeButton(pressed: Bool)
    case playlistShadeLeft(active: Bool)
    case playlistShadeTile
    case playlistShadeRight(active: Bool)
    case playlistUnshadeButton(pressed: Bool)

    static let sliderLevels = 28
    static let blankDigit = 10
}
