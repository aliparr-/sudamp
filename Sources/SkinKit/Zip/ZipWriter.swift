// SPDX-License-Identifier: GPL-3.0-or-later
// Deterministic ZIP writer for generated skins (skingen) and fuzz fixtures. Output depends only on the entries:
// fixed DOS timestamp (1980-01-01 00:00), no extra fields, no OS-specific attributes, entries in the given order,
// and sudamp's own DEFLATE encoder (or none), so two runs on any machine are byte-identical.

import Foundation

public enum ZipWriter {
    public enum Method: Sendable {
        /// Method 0, no compression.
        case stored
        /// Method 8, compressed with `Deflate.encode` (deterministic, independent of the OS's zlib).
        case deflate
    }

    public struct Entry: Sendable {
        public var path: String
        public var data: Data
        public var method: Method
        /// Raw name bytes written without the UTF-8 flag (CP437 test archives); `path` is ignored when set.
        public var rawName: [UInt8]?

        public init(path: String, data: Data, method: Method = .deflate, rawName: [UInt8]? = nil) {
            self.path = path
            self.data = data
            self.method = method
            self.rawName = rawName
        }
    }

    /// DOS time 00:00:00 and date 1980-01-01, the earliest representable value (also what AndAmp's build uses).
    static let dosTime: UInt16 = 0
    static let dosDate: UInt16 = (0 << 9) | (1 << 5) | 1

    public static func archive(_ entries: [Entry], comment: String = "") -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = entry.rawName.map { Data($0) } ?? Data(entry.path.utf8)
            let isASCII = entry.path.utf8.allSatisfy { $0 < 0x80 }
            let flags: UInt16 = entry.rawName != nil || isASCII ? 0 : 0x800
            let crc = CRC32.checksum(entry.data)
            let payload: Data
            let method: UInt16
            switch entry.method {
            case .stored:
                payload = entry.data
                method = 0
            case .deflate:
                let compressed = Deflate.encode(entry.data)
                // Keep whichever is smaller, as zip tools do; the choice is deterministic either way.
                if compressed.count < entry.data.count {
                    payload = compressed
                    method = 8
                } else {
                    payload = entry.data
                    method = 0
                }
            }
            let version: UInt16 = method == 8 ? 20 : 10
            let localOffset = out.count

            out.append(u32: 0x0403_4B50)
            out.append(u16: version)
            out.append(u16: flags)
            out.append(u16: method)
            out.append(u16: dosTime)
            out.append(u16: dosDate)
            out.append(u32: crc)
            out.append(u32: UInt32(payload.count))
            out.append(u32: UInt32(entry.data.count))
            out.append(u16: UInt16(name.count))
            out.append(u16: 0)
            out.append(name)
            out.append(payload)

            central.append(u32: 0x0201_4B50)
            central.append(u16: version)  // version made by: MS-DOS, spec 1.0/2.0
            central.append(u16: version)
            central.append(u16: flags)
            central.append(u16: method)
            central.append(u16: dosTime)
            central.append(u16: dosDate)
            central.append(u32: crc)
            central.append(u32: UInt32(payload.count))
            central.append(u32: UInt32(entry.data.count))
            central.append(u16: UInt16(name.count))
            central.append(u16: 0)  // extra
            central.append(u16: 0)  // comment
            central.append(u16: 0)  // disk
            central.append(u16: 0)  // internal attributes
            central.append(u32: 0)  // external attributes
            central.append(u32: UInt32(localOffset))
            central.append(name)
        }
        let cdOffset = out.count
        out.append(central)
        let commentBytes = Data(comment.utf8.prefix(0xFFFF))
        out.append(u32: 0x0605_4B50)
        out.append(u16: 0)
        out.append(u16: 0)
        out.append(u16: UInt16(entries.count))
        out.append(u16: UInt16(entries.count))
        out.append(u32: UInt32(central.count))
        out.append(u32: UInt32(cdOffset))
        out.append(u16: UInt16(commentBytes.count))
        out.append(commentBytes)
        return out
    }
}

extension Data {
    mutating func append(u16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func append(u32 value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
