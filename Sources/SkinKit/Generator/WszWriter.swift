// SPDX-License-Identifier: GPL-3.0-or-later
//
// Writes a code-drawn skin out as classic .wsz files at Webamp's sprite positions.
//
// Ported from Bitamp, Sources/BitampKit/Skin/WszWriter.swift
// (https://github.com/ryanromanov/Bitamp @ 91952819c9cc0394dd03a961dd27a101a52ee6ef).
// sudamp changes: sprite positions come from SkinKit's generated Webamp table instead of Bitamp's own map (so the
// pressed EQ close button lands at 0,125 like Webamp); title-bar buttons are also painted into the title bars,
// which other players show when nothing is pressed; the extra sprites listed in SkinElement are written; files
// are zipped by `ZipWriter` (fixed timestamps, sorted names, sudamp's DEFLATE) instead of /usr/bin/zip, so the
// output is byte-stable.
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

import Foundation

enum WszWriter {
    /// The classic sheet sizes.
    static let sheetSizes: [String: IntSize] = [
        "main": IntSize(275, 116), "titlebar": IntSize(344, 87), "cbuttons": IntSize(136, 36),
        "playpaus": IntSize(42, 9), "monoster": IntSize(56, 24), "volume": IntSize(68, 433),
        "balance": IntSize(47, 433), "posbar": IntSize(307, 10), "shufrep": IntSize(92, 85),
        "nums_ex": IntSize(108, 13), "text": IntSize(155, 18), "eqmain": IntSize(275, 315),
        "eq_ex": IntSize(275, 56), "pledit": IntSize(280, 186),
    ]

    /// Every element that has a place on a classic sheet.
    static let elements: [SkinElement] = {
        var elements: [SkinElement] = [
            .mainBackground, .positionBackground, .eqBackground, .eqGraphBackground, .eqPreampLine,
            .playlistLeftTile, .playlistRightTile, .playlistBottomLeft, .playlistBottomRight, .playlistBottomTile,
            .playlistVisualizerBackground, .mainShadePosition, .playlistShadeTile,
            .eqShadeButton(pressed: true), .eqUnshadeButton(pressed: true),
            .playlistCloseButton(pressed: true), .playlistShadeButton(pressed: true), .playlistUnshadeButton(pressed: true),
        ]
        for flag in [false, true] {
            elements += [
                .titleBar(active: flag), .mono(active: flag), .stereo(active: flag),
                .volumeThumb(pressed: flag), .balanceThumb(pressed: flag), .positionThumb(pressed: flag),
                .eqTitleBar(active: flag), .eqSliderThumb(pressed: flag), .playlistTopLeft(active: flag),
                .playlistTitle(active: flag), .playlistTopTile(active: flag), .playlistTopRight(active: flag),
                .playlistScrollThumb(pressed: flag), .mainShadeBackground(active: flag),
                .mainUnshadeButton(pressed: flag), .eqShadeBackground(active: flag),
                .playlistShadeLeft(active: flag), .playlistShadeRight(active: flag),
                .eqCloseButton(pressed: flag), .eqShadeCloseButton(pressed: flag),
                .workIndicator(working: flag), .clutterBar(enabled: !flag),
            ]
            elements += TitleButton.allCases.map { .titleButton($0, pressed: flag) }
            elements += TransportButton.allCases.map { .transport($0, pressed: flag) }
            elements += PlaylistMenuButton.allCases.map { .playlistMenu($0, selected: flag) }
            for on in [false, true] {
                elements += ToggleButton.allCases.map { .toggle($0, on: on, pressed: flag) }
                elements += [EQButton.on, .auto].map { .eqButton($0, on: on, pressed: flag) }
            }
            elements.append(.eqButton(.presets, on: false, pressed: flag))
        }
        elements += PlayStatus.allCases.map { .playStatus($0) }
        for thumb in ShadeThumb.allCases {
            elements += [.mainShadeThumb(thumb), .eqShadeVolumeThumb(thumb), .eqShadeBalanceThumb(thumb)]
        }
        elements += (0..<SkinElement.sliderLevels).flatMap {
            [SkinElement.volumeBackground(level: $0), .balanceBackground(level: $0), .eqSliderBackground(level: $0)]
        }
        elements += (0..<5).map { .clutterButton($0) } + (0..<5).map { .playlistMenuBar($0) }
        elements += (0...SkinElement.blankDigit).map { .digit($0) } + [.minus]
        return elements
    }()

