// SPDX-License-Identifier: GPL-3.0-or-later
// Docking geometry and the live WindowManager geometry (PLAN M5: "the ported Webamp snapUtils tests and Bitamp
// docking tests pass against the live WindowManager geometry"). The Webamp snapUtils cases themselves run on
// SkinKit's SnapGeometry (SnapGeometryTests); these exercise the WindowManager rules built on it.
//
// Adapted test cases, with their notices:
// - Bitamp Tests/BitampTests/BitampTests.swift DockingTests @ 91952819 (MIT, Copyright (c) 2026 Ryan Romanosky and
//   Bitamp contributors): same frames, snap distance 15 instead of 10, three windows instead of five.
// - MacAmp Tests/MacAmpTests/ScreenClampTests.swift and DockGraphTests.swift @ cb0c77f (MIT, Copyright (c)
//   2025-2026 Hank Yeomans): the clamp cases, converted to top-left space.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to the following conditions: The above
// copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
// LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
// SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
// OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
import AppKit
import SkinKit
import Testing
@testable import SkinUI

/// Moves `role` alone (as a drag of a non-main window would) from `start` and returns where it lands.
func dragLanding(_ role: SkinWindowRole, frames: DockingGeometry.Frames, by delta: IntPoint = .zero,
                 screens: [DockScreen] = []) -> IntRect {
    let drag = DockDrag(lead: role, moving: [role], start: [role: frames[role]!], startMouse: .zero)
    let offset = DockingGeometry.dragOffset(drag, mouse: delta, frames: frames, visible: Set(frames.keys), screens: screens)
    return DockingGeometry.apply(drag, offset: offset)[role]!
}

@Suite struct BitampDockingTests {
    let main = tl(100, 500, 550, 232)

    @Test func snapsBelowAndAligned() {
        // 6 points below and 4 to the right of a flush stack under the main window.
        let near = tl(104, 500 - 232 - 6, 550, 232)
        #expect(dragLanding(.equalizer, frames: [.main: main, .equalizer: near]) == tl(100, 500 - 232, 550, 232))
    }

    @Test func leavesFarWindowsAlone() {
        let far = tl(400, 100, 550, 232)
        #expect(dragLanding(.equalizer, frames: [.main: main, .equalizer: far]) == far)
    }

    @Test func snapsToScreenEdges() {
        let screen = DockScreen(frame: tl(0, 0, 1440, 900), visible: tl(0, 0, 1440, 900))
        let nearCorner = tl(7, 895 - 232, 550, 232)
        #expect(dragLanding(.playlist, frames: [.playlist: nearCorner], screens: [screen]) == tl(0, 900 - 232, 550, 232))
    }

    @Test func dockedFollowsChains() {
        let equalizer = tl(100, 268, 550, 232)  // under main
        let playlist = tl(100, 36, 550, 232)    // under the equalizer
        #expect(DockingGeometry.cluster(of: .main, frames: [.main: main, .equalizer: equalizer, .playlist: playlist])
            == [.main, .equalizer, .playlist])
        let sideways = tl(650, 600, 550, 232)   // right of main
        #expect(DockingGeometry.cluster(of: .main, frames: [.main: main, .equalizer: equalizer, .playlist: sideways])
            == [.main, .equalizer, .playlist])
        let loose = tl(900, 500, 550, 232)
        #expect(DockingGeometry.cluster(of: .main, frames: [.main: main, .equalizer: equalizer, .playlist: loose])
            == [.main, .equalizer])
    }

    @Test func cornersDoNotDock() {
        let diagonal = tl(650, 268, 550, 232)
        #expect(!SnapGeometry.areTouching(main, diagonal))
        #expect(DockingGeometry.cluster(of: .main, frames: [.main: main, .equalizer: diagonal]) == [.main])
    }
}

@Suite struct DockingGeometryTests {
    let main = IntRect(100, 100, 275, 116)

