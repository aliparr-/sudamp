// SPDX-License-Identifier: GPL-3.0-or-later
// The pointer state machine: SkinKit hit-test → pressed sprites, release-inside activation, menus on press,
// slider value mapping, marquee click vs scrub, window drags and double-click shade.
import Foundation
import SkinKit
import Testing
@testable import SkinUI

func playingState(rows: Int = 16) -> SkinPlayerState {
    var p = SkinPlayerState()
    p.playState = .playing
    p.title = "[DEEP HOUSE] A TITLE LONG ENOUGH TO SCROLL ACROSS THE MARQUEE"
    p.elapsed = 930
    p.duration = 3720
    p.volume = 0.75
    p.playlist = (0..<rows).map { .init(tag: .youtube, title: "Station \($0)", duration: 300) }
    return p
}

func drawn(_ p: SkinPlayerState, _ kind: WindowKind, local: SkinLocalState = SkinLocalState()) -> WindowState {
    SkinStateMapper.windowState(p, kind: kind, local: local)
}

/// The composer state for `kind` with the default playing state.
func drawn(_ kind: WindowKind, local: SkinLocalState = SkinLocalState()) -> WindowState {
    drawn(playingState(), kind, local: local)
}

/// Press and release on a control's centre.
func click(_ control: Control, _ kind: WindowKind, role: SkinWindowRole, state: WindowState? = nil) -> [SkinControlEvent] {
    var interaction = SkinInteraction(role: role)
    let s = state ?? drawn(kind)
    let at = pointer(centre(control, in: kind))
    return events(interaction.mouseDown(at, kind: kind, state: s) + interaction.mouseUp(at, kind: kind, state: s))
}

@Suite struct ButtonTests {
    @Test func mainWindowButtonsActOnRelease() {
        let expected: [(Control, SkinControlEvent)] = [
            (.previous, .previous), (.play, .play), (.pause, .pause), (.stop, .stop), (.next, .next), (.eject, .eject),
            (.shuffle, .shuffle), (.repeat, .repeat), (.eqToggle, .eqWindowToggle), (.playlistToggle, .plToggle),
            (.minimize, .minimize), (.shade, .shade(.main)), (.close, .close(.main)), (.about, .about),
            (.time, .timeModeToggle), (.visualizer, .visualizerModeToggle),
        ]
        for (control, event) in expected {
            #expect(click(control, .main, role: .main) == [event], "\(control)")
        }
        let clutter = click(.clutterA, .main, role: .main)
        guard case .clutter(.alwaysOnTop, _)? = clutter.first else {
            Issue.record("clutter A: \(clutter)")
            return
        }
        #expect(clutter.count == 1)
    }

    @Test func pressedSpriteFollowsThePointerAndReleaseOutsideCancels() {
        var interaction = SkinInteraction(role: .main)
        let s = drawn(.main)
        let inside = pointer(centre(.play, in: .main))
        let outside = pointer(CGPoint(x: 5, y: 60))
        #expect(interaction.mouseDown(inside, kind: .main, state: s).isEmpty)
        #expect(interaction.pressed == .play)
        _ = interaction.mouseDragged(outside, kind: .main, state: s)
        #expect(interaction.pressed == nil)
        _ = interaction.mouseDragged(inside, kind: .main, state: s)
        #expect(interaction.pressed == .play)
        _ = interaction.mouseDragged(outside, kind: .main, state: s)
        #expect(interaction.mouseUp(outside, kind: .main, state: s).isEmpty)
        #expect(interaction.pressed == nil && interaction.gesture == nil)
    }

    @Test func menuButtonsActOnPress() {
        var interaction = SkinInteraction(role: .main)
        let s = drawn(.main)
        let at = pointer(centre(.options, in: .main))
        let down = events(interaction.mouseDown(at, kind: .main, state: s))
        #expect(down == [.optionsMenu(screenPoint: at.screen)])
        #expect(down.first?.opensMenu == true)
        #expect(interaction.pressed == .options)
        #expect(interaction.mouseUp(at, kind: .main, state: s).isEmpty)
        #expect(interaction.pressed == nil)
    }