    /// Where an element goes: its sheet and the top-left of its sprite (or frame) there.
    static func placement(of element: SkinElement) -> (sheet: String, at: IntPoint)? {
        func sprite(_ s: Sprite, dx: Int = 0, dy: Int = 0) -> (String, IntPoint) {
            (s.source.sheet.fileBase, IntPoint(s.source.rect.x + dx, s.source.rect.y + dy))
        }
        switch element {
        case .mainBackground: return sprite(.mainWindowBackground)
        case .titleBar(let active): return sprite(active ? .mainTitleBarSelected : .mainTitleBar)
        case .titleButton(let button, let pressed):
            switch button {
            case .options: return sprite(pressed ? .mainOptionsButtonDepressed : .mainOptionsButton)
            case .minimize: return sprite(pressed ? .mainMinimizeButtonDepressed : .mainMinimizeButton)
            case .shade: return sprite(pressed ? .mainShadeButtonDepressed : .mainShadeButton)
            case .close: return sprite(pressed ? .mainCloseButtonDepressed : .mainCloseButton)
            }
        case .transport(let button, let pressed):
            switch button {
            case .previous: return sprite(pressed ? .mainPreviousButtonActive : .mainPreviousButton)
            case .play: return sprite(pressed ? .mainPlayButtonActive : .mainPlayButton)
            case .pause: return sprite(pressed ? .mainPauseButtonActive : .mainPauseButton)
            case .stop: return sprite(pressed ? .mainStopButtonActive : .mainStopButton)
            case .next: return sprite(pressed ? .mainNextButtonActive : .mainNextButton)
            case .eject: return sprite(pressed ? .mainEjectButtonActive : .mainEjectButton)
            }
        case .playStatus(let status):
            switch status {
            case .playing: return sprite(.mainPlayingIndicator)
            case .paused: return sprite(.mainPausedIndicator)
            case .stopped: return sprite(.mainStoppedIndicator)
            }
        case .workIndicator(let working): return sprite(working ? .mainWorkingIndicator : .mainNotWorkingIndicator)
        case .mono(let active): return sprite(active ? .mainMonoSelected : .mainMono)
        case .stereo(let active): return sprite(active ? .mainStereoSelected : .mainStereo)
        case .volumeBackground(let level): return sprite(.mainVolumeBackground, dy: level * 15)
        case .volumeThumb(let pressed): return sprite(pressed ? .mainVolumeThumbSelected : .mainVolumeThumb)
        case .balanceBackground(let level): return sprite(.mainBalanceBackground, dy: level * 15)
        case .balanceThumb(let pressed): return sprite(pressed ? .mainBalanceThumbActive : .mainBalanceThumb)
        case .positionBackground: return sprite(.mainPositionSliderBackground)
        case .positionThumb(let pressed): return sprite(pressed ? .mainPositionSliderThumbSelected : .mainPositionSliderThumb)
        case .toggle(let button, let on, let pressed):
            switch (button, on, pressed) {
            case (.shuffle, false, false): return sprite(.mainShuffleButton)
            case (.shuffle, false, true): return sprite(.mainShuffleButtonDepressed)
            case (.shuffle, true, false): return sprite(.mainShuffleButtonSelected)
            case (.shuffle, true, true): return sprite(.mainShuffleButtonSelectedDepressed)
            case (.repeatTrack, false, false): return sprite(.mainRepeatButton)
            case (.repeatTrack, false, true): return sprite(.mainRepeatButtonDepressed)
            case (.repeatTrack, true, false): return sprite(.mainRepeatButtonSelected)
            case (.repeatTrack, true, true): return sprite(.mainRepeatButtonSelectedDepressed)
            case (.equalizer, false, false): return sprite(.mainEqButton)
            case (.equalizer, false, true): return sprite(.mainEqButtonDepressed)
            case (.equalizer, true, false): return sprite(.mainEqButtonSelected)
            case (.equalizer, true, true): return sprite(.mainEqButtonDepressedSelected)
            case (.playlist, false, false): return sprite(.mainPlaylistButton)
            case (.playlist, false, true): return sprite(.mainPlaylistButtonDepressed)
            case (.playlist, true, false): return sprite(.mainPlaylistButtonSelected)
            case (.playlist, true, true): return sprite(.mainPlaylistButtonDepressedSelected)
            }
        case .about: return nil  // Painted into the main background.
        case .digit(let digit):
            return digit == SkinElement.blankDigit ? sprite(.noMinusSignEx) : sprite(.digit0Ex, dx: digit * 9)
        case .minus: return sprite(.minusSignEx)
        case .clutterBar(let enabled): return sprite(enabled ? .mainClutterBarBackground : .mainClutterBarBackgroundDisabled)
        case .clutterButton(let index):
            let sprites: [Sprite] = [.mainClutterBarButtonOSelected, .mainClutterBarButtonASelected,
                                     .mainClutterBarButtonISelected, .mainClutterBarButtonDSelected,
                                     .mainClutterBarButtonVSelected]
            return sprite(sprites[index])

        case .eqBackground: return sprite(.eqWindowBackground)
        case .eqTitleBar(let active): return sprite(active ? .eqTitleBarSelected : .eqTitleBar)
        case .eqCloseButton(let pressed): return sprite(pressed ? .eqCloseButtonActive : .eqCloseButton)
        case .eqButton(let button, let on, let pressed):
            switch (button, on, pressed) {
            case (.on, false, false): return sprite(.eqOnButton)
            case (.on, false, true): return sprite(.eqOnButtonDepressed)
            case (.on, true, false): return sprite(.eqOnButtonSelected)
            case (.on, true, true): return sprite(.eqOnButtonSelectedDepressed)
            case (.auto, false, false): return sprite(.eqAutoButton)
            case (.auto, false, true): return sprite(.eqAutoButtonDepressed)
            case (.auto, true, false): return sprite(.eqAutoButtonSelected)
            case (.auto, true, true): return sprite(.eqAutoButtonSelectedDepressed)
            case (.presets, _, let pressed): return sprite(pressed ? .eqPresetsButtonSelected : .eqPresetsButton)
            }
        case .eqSliderBackground(let level):
            return sprite(.eqSliderBackground, dx: (level % 14) * 15, dy: (level / 14) * 65)
        case .eqSliderThumb(let pressed): return sprite(pressed ? .eqSliderThumbSelected : .eqSliderThumb)
        case .eqGraphBackground: return sprite(.eqGraphBackground)
        case .eqPreampLine: return sprite(.eqPreampLine)

        case .playlistTopLeft(let active): return sprite(active ? .playlistTopLeftSelected : .playlistTopLeftCorner)
        case .playlistTitle(let active): return sprite(active ? .playlistTitleBarSelected : .playlistTitleBar)
        case .playlistTopTile(let active): return sprite(active ? .playlistTopTileSelected : .playlistTopTile)
        case .playlistTopRight(let active):
            return sprite(active ? .playlistTopRightCornerSelected : .playlistTopRightCorner)
        case .playlistLeftTile: return sprite(.playlistLeftTile)
        case .playlistRightTile: return sprite(.playlistRightTile)
        case .playlistBottomLeft: return sprite(.playlistBottomLeftCorner)
        case .playlistBottomRight: return sprite(.playlistBottomRightCorner)
        case .playlistBottomTile: return sprite(.playlistBottomTile)
        case .playlistVisualizerBackground: return sprite(.playlistVisualizerBackground)
        case .playlistScrollThumb(let pressed): return sprite(pressed ? .playlistScrollHandleSelected : .playlistScrollHandle)
        case .playlistCloseButton(let pressed): return pressed ? sprite(.playlistCloseSelected) : nil
        case .playlistMenu(let button, let selected):
            return sprite(selected ? button.sprites.selected : button.sprites.normal)
        case .playlistMenuBar(let index):
            let bars: [Sprite] = [.playlistAddMenuBar, .playlistRemoveMenuBar, .playlistSelectMenuBar,
                                  .playlistMiscMenuBar, .playlistListBar]
            return sprite(bars[index])

        case .mainShadeBackground(let active): return sprite(active ? .mainShadeBackgroundSelected : .mainShadeBackground)
        case .mainUnshadeButton(let pressed):
            return sprite(pressed ? .mainShadeButtonSelectedDepressed : .mainShadeButtonSelected)
        case .mainShadePosition: return sprite(.mainShadePositionBackground)
        case .mainShadeThumb(let thumb):
            switch thumb {
            case .left: return sprite(.mainShadePositionThumbLeft)
            case .center: return sprite(.mainShadePositionThumb)
            case .right: return sprite(.mainShadePositionThumbRight)
            }
        case .eqShadeButton(let pressed): return pressed ? sprite(.eqMaximizeButtonActive) : nil
        case .eqShadeBackground(let active): return sprite(active ? .eqShadeBackgroundSelected : .eqShadeBackground)
        case .eqUnshadeButton(let pressed): return pressed ? sprite(.eqMinimizeButtonActive) : nil
        case .eqShadeCloseButton(let pressed): return sprite(pressed ? .eqShadeCloseButtonActive : .eqShadeCloseButton)
        case .eqShadeVolumeThumb(let thumb):
            switch thumb {
            case .left: return sprite(.eqShadeVolumeSliderLeft)
            case .center: return sprite(.eqShadeVolumeSliderCenter)
            case .right: return sprite(.eqShadeVolumeSliderRight)
            }
        case .eqShadeBalanceThumb(let thumb):
            switch thumb {
            case .left: return sprite(.eqShadeBalanceSliderLeft)
            case .center: return sprite(.eqShadeBalanceSliderCenter)
            case .right: return sprite(.eqShadeBalanceSliderRight)
            }
        case .playlistShadeButton(let pressed): return pressed ? sprite(.playlistCollapseSelected) : nil
        case .playlistShadeLeft: return sprite(.playlistShadeBackgroundLeft)
        case .playlistShadeTile: return sprite(.playlistShadeBackground)
        case .playlistShadeRight(let active):
            return sprite(active ? .playlistShadeBackgroundRightSelected : .playlistShadeBackgroundRight)
        case .playlistUnshadeButton(let pressed): return pressed ? sprite(.playlistExpandSelected) : nil
        }
    }