    @Test func snapDistanceIsFifteenPoints() {
        let fourteen = IntRect(100, 216 + 14, 275, 116)
        let fifteen = IntRect(100, 216 + 15, 275, 116)
        #expect(dragLanding(.equalizer, frames: [.main: main, .equalizer: fourteen]) == IntRect(100, 216, 275, 116))
        #expect(dragLanding(.equalizer, frames: [.main: main, .equalizer: fifteen]) == fifteen)
    }

    @Test func aClosedWindowStillLinksTheChain() {
        // MacAmp DockGraphTests.closedMiddleWindowKeepsChain: frames of closed windows still count.
        let frames: DockingGeometry.Frames = [.main: IntRect(0, 0, 275, 116), .equalizer: IntRect(0, 116, 275, 116),
                                              .playlist: IntRect(0, 232, 275, 232)]
        #expect(DockingGeometry.cluster(of: .main, frames: frames) == [.main, .equalizer, .playlist])
        var withoutEQ = frames
        withoutEQ[.equalizer] = nil
        #expect(DockingGeometry.cluster(of: .main, frames: withoutEQ) == [.main])
    }

    @Test func mainCarriesItsClusterOthersMoveAlone() {
        let frames: DockingGeometry.Frames = [.main: main, .equalizer: IntRect(100, 216, 275, 116),
                                              .playlist: IntRect(375, 100, 275, 232)]
        #expect(DockingGeometry.beginDrag(.main, frames: frames, mouse: .zero).moving == [.main, .equalizer, .playlist])
        #expect(DockingGeometry.beginDrag(.equalizer, frames: frames, mouse: .zero).moving == [.equalizer])
        let drag = DockingGeometry.beginDrag(.main, frames: frames, mouse: IntPoint(10, 10))
        let offset = DockingGeometry.dragOffset(drag, mouse: IntPoint(310, 60), frames: frames, visible: [.main, .equalizer, .playlist],
                                                screens: [])
        #expect(offset == IntPoint(300, 50))
        let moved = DockingGeometry.apply(drag, offset: offset)
        #expect(moved[.equalizer] == IntRect(400, 266, 275, 116) && moved[.playlist] == IntRect(675, 150, 275, 232))
    }

