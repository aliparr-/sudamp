// SPDX-License-Identifier: GPL-3.0-or-later
// 16-bit BMP sheets widen to the full 8-bit range as browsers (and so Webamp's museum screenshots) do, not by
// ImageIO's shift: the expected levels below are the ones measured in museum screenshots (docs/spikes/golden.md).
import Foundation
import Testing
@testable import SkinKit

/// A 16-bit BMP: `rows` top to bottom, BI_RGB 5-5-5 unless `masks` asks for BI_BITFIELDS.
func bmp16(width: Int, rows: [[UInt16]], topDown: Bool = false, masks: (UInt32, UInt32, UInt32)? = nil, truncate: Int = 0) -> Data {
    let stride = (width * 2 + 3) / 4 * 4
    let maskBytes = masks == nil ? 0 : 12
    let offset = 14 + 40 + maskBytes
    var d = Data()
    func le16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    func le32(_ v: Int) { for k in 0..<4 { d.append(UInt8((v >> (8 * k)) & 0xFF)) } }
    d.append(contentsOf: [0x42, 0x4D])
    le32(offset + stride * rows.count)
    le32(0)
    le32(offset)
    le32(40)
    le32(width)
    le32(topDown ? -rows.count : rows.count)
    le16(1)
    le16(16)
    le32(masks == nil ? 0 : 3)
    le32(stride * rows.count)
    le32(2835); le32(2835); le32(0); le32(0)
    if let masks { le32(Int(masks.0)); le32(Int(masks.1)); le32(Int(masks.2)) }
    for row in (topDown ? rows : rows.reversed()) {
        for v in row { le16(Int(v)) }
        for _ in 0..<(stride - width * 2) { d.append(0) }
    }
    return d.dropLast(truncate)
}

