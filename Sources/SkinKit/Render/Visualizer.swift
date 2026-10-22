// SPDX-License-Identifier: GPL-3.0-or-later
// Draws the classic visualiser into a frame at 1x in viscolor.txt colours (DESIGN §5.4, §8.1). Analysis lives in
// the Audio module; this only paints bar heights and scope rows. Colour rules follow viscolor.txt's documented
// layout and Webamp's components/Vis.tsx and VisPainter.ts @ 7734cd3 (MIT © 2015 Jordan Eldredge): grid dots at
// even columns and odd rows; spectrum row r (0 = top) uses colour 2 + r; peaks use colour 23; the oscilloscope
// uses colours 18-22, brightest in the middle rows; the shade-mode strip has no dots and five colour steps.
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

/// One frame of visualiser data. Decodes from state fixtures with every key optional.
public struct VisualizerFrame: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case spectrum, oscilloscope, off
    }

    public var mode: Mode
    /// 19 bar heights, 0...16.
    public var bars: [Int]
    /// Peak heights, 0...16 (0 = none); optional.
    public var peaks: [Int]
    /// 76 scope samples as rows, 0...15 (0 = top).
    public var scope: [Int]

    public static let barCount = 19
    public static let scopeCount = 76

    public init(mode: Mode = .spectrum, bars: [Int] = [], peaks: [Int] = [], scope: [Int] = []) {
        self.mode = mode
        self.bars = bars
        self.peaks = peaks
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey { case mode, bars, peaks, scope }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .spectrum
        bars = try c.decodeIfPresent([Int].self, forKey: .bars) ?? []
        peaks = try c.decodeIfPresent([Int].self, forKey: .peaks) ?? []
        scope = try c.decodeIfPresent([Int].self, forKey: .scope) ?? []
    }
}

public enum VisualizerRenderer {
    /// Oscilloscope colour step for a row of the 16-row display (0 = colour 18, the brightest).
    static func scopeColorIndex(_ row: Int) -> Int {
        switch row {
        case 14...: return 4
        case 12...13: return 3
        case 10...11: return 2
        case 8...9: return 1
        case 6...7: return 0
        case 4...5: return 1
        case 2...3: return 2
        default: return 3
        }
    }

    /// The main window's 76x16 visualiser at `rect`'s origin.
    public static func draw(_ frame: VisualizerFrame, colors: [RGBA], into bitmap: inout Bitmap, at rect: IntRect) {
        guard frame.mode != .off, colors.count >= 24 else { return }
        bitmap.fill(rect, colors[0])
        for x in stride(from: 0, to: rect.width, by: 2) {
            for y in stride(from: 1, to: rect.height, by: 2) {
                bitmap[rect.x + x, rect.y + y] = colors[1]
            }
        }
        let height = rect.height
        switch frame.mode {
        case .spectrum:
            for i in 0..<VisualizerFrame.barCount {
                let x0 = rect.x + i * 4
                let bar = min(max(i < frame.bars.count ? frame.bars[i] : 0, 0), height)
                for row in (height - bar)..<height {
                    let color = colors[2 + min(row, 15)]
                    for dx in 0..<3 { bitmap[x0 + dx, rect.y + row] = color }
                }
                let peak = min(max(i < frame.peaks.count ? frame.peaks[i] : 0, 0), height)
                if peak > 0 {
                    for dx in 0..<3 { bitmap[x0 + dx, rect.y + height - peak] = colors[23] }
                }
            }
        case .oscilloscope:
            var previous: Int?
            for x in 0..<min(VisualizerFrame.scopeCount, rect.width) {
                guard x < frame.scope.count else { break }
                let row = min(max(frame.scope[x], 0), height - 1)
                let (top, bottom) = previous.map { (min($0, row), max($0, row)) } ?? (row, row)
                for r in top...bottom {
                    bitmap[rect.x + x, rect.y + r] = colors[18 + scopeColorIndex(r)]
                }
                previous = row
            }
        case .off:
            break
        }
    }

    /// The shade-mode 38x5 strip: no grid; 19 one-pixel bars two pixels apart, scaled to 5 rows and coloured
    /// with viscolor 4, 8, 11, 14, 17 from top to bottom; the scope shows every other sample in colour 18.
    public static func drawShade(_ frame: VisualizerFrame, colors: [RGBA], into bitmap: inout Bitmap, at rect: IntRect) {
        guard frame.mode != .off, colors.count >= 24 else { return }
        bitmap.fill(rect, colors[0])
        let steps = [colors[4], colors[8], colors[11], colors[14], colors[17]]
        switch frame.mode {
        case .spectrum:
            for i in 0..<VisualizerFrame.barCount {
                let value = min(max(i < frame.bars.count ? frame.bars[i] : 0, 0), 16)
                let bar = Int((Double(value) * Double(rect.height) / 16).rounded())
                for row in (rect.height - bar)..<rect.height {
                    bitmap[rect.x + i * 2, rect.y + row] = steps[min(row, steps.count - 1)]
                }
            }
        case .oscilloscope:
            for x in 0..<rect.width {
                let i = x * 2
                guard i < frame.scope.count else { break }
                let row = Int((Double(min(max(frame.scope[i], 0), 15)) * Double(rect.height - 1) / 15).rounded())
                bitmap[rect.x + x, rect.y + row] = colors[18]
            }
        case .off:
            break
        }
    }
}
