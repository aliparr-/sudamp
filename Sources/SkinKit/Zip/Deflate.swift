// SPDX-License-Identifier: GPL-3.0-or-later
// A small, deterministic DEFLATE (RFC 1951) encoder: greedy LZ77 with hash chains, one fixed-Huffman block.
// skingen needs byte-identical .wsz output on every macOS version, and the system zlib's output is not a
// promise, so generated archives are compressed here. Decoding uses Compression (any conforming inflater works).

import Foundation

enum Deflate {
    private static let windowSize = 32_768
    private static let minMatch = 3
    private static let maxMatch = 258
    /// How many earlier positions with the same hash are tried; bounds the work on repetitive input.
    private static let maxChain = 256
    private static let hashBits = 15

    private static let lengthBase: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    private static let lengthExtra: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    private static let distanceBase: [Int] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
        6145, 8193, 12289, 16385, 24577,
    ]
    private static let distanceExtra: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]

    /// Fixed literal/length code for `symbol` (0...287): (code, bit length), RFC 1951 §3.2.6.
    private static func fixedCode(_ symbol: Int) -> (code: Int, length: Int) {
        switch symbol {
        case 0...143: return (0x30 + symbol, 8)
        case 144...255: return (0x190 + symbol - 144, 9)
        case 256...279: return (symbol - 256, 7)
        default: return (0xC0 + symbol - 280, 8)
        }
    }

    /// Bit-reversed fixed codes, ready to be written LSB-first.
    private static let reversedFixed: [(code: Int, length: Int)] = (0..<288).map { symbol in
        let (code, length) = fixedCode(symbol)
        return (reverse(code, length), length)
    }

    private static let reversedDistance: [Int] = (0..<30).map { reverse($0, 5) }

    private static func reverse(_ code: Int, _ length: Int) -> Int {
        var result = 0, c = code
        for _ in 0..<length {
            result = (result << 1) | (c & 1)
            c >>= 1
        }
        return result
    }

    private struct BitWriter {
        var out = [UInt8]()
        var buffer: UInt64 = 0
        var count = 0

        mutating func write(_ value: Int, _ bits: Int) {
            guard bits > 0 else { return }
            buffer |= UInt64(value) << UInt64(count)
            count += bits
            while count >= 8 {
                out.append(UInt8(truncatingIfNeeded: buffer))
                buffer >>= 8
                count -= 8
            }
        }

        mutating func flush() {
            if count > 0 { out.append(UInt8(truncatingIfNeeded: buffer)) }
            buffer = 0
            count = 0
        }
    }

    static func encode(_ data: Data) -> Data {
        let input = [UInt8](data)
        var bits = BitWriter()
        bits.out.reserveCapacity(input.count / 4 + 16)
        bits.write(1, 1)  // BFINAL
        bits.write(1, 2)  // BTYPE = 01, fixed Huffman

        func literal(_ byte: UInt8) {
            let c = reversedFixed[Int(byte)]
            bits.write(c.code, c.length)
        }

        func match(length: Int, distance: Int) {
            var li = lengthBase.count - 1
            while lengthBase[li] > length { li -= 1 }
            let lc = reversedFixed[257 + li]
            bits.write(lc.code, lc.length)
            bits.write(length - lengthBase[li], lengthExtra[li])
            var di = distanceBase.count - 1
            while distanceBase[di] > distance { di -= 1 }
            bits.write(reversedDistance[di], 5)
            bits.write(distance - distanceBase[di], distanceExtra[di])
        }

        let n = input.count
        let hashSize = 1 << hashBits
        var head = [Int](repeating: -1, count: hashSize)
        var prev = [Int](repeating: -1, count: windowSize)

        func hash(_ i: Int) -> Int {
            (Int(input[i]) << 10 ^ Int(input[i + 1]) << 5 ^ Int(input[i + 2])) & (hashSize - 1)
        }

        func insert(_ i: Int) {
            guard i + 2 < n else { return }
            let h = hash(i)
            prev[i & (windowSize - 1)] = head[h]
            head[h] = i
        }

        var i = 0
        while i < n {
            var bestLength = 0, bestDistance = 0
            if i + minMatch <= n {
                var candidate = head[hash(i)]
                var chain = 0
                let limit = min(maxMatch, n - i)
                while candidate >= 0, i - candidate <= windowSize, chain < maxChain {
                    if input[candidate + bestLength] == input[i + bestLength] || bestLength == 0 {
                        var length = 0
                        while length < limit, input[candidate + length] == input[i + length] { length += 1 }
                        if length > bestLength {
                            bestLength = length
                            bestDistance = i - candidate
                            if length == limit { break }
                        }
                    }
                    let next = prev[candidate & (windowSize - 1)]
                    // Chains only go backwards; stop if the slot was reused by a newer position.
                    if next >= candidate { break }
                    candidate = next
                    chain += 1
                }
            }
            if bestLength >= minMatch {
                match(length: bestLength, distance: bestDistance)
                for k in i..<(i + bestLength) { insert(k) }
                i += bestLength
            } else {
                literal(input[i])
                insert(i)
                i += 1
            }
        }
        let end = reversedFixed[256]
        bits.write(end.code, end.length)
        bits.flush()
        return Data(bits.out)
    }
}