    // MARK: - Flattening

    /// What a sprite sits on in the window, and where, so its transparent parts can be filled in.
    static func backdrop(of element: SkinElement) -> (SkinElement, IntPoint)? {
        switch element {
        case .titleButton(let button, _): return (.titleBar(active: true), button.rect.origin)
        case .transport(let button, _): return (.mainBackground, button.rect.origin)
        case .toggle(let button, _, _): return (.mainBackground, button.rect.origin)
        case .playStatus: return (.mainBackground, MainLayout.playPause.origin)
        case .workIndicator: return (.mainBackground, MainLayout.workIndicator.origin)
        case .mono: return (.mainBackground, MainLayout.mono.origin)
        case .stereo: return (.mainBackground, MainLayout.stereo.origin)
        case .digit: return (.mainBackground, IntPoint(MainLayout.digitX[0], MainLayout.digitY))
        case .minus: return (.mainBackground, MainLayout.minusNumsEx.origin)
        case .volumeBackground: return (.mainBackground, MainLayout.volume.origin)
        case .balanceBackground: return (.mainBackground, MainLayout.balance.origin)
        case .positionBackground: return (.mainBackground, MainLayout.position.origin)
        case .volumeThumb: return (.volumeBackground(level: 13), IntPoint(27, 1))
        case .balanceThumb: return (.balanceBackground(level: 0), IntPoint(12, 1))
        case .positionThumb: return (.positionBackground, IntPoint(0, 0))

        case .eqButton(let button, _, _): return (.eqBackground, button.rect.origin)
        case .eqSliderBackground: return (.eqBackground, EQLayout.band(0).origin)
        case .eqSliderThumb: return (.eqSliderBackground(level: 13), IntPoint(1, 26))
        case .eqGraphBackground: return (.eqBackground, EQLayout.graph.origin)
        case .eqPreampLine: return (.eqGraphBackground, IntPoint(0, 9))
        case .eqCloseButton: return (.eqTitleBar(active: true), EQLayout.close.origin)
        case .eqShadeButton: return (.eqTitleBar(active: true), EQLayout.shade.origin)

        case .playlistScrollThumb: return (.playlistRightTile, IntPoint(5, 0))
        case .playlistCloseButton: return (.playlistTopRight(active: true), IntPoint(14, 3))
        case .playlistShadeButton: return (.playlistTopRight(active: true), IntPoint(5, 3))
        case .playlistUnshadeButton: return (.playlistShadeRight(active: true), IntPoint(31, 3))

        case .mainUnshadeButton: return (.mainShadeBackground(active: true), MainLayout.shade.origin)
        case .mainShadePosition: return (.mainShadeBackground(active: true), ShadeLayout.position.origin)
        case .mainShadeThumb: return (.mainShadePosition, IntPoint(7, 0))
        case .eqUnshadeButton: return (.eqShadeBackground(active: true), EQLayout.shade.origin)
        case .eqShadeCloseButton: return (.eqShadeBackground(active: true), EQLayout.close.origin)
        case .eqShadeVolumeThumb: return (.eqShadeBackground(active: true), EQShadeLayout.volume.origin)
        case .eqShadeBalanceThumb: return (.eqShadeBackground(active: true), EQShadeLayout.balance.origin)

        default: return nil  // Backgrounds, tiles and self-contained buttons are opaque already.
        }
    }

