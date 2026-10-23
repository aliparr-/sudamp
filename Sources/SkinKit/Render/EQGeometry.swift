// SPDX-License-Identifier: GPL-3.0-or-later
//
// Equalizer slider geometry and the eqmain response curve.
//
// Slider frames and travel follow Webamp's components/EqualizerWindow/Band.tsx and VerticalSlider.tsx
// (@ 7734cd3): frame = round(value/100 * 27), sheet offset ((n % 14) * 15, (n / 14) * 65), thumb top =
// floor(51 * (1 - value/100)), i.e. 51 px of travel (Bitamp and wamp use 52). The value/decibel mapping and the
// 0 dB snap come from Bitamp's VerticalSliderGeometry (UI/EqualizerView.swift @ 91952819). The curve is Webamp's
// EqGraph.tsx drawEqLine with its natural cubic spline (spline.js, adapted there from morganherlocker/
// cubic-spline), drawn in the 19 EQ_GRAPH_LINE_COLORS, one colour per row. Unlike the bands, the preamp line moves
// *down* as the preamp rises: Winamp (its released source, draw_eq.cpp), XMMS 1.0 and Webamp all draw it so,
// and Webamp's museum screenshots match only this way (docs/spikes/golden.md). Colours from outside a
// short eqmain.bmp are transparent and draw nothing, as Webamp's pattern from an empty sprite does; writing them
// punched see-through holes into the window (found by the museum golden metric, docs/spikes/golden.md).
//
// Notices:
// Webamp — The MIT License (MIT), Copyright (c) [2015] [Jordan Eldredge]
// Bitamp — MIT License, Copyright (c) 2026 Ryan Romanosky and Bitamp contributors
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

/// A vertical EQ slider: values 0...100 (50 = 0 dB), thumb positions in pixels from the slider's top.
public enum EQSliderGeometry {
    public static let travel = EQLayout.thumbTravel
    public static let frames = 28
    public static let decibelRange: ClosedRange<Double> = -12...12
    /// Values this close to 0 dB snap to it, so flat is easy to hit (Bitamp).
    public static let snapDecibels = 0.6

    /// Background frame 0...27 for a value.
    public static func frame(for value: Double) -> Int {
        Int((clamped(value, 0, 100) / 100 * 27).rounded(.toNearestOrAwayFromZero))
    }

    /// Offset of a frame inside EQ_SLIDER_BACKGROUND.
    public static func frameOffset(_ frame: Int) -> IntPoint {
        IntPoint((frame % 14) * 15, (frame / 14) * 65)
    }

    /// Thumb top, 0 (value 100, +12 dB) ... 51 (value 0, -12 dB).
    public static func thumbOffset(for value: Double) -> Int {
        // The epsilon keeps exact positions exact after a value -> offset -> value round trip.
        Int((Double(travel) * (1 - clamped(value, 0, 100) / 100) + 1e-9).rounded(.down))
    }

    /// The value for a thumb top (inverse of `thumbOffset`, up to rounding).
    public static func value(forThumbOffset offset: Int) -> Double {
        (1 - Double(min(max(offset, 0), travel)) / Double(travel)) * 100
    }

    public static func decibels(for value: Double) -> Double {
        let db = (clamped(value, 0, 100) - 50) / 50 * 12
        return abs(db) < snapDecibels ? 0 : db
    }

    public static func value(forDecibels db: Double) -> Double {
        (clamped(db, decibelRange.lowerBound, decibelRange.upperBound) / 12) * 50 + 50
    }
}

public enum EQGraph {
    public static let height = 19
    public static let bandSpacing = 12

    /// Natural cubic spline through (xs, ys), sampled at every integer x in 0...xs.last (Webamp spline.js).
    public static func spline(xs: [Double], ys: [Double]) -> [Double] {
        precondition(xs.count == ys.count && xs.count >= 2, "spline needs matching xs/ys with 2+ points")
        let ks = naturalKs(xs, ys)
        let maxX = Int(xs[xs.count - 1])
        var all: [Double] = []
        var i = 1
        for xi in 0...maxX {
            let x = Double(xi)
            while xs[i] < x { i += 1 }
            let t = (x - xs[i - 1]) / (xs[i] - xs[i - 1])
            let a = ks[i - 1] * (xs[i] - xs[i - 1]) - (ys[i] - ys[i - 1])
            let b = -ks[i] * (xs[i] - xs[i - 1]) + (ys[i] - ys[i - 1])
            all.append((1 - t) * ys[i - 1] + t * ys[i] + t * (1 - t) * (a * (1 - t) + b * t))
        }
        return all
    }