    @Test func shadeStripButtons() {
        for (control, event) in [(Control.play, SkinControlEvent.play), (.stop, .stop), (.next, .next), (.eject, .eject),
                                 (.time, .timeModeToggle), (.shade, .shade(.main)), (.close, .close(.main))] {
            #expect(click(control, .shade, role: .main, state: drawn(.shade)) == [event], "\(control)")
        }
    }

    @Test func equalizerButtons() {
        let s = drawn(.eq)
        #expect(click(.eqOn, .eq, role: .equalizer, state: s) == [.eqToggle])
        #expect(click(.eqAuto, .eq, role: .equalizer, state: s) == [.eqAuto])
        #expect(click(.eqMax, .eq, role: .equalizer, state: s) == [.eqSetAll(decibels: 12)])
        #expect(click(.eqZero, .eq, role: .equalizer, state: s) == [.eqSetAll(decibels: 0)])
        #expect(click(.eqMin, .eq, role: .equalizer, state: s) == [.eqSetAll(decibels: -12)])
        #expect(click(.close, .eq, role: .equalizer, state: s) == [.close(.equalizer)])
        #expect(click(.shade, .eq, role: .equalizer, state: s) == [.shade(.equalizer)])
        var interaction = SkinInteraction(role: .equalizer)
        let at = pointer(centre(.eqPresets, in: .eq))
        #expect(events(interaction.mouseDown(at, kind: .eq, state: s)) == [.presetsMenu(screenPoint: at.screen)])
    }

    @Test func playlistButtons() {
        let s = drawn(.playlist)
        for (control, event) in [(Control.playlistPlay, SkinControlEvent.play), (.playlistPause, .pause),
                                 (.playlistStop, .stop), (.playlistNext, .next), (.playlistPrevious, .previous),
                                 (.playlistEject, .eject), (.playlistMiniTime, .timeModeToggle), (.close, .close(.playlist)),
                                 (.shade, .shade(.playlist)), (.playlistScrollDown, .playlistScroll(firstRow: 1))] {
            #expect(click(control, .playlist, role: .playlist, state: s) == [event], "\(control)")
        }
        #expect(click(.playlistScrollUp, .playlist, role: .playlist, state: s).isEmpty, "already at the top")
        var interaction = SkinInteraction(role: .playlist)
        let at = pointer(centre(.playlistAdd, in: .playlist))
        #expect(events(interaction.mouseDown(at, kind: .playlist, state: s)) == [.playlistMenu(.add, screenPoint: at.screen)])
    }
}

