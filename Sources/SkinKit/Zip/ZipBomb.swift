// SPDX-License-Identifier: GPL-3.0-or-later
// Builds zip bombs for tests and `sudamp-dev skin-fuzz --make-bomb`: a small archive whose entry inflates to a
// huge size. The DEFLATE stream is produced by Compression in fixed-size chunks, so making a 1 GiB bomb never
// holds more than one chunk of input in memory.

import Compression
import Foundation

public enum ZipBomb {
    /// An archive with `name` (default a whitelisted sheet, so the loader must look at it) declaring and holding
    /// `uncompressedSize` zero bytes, plus a small viscolor.txt. `lie` makes the header declare `lie` bytes
    /// instead, to test that inflation stops at the declared size.
    public static func make(name: String = "Skin/MAIN.BMP", uncompressedSize: Int, lie: Int? = nil) -> Data {
        let stream = deflateZeros(count: uncompressedSize)
        var entries: [(name: String, method: UInt16, crc: UInt32, compressed: Data, size: Int)] = []
        entries.append((name, 8, zerosCRC(count: uncompressedSize), stream, lie ?? uncompressedSize))
        let vis = Data("0,0,0\r\n".utf8)
        entries.append(("Skin/viscolor.txt", 0, CRC32.checksum(vis), vis, vis.count))

        var out = Data(), central = Data()
        for e in entries {
            let nameBytes = Data(e.name.utf8)
            let offset = out.count
            out.append(u32: 0x0403_4B50); out.append(u16: 20); out.append(u16: 0); out.append(u16: e.method)
            out.append(u16: 0); out.append(u16: 0x21); out.append(u32: e.crc)
            out.append(u32: UInt32(e.compressed.count)); out.append(u32: UInt32(truncatingIfNeeded: e.size))
            out.append(u16: UInt16(nameBytes.count)); out.append(u16: 0); out.append(nameBytes); out.append(e.compressed)
            central.append(u32: 0x0201_4B50); central.append(u16: 20); central.append(u16: 20); central.append(u16: 0)
            central.append(u16: e.method); central.append(u16: 0); central.append(u16: 0x21); central.append(u32: e.crc)
            central.append(u32: UInt32(e.compressed.count)); central.append(u32: UInt32(truncatingIfNeeded: e.size))
            central.append(u16: UInt16(nameBytes.count)); central.append(u16: 0); central.append(u16: 0)
            central.append(u16: 0); central.append(u16: 0); central.append(u32: 0); central.append(u32: UInt32(offset))
            central.append(nameBytes)
        }
        let cdOffset = out.count
        out.append(central)
        out.append(u32: 0x0605_4B50); out.append(u16: 0); out.append(u16: 0)
        out.append(u16: UInt16(entries.count)); out.append(u16: UInt16(entries.count))
        out.append(u32: UInt32(central.count)); out.append(u32: UInt32(cdOffset)); out.append(u16: 0)
        return out
    }

    /// Raw DEFLATE of `count` zero bytes, encoded chunk by chunk.
    static func deflateZeros(count: Int) -> Data {
        let chunk = 4 << 20
        let zeros = [UInt8](repeating: 0, count: chunk)
        let outCapacity = 1 << 16
        var outBuffer = [UInt8](repeating: 0, count: outCapacity)
        var result = Data()
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { return Data() }
        defer { compression_stream_destroy(&stream) }
        var remaining = count
        zeros.withUnsafeBufferPointer { src in
            outBuffer.withUnsafeMutableBufferPointer { dst in
                repeat {
                    let take = min(chunk, remaining)
                    remaining -= take
                    stream.src_ptr = src.baseAddress!
                    stream.src_size = take
                    let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    var status: compression_status
                    repeat {
                        stream.dst_ptr = dst.baseAddress!
                        stream.dst_size = outCapacity
                        status = compression_stream_process(&stream, flags)
                        result.append(dst.baseAddress!, count: outCapacity - stream.dst_size)
                    } while status == COMPRESSION_STATUS_OK && (stream.src_size > 0 || (flags != 0 && stream.dst_size == 0))
                    if status == COMPRESSION_STATUS_ERROR { return }
                } while remaining > 0
            }
        }
        return result
    }

    /// CRC-32 of `count` zero bytes in O(log n): appending a zero byte is a linear map on the CRC register over
    /// GF(2), so n bytes is that 32x32 bit matrix raised to the n-th power (the trick behind zlib's crc32_combine).
    static func zerosCRC(count: Int) -> UInt32 {
        typealias Matrix = [UInt32]  // 32 columns; column i is the image of bit i.
        func apply(_ m: Matrix, _ v: UInt32) -> UInt32 {
            var result: UInt32 = 0, v = v, i = 0
            while v != 0 {
                if v & 1 != 0 { result ^= m[i] }
                v >>= 1
                i += 1
            }
            return result
        }
        func multiply(_ a: Matrix, _ b: Matrix) -> Matrix { b.map { apply(a, $0) } }
        // One zero byte: crc' = table[crc & 0xFF] ^ (crc >> 8), linear in crc.
        var step: Matrix = (0..<32).map { bit in CRC32.update(UInt32(1) << UInt32(bit), [0]) ^ CRC32.update(0, [0]) }
        var power: Matrix = (0..<32).map { UInt32(1) << UInt32($0) }  // identity
        var n = count
        while n > 0 {
            if n & 1 != 0 { power = multiply(step, power) }
            step = multiply(step, step)
            n >>= 1
        }
        return apply(power, 0xFFFF_FFFF) ^ 0xFFFF_FFFF
    }
}