    /// Buttons the classic format paints into a background rather than drawing as sprites.
    static func paintedIn(_ element: SkinElement) -> [(SkinElement, IntPoint)] {
        switch element {
        case .mainBackground:
            return [(.about(pressed: false), MainLayout.about.origin)]
        case .titleBar:
            return TitleButton.allCases.map { (.titleButton($0, pressed: false), $0.rect.origin) }
        case .mainShadeBackground:
            return [(.titleButton(.options, pressed: false), MainLayout.options.origin),
                    (.titleButton(.minimize, pressed: false), MainLayout.minimize.origin),
                    (.mainUnshadeButton(pressed: false), MainLayout.shade.origin),
                    (.titleButton(.close, pressed: false), MainLayout.close.origin)]
        case .eqTitleBar:
            return [(.eqShadeButton(pressed: false), EQLayout.shade.origin),
                    (.eqCloseButton(pressed: false), EQLayout.close.origin)]
        case .eqShadeBackground:
            return [(.eqUnshadeButton(pressed: false), EQLayout.shade.origin),
                    (.eqShadeCloseButton(pressed: false), EQLayout.close.origin)]
        case .playlistTopRight:
            return [(.playlistShadeButton(pressed: false), IntPoint(5, 3)),
                    (.playlistCloseButton(pressed: false), IntPoint(14, 3))]
        case .playlistShadeRight:
            return [(.playlistUnshadeButton(pressed: false), IntPoint(31, 3)),
                    (.playlistCloseButton(pressed: false), IntPoint(40, 3))]
        default:
            return []
        }
    }

