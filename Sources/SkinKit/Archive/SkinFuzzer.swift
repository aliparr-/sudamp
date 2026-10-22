// SPDX-License-Identifier: GPL-3.0-or-later
// Mutates skin archives for robustness testing (PLAN M4: truncation, bit flips, wrong sizes, nested folders,
// CP437 names). Used by `sudamp-dev skin-fuzz` and the tests; every mutation is reproducible from its seed.

import Foundation

public enum SkinFuzzer {
    public enum Mutation: String, CaseIterable, Codable, Sendable {
        /// Cut the archive at a random length.
        case truncate
        /// Flip 1-64 random bits anywhere.
        case bitFlips
        /// Overwrite size fields in the central directory and local headers with random or extreme values.
        case wrongSizes
        /// Rewrite every entry under random nested folders with random letter case.
        case nestedFolders
        /// Rewrite names as raw CP437 bytes (no UTF-8 flag), including high characters.
        case cp437Names
        /// Duplicate entries with different contents (last image wins, first pledit.txt wins).
        case duplicates
        /// Replace whitelisted entries with junk, truncated images or images claiming huge sizes.
        case corruptImages
        /// Change the entry count and directory offset in the end record.
        case endRecord
        /// Replace or add region.txt, viscolor.txt and pledit.txt with hostile text: huge numbers, junk bytes,
        /// endless lines, odd encodings.
        case hostileText
    }

    /// Text-file payloads used by `.hostileText`.
    static let hostileTexts: [String] = [
        "[Normal]\r\nNumPoints=99999999999999999999,3,-7,NaN\r\nPointList=1e309,5 -99999999999999999999,0, 3,4, 5,,,6\r\n",
        "[Normal]\nNumPoints=" + String(repeating: "3,", count: 4000) + "\nPointList=" + String(repeating: "1,2 ", count: 9000),
        "[WindowShade]\nNumPoints=4\nPointList=0,0 275,0\n 275,14 0,14\n[Equalizer]\nNumPoints=\nPointList=1,1",
        String(repeating: "255,255,255\n", count: 400) + "999999,-1,abc\n\u{0}\u{1}\u{FFFD}",
        "[Text]\nNormal=#\nCurrent=#GGGGGG\nNormalBG=\"\nSelectedBG='#12\nFont=" + String(repeating: "W", count: 70_000),
        "\u{FEFF}[text]\r\nnormal = 00ff00 = trailing = more\r\n;comment=1\r\n[",
    ]

    /// Applies `mutation` to `archive`, deterministically for a given generator state.
    public static func mutate(_ archive: Data, _ mutation: Mutation, using rng: inout some RandomNumberGenerator) -> Data {
        var bytes = [UInt8](archive)
        switch mutation {
        case .truncate:
            guard !bytes.isEmpty else { return archive }
            return Data(bytes.prefix(Int.random(in: 0..<bytes.count, using: &rng)))
        case .bitFlips:
            guard !bytes.isEmpty else { return archive }
            for _ in 0..<Int.random(in: 1...64, using: &rng) {
                let i = Int.random(in: 0..<bytes.count, using: &rng)
                bytes[i] ^= UInt8(1) << UInt8.random(in: 0...7, using: &rng)
            }
            return Data(bytes)
        case .wrongSizes:
            let extremes: [UInt32] = [0, 1, 0xFFFF_FFFF, 0x7FFF_FFFF, 1 << 30, 40 << 20, 54]
            for offset in signatureOffsets(bytes, [0x50, 0x4B, 0x01, 0x02]) where Bool.random(using: &rng) {
                for field in [20, 24] where offset + field + 4 <= bytes.count && Bool.random(using: &rng) {
                    let value = Bool.random(using: &rng) ? extremes.randomElement(using: &rng)! : UInt32.random(in: 0...200_000, using: &rng)
                    write32(&bytes, offset + field, value)
                }
            }
            for offset in signatureOffsets(bytes, [0x50, 0x4B, 0x03, 0x04]) where Bool.random(using: &rng) {
                if offset + 26 <= bytes.count { write32(&bytes, offset + 22, UInt32.random(in: 0...0xFFFF_FFFF, using: &rng)) }
            }
            return Data(bytes)
        case .nestedFolders, .cp437Names, .duplicates, .corruptImages, .hostileText:
            guard let zip = try? ZipArchive(data: archive) else { return archive }
            var entries: [ZipWriter.Entry] = []
            for entry in zip.entries where !entry.isDirectory {
                guard let data = try? zip.contents(of: entry) else { continue }
                entries.append(ZipWriter.Entry(path: entry.path, data: data, method: .stored))
            }
            return rewrite(entries, mutation, using: &rng)
        case .endRecord:
            guard bytes.count >= 22 else { return archive }
            let end = bytes.count - 22
            guard bytes[end] == 0x50, bytes[end + 1] == 0x4B else { return archive }
            let count = UInt16.random(in: 0...0xFFFF, using: &rng)
            bytes[end + 8] = UInt8(count & 0xFF); bytes[end + 9] = UInt8(count >> 8)
            bytes[end + 10] = UInt8(count & 0xFF); bytes[end + 11] = UInt8(count >> 8)
            if Bool.random(using: &rng) { write32(&bytes, end + 16, UInt32.random(in: 0...UInt32(bytes.count + 100), using: &rng)) }
            return Data(bytes)
        }
    }

