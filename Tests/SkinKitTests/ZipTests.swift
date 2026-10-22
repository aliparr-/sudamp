// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing
@testable import SkinKit

@Suite struct ZipReaderTests {
    @Test func storedAndDeflatedEntriesRoundTrip() throws {
        var rng = SystemRandomNumberGenerator()
        let noise = Data((0..<5000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let pixelArt = BMPWriter.encode(Bitmap(width: 120, height: 40, fill: RGBA(hex: 0x0d9488)))
        let entries = [
            ZipWriter.Entry(path: "a.txt", data: Data("hello".utf8), method: .stored),
            ZipWriter.Entry(path: "Skin/MAIN.BMP", data: pixelArt, method: .deflate),
            ZipWriter.Entry(path: "noise.bin", data: noise, method: .deflate),
            ZipWriter.Entry(path: "empty", data: Data(), method: .deflate),
        ]
        let archive = try ZipArchive(data: ZipWriter.archive(entries))
        #expect(archive.entries.map(\.path) == ["a.txt", "Skin/MAIN.BMP", "noise.bin", "empty"])
        #expect(archive.entries[1].method == 8, "pixel art should compress")
        #expect(archive.entries[1].compressedSize < pixelArt.count / 20)
        for (entry, original) in zip(archive.entries, entries) {
            #expect(try archive.contents(of: entry) == original.data)
            #expect(entry.crc32 == CRC32.checksum(original.data))
        }
        #expect(archive.entries[1].basename == "MAIN.BMP")
    }

    @Test func deflateHandlesLongRunsAndShortInputs() throws {
        for input in [Data(), Data([7]), Data([1, 2]), Data(repeating: 0, count: 300_000),
                      Data((0..<70_000).map { UInt8($0 % 251) })] {
            let entry = ZipWriter.Entry(path: "x", data: input, method: .deflate)
            let archive = try ZipArchive(data: ZipWriter.archive([entry]))
            #expect(try archive.contents(of: archive.entries[0]) == input)
        }
    }

    @Test func writerIsDeterministic() {
        let entries = [ZipWriter.Entry(path: "main.bmp", data: Data(repeating: 9, count: 4096))]
        #expect(ZipWriter.archive(entries) == ZipWriter.archive(entries))
    }

    @Test func rejectsNonZips() {
        #expect(throws: ZipError.notAZip) { try ZipArchive(data: Data("not a zip at all, sorry".utf8)) }
        #expect(throws: ZipError.notAZip) { try ZipArchive(data: Data()) }
    }

    @Test func cp437NamesDecode() throws {
        #expect(CP437.decode([0x80, 0x81, 0xE1, 0x41]) == "ÇüßA")
        #expect(CP437.decode([0xFF]) == "\u{00A0}")
        // A name without the UTF-8 flag: byte 0x94 is "ö" in CP437.
        var data = ZipWriter.archive([ZipWriter.Entry(path: "sk_n/main.bmp", data: Data([1]), method: .stored)])
        let nameAt = 30 + 2  // "sk_n": replace "_" in the local and central names.
        data[nameAt] = 0x94
        let cdName = data.count - 22 - "sk_n/main.bmp".utf8.count + 2
        data[cdName] = 0x94
        let archive = try ZipArchive(data: data)
        #expect(archive.entries[0].path == "skön/main.bmp")
        #expect(archive.entries[0].basename == "main.bmp")
    }

    @Test func entryCountCapIsCheckedFromTheEndRecord() throws {
        let many = (0..<600).map { ZipWriter.Entry(path: "f\($0)", data: Data(), method: .stored) }
        #expect(throws: ZipError.tooManyEntries(600)) { try ZipArchive(data: ZipWriter.archive(many)) }
        var limits = ZipLimits.skin
        limits.maxEntries = 1000
        #expect(try ZipArchive(data: ZipWriter.archive(many), limits: limits).entries.count == 600)
    }

    @Test func declaredSizeOverCapIsRejectedBeforeInflating() throws {
        let bomb = ZipBomb.make(uncompressedSize: 40 << 20)
        let archive = try ZipArchive(data: bomb)
        #expect(throws: ZipError.entryTooLarge(name: "Skin/MAIN.BMP", bytes: 40 << 20)) {
            try archive.contents(of: archive.entries[0])
        }
        #expect(throws: ZipError.entryTooLarge(name: "Skin/MAIN.BMP", bytes: 40 << 20)) { try SkinArchive(archive) }
    }

    @Test func lyingHeaderStopsAtTheDeclaredSize() throws {
        // Declares 1 KB but inflates to 8 MiB: inflation stops after 1 KB + 1 byte.
        let bomb = ZipBomb.make(uncompressedSize: 8 << 20, lie: 1024)
        let archive = try ZipArchive(data: bomb)
        #expect(throws: ZipError.sizeMismatch(name: "Skin/MAIN.BMP")) { try archive.contents(of: archive.entries[0]) }
        // The skin still loads; the sheet is reported and falls back.
        let skin = try SkinArchive(archive)
        #expect(skin.images["main"] == nil)
        #expect(skin.entryErrors.map(\.error) == [.sizeMismatch(name: "Skin/MAIN.BMP")])
    }

    @Test func totalCapCoversEverythingExtracted() throws {
        var limits = ZipLimits.skin
        limits.maxTotalBytes = 10_000
        let entries = ["main.bmp", "titlebar.bmp"].map {
            ZipWriter.Entry(path: $0, data: Data(repeating: 1, count: 6000), method: .deflate)
        }
        let archive = try ZipArchive(data: ZipWriter.archive(entries), limits: limits)
        #expect(throws: ZipError.totalTooLarge(bytes: 12_000)) { try SkinArchive(archive) }
    }

    @Test func zip64AndEncryptionAreRefused() throws {
        var data = ZipWriter.archive([ZipWriter.Entry(path: "main.bmp", data: Data([1, 2, 3]), method: .stored)])
        // Set the encryption flag in the central directory (offset 8 into the central record).
        let cd = Int(data[data.count - 6]) | Int(data[data.count - 5]) << 8
        data[cd + 8] |= 1
        let archive = try ZipArchive(data: data)
        #expect(throws: ZipError.encrypted(name: "main.bmp")) { try archive.contents(of: archive.entries[0]) }

        var zip64 = ZipWriter.archive([])
        zip64[zip64.count - 12] = 0xFF; zip64[zip64.count - 11] = 0xFF  // entry count 0xFFFF
        zip64[zip64.count - 10] = 0xFF; zip64[zip64.count - 9] = 0xFF
        #expect(throws: ZipError.zip64) { try ZipArchive(data: zip64) }
    }

    @Test func zerosCRCMatchesDirectComputation() {
        for n in [0, 1, 2, 255, 4096, 100_001] {
            #expect(ZipBomb.zerosCRC(count: n) == CRC32.checksum([UInt8](repeating: 0, count: n)), "n=\(n)")
        }
    }
}

/// PLAN M4: a 1 MB archive holding a 1 GiB entry is rejected, and peak memory stays under 150 MB.
@Suite(.serialized) struct ZipBomb1GiBTests {
    @Test func zipBombIsRejectedWithoutInflating() async throws {
        let bomb = try await offPool { ZipBomb.make(uncompressedSize: 1 << 30) }
        #expect(bomb.count < 1_200_000, "bomb is \(bomb.count) bytes")
        #expect(bomb.count > 900_000)
        let before = residentFootprint()
        let archive = try ZipArchive(data: bomb)
        #expect(archive.entries[0].uncompressedSize == 1 << 30)
        #expect(throws: ZipError.entryTooLarge(name: "Skin/MAIN.BMP", bytes: 1 << 30)) { try SkinArchive(archive) }
        let rejection = try await offPool { SkinLoader.load(data: bomb).rejection?.kind }
        #expect(rejection == "entryTooLarge")
        let grown = residentFootprint() - before
        #expect(grown < 150 << 20, "footprint grew by \(grown) bytes")
    }
}

/// Physical footprint of this process (what Activity Monitor shows as Memory).
func residentFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}