    /// A sprite as it goes into the .wsz: on its backdrop, with painted-in buttons, opaque.
    static func flattened(_ element: SkinElement, from painter: SudampDarkPainter) -> Bitmap {
        let sprite = painter.image(for: element)
        let canvas = Canvas(sprite.width, sprite.height)
        canvas.fill(0, 0, sprite.width, sprite.height, rgb(0x000000))
        if let (backdrop, at) = backdrop(of: element) {
            canvas.draw(flattened(backdrop, from: painter), -at.x, -at.y)
        }
        canvas.draw(sprite, 0, 0)
        for (button, at) in paintedIn(element) {
            canvas.draw(painter.image(for: button), at: at)
        }
        return canvas.image()
    }

    // MARK: - Sheets and files

    /// The classic bitmaps, keyed by sheet name.
    static func sheets(for painter: SudampDarkPainter) -> [String: Bitmap] {
        var canvases: [String: Canvas] = [:]
        for (name, size) in sheetSizes {
            let canvas = Canvas(size)
            canvas.fill(0, 0, canvas.width, canvas.height, rgb(0x000000))
            canvases[name] = canvas
        }
        for element in elements {
            guard let (sheet, at) = placement(of: element), let canvas = canvases[sheet] else { continue }
            canvas.draw(flattened(element, from: painter), at: at)
        }

        // Text glyphs on the marquee's background colour. `<>{}` share the `[]` cells, so they are not drawn.
        let text = canvases["text"]!
        let marqueeColor = flattened(.mainBackground, from: painter)[MainLayout.marqueeText.minX + 1, MainLayout.marqueeText.minY + 1]
        text.fill(0, 0, text.width, text.height, marqueeColor)
        for (character, cell) in FontLookup.cells where !"<>{}".contains(character) {
            let glyph = character.isLetter && character.isLowercase ? Character(character.uppercased()) : character
            text.draw(painter.glyph(for: glyph), cell.column * FontLookup.cellWidth, cell.row * FontLookup.cellHeight)
        }

        // The equalizer graph's colours: a 1-pixel column in eqmain.bmp at EQ_GRAPH_LINE_COLORS.
        let eqmain = canvases["eqmain"]!
        let strip = Sprite.eqGraphLineColors.source.rect
        for (row, color) in SudampDarkTheme.Palette(painter.theme).eqGraphColors.prefix(19).enumerated() {
            eqmain.fill(strip.x, strip.y + row, 1, 1, color)
        }
        return canvases.mapValues { $0.image() }
    }

    /// Every file in the .wsz, by lower-case file name.
    static func files(for painter: SudampDarkPainter) -> [String: Data] {
        var files: [String: Data] = [:]
        for (name, image) in sheets(for: painter) {
            files["\(name).bmp"] = BMPWriter.encode(image)
        }
        let palette = SudampDarkTheme.Palette(painter.theme)
        files["viscolor.txt"] = Data((palette.viscolors.map { "\($0.r),\($0.g),\($0.b)" }.joined(separator: "\r\n") + "\r\n").utf8)
        let style = palette.playlistStyle
        files["pledit.txt"] = Data("""
            [Text]\r
            Normal=\(style.normal.hexString)\r
            Current=\(style.current.hexString)\r
            NormalBG=\(style.normalBackground.hexString)\r
            SelectedBG=\(style.selectedBackground.hexString)\r
            Font=\(style.font)\r

            """.utf8)
        files["readme.txt"] = Data(SudampDark.readme.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        return files
    }
}