@Suite struct RowAndScrollTests {
    @Test func rowsSelectOnClickAndActivateOnDoubleClick() {
        var interaction = SkinInteraction(role: .playlist)
        var local = SkinLocalState()
        local.playlistFirstRow = 2
        let s = drawn(.playlist, local: local)
        // Row 3 on screen (y = 23 + 3 * 13 + 6) is station 5.
        let row = CGPoint(x: 60, y: 23 + 3 * 13 + 6)
        #expect(events(interaction.mouseDown(pointer(row), kind: .playlist, state: s)) == [.playlistRowSelected(index: 5)])
        _ = interaction.mouseUp(pointer(row), kind: .playlist, state: s)
        #expect(events(interaction.mouseDown(pointer(row, clickCount: 2), kind: .playlist, state: s))
            == [.playlistRowActivated(index: 5)])
        #expect(SkinInteraction.rowIndex(at: CGPoint(x: 60, y: 21), state: s) == nil, "padding above the first row")
        let few = drawn(playingState(rows: 2), .playlist)
        #expect(SkinInteraction.rowIndex(at: row, state: few) == nil, "no station there")
    }

    @Test func wheelScrollsRowsAndVolume() {
        var interaction = SkinInteraction(role: .playlist)
        var local = SkinLocalState()
        local.playlistFirstRow = 2
        let s = drawn(.playlist, local: local)
        #expect(events(interaction.scroll(steps: 1, kind: .playlist, state: s)) == [.playlistScroll(firstRow: 1)])
        #expect(events(interaction.scroll(steps: -5, kind: .playlist, state: s)) == [.playlistScroll(firstRow: 3)])
        var main = SkinInteraction(role: .main)
        let m = drawn(.main)
        let up = events(main.scroll(steps: 2, kind: .main, state: m))
        guard case .volume(let v)? = up.first else {
            Issue.record("expected a volume event, got \(up)")
            return
        }
        #expect(abs(v - 0.79) < 1e-9)
        #expect(main.scroll(steps: 0, kind: .main, state: m).isEmpty)
    }

    @Test func scrollbarDragScrollsToRows() {
        var interaction = SkinInteraction(role: .playlist)
        let s = drawn(.playlist)  // 16 rows: first row 0...3
        let thumb = CGPoint(x: 263, y: 25)
        #expect(interaction.mouseDown(pointer(thumb), kind: .playlist, state: s).isEmpty, "grabbed in place")
        let bottom = events(interaction.mouseDragged(pointer(CGPoint(x: 263, y: 400)), kind: .playlist, state: s))
        #expect(bottom == [.playlistScroll(firstRow: 3)])
        #expect(interaction.overrides.scroll == 1)
        _ = interaction.mouseUp(pointer(CGPoint(x: 263, y: 400)), kind: .playlist, state: s)
        #expect(interaction.overrides.scroll == nil, "the thumb settles on the row")
    }
}