    @Test func hiddenWindowsAreNotSnapTargets() {
        let eq = IntRect(100, 226, 275, 116)  // 10 below main
        let drag = DockDrag(lead: .equalizer, moving: [.equalizer], start: [.equalizer: eq], startMouse: .zero)
        let frames: DockingGeometry.Frames = [.main: main, .equalizer: eq]
        #expect(DockingGeometry.dragOffset(drag, mouse: .zero, frames: frames, visible: [.equalizer], screens: []) == .zero)
        #expect(DockingGeometry.dragOffset(drag, mouse: .zero, frames: frames, visible: [.main, .equalizer], screens: [])
            == IntPoint(0, -10))
    }

    @Test func windowsCanCrossDisplaysAndNeverHideUnderTheMenuBar() {
        let left = DockScreen(frame: IntRect(0, 0, 1000, 800), visible: IntRect(0, 25, 1000, 775))
        let right = DockScreen(frame: IntRect(1000, 0, 1000, 800), visible: IntRect(1000, 25, 1000, 775))
        let start = IntRect(400, 300, 275, 116)
        // Halfway across the boundary: no clamping back onto the left display.
        let across = dragLanding(.playlist, frames: [.playlist: start], by: IntPoint(480, 0), screens: [left, right])
        #expect(across == IntRect(880, 300, 275, 116))
        // Dragged up into the menu bar strip: pushed down to the visible top.
        let up = dragLanding(.playlist, frames: [.playlist: start], by: IntPoint(0, -295), screens: [left, right])
        #expect(up.y == 25)
        // Near the visible top: snaps to it.
        let near = dragLanding(.playlist, frames: [.playlist: start], by: IntPoint(0, -265), screens: [left, right])
        #expect(near.y == 25)
    }

    @Test func shadeKeepsTheTopAndPullsUpWhatHangsBelow() {
        let frames: DockingGeometry.Frames = [.main: IntRect(0, 0, 275, 116), .equalizer: IntRect(0, 116, 275, 116),
                                              .playlist: IntRect(0, 232, 275, 232)]
        let shaded = DockingGeometry.resize(.main, to: IntSize(275, 14), frames: frames)
        #expect(shaded[.main] == IntRect(0, 0, 275, 14))
        #expect(shaded[.equalizer] == IntRect(0, 14, 275, 116))
        #expect(shaded[.playlist] == IntRect(0, 130, 275, 232))
        #expect(DockingGeometry.resize(.main, to: IntSize(275, 116), frames: shaded) == frames)
        // A window beside the shaded one stays; one hanging under a moved window follows it.
        let side: DockingGeometry.Frames = [.main: IntRect(0, 0, 275, 116), .playlist: IntRect(275, 0, 275, 232),
                                            .equalizer: IntRect(0, 116, 275, 116)]
        let result = DockingGeometry.resize(.main, to: IntSize(275, 14), frames: side)
        #expect(result[.playlist] == IntRect(275, 0, 275, 232))
        #expect(result[.equalizer] == IntRect(0, 14, 275, 116))
    }

    @Test func rescaleKeepsDockedWindowsDocked() {
        let frames: DockingGeometry.Frames = [.main: IntRect(10, 20, 275, 116), .equalizer: IntRect(10, 136, 275, 116),
                                              .playlist: IntRect(285, 20, 275, 232)]
        let sizes: [SkinWindowRole: IntSize] = [.main: IntSize(550, 232), .equalizer: IntSize(550, 232), .playlist: IntSize(550, 464)]
        let doubled = DockingGeometry.rescale(frames, sizes: sizes, anchor: .main, oldScale: 1, newScale: 2)
        #expect(doubled[.main] == IntRect(10, 20, 550, 232))
        #expect(doubled[.equalizer] == IntRect(10, 252, 550, 232))
        #expect(doubled[.playlist] == IntRect(560, 20, 550, 464))
        #expect(DockingGeometry.cluster(of: .main, frames: doubled) == [.main, .equalizer, .playlist])
    }

    @Test func newWindowsOpenDockedUnderTheCluster() {
        let frames: DockingGeometry.Frames = [.main: IntRect(0, 0, 275, 116), .playlist: IntRect(0, 116, 275, 232)]
        #expect(DockingGeometry.dockedBelowCluster(.equalizer, size: IntSize(275, 116), frames: frames) == IntRect(0, 348, 275, 116))
        #expect(DockingGeometry.stacked(mainTopLeft: IntPoint(5, 6), sizes: [.main: IntSize(275, 116), .equalizer: IntSize(275, 116)],
                                        order: [.main, .equalizer]) == [.main: IntRect(5, 6, 275, 116), .equalizer: IntRect(5, 122, 275, 116)])
    }

    @Test func coordinatesRoundTripThroughAppKit() {
        let frame = CGRect(x: 100, y: 500, width: 550, height: 232)
        let box = DockingGeometry.topLeft(frame)
        #expect(box == IntRect(100, -732, 550, 232))
        #expect(DockingGeometry.appKit(box) == frame)
        #expect(DockingGeometry.topLeft(CGPoint(x: 3, y: 4)) == IntPoint(3, -4))
        let screen = DockScreen(frame: IntRect(0, -900, 1440, 900), visible: IntRect(0, -875, 1440, 875))
        #expect(screen.menuBar == IntRect(0, -900, 1440, 25))
    }
}

/// MacAmp's ScreenClamp cases (AppKit numbers, converted). Screen: 3840x1600 with a 30 px menu bar.
@Suite struct ScreenClampTests {
    let lg = tl(0, 0, 3840, 1570)
    let main = tl(100, 1200, 550, 232)
    let eq = tl(100, 968, 550, 232)

    func appKit(_ r: IntRect?) -> CGRect? { r.map(DockingGeometry.appKit) }

    @Test func aGroupAlreadyOnScreenDoesNotMove() {
        #expect(DockingGeometry.clamp([.main: main, .equalizer: eq], visible: [.main, .equalizer], visibleFrames: [lg]).isEmpty)
    }

