// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure window-snapping geometry (DESIGN §8.1: Webamp's 15 px snap and its snapUtils tests). SkinUI's docking
// (ported from Bitamp's Docking.swift) can build on these functions; they work in skin pixels.
//
// Ported from Webamp, packages/webamp/js/snapUtils.ts @ 7734cd3c7cf144bab2d8614ce9f9ba2ff21e163e, including its
// quirks (a snapped coordinate of 0 counts as "no snap" in snapToMany and snapDiffManyToMany, as JS `||` does),
// so Webamp's snapUtils.test.ts cases pass unchanged.
//
// Webamp's notice:
//
// The MIT License (MIT)
//
// Copyright (c) [2015] [Jordan Eldredge]
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

/// A new position on either axis, or nil where nothing snapped.
public struct SnapOffset: Hashable, Sendable {
    public var x: Int?
    public var y: Int?

    public init(x: Int? = nil, y: Int? = nil) {
        self.x = x
        self.y = y
    }
}

public enum SnapGeometry {
    public static let snapDistance = 15

    public static func top(_ box: IntRect) -> Int { box.y }
    public static func bottom(_ box: IntRect) -> Int { box.y + box.height }
    public static func left(_ box: IntRect) -> Int { box.x }
    public static func right(_ box: IntRect) -> Int { box.x + box.width }

    public static func near(_ a: Int, _ b: Int) -> Bool { abs(a - b) < snapDistance }

    public static func overlapX(_ a: IntRect, _ b: IntRect) -> Bool {
        left(a) <= right(b) + snapDistance && left(b) <= right(a) + snapDistance
    }

    public static func overlapY(_ a: IntRect, _ b: IntRect) -> Bool {
        top(a) <= bottom(b) + snapDistance && top(b) <= bottom(a) + snapDistance
    }

    /// A new position for `a` that snaps it to `b`, per axis.
    public static func snap(_ a: IntRect, _ b: IntRect) -> SnapOffset {
        var result = SnapOffset()
        if overlapY(a, b) {
            if near(left(a), right(b)) {
                result.x = right(b)
            } else if near(right(a), left(b)) {
                result.x = left(b) - a.width
            } else if near(left(a), left(b)) {
                result.x = left(b)
            } else if near(right(a), right(b)) {
                result.x = right(b) - a.width
            }
        }
        if overlapX(a, b) {
            if near(top(a), bottom(b)) {
                result.y = bottom(b)
            } else if near(bottom(a), top(b)) {
                result.y = top(b) - a.height
            } else if near(top(a), top(b)) {
                result.y = top(b)
            } else if near(bottom(a), bottom(b)) {
                result.y = bottom(b) - a.height
            }
        }
        return result
    }

    /// How far `a` moves to snap to `b` (0 where it does not).
    public static func snapDiff(_ a: IntRect, _ b: IntRect) -> IntPoint {
        let snapped = snap(a, b)
        return IntPoint(snapped.x.map { $0 - a.x } ?? 0, snapped.y.map { $0 - a.y } ?? 0)
    }

    public static func snapDiffManyToMany(_ boxesA: [IntRect], _ boxesB: [IntRect]) -> IntPoint {
        var x = 0, y = 0
        outer: for a in boxesA {
            for b in boxesB {
                let diff = snapDiff(a, b)
                if x == 0 { x = diff.x }
                if y == 0 { y = diff.y }
                if x > 0 && y > 0 { break outer }
            }
        }
        return IntPoint(x, y)
    }

    public static func snapToMany(_ a: IntRect, _ others: [IntRect]) -> SnapOffset {
        var result = SnapOffset()
        for b in others {
            let snapped = snap(a, b)
            if let x = snapped.x, x != 0 { result.x = x }
            if let y = snapped.y, y != 0 { result.y = y }
        }
        return result
    }

    /// Snaps `a` to the inside edges of a `bounds`-sized area (the screen).
    public static func snapWithin(_ a: IntRect, _ bounds: IntSize) -> SnapOffset {
        var result = SnapOffset()
        if a.x - snapDistance < 0 {
            result.x = 0
        } else if a.x + a.width + snapDistance > bounds.width {
            result.x = bounds.width - a.width
        }
        if a.y - snapDistance < 0 {
            result.y = 0
        } else if a.y + a.height + snapDistance > bounds.height {
            result.y = bounds.height - a.height
        }
        return result
    }

    public static func snapWithinDiff(_ a: IntRect, _ bounds: IntSize) -> IntPoint {
        let snapped = snapWithin(a, bounds)
        return IntPoint(snapped.x.map { $0 - a.x } ?? 0, snapped.y.map { $0 - a.y } ?? 0)
    }

    /// Applies snaps in order; later ones win, nil leaves the axis alone.
    public static func applySnap(_ original: IntPoint, _ snaps: SnapOffset...) -> IntPoint {
        snaps.reduce(original) { IntPoint($1.x ?? $0.x, $1.y ?? $0.y) }
    }

    public static func boundingBox(_ boxes: [IntRect]) -> IntRect? {
        guard let first = boxes.last else { return nil }
        var t = top(first), r = right(first), b = bottom(first), l = left(first)
        for box in boxes.dropLast() {
            t = min(t, top(box))
            r = max(r, right(box))
            b = max(b, bottom(box))
            l = min(l, left(box))
        }
        return IntRect(l, t, r - l, b - t)
    }

    /// Every candidate transitively connected to `node` (Webamp traceConnection), in discovery order.
    public static func traceConnection<Node: Hashable>(_ candidates: [Node], from node: Node,
                                                       connected areConnected: (Node, Node) -> Bool) -> [Node] {
        var found: [Node] = []
        var seen = Set<Node>()
        func check(_ n: Node) {
            for candidate in candidates where !seen.contains(candidate) && areConnected(candidate, n) {
                seen.insert(candidate)
                found.append(candidate)
                check(candidate)
            }
        }
        check(node)
        return found
    }

    public static func applyDiff(_ a: IntPoint, _ b: IntPoint) -> IntPoint {
        IntPoint(a.x + b.x, a.y + b.y)
    }

    /// Combines diffs using the smallest non-zero value per axis (Webamp's TODO: not by absolute value).
    public static func applyMultipleDiffs(_ initial: IntPoint, _ diffs: IntPoint...) -> IntPoint {
        guard var meta = diffs.first else { return initial }
        for diff in diffs.dropFirst() {
            meta = IntPoint(meta.x == 0 || diff.x == 0 ? meta.x + diff.x : min(meta.x, diff.x),
                            meta.y == 0 || diff.y == 0 ? meta.y + diff.y : min(meta.y, diff.y))
        }
        return applyDiff(initial, meta)
    }

    /// Whether two windows touch edge to edge with overlap along that edge (docked, in Webamp's sense).
    public static func areTouching(_ a: IntRect, _ b: IntRect) -> Bool {
        let verticalOverlap = top(a) < bottom(b) && top(b) < bottom(a)
        let horizontalOverlap = left(a) < right(b) && left(b) < right(a)
        return (verticalOverlap && (left(a) == right(b) || right(a) == left(b)))
            || (horizontalOverlap && (top(a) == bottom(b) || bottom(a) == top(b)))
    }
}
