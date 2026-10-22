// SPDX-License-Identifier: GPL-3.0-or-later
// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320), as ZIP uses. Compression has no CRC API and zlib has no
// Swift module on the Command Line Tools, so the table is computed here once.

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        update(0xFFFF_FFFF, bytes) ^ 0xFFFF_FFFF
    }

    /// Running form: start from 0xFFFFFFFF, feed chunks, then XOR the result with 0xFFFFFFFF.
    static func update<C: Collection>(_ start: UInt32, _ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc = start
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc
    }
}