    @Test func anOffScreenDockedGroupMovesBackAsAUnit() throws {
        let low: DockingGeometry.Frames = [.main: main.offsetBy(0, 2000), .equalizer: eq.offsetBy(0, 2000)]
        let moved = DockingGeometry.clamp(low, visible: [.main, .equalizer], visibleFrames: [lg])
        let newMain = try #require(appKit(moved[.main])), newEQ = try #require(appKit(moved[.equalizer]))
        #expect(newEQ.minY == 0)
        #expect(newMain.minY - newEQ.maxY == 0)
        #expect(newMain.minX == newEQ.minX)
    }

    @Test func aGroupTallerThanTheScreenKeepsItsTopOnScreen() {
        let tall = tl(593, -21312, 400, 1566 + 100)
        let moved = DockingGeometry.clamp([.playlist: tall], visible: [.playlist], visibleFrames: [lg])
        #expect(appKit(moved[.playlist])?.maxY == 1570)
    }

    @Test func aTopEdgeAboveTheVisibleFrameIsPulledDown() {
        let moved = DockingGeometry.clamp([.main: main.offsetBy(0, -500)], visible: [.main], visibleFrames: [lg])
        #expect(appKit(moved[.main])?.maxY == 1570)
    }

    @Test func aWindowOnAVanishedDisplayMovesToTheMainScreen() throws {
        let laptop = tl(0, 0, 1512, 949)
        let moved = DockingGeometry.clamp([.main: tl(3000, 1200, 550, 232)], visible: [.main], visibleFrames: [laptop])
        let frame = try #require(moved[.main])
        #expect(laptop.contains(frame))
    }

    @Test func theScreenOverlappingTheGroupMostIsChosen() {
        let left = tl(-1512, 0, 1512, 949)
        #expect(DockingGeometry.clampScreen(for: tl(-1300, 900, 550, 232), visibleFrames: [lg, left]) == left)
    }

    @Test func aHiddenOnlyGroupIsMeasuredByItsOwnFrames() {
        let moved = DockingGeometry.clamp([.playlist: tl(5000, 300, 1200, 725)], visible: [], visibleFrames: [lg])
        #expect(appKit(moved[.playlist])?.maxX == 3840)
    }

    @Test func visibleMembersDecideTheOffsetHiddenMembersFollow() throws {
        let frames: DockingGeometry.Frames = [.main: main.offsetBy(0, 2000), .equalizer: eq.offsetBy(0, 2000)]
        let moved = DockingGeometry.clamp(frames, visible: [.main], visibleFrames: [lg])
        let newMain = try #require(appKit(moved[.main])), newEQ = try #require(appKit(moved[.equalizer]))
        #expect(newMain.minY == 0)
        #expect(newMain.minY - newEQ.maxY == 0)
    }

    @Test func strandedGroupsThatFitTogetherMoveTogether() throws {
        let laptop = tl(0, 0, 1800, 1130)
        let playlist = tl(900, 1200, 550, 464)  // right of the Main/EQ group, off-screen above
        let frames: DockingGeometry.Frames = [.main: main, .equalizer: eq, .playlist: playlist]
        let moved = DockingGeometry.clamp(frames, visible: [.main, .equalizer, .playlist], visibleFrames: [laptop])
        let newMain = try #require(moved[.main]), newPlaylist = try #require(moved[.playlist])
        #expect(newPlaylist.x - newMain.x == playlist.x - main.x)
        #expect(newPlaylist.y - newMain.y == playlist.y - main.y)
        #expect(laptop.contains(newMain) && laptop.contains(newPlaylist))
    }

    @Test func strandedGroupsTooWideToFitTogetherAreClampedAlone() throws {
        let laptop = tl(0, 0, 1800, 1130)
        let playlist = tl(2600, 300, 550, 464)  // off the right edge; Main/EQ off the top
        let moved = DockingGeometry.clamp([.main: main, .equalizer: eq, .playlist: playlist],
                                          visible: [.main, .equalizer, .playlist], visibleFrames: [laptop])
        let newMain = try #require(moved[.main]), newEQ = try #require(moved[.equalizer])
        let newPlaylist = try #require(moved[.playlist])
        #expect(laptop.contains(newMain) && laptop.contains(newEQ) && laptop.contains(newPlaylist))
        #expect(newEQ.y == newMain.maxY && newMain.x == newEQ.x, "still docked")
    }
}

