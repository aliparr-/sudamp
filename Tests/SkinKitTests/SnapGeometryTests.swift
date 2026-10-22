// SPDX-License-Identifier: GPL-3.0-or-later
// Webamp's snapUtils.test.ts @ 7734cd3 (MIT © 2015 Jordan Eldredge), ported case by case. Expected `{}` objects
// are SnapOffset() (both axes nil); duplicated cases in the original are kept once.
//
// Notices for the sources named above:
//
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
import Testing
@testable import SkinKit

private func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> IntRect { IntRect(x, y, w, h) }
private typealias S = SnapGeometry

@Suite struct SnapGeometryTests {
    @Test func sideFunctions() {
        let b = box(10, 15, 50, 100)
        #expect(S.top(b) == 15)
        #expect(S.bottom(b) == 115)
        #expect(S.left(b) == 10)
        #expect(S.right(b) == 60)
    }

    @Test func nearFunction() {
        #expect(S.near(10, 20))
        #expect(!S.near(10, 30))
    }

    @Test func overlapFunctions() {
        #expect(S.overlapY(box(0, 10, 100, 50), box(0, 40, 100, 50)))
        #expect(S.overlapY(box(0, 10, 100, 50), box(0, 70, 100, 50)))
        #expect(!S.overlapY(box(0, 10, 100, 50), box(0, 90, 100, 50)))
        #expect(S.overlapX(box(10, 0, 50, 100), box(40, 0, 50, 100)))
        #expect(S.overlapX(box(10, 0, 50, 100), box(70, 0, 50, 100)))
        #expect(!S.overlapX(box(10, 0, 50, 100), box(90, 0, 50, 100)))
    }

    @Test(arguments: [
        // (a, b, expected) from "snap function"
        (box(10, 10, 100, 100), box(200, 200, 100, 100), SnapOffset()),
        (box(120, 30, 100, 100), box(10, 10, 100, 100), SnapOffset(x: 110)),
        (box(10, 30, 100, 100), box(120, 10, 100, 100), SnapOffset(x: 20)),
        (box(30, 10, 100, 100), box(10, 120, 100, 100), SnapOffset(y: 20)),
        (box(30, 120, 100, 100), box(10, 10, 100, 100), SnapOffset(y: 110)),
        (box(10, 10, 100, 100), box(110, 150, 100, 100), SnapOffset()),
        (box(10, 10, 100, 100), box(120, 120, 100, 100), SnapOffset(x: 20, y: 20)),
        (box(10, 10, 100, 100), box(15, 110, 100, 100), SnapOffset(x: 15, y: 10)),
        (box(10, 10, 100, 100), box(110, 15, 100, 100), SnapOffset(x: 10, y: 15)),
        (box(110, 110, 100, 100), box(0, 0, 100, 100), SnapOffset(x: 100, y: 100)),
        (box(0, 90, 100, 100), box(0, 0, 100, 100), SnapOffset(x: 0, y: 100)),
    ])
    func snap(a: IntRect, b: IntRect, expected: SnapOffset) {
        #expect(S.snap(a, b) == expected)
    }

    @Test(arguments: [
        (box(120, 10, 100, 100), SnapOffset(y: 0)),
        (box(120, 910, 100, 100), SnapOffset(y: 900)),
        (box(910, 120, 100, 100), SnapOffset(x: 900)),
        (box(10, 120, 100, 100), SnapOffset(x: 0)),
        (box(10, 10, 100, 100), SnapOffset(x: 0, y: 0)),
    ])
    func snapWithin(inner: IntRect, expected: SnapOffset) {
        #expect(S.snapWithin(inner, IntSize(1000, 1000)) == expected)
    }

    @Test func applySnap() {
        #expect(S.applySnap(IntPoint(10, 10), SnapOffset()) == IntPoint(10, 10))
        #expect(S.applySnap(IntPoint(10, 10), SnapOffset(x: 50, y: 50)) == IntPoint(50, 50))
        #expect(S.applySnap(IntPoint(10, 10), SnapOffset(x: 0, y: 0)) == IntPoint(0, 0))
        #expect(S.applySnap(IntPoint(10, 10), SnapOffset(x: 0), SnapOffset(y: 0)) == IntPoint(0, 0))
        #expect(S.applySnap(IntPoint(10, 10), SnapOffset(x: 50, y: 20), SnapOffset(x: 60, y: 60)) == IntPoint(60, 60))
    }

    @Test(arguments: [
        (box(10, 10, 100, 100), box(200, 200, 100, 100), IntPoint(0, 0)),
        (box(120, 30, 100, 100), box(10, 10, 100, 100), IntPoint(-10, 0)),
        (box(10, 30, 100, 100), box(120, 10, 100, 100), IntPoint(10, 0)),
        (box(30, 10, 100, 100), box(10, 120, 100, 100), IntPoint(0, 10)),
        (box(30, 120, 100, 100), box(10, 10, 100, 100), IntPoint(0, -10)),
        (box(10, 10, 100, 100), box(110, 150, 100, 100), IntPoint(0, 0)),
        (box(10, 10, 100, 100), box(120, 120, 100, 100), IntPoint(10, 10)),
        (box(10, 10, 100, 100), box(15, 110, 100, 100), IntPoint(5, 0)),
        (box(10, 10, 100, 100), box(110, 15, 100, 100), IntPoint(0, 5)),
        (box(110, 110, 100, 100), box(0, 0, 100, 100), IntPoint(-10, -10)),
    ])
    func snapDiff(a: IntRect, b: IntRect, expected: IntPoint) {
        #expect(S.snapDiff(a, b) == expected)
    }

    @Test func boundingBox() {
        let one = box(10, 10, 100, 100)
        let boxes = [one]
        _ = S.boundingBox(boxes)
        #expect(boxes == [one])  // does not mutate (trivially true for Swift values)
        #expect(S.boundingBox([one]) == one)
        #expect(S.boundingBox([one, box(20, 20, 80, 80)]) == one)
        #expect(S.boundingBox([one, box(120, 220, 100, 100)]) == box(10, 10, 210, 310))
        #expect(S.boundingBox([one, box(120, 220, 100, 100), box(3, 220, 100, 100)]) == box(3, 10, 217, 310))
        #expect(S.boundingBox([]) == nil)
    }

    @Test func applyMultipleDiffsUsesTheSmallestNonZero() {
        #expect(S.applyMultipleDiffs(IntPoint(31, -8), IntPoint(0, 8), IntPoint(0, 0)) == IntPoint(31, 0))
    }

    // sudamp additions on the same geometry: main + EQ + playlist stacked are one docked group.
    @Test func stackedWindowsTraceAsOneGroup() {
        let main = box(100, 100, 275, 116), eq = box(100, 216, 275, 116), playlist = box(100, 332, 275, 232)
        let stray = box(700, 100, 275, 116)
        let group = S.traceConnection([eq, playlist, stray], from: main, connected: S.areTouching)
        #expect(Set(group) == [eq, playlist])
        #expect(S.areTouching(main, eq))
        #expect(!S.areTouching(main, box(375, 216, 275, 116)), "corner contact is not docking")
        #expect(S.snapWithin(box(5, 5, 275, 116), IntSize(1440, 900)) == SnapOffset(x: 0, y: 0))
    }
}
