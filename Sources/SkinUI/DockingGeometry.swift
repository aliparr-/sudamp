// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure docking geometry for WindowManager (DESIGN §8.1): which windows are docked, where a drag lands after
// snapping, what follows a shade toggle or a scale change, and how stranded windows come back on screen.
//
// Space: whole points, "top-left space" (x right, y down: y = -maxY of the AppKit frame). Docking is
// translation-invariant, so no screen is needed to convert. Windows are always (skin size × scale) points at
// whole-point origins, so docked windows touch exactly and SkinKit's SnapGeometry (Webamp snapUtils, 15 px)
// applies unchanged; the snap distance is 15 points at every scale, as Webamp's is 15 CSS px in double mode.
//
// Sources: the snap/touching primitives are SkinKit's SnapGeometry (Webamp snapUtils @ 7734cd3). The rules on
// top are adapted from Bitamp's Docking.swift/WindowGroup (ryanromanov/Bitamp @ 91952819: Main drags its docked
// group, other windows move alone, shade keeps the top edge and moves what hangs below, scale rescales around
// Main's top-left) and MacAmp (hfyeomans/MacAmp @ cb0c77f: closed windows keep linking the dock chain; the
// menu-bar strip guard from WindowSnapManager; `clamp` is a port of Models/ScreenClamp.swift, itself Webamp's
// `ensureWindowsAreOnScreen`).
//
// Notices:
//
// MacAmp — MIT License, Copyright (c) 2025-2026 Hank Yeomans
// Bitamp — MIT License, Copyright (c) 2026 Ryan Romanosky and Bitamp contributors
// Webamp — The MIT License (MIT), Copyright (c) [2015] [Jordan Eldredge]
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

import CoreGraphics
import SkinKit

/// One display: its full frame and its visible frame (below the menu bar, beside the Dock), in top-left space.
nonisolated public struct DockScreen: Equatable, Sendable {
    public var frame: IntRect
    public var visible: IntRect

    public init(frame: IntRect, visible: IntRect) {
        self.frame = frame
        self.visible = visible
    }

    /// The menu-bar strip (between the frame's top and the visible top), if any.
    public var menuBar: IntRect? {
        let inset = visible.y - frame.y
        return inset > 0 ? IntRect(frame.x, frame.y, frame.width, inset) : nil
    }
}

/// A drag in progress: who moves, from where.
nonisolated public struct DockDrag: Equatable, Sendable {
    public var lead: SkinWindowRole
    public var moving: Set<SkinWindowRole>
    public var start: [SkinWindowRole: IntRect]
    public var startMouse: IntPoint
}