/// The live WindowManager (real SkinWindows, never ordered on screen; screens injected).
@MainActor @Suite(.serialized) struct WindowManagerTests {
    @Test func firstLaunchStacksTheWindowsCentredOnTheMainScreen() {
        let manager = makeManager(scale: 1)
        defer { manager.close() }
        let frames = manager.frames()
        #expect(frames[.main] == IntRect(582, -670, 275, 116))
        #expect(frames[.equalizer] == IntRect(582, -554, 275, 116))
        #expect(frames[.playlist] == IntRect(582, -438, 275, 232))
        #expect(manager.windows[.main]?.frame == CGRect(x: 582, y: 554, width: 275, height: 116))
        #expect(manager.openWindows == [.main, .equalizer, .playlist])
    }

    @Test func designFirstLaunchOpensMainAndPlaylistDocked() {
        let manager = makeManager(scale: 1, open: [.main, .playlist])
        defer { manager.close() }
        let frames = manager.frames()
        #expect(frames[.playlist]?.y == frames[.main]?.maxY, "Playlist docked under Main")
        #expect(frames[.equalizer]?.y == frames[.playlist]?.maxY, "the closed EQ waits at the bottom of the stack")
        #expect(manager.windows[.main]?.skinView.chrome.eqOpen == false)
        #expect(manager.windows[.main]?.skinView.chrome.playlistOpen == true)
    }

    @Test(arguments: [1, 2, 3])
    func windowsArePixelExactAtEveryScale(scale: Int) {
        let manager = makeManager(scale: scale)
        defer { manager.close() }
        for (role, window) in manager.windows {
            let kind = role.kind(shaded: false)
            #expect(window.frame.size == SkinScale.pointSize(kind, scale: scale), "\(role)")
            #expect(window.skinView.frame.size == SkinScale.pointSize(kind, scale: scale))
            #expect(window.frame.origin.x == window.frame.origin.x.rounded() && window.frame.origin.y == window.frame.origin.y.rounded())
        }
    }

    @Test func draggingMainMovesItsDockedClusterAndSnaps() {
        let manager = makeManager(scale: 1)
        defer { manager.close() }
        let before = manager.frames()
        manager.beginDrag(.main, mouse: CGPoint(x: 600, y: 660))
        #expect(manager.isDragging)
        manager.continueDrag(mouse: CGPoint(x: 700, y: 610))  // right 100, down 50
        manager.endDrag()
        let after = manager.frames()
        for role in SkinWindowRole.allCases {
            #expect(after[role] == before[role]!.offsetBy(100, 50), "\(role)")
        }
        // Near the left screen edge (within 15): snaps flush.
        manager.beginDrag(.main, mouse: .zero)
        manager.continueDrag(mouse: CGPoint(x: -(682 - 9), y: 0))
        manager.endDrag()
        #expect(manager.frames()[.main]?.x == 0)
        #expect(manager.frames()[.playlist]?.x == 0)
    }

    @Test func otherWindowsDragAloneAndRedockBySnapping() {
        let manager = makeManager(scale: 1)
        defer { manager.close() }
        let main = manager.frames()[.main]!
        manager.beginDrag(.equalizer, mouse: .zero)
        manager.continueDrag(mouse: CGPoint(x: 400, y: 0))
        manager.endDrag()
        #expect(manager.frames()[.equalizer] == IntRect(main.x + 400, main.maxY, 275, 116))
        #expect(manager.frames()[.main] == main, "Main stays")
        #expect(DockingGeometry.cluster(of: .main, frames: manager.frames()) == [.main])
        // Back to 6 right / 4 below Main's bottom-left: snaps flush under Main.
        manager.beginDrag(.equalizer, mouse: .zero)
        manager.continueDrag(mouse: CGPoint(x: -394, y: -4))
        manager.endDrag()
        #expect(manager.frames()[.equalizer] == IntRect(main.x, main.maxY, 275, 116))
        #expect(DockingGeometry.cluster(of: .main, frames: manager.frames()) == [.main, .equalizer, .playlist])
    }

