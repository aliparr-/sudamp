// SPDX-License-Identifier: GPL-3.0-or-later
//
// 24-bit bottom-up Windows bitmap encoder for generated skins.
//
// Ported from Bitamp, Sources/BitampKit/Skin/WszWriter.swift `bmp(_:)`
// (https://github.com/ryanromanov/Bitamp @ 91952819c9cc0394dd03a961dd27a101a52ee6ef).
// sudamp changes: encodes a `Bitmap` directly (no CGContext round trip), so output bytes depend only on pixels.
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

public enum BMPWriter {
    /// A 24-bit, bottom-up BMP (BITMAPINFOHEADER), the most widely readable form, which classic players expect.
    /// Alpha is dropped; generated sheets are opaque.
    public static func encode(_ bitmap: Bitmap) -> Data {
        let (width, height) = (bitmap.width, bitmap.height)
        let rowSize = (width * 3 + 3) & ~3  // Rows are padded to 4 bytes.
        let pixelBytes = rowSize * height
        var data = Data()
        data.reserveCapacity(54 + pixelBytes)
        data.append(contentsOf: Array("BM".utf8))
        data.append(u32: UInt32(54 + pixelBytes)); data.append(u32: 0); data.append(u32: 54)  // File header.
        data.append(u32: 40); data.append(u32: UInt32(width)); data.append(u32: UInt32(height))  // Bottom-up.
        data.append(u16: 1); data.append(u16: 24); data.append(u32: 0); data.append(u32: UInt32(pixelBytes))
        data.append(u32: 2835); data.append(u32: 2835); data.append(u32: 0); data.append(u32: 0)  // 72 dpi.
        var row = [UInt8](repeating: 0, count: rowSize)
        for y in stride(from: height - 1, through: 0, by: -1) {  // The bottom row comes first.
            for x in 0..<width {
                let i = (y * width + x) * 4
                row[x * 3] = bitmap.pixels[i + 2]
                row[x * 3 + 1] = bitmap.pixels[i + 1]
                row[x * 3 + 2] = bitmap.pixels[i]  // BGR
            }
            data.append(contentsOf: row)
        }
        return data
    }
}