    private static func rewrite(_ entries: [ZipWriter.Entry], _ mutation: Mutation, using rng: inout some RandomNumberGenerator) -> Data {
        var out = entries
        switch mutation {
        case .nestedFolders:
            let depth = Int.random(in: 1...4, using: &rng)
            let folders = (0..<depth).map { _ in ["Skin", "my skin", "__MACOSX", "x", "Winamp Skins"].randomElement(using: &rng)! }
            for i in out.indices {
                let base = out[i].path.split(separator: "/").last.map(String.init) ?? out[i].path
                let cased = String(base.map { Bool.random(using: &rng) ? Character($0.uppercased()) : Character($0.lowercased()) })
                let separator = Bool.random(using: &rng) ? "/" : "\\"
                out[i].path = (folders + [cased]).joined(separator: separator)
            }
        case .cp437Names:
            for i in out.indices {
                let base = Array(out[i].path.utf8)
                let prefix = (0..<Int.random(in: 0...6, using: &rng)).map { _ in UInt8.random(in: 0x80...0xFF, using: &rng) }
                out[i].rawName = Bool.random(using: &rng) ? prefix + [0x2F] + base : base + prefix
            }
        case .duplicates:
            for entry in entries where Bool.random(using: &rng) {
                var copy = entry
                copy.path = Bool.random(using: &rng) ? entry.path.uppercased() : "dup/" + entry.path
                copy.data = Data((0..<Int.random(in: 0...512, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
                out.insert(copy, at: Int.random(in: 0...out.count, using: &rng))
            }
        case .corruptImages:
            for i in out.indices where out[i].path.lowercased().hasSuffix(".bmp") && Bool.random(using: &rng) {
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: out[i].data = Data(out[i].data.prefix(Int.random(in: 0...max(0, out[i].data.count), using: &rng)))
                case 1: out[i].data = Data((0..<Int.random(in: 0...4096, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
                case 2: out[i].data = hugeBMPHeader(width: Int32.random(in: 3000...60000, using: &rng), height: Int32.random(in: -60000...60000, using: &rng))
                default:
                    var data = [UInt8](out[i].data)
                    if data.count > 30 { for k in 18..<30 { data[k] = UInt8.random(in: 0...255, using: &rng) } }
                    out[i].data = Data(data)
                }
            }
        case .hostileText:
            for name in ["region.txt", "viscolor.txt", "pledit.txt"] where Bool.random(using: &rng) {
                var bytes = Data(hostileTexts.randomElement(using: &rng)!.utf8)
                if Bool.random(using: &rng) { bytes.append(contentsOf: (0..<64).map { _ in UInt8.random(in: 0x80...0xFF, using: &rng) }) }
                out.removeAll { $0.path.lowercased().hasSuffix(name) }
                out.append(ZipWriter.Entry(path: Bool.random(using: &rng) ? name.uppercased() : name, data: bytes, method: .stored))
            }
        default:
            break
        }
        for i in out.indices { out[i].method = Bool.random(using: &rng) ? .stored : .deflate }
        return ZipWriter.archive(out)
    }

    /// A BMP header that claims an enormous image backed by almost no pixel data.
    static func hugeBMPHeader(width: Int32, height: Int32) -> Data {
        var d = Data()
        d.append(contentsOf: Array("BM".utf8))
        d.append(u32: 54 + 16); d.append(u32: 0); d.append(u32: 54)
        d.append(u32: 40); d.append(u32: UInt32(bitPattern: width)); d.append(u32: UInt32(bitPattern: height))
        d.append(u16: 1); d.append(u16: 24); d.append(u32: 0); d.append(u32: 16)
        d.append(u32: 2835); d.append(u32: 2835); d.append(u32: 0); d.append(u32: 0)
        d.append(Data(repeating: 0x7F, count: 16))
        return d
    }

    private static func signatureOffsets(_ bytes: [UInt8], _ signature: [UInt8]) -> [Int] {
        guard bytes.count >= 4 else { return [] }
        var result: [Int] = []
        for i in 0...(bytes.count - 4) where bytes[i] == signature[0] && bytes[i + 1] == signature[1]
            && bytes[i + 2] == signature[2] && bytes[i + 3] == signature[3] {
            result.append(i)
        }
        return result
    }

    private static func write32(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        guard at >= 0, at + 4 <= bytes.count else { return }
        for k in 0..<4 { bytes[at + k] = UInt8((value >> (8 * UInt32(k))) & 0xFF) }
    }
}