    @Test func shadeAndScaleKeepTheStackDocked() {
        let manager = makeManager(scale: 1)
        defer { manager.close() }
        let main = manager.frames()[.main]!
        manager.setShaded(true, .main)
        #expect(manager.isShaded(.main))
        #expect(manager.windows[.main]?.skinView.kind == .shade)
        #expect(manager.frames()[.main] == IntRect(main.x, main.y, 275, 14))
        #expect(manager.frames()[.equalizer]?.y == main.y + 14)
        #expect(manager.frames()[.playlist]?.y == main.y + 14 + 116)
        manager.setScale(2)
        // Rescaled around Main's top-left; the 2x stack is then clamped up onto the 875-point screen as a unit.
        let frames = manager.frames()
        let top = frames[.main]!
        #expect(top.x == main.x && top.size == IntSize(550, 28))
        #expect(frames[.equalizer] == IntRect(main.x, top.maxY, 550, 232))
        #expect(frames[.playlist] == IntRect(main.x, top.maxY + 232, 550, 464))
        #expect(frames[.playlist]!.maxY <= 0, "inside the visible frame")
        manager.setShaded(false, .main)
        #expect(manager.frames()[.equalizer]?.y == top.y + 232)
        manager.toggleScale()
        #expect(manager.scale == 1)
        manager.cycleScale()
        manager.cycleScale()
        #expect(manager.scale == 3)
        manager.setShaded(true, .playlist)
        #expect(!manager.isShaded(.playlist), "no playlist shade in v1")
    }

    @Test func windowEventsAreAppliedAndForwarded() {
        let manager = makeManager(scale: 1)
        defer { manager.close() }
        var received: [(SkinControlEvent, SkinWindowRole)] = []
        manager.onEvent = { received.append(($0, $1)) }
        manager.handle(.shade(.equalizer), from: .equalizer)
        #expect(manager.isShaded(.equalizer) && manager.frames()[.equalizer]?.height == 14)
        manager.handle(.close(.playlist), from: .playlist)
        #expect(!manager.isOpen(.playlist))
        #expect(manager.windows[.main]?.skinView.chrome.playlistOpen == false)
        manager.handle(.plToggle, from: .main)
        #expect(manager.isOpen(.playlist))
        manager.handle(.eqWindowToggle, from: .main)
        #expect(!manager.isOpen(.equalizer))
        manager.handle(.clutter(.alwaysOnTop, screenPoint: .zero), from: .main)
        #expect(manager.alwaysOnTop && manager.windows[.playlist]?.level == .floating)
        manager.handle(.clutter(.doubleSize, screenPoint: .zero), from: .main)
        #expect(manager.scale == 2 && manager.windows[.main]?.skinView.chrome.doubleSize == true)
        manager.handle(.close(.main), from: .main)
        #expect(manager.isOpen(.main), "closing Main is the app's quit, not a hide")
        manager.handle(.play, from: .playlist)
        #expect(received.count == 8)
        #expect(received.last.map { $0.0 == .play && $0.1 == .playlist } == true)
    }

    @Test func layoutPersistsAndRestores() throws {
        let dir = try TempDir()
        let url = dir.url.appending(path: "profile/layout.json")
        do {
            let manager = makeManager(scale: 1, layoutURL: url)
            manager.beginDrag(.main, mouse: .zero)
            manager.continueDrag(mouse: CGPoint(x: -200, y: 100))
            manager.endDrag()
            manager.setShaded(true, .equalizer)
            manager.setOpen(false, .playlist)
            manager.setScale(2)
            manager.setAlwaysOnTop(true)
            #expect(manager.lastSaveError == nil)
            let saved = manager.frames()
            manager.close()
            let restored = makeManager(scale: nil, layoutURL: url)
            defer { restored.close() }
            #expect(restored.scale == 2)
            #expect(restored.frames() == saved)
            #expect(restored.isShaded(.equalizer) && !restored.isOpen(.playlist) && restored.alwaysOnTop)
            #expect(restored.windows[.equalizer]?.skinView.kind == .eqShade)
        }
        let layout = try #require(WindowLayout.load(from: url))
        #expect(layout.version == 1 && layout.scale == 2 && layout.entry(.playlist)?.open == false)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"equalizer\"") && text.contains("\"shaded\" : true"))
    }