func rgb555(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> UInt16 { r << 10 | g << 5 | b }

@Suite struct BMP16Tests {
    @Test func fiveBitChannelsScaleToTheFullRange() throws {
        // Levels measured in a museum screenshot of a 16-bit skin (MAGiC.wsz): 18,16,15 -> 148,132,123;
        // 29,27,27 -> 239,222,222; 3,2,2 -> 25,16,16; 10,8,8 -> 82,66,66. ImageIO's shift gives 144,128,120 etc.
        let data = bmp16(width: 3, rows: [
            [rgb555(18, 16, 15), rgb555(29, 27, 27), rgb555(3, 2, 2)],
            [rgb555(10, 8, 8), rgb555(31, 31, 31), rgb555(0, 0, 0)],
        ])
        let bitmap = try SheetDecoder.decode(data)
        #expect(bitmap.size == IntSize(3, 2))
        #expect(bitmap[0, 0] == RGBA(148, 132, 123))
        #expect(bitmap[1, 0] == RGBA(239, 222, 222))
        #expect(bitmap[2, 0] == RGBA(25, 16, 16))
        #expect(bitmap[0, 1] == RGBA(82, 66, 66))
        #expect(bitmap[1, 1] == .white)
        #expect(bitmap[2, 1] == .black)
    }

    @Test func rowOrderAndPaddingAreHonoured() throws {
        let rows: [[UInt16]] = [[rgb555(31, 0, 0), rgb555(0, 31, 0), rgb555(0, 0, 31)], [rgb555(1, 2, 3), 0, rgb555(31, 31, 0)]]
        let bottomUp = try SheetDecoder.decode(bmp16(width: 3, rows: rows))
        let topDown = try SheetDecoder.decode(bmp16(width: 3, rows: rows, topDown: true))
        #expect(bottomUp == topDown)
        #expect(bottomUp[0, 0] == RGBA(255, 0, 0) && bottomUp[1, 0] == RGBA(0, 255, 0) && bottomUp[2, 0] == RGBA(0, 0, 255))
        #expect(bottomUp[2, 1] == RGBA(255, 255, 0))
    }

    @Test func bitfieldMasksSelectTheChannels() throws {
        // 5-6-5: green has six bits (63 -> 255, 1 -> round(255/63) = 4).
        let data = bmp16(width: 2, rows: [[UInt16(31 << 11 | 63 << 5 | 31), UInt16(0 << 11 | 1 << 5 | 16)]],
                         masks: (0xF800, 0x07E0, 0x001F))
        let header = try #require(BMP16Decoder.header(data))
        #expect(header.redMask == 0xF800 && header.greenMask == 0x07E0 && header.blueMask == 0x001F)
        let bitmap = try SheetDecoder.decode(data)
        #expect(bitmap[0, 0] == .white)
        #expect(bitmap[1, 0] == RGBA(0, 4, 132))
    }

    @Test func channelTablesFollowSkia() {
        let five = BMP16Decoder.Channel(0x001F)
        #expect((0...31).map { five.expand(UInt32($0)) } == [0, 8, 16, 25, 33, 41, 49, 58, 66, 74, 82, 90, 99, 107, 115, 123,
                                                               132, 140, 148, 156, 165, 173, 181, 189, 197, 206, 214, 222, 230, 239, 247, 255])
        #expect(BMP16Decoder.Channel(0x0001).expand(1) == 255)
        #expect(BMP16Decoder.Channel(0).expand(0xFFFF) == 0)
        // Wider than 8 bits keeps the top 8.
        #expect(BMP16Decoder.Channel(0xFFF0).expand(0xABC0) == 0xAB)
        #expect(BMP16Decoder.isContiguous(0x07E0) && !BMP16Decoder.isContiguous(0x0505))
    }

    @Test func otherBitmapsAreLeftToImageIO() throws {
        #expect(BMP16Decoder.header(BMPWriter.encode(Bitmap(width: 2, height: 2, fill: .white))) == nil)  // 24-bit
        #expect(BMP16Decoder.header(Data("not a bmp".utf8)) == nil)
        // Non-contiguous masks and unknown compressions fall back too.
        #expect(BMP16Decoder.header(bmp16(width: 1, rows: [[0]], masks: (0x5555, 0x0A0A, 0x00F0))) == nil)
        var rle = bmp16(width: 1, rows: [[0]])
        rle[30] = 1
        #expect(BMP16Decoder.header(rle) == nil)
    }

    @Test func shortPixelDataFallsBackWithoutCrashing() throws {
        let data = bmp16(width: 4, rows: [[1, 2, 3, 4], [5, 6, 7, 8]], truncate: 3)
        let header = try #require(BMP16Decoder.header(data))
        #expect(BMP16Decoder.decode(data, header: header) == nil)
        _ = try? SheetDecoder.decode(data)   // ImageIO's turn: decodes or throws, never traps
    }

    /// Hostile input: corrupted headers, masks, offsets and lengths never trap, and whatever decodes stays bounded.
    @Test func corruptedSixteenBitFilesNeverTrap() async throws {
        let base = bmp16(width: 5, rows: (0..<4).map { y in (0..<5).map { UInt16($0 * 997 + y * 31) } }, masks: (0xF800, 0x07E0, 0x001F))
        let (decoded, oversized) = try await offPool {
            var rng = SeededRandomForTests(seed: 16)
            var decoded = 0, oversized = 0
            for i in 0..<3000 {
                var data = base
                for _ in 0..<(1 + i % 4) {
                    let at = Int.random(in: 0..<(i % 3 == 0 ? 70 : data.count), using: &rng)
                    data[at] = UInt8.random(in: 0...255, using: &rng)
                }
                if i % 5 == 0 { data = data.prefix(Int.random(in: 0...data.count, using: &rng)) }
                if let bitmap = try? SheetDecoder.decode(data) {
                    decoded += 1
                    if bitmap.width > SheetDecoder.maxDimension || bitmap.height > SheetDecoder.maxDimension { oversized += 1 }
                }
            }
            return (decoded, oversized)
        }
        #expect(oversized == 0)
        #expect(decoded > 0)
    }

    @Test func oversizedSheetsAreRefusedFromTheHeader() {
        var data = bmp16(width: 1, rows: [[0]])
        data.replaceSubrange(18..<22, with: [0x01, 0x10, 0, 0])   // width 4097
        #expect(throws: SheetDecodeError.tooLarge(width: 4097, height: 1)) { try SheetDecoder.decode(data) }
    }
}