@Suite struct SliderTests {
    @Test func volumeGrabsTheThumbOrJumpsToThePointer() throws {
        var interaction = SkinInteraction(role: .main)
        let s = drawn(.main)  // volume 75: thumb at 107 + 38.25
        let onThumb = CGPoint(x: 150, y: 63)
        #expect(events(interaction.mouseDown(pointer(onThumb), kind: .main, state: s)) == [.volume(0.75)])
        #expect(interaction.pressed == .volume)
        let moved = events(interaction.mouseDragged(pointer(CGPoint(x: 150 + 5.1, y: 63)), kind: .main, state: s))
        let v = try #require({ if case .volume(let v)? = moved.first { return v } else { return nil } }())
        #expect(abs(v - 0.85) < 1e-9)
        #expect(events(interaction.mouseDragged(pointer(CGPoint(x: -40, y: 90)), kind: .main, state: s)) == [.volume(0)])
        #expect(events(interaction.mouseDragged(pointer(CGPoint(x: 400, y: 90)), kind: .main, state: s)) == [.volume(1)])
        #expect(interaction.mouseDragged(pointer(CGPoint(x: 401, y: 90)), kind: .main, state: s).isEmpty, "no duplicates")
        _ = interaction.mouseUp(pointer(CGPoint(x: 400, y: 90)), kind: .main, state: s)
        #expect(interaction.overrides.volume == 1, "kept until the app's next state")

        var jump = SkinInteraction(role: .main)
        #expect(events(jump.mouseDown(pointer(CGPoint(x: 114, y: 63)), kind: .main, state: s)) == [.volume(0)],
                "thumb middle jumps to the pointer: (114 - 7 - 107) / 51")
    }

    @Test func balanceSnapsToTheCentre() throws {
        var interaction = SkinInteraction(role: .main)
        let s = drawn(.main)
        let track = try #require(SliderTrack.track(for: .balance, in: .main))
        func x(_ fraction: Double) -> CGPoint { CGPoint(x: track.leading(fraction: fraction) + 7, y: 63) }
        #expect(events(interaction.mouseDown(pointer(x(0.5)), kind: .main, state: s)) == [.balance(0)])
        #expect(interaction.mouseDragged(pointer(x(0.6)), kind: .main, state: s).isEmpty, "0.2 snaps to centre, unchanged")
        let right = events(interaction.mouseDragged(pointer(x(0.75)), kind: .main, state: s))
        #expect(right == [.balance(0.5)])
        #expect(events(interaction.mouseDragged(pointer(x(0)), kind: .main, state: s)) == [.balance(-1)])
        #expect(SliderValues.balance(fraction: 0.62) == 0)
        #expect(SliderValues.balance(fraction: 0.63) > 0.25)
    }

    @Test func positionPreviewsThenSeeksOnRelease() throws {
        var interaction = SkinInteraction(role: .main)
        let s = drawn(.main)  // 930 / 3720 = 0.25
        let track = try #require(SliderTrack.track(for: .position, in: .main))
        let thumb = CGPoint(x: track.leading(fraction: 0.25) + 10, y: 77)
        #expect(interaction.mouseDown(pointer(thumb), kind: .main, state: s).isEmpty)
        #expect(interaction.overrides.position == 0.25)
        let target = CGPoint(x: track.leading(fraction: 0.5) + 10, y: 77)
        #expect(interaction.mouseDragged(pointer(target), kind: .main, state: s).isEmpty)
        #expect(interaction.overrides.position == 0.5)
        #expect(events(interaction.mouseUp(pointer(target), kind: .main, state: s)) == [.seek(fraction: 0.5)])
    }

    @Test func liveStreamsCannotSeek() {
        var live = playingState()
        live.duration = nil
        let s = drawn(live, .main)
        #expect(SkinInteraction.behaviour(of: .position, in: .main, state: s) == .inert)
        #expect(click(.position, .main, role: .main, state: s).isEmpty)
        var stopped = playingState()
        stopped.playState = .stopped
        #expect(SkinInteraction.behaviour(of: .position, in: .main, state: drawn(stopped, .main)) == .inert)
    }

    @Test func eqBandsRunFromPlusTwelveAtTheTop() {
        var interaction = SkinInteraction(role: .equalizer)
        let s = drawn(.eq)
        let x = Double(EQLayout.band(4).x + 7)
        // Pressed at the top of the slider, away from the thumb: the thumb's middle jumps there (+12 dB).
        #expect(events(interaction.mouseDown(pointer(CGPoint(x: x, y: 38)), kind: .eq, state: s)) == [.eqBand(index: 4, decibels: 12)])
        #expect(events(interaction.mouseDragged(pointer(CGPoint(x: x, y: 300)), kind: .eq, state: s))
            == [.eqBand(index: 4, decibels: -12)])
        // Centre of travel: 38 + 25.5 + 5.5 (grab at the thumb's middle) → 0 dB; ±0.6 dB snaps to flat.
        #expect(events(interaction.mouseDragged(pointer(CGPoint(x: x, y: 38 + 25.5 + 5.5 + 1)), kind: .eq, state: s))
            == [.eqBand(index: 4, decibels: 0)])
        #expect(interaction.overrides.bands[4] == 0)
        #expect(interaction.pressed == .band4)
        var preamp = SkinInteraction(role: .equalizer)
        #expect(events(preamp.mouseDown(pointer(CGPoint(x: 28, y: 100)), kind: .eq, state: s)) == [.preamp(decibels: -12)])
    }

    @Test func eqSliderGeometryRoundTrips() {
        for db in stride(from: -12.0, through: 12.0, by: 3) {
            #expect(abs(SliderValues.decibels(eqFraction: SliderValues.eqFraction(decibels: db)) - db) < 1e-9)
        }
        #expect(SliderValues.decibels(eqFraction: 0.5 + 0.01) == 0, "0 dB snap")
    }

    @Test func eqShadeAndShadeSliders() {
        var eqShade = SkinInteraction(role: .equalizer)
        let es = drawn(.eqShade)
        #expect(events(eqShade.mouseDown(pointer(CGPoint(x: 0, y: 7)), kind: .eqShade, state: es)).isEmpty,
                "left of the volume slider is title bar")
        var volume = SkinInteraction(role: .equalizer)
        #expect(events(volume.mouseDown(pointer(CGPoint(x: 62.5, y: 7)), kind: .eqShade, state: es)) == [.volume(0)])
        var balance = SkinInteraction(role: .equalizer)
        #expect(events(balance.mouseDown(pointer(CGPoint(x: 206, y: 7)), kind: .eqShade, state: es)) == [.balance(1)])
        var shade = SkinInteraction(role: .main)
        let ss = drawn(.shade)
        _ = shade.mouseDown(pointer(CGPoint(x: 227.5, y: 7)), kind: .shade, state: ss)
        #expect(events(shade.mouseUp(pointer(CGPoint(x: 300, y: 7)), kind: .shade, state: ss)) == [.seek(fraction: 1)])
    }

    @Test func tracksMatchTheComposerThumbs() throws {
        let volume = try #require(SliderTrack.track(for: .volume, in: .main))
        #expect(volume.origin == 107 && volume.travel == 51 && volume.thumbLength == 14)
        let band = try #require(SliderTrack.track(for: .band9, in: .eq))
        #expect(band.axis == .vertical && band.origin == 38 && band.travel == 51 && band.thumbLength == 11)
        #expect(SliderTrack.track(for: .volume, in: .eq) == nil)
        #expect(SliderTrack.track(for: .play, in: .main) == nil)
    }
}