nonisolated public enum DockingGeometry {
    public typealias Frames = [SkinWindowRole: IntRect]

    // MARK: Spaces

    /// An AppKit frame (y up) in top-left space, rounded to whole points.
    public static func topLeft(_ frame: CGRect) -> IntRect {
        IntRect(Int(frame.minX.rounded()), Int((-frame.maxY).rounded()),
                Int(frame.width.rounded()), Int(frame.height.rounded()))
    }

    public static func appKit(_ rect: IntRect) -> CGRect {
        CGRect(x: rect.x, y: -(rect.y + rect.height), width: rect.width, height: rect.height)
    }

    /// An AppKit screen point in top-left space.
    public static func topLeft(_ point: CGPoint) -> IntPoint {
        IntPoint(Int(point.x.rounded()), Int((-point.y).rounded()))
    }

    // MARK: Docking

    /// Every window transitively touching `role` edge to edge (Webamp's traceConnection over areTouching),
    /// including `role`. Closed windows keep linking the chain, as in MacAmp, so a hidden EQ between Main and
    /// the Playlist still holds them together.
    public static func cluster(of role: SkinWindowRole, frames: Frames) -> Set<SkinWindowRole> {
        let candidates = SkinWindowRole.allCases.filter { frames[$0] != nil }
        let found = SnapGeometry.traceConnection(candidates, from: role) { a, b in
            guard let ra = frames[a], let rb = frames[b] else { return false }
            return SnapGeometry.areTouching(ra, rb)
        }
        return Set(found).union([role])
    }

    /// Starts a drag: Main carries its docked cluster; the equalizer and playlist move alone (Bitamp, Winamp).
    public static func beginDrag(_ lead: SkinWindowRole, frames: Frames, mouse: IntPoint) -> DockDrag {
        let moving: Set<SkinWindowRole> = lead == .main ? cluster(of: .main, frames: frames) : [lead]
        return DockDrag(lead: lead, moving: moving, start: frames.filter { moving.contains($0.key) }, startMouse: mouse)
    }

    /// The offset to apply to every moving window's start frame for the pointer at `mouse`: the moving group's
    /// bounding box snaps to the visible stationary windows (15 px), then to the edges of the screen it is
    /// mostly on (screen edges win, as in Webamp's applySnap order), and never tucks under a menu bar.
    public static func dragOffset(_ drag: DockDrag, mouse: IntPoint, frames: Frames, visible: Set<SkinWindowRole>,
                                  screens: [DockScreen]) -> IntPoint {
        guard let box = SnapGeometry.boundingBox(Array(drag.start.values)) else { return .zero }
        let raw = IntPoint(mouse.x - drag.startMouse.x, mouse.y - drag.startMouse.y)
        let proposed = box.offsetBy(raw.x, raw.y)
        let others = frames.filter { visible.contains($0.key) && !drag.moving.contains($0.key) }.map(\.value)
        let toOthers = SnapGeometry.snapToMany(proposed, others)
        var snapped = SnapGeometry.applySnap(proposed.origin, toOthers)
        if let screen = bestScreen(for: proposed, screens: screens) {
            snapped = SnapGeometry.applySnap(snapped, snapToEdges(proposed, screen.visible))
        }
        if let strip = screens.compactMap(\.menuBar).first(where: { strip in
            let centre = snapped.x + box.width / 2
            return centre >= strip.minX && centre < strip.maxX
                && snapped.y >= strip.minY - SnapGeometry.snapDistance && snapped.y < strip.maxY
        }) {
            snapped.y = strip.maxY
        }
        return IntPoint(snapped.x - box.x, snapped.y - box.y)
    }

    /// The moving windows' frames after `offset`.
    public static func apply(_ drag: DockDrag, offset: IntPoint) -> Frames {
        drag.start.mapValues { $0.offsetBy(offset.x, offset.y) }
    }

    /// Snaps a box to the inside edges of `bounds` when an edge is within the snap distance on either side.
    /// Unlike Webamp's snapWithin (one browser viewport), this never clamps, so windows can cross displays.
    public static func snapToEdges(_ box: IntRect, _ bounds: IntRect) -> SnapOffset {
        var result = SnapOffset()
        if SnapGeometry.near(box.minX, bounds.minX) {
            result.x = bounds.minX
        } else if SnapGeometry.near(box.maxX, bounds.maxX) {
            result.x = bounds.maxX - box.width
        }
        if SnapGeometry.near(box.minY, bounds.minY) {
            result.y = bounds.minY
        } else if SnapGeometry.near(box.maxY, bounds.maxY) {
            result.y = bounds.maxY - box.height
        }
        return result
    }

    /// The screen a box overlaps most, else the nearest one.
    public static func bestScreen(for box: IntRect, screens: [DockScreen]) -> DockScreen? {
        func area(_ s: DockScreen) -> Int {
            let i = s.frame.intersection(box)
            return i.isEmpty ? 0 : i.width * i.height
        }
        if let best = screens.max(by: { area($0) < area($1) }), area(best) > 0 { return best }
        func distance(_ s: DockScreen) -> Int {
            let dx = max(s.frame.minX - box.maxX, box.minX - s.frame.maxX, 0)
            let dy = max(s.frame.minY - box.maxY, box.minY - s.frame.maxY, 0)
            return dx * dx + dy * dy
        }
        return screens.min { distance($0) < distance($1) }
    }

    // MARK: Shade and scale

    /// New frames after `role` changes size with its top-left fixed (shade/unshade). Windows hanging below it
    /// (stacked under it, or beside something that is) move by the height change so the stack stays docked;
    /// windows beside the resized one stay put (Bitamp setShaded, MacAmp followResize).
    public static func resize(_ role: SkinWindowRole, to size: IntSize, frames: Frames) -> Frames {
        guard let old = frames[role] else { return frames }
        var result = frames
        result[role] = IntRect(old.x, old.y, size.width, size.height)
        let delta = size.height - old.height
        guard delta != 0 else { return result }
        var hanging: Set<SkinWindowRole> = []
        var changed = true
        while changed {
            changed = false
            for candidate in SkinWindowRole.allCases where candidate != role && !hanging.contains(candidate) {
                guard let box = frames[candidate] else { continue }
                let below = ([role] + Array(hanging)).contains { parent in
                    guard let p = frames[parent] else { return false }
                    let stacked = box.minY == p.maxY && box.minX < p.maxX && p.minX < box.maxX
                    return stacked || (parent != role && SnapGeometry.areTouching(box, p) && box.minY >= old.maxY)
                }
                if below {
                    hanging.insert(candidate)
                    changed = true
                }
            }
        }
        for member in hanging { result[member] = frames[member]!.offsetBy(0, delta) }
        return result
    }

    /// Frames for a new scale: offsets from the anchor's top-left scale by `newScale / oldScale` (so docked
    /// windows stay docked) and every window takes its new size.
    public static func rescale(_ frames: Frames, sizes: [SkinWindowRole: IntSize], anchor: SkinWindowRole,
                               oldScale: Int, newScale: Int) -> Frames {
        guard let a = frames[anchor], oldScale > 0 else { return frames }
        func scaled(_ v: Int) -> Int { Int((Double(v) * Double(newScale) / Double(oldScale)).rounded()) }
        var result: Frames = [:]
        for (role, frame) in frames {
            let size = sizes[role] ?? IntSize(scaled(frame.width), scaled(frame.height))
            result[role] = IntRect(a.x + scaled(frame.x - a.x), a.y + scaled(frame.y - a.y), size.width, size.height)
        }
        return result
    }

    /// The classic stack under Main's top-left: windows in `order` docked one below the other, left edges aligned.
    public static func stacked(mainTopLeft: IntPoint, sizes: [SkinWindowRole: IntSize],
                               order: [SkinWindowRole]) -> Frames {
        var frames: Frames = [:]
        var y = mainTopLeft.y
        for role in order {
            guard let size = sizes[role] else { continue }
            frames[role] = IntRect(mainTopLeft.x, y, size.width, size.height)
            y += size.height
        }
        return frames
    }

    /// Where to open a window that has no saved place: docked under the lowest window of Main's cluster.
    public static func dockedBelowCluster(_ role: SkinWindowRole, size: IntSize, frames: Frames) -> IntRect {
        let others = frames.filter { $0.key != role }
        let cluster = cluster(of: .main, frames: others)
        let members = cluster.compactMap { others[$0] }
        guard let main = others[.main], let lowest = members.max(by: { $0.maxY < $1.maxY }) else {
            return IntRect(0, 0, size.width, size.height)
        }
        return IntRect(main.x, lowest.maxY, size.width, size.height)
    }

    // MARK: Screen clamp (port of MacAmp ScreenClamp, top-left space)

    /// The visible frame overlapping `union` the most, else the first (main) screen.
    public static func clampScreen(for union: IntRect, visibleFrames: [IntRect]) -> IntRect? {
        func area(_ r: IntRect) -> Int {
            let i = r.intersection(union)
            return i.isEmpty ? 0 : i.width * i.height
        }
        if let best = visibleFrames.max(by: { area($0) < area($1) }), area(best) > 0 { return best }
        return visibleFrames.first
    }

    /// Offset bringing `union` inside `visible`; an oversized group keeps its left and top edges visible.
    public static func clampOffset(for union: IntRect, in visible: IntRect) -> IntPoint {
        var dx = 0
        if union.width > visible.width || union.minX < visible.minX {
            dx = visible.minX - union.minX
        } else if union.maxX > visible.maxX {
            dx = visible.maxX - union.maxX
        }
        var dy = 0
        if union.height > visible.height || union.minY < visible.minY {
            dy = visible.minY - union.minY
        } else if union.maxY > visible.maxY {
            dy = visible.maxY - union.maxY
        }
        return IntPoint(dx, dy)
    }

    /// Docked groups (lone windows are their own group).
    public static func groups(_ frames: Frames) -> [Set<SkinWindowRole>] {
        var remaining = SkinWindowRole.allCases.filter { frames[$0] != nil }
        var result: [Set<SkinWindowRole>] = []
        while let first = remaining.first {
            let group = cluster(of: first, frames: frames)
            result.append(group)
            remaining.removeAll { group.contains($0) }
        }
        return result
    }

    /// New frames for stranded groups, measured by their visible members; stranded groups that fit on one
    /// screen together move together, keeping their relative places. Groups already on screen are left alone.
    public static func clamp(_ frames: Frames, visible: Set<SkinWindowRole>, visibleFrames: [IntRect]) -> Frames {
        var stranded: [(group: Set<SkinWindowRole>, union: IntRect)] = []
        for group in groups(frames) {
            guard let union = measuredUnion(group, frames: frames, visible: visible),
                  let target = clampScreen(for: union, visibleFrames: visibleFrames),
                  clampOffset(for: union, in: target) != .zero else { continue }
            stranded.append((group, union))
        }
        guard let first = stranded.first else { return [:] }
        let combined = SnapGeometry.boundingBox(stranded.map(\.union)) ?? first.union
        if stranded.count > 1, let target = clampScreen(for: combined, visibleFrames: visibleFrames),
           combined.width <= target.width, combined.height <= target.height {
            return shifted(stranded.map(\.group), by: clampOffset(for: combined, in: target), frames: frames)
        }
        var moved: Frames = [:]
        for (group, union) in stranded {
            guard let target = clampScreen(for: union, visibleFrames: visibleFrames) else { continue }
            moved.merge(shifted([group], by: clampOffset(for: union, in: target), frames: frames)) { $1 }
        }
        return moved
    }

    private static func measuredUnion(_ group: Set<SkinWindowRole>, frames: Frames,
                                      visible: Set<SkinWindowRole>) -> IntRect? {
        let shown = group.intersection(visible)
        let measured = (shown.isEmpty ? group : shown).compactMap { frames[$0] }
        return SnapGeometry.boundingBox(measured)
    }

    private static func shifted(_ groups: [Set<SkinWindowRole>], by delta: IntPoint, frames: Frames) -> Frames {
        guard delta != .zero else { return [:] }
        var moved: Frames = [:]
        for role in groups.joined() {
            if let frame = frames[role] { moved[role] = frame.offsetBy(delta.x, delta.y) }
        }
        return moved
    }
}