    @Test func badLayoutFilesAreIgnored() throws {
        let dir = try TempDir()
        let url = dir.url.appending(path: "layout.json")
        #expect(WindowLayout.load(from: url) == nil, "missing")
        try Data("not json".utf8).write(to: url)
        #expect(WindowLayout.load(from: url) == nil)
        var future = WindowLayout(scale: 2, alwaysOnTop: false, windows: [:])
        future.version = 99
        try future.save(to: url)
        #expect(WindowLayout.load(from: url) == nil)
        try WindowLayout(scale: 5, alwaysOnTop: false, windows: [:]).save(to: url)
        #expect(WindowLayout.load(from: url) == nil)
        try WindowLayout(scale: 2, alwaysOnTop: false, windows: [.main: .init(x: 1e9, top: 0, open: true, shaded: false)])
            .save(to: url)
        #expect(WindowLayout.load(from: url) == nil)
        let manager = makeManager(scale: 1, layoutURL: url)
        defer { manager.close() }
        #expect(manager.frames()[.main] == IntRect(582, -670, 275, 116), "falls back to the default stack")
    }

    @Test func displayChangesBringStrandedGroupsBack() {
        let screens = ScreenBox([testScreen])
        let manager = makeManager(scale: 1, screens: screens)
        defer { manager.close() }
        // The display the windows were on is replaced by a small one to the left.
        screens.screens = [DockScreen(frame: IntRect(-800, -600, 800, 600), visible: IntRect(-800, -575, 800, 575))]
        manager.clampToScreens()
        let frames = manager.frames()
        let visible = IntRect(-800, -575, 800, 575)
        for role in SkinWindowRole.allCases { #expect(visible.contains(frames[role]!), "\(role)") }
        #expect(DockingGeometry.cluster(of: .main, frames: frames) == [.main, .equalizer, .playlist], "still docked")
        manager.regroup()
        #expect(manager.frames()[.equalizer]?.y == manager.frames()[.main]?.maxY)
    }

    @Test func skinSwitchingAndTheRegionKillSwitch() throws {
        let manager = makeManager(scale: 2)
        defer { manager.close() }
        let andamp = try #require(SkinLoader.load(url: Repo.url("Fixtures/skins/AndAmp-Dark.wsz")).skin)
        manager.setSkin(andamp)
        let view = try #require(manager.windows[.main]?.skinView)
        #expect(view.skin.name == "AndAmp-Dark")
        let shaped = try #require(view.baseBitmap)
        #expect(stride(from: 3, to: shaped.pixels.count, by: 4).contains { shaped.pixels[$0] == 0 }, "region.txt cut-outs")
        manager.setRegionEnabled(false)
        let square = try #require(view.baseBitmap)
        #expect(stride(from: 3, to: square.pixels.count, by: 4).allSatisfy { square.pixels[$0] == 255 }, "kill switch: opaque")
        #expect(!manager.regionEnabled)
    }

    @Test func playerStateReachesEveryWindow() {
        let manager = makeManager(scale: 1)
        defer { manager.close() }
        var state = playingState()
        state.volume = 0.2
        manager.playerState = state
        for window in manager.windows.values { #expect(window.skinView.playerState.volume == 0.2) }
        manager.scrollPlaylist(toRow: 2)
        #expect(manager.windows[.playlist]?.skinView.firstVisibleRow == 2)
        #expect(manager.describeFrames().split(separator: "\n").count == 3)
    }
}