    private static func naturalKs(_ xs: [Double], _ ys: [Double]) -> [Double] {
        let n = xs.count - 1
        var m = [[Double]](repeating: [Double](repeating: 0, count: n + 2), count: n + 1)
        for i in 1..<max(1, n) where i < n {
            m[i][i - 1] = 1 / (xs[i] - xs[i - 1])
            m[i][i] = 2 * (1 / (xs[i] - xs[i - 1]) + 1 / (xs[i + 1] - xs[i]))
            m[i][i + 1] = 1 / (xs[i + 1] - xs[i])
            m[i][n + 1] = 3 * ((ys[i] - ys[i - 1]) / ((xs[i] - xs[i - 1]) * (xs[i] - xs[i - 1]))
                + (ys[i + 1] - ys[i]) / ((xs[i + 1] - xs[i]) * (xs[i + 1] - xs[i])))
        }
        m[0][0] = 2 / (xs[1] - xs[0])
        m[0][1] = 1 / (xs[1] - xs[0])
        m[0][n + 1] = 3 * (ys[1] - ys[0]) / ((xs[1] - xs[0]) * (xs[1] - xs[0]))
        m[n][n - 1] = 1 / (xs[n] - xs[n - 1])
        m[n][n] = 2 / (xs[n] - xs[n - 1])
        m[n][n + 1] = 3 * (ys[n] - ys[n - 1]) / ((xs[n] - xs[n - 1]) * (xs[n] - xs[n - 1]))
        return solve(&m)
    }

    /// Gaussian elimination with partial pivoting, as spline.js does it.
    private static func solve(_ m: inout [[Double]]) -> [Double] {
        let size = m.count
        var ks = [Double](repeating: 0, count: size)
        for k in 0..<size {
            var iMax = 0, best = -Double.infinity
            for i in k..<size where m[i][k] > best {
                iMax = i
                best = m[i][k]
            }
            m.swapAt(k, iMax)
            for i in (k + 1)..<max(k + 1, size) {
                let factor = m[i][k] / m[k][k]
                for j in (k + 1)..<(size + 1) { m[i][j] -= m[k][j] * factor }
                m[i][k] = 0
            }
        }
        for i in stride(from: size - 1, through: 0, by: -1) {
            let v = m[i][size] / m[i][i]
            ks[i] = v
            for j in stride(from: i - 1, through: 0, by: -1) {
                m[j][size] -= m[j][i] * v
                m[j][i] = 0
            }
        }
        return ks
    }

    /// Row (0 = top) for a 0...100 value: Webamp's percentToRange((100 - v)/100, 0, 18).
    public static func row(for value: Double) -> Int {
        Int(((100 - clamped(value, 0, 100)) / 100 * Double(height - 1)).rounded(.toNearestOrAwayFromZero))
    }

    /// The preamp line's row (0 = top): Webamp's percentToRange(v/100, 0, 18), so preamp 100 (+12 dB) is the bottom
    /// row. Winamp truncates instead of rounding, so its line is one row off this at 13 of its 64 slider positions.
    public static func preampRow(for value: Double) -> Int {
        Int((clamped(value, 0, 100) / 100 * Double(height - 1)).rounded(.toNearestOrAwayFromZero))
    }

    /// The curve's row for every column (109 columns for 10 bands 12 px apart), clamped to the graph.
    public static func curveRows(bands: [Double]) -> [Int] {
        let values = bands.count == 10 ? bands : [Double](repeating: 50, count: 10)
        let xs = (0..<10).map { Double($0 * bandSpacing) }
        let ys = values.map { Double(row(for: $0)) }  // Webamp rounds each band to a row before the spline
        return spline(xs: xs, ys: ys).map { min(max(Int($0.rounded(.toNearestOrAwayFromZero)), 0), height - 1) }
    }

    /// Draws the preamp line and curve into the graph at `origin` (the graph background must already be there).
    public static func draw(bands: [Double], preamp: Double, colors: [RGBA], preampLine: ResolvedSprite?,
                            into bitmap: inout Bitmap, origin: IntPoint) {
        if let line = preampLine {
            bitmap.draw(line.sheet, from: line.rect, at: IntPoint(origin.x, origin.y + preampRow(for: preamp)))
        }
        guard colors.count >= height else { return }
        let rows = curveRows(bands: bands)
        var last = rows.first ?? 0
        for (x, y) in rows.enumerated() {
            let top = min(y, last), span = abs(last - y)
            for r in top...(top + span) where colors[r].a != 0 {
                bitmap[origin.x + EQLayout.graphPaddingLeft + x, origin.y + r] = colors[r]
            }
            last = y
        }
    }
}