@Suite struct MarqueeAndDragTests {
    @Test func marqueeClickUnderThreePoints() {
        var interaction = SkinInteraction(role: .main)
        let s = drawn(.main)
        let start = centre(.marquee, in: .main)
        #expect(interaction.mouseDown(pointer(start), kind: .main, state: s).isEmpty)
        // 1 skin px at scale 2 = 2 points: still a click.
        let nudged = pointer(CGPoint(x: start.x + 1, y: start.y))
        #expect(interaction.mouseDragged(nudged, kind: .main, state: s).isEmpty)
        #expect(events(interaction.mouseUp(nudged, kind: .main, state: s)) == [.marqueeClick(screenPoint: nudged.screen)])
        #expect(interaction.marqueeDrag == 0)
    }

    @Test func marqueeDragOfThreePointsScrubsTheTitle() {
        var interaction = SkinInteraction(role: .main)
        let s = drawn(.main)
        let start = centre(.marquee, in: .main)
        _ = interaction.mouseDown(pointer(start), kind: .main, state: s)
        // 1.5 skin px at scale 2 = 3 points: a drag.
        let outputs = interaction.mouseDragged(pointer(CGPoint(x: start.x + 1.5, y: start.y)), kind: .main, state: s)
        #expect(outputs == [.marqueeScrubBegan])
        #expect(interaction.isScrubbingMarquee)
        _ = interaction.mouseDragged(pointer(CGPoint(x: start.x + 20, y: start.y + 4)), kind: .main, state: s)
        #expect(interaction.marqueeDrag == -20, "the text follows the pointer")
        #expect(interaction.mouseUp(pointer(CGPoint(x: start.x + 20, y: start.y)), kind: .main, state: s) == [.marqueeScrubEnded])
        // The next scrub continues from there.
        _ = interaction.mouseDown(pointer(start), kind: .main, state: s)
        _ = interaction.mouseDragged(pointer(CGPoint(x: start.x - 30, y: start.y)), kind: .main, state: s)
        #expect(interaction.marqueeDrag == 10)
    }

    @Test func titleBarAndBackgroundDragTheWindow() {
        var interaction = SkinInteraction(role: .main)
        let s = drawn(.main)
        let title = pointer(CGPoint(x: 100, y: 5))
        #expect(interaction.mouseDown(title, kind: .main, state: s) == [.beginWindowDrag(screen: title.screen)])
        let moved = pointer(CGPoint(x: 130, y: 25))
        #expect(interaction.mouseDragged(moved, kind: .main, state: s) == [.dragWindow(screen: moved.screen)])
        #expect(interaction.mouseUp(moved, kind: .main, state: s) == [.endWindowDrag])
        let background = pointer(CGPoint(x: 3, y: 60))
        #expect(Layout.hitTest(.main, IntPoint(3, 60)) == nil)
        #expect(interaction.mouseDown(background, kind: .main, state: s) == [.beginWindowDrag(screen: background.screen)])
        _ = interaction.mouseUp(background, kind: .main, state: s)
        var eq = SkinInteraction(role: .equalizer)
        let graph = pointer(centre(.eqGraph, in: .eq))
        #expect(eq.mouseDown(graph, kind: .eq, state: drawn(.eq)) == [.beginWindowDrag(screen: graph.screen)])
    }

    @Test func doubleClickOnTheTitleBarTogglesShade() {
        var interaction = SkinInteraction(role: .main)
        let s = drawn(.main)
        let first = pointer(CGPoint(x: 100, y: 5))
        _ = interaction.mouseDown(first, kind: .main, state: s)
        _ = interaction.mouseUp(first, kind: .main, state: s)
        let second = pointer(CGPoint(x: 100, y: 5), clickCount: 2)
        #expect(interaction.mouseDown(second, kind: .main, state: s) == [.event(.shade(.main))])
        #expect(interaction.gesture == nil, "no drag after the shade toggle")
        var eq = SkinInteraction(role: .equalizer)
        #expect(events(eq.mouseDown(second, kind: .eq, state: drawn(.eq))) == [.shade(.equalizer)])
        var shaded = SkinInteraction(role: .main)
        let strip = pointer(CGPoint(x: 40, y: 7), clickCount: 2)  // (100, 5) is the shade strip's visualiser
        #expect(events(shaded.mouseDown(strip, kind: .shade, state: drawn(.shade))) == [.shade(.main)])
    }

    @Test func rightClickAsksForTheContextMenuAndEndsADrag() {
        var interaction = SkinInteraction(role: .playlist)
        let s = drawn(.playlist)
        let at = pointer(CGPoint(x: 100, y: 5))
        _ = interaction.mouseDown(at, kind: .playlist, state: s)
        #expect(interaction.rightMouseDown(at) == [.endWindowDrag, .event(.contextMenu(screenPoint: at.screen))])
        var idle = SkinInteraction(role: .main)
        #expect(idle.rightMouseDown(at) == [.event(.contextMenu(screenPoint: at.screen))])
    }

    @Test func everyHotspotHasABehaviour() {
        for kind in WindowKind.allCases {
            let state = drawn(kind)
            for (control, _) in Layout.hitRects(kind) {
                let behaviour = SkinInteraction.behaviour(of: control, in: kind, state: state)
                if behaviour == .button {
                    let event = SkinInteraction.buttonEvent(control, role: .main, kind: kind, state: state, screen: .zero)
                    #expect(event != nil || [.playlistScrollUp, .playlistScrollDown].contains(control),
                            "\(kind)/\(control) is a button without an event")
                }
            }
        }
    }

    @Test func eventsDescribeThemselvesForLogs() {
        #expect(SkinControlEvent.volume(0.5).description == "volume(0.500)")
        #expect(SkinControlEvent.eqBand(index: 2, decibels: -3).description == "eqBand(2, -3.000 dB)")
        #expect(SkinControlEvent.marqueeClick(screenPoint: CGPoint(x: 10.4, y: 20.6)).description == "marqueeClick@10,21")
        #expect(SkinControlEvent.shade(.equalizer).description == "shade(equalizer)")
        #expect(SkinView.keyEvent("x") == .play && SkinView.keyEvent("B") == .next && SkinView.keyEvent("q") == nil)
    }
}
