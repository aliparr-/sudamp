// SPDX-License-Identifier: GPL-3.0-or-later
//
// In-memory ZIP reader for .wsz skins: stored or deflate entries, no encryption, no zip64.
//
// Ported from Bitamp, Sources/BitampKit/Skin/ZipArchive.swift
// (https://github.com/ryanromanov/Bitamp @ 91952819c9cc0394dd03a961dd27a101a52ee6ef).
// sudamp changes: every size cap is checked before anything is allocated (DESIGN §8.2; uncapped, a 1 MB bomb
// pushed the original to 2.16 GB), inflation is bounded by the declared size, names decode as UTF-8 or CP437,
// zip64/multi-disk/encrypted entries are refused, the archive is read from `Data` without copying, and the
// type is Sendable.
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

import Compression
import Foundation

/// Resource caps for reading untrusted archives. All checks happen before the matching allocation.
public struct ZipLimits: Sendable, Equatable {
    /// Largest entry, by declared uncompressed size, by compressed size, and while inflating.
    public var maxEntryBytes: Int
    /// Largest sum of declared uncompressed sizes over the entries actually extracted.
    public var maxTotalBytes: Int
    /// Most central-directory entries, checked from the end record before any entry is parsed.
    public var maxEntries: Int
    /// Largest archive file read from disk (checked with a stat before reading).
    public var maxArchiveBytes: Int

    public init(maxEntryBytes: Int, maxTotalBytes: Int, maxEntries: Int, maxArchiveBytes: Int) {
        self.maxEntryBytes = maxEntryBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxEntries = maxEntries
        self.maxArchiveBytes = maxArchiveBytes
    }

    /// DESIGN §8.2: 32 MB per entry, 96 MB in total, 512 entries (wamp's policy plus an entry cap).
    public static let skin = ZipLimits(
        maxEntryBytes: 32 << 20, maxTotalBytes: 96 << 20, maxEntries: 512, maxArchiveBytes: 128 << 20)
}

public enum ZipError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAZip
    /// A valid archive with no file a classic skin uses.
    case notASkin
    case corrupt(String)
    case zip64
    case tooManyEntries(Int)
    case archiveTooLarge(bytes: Int)
    case entryTooLarge(name: String, bytes: Int)
    case totalTooLarge(bytes: Int)
    case unsupportedMethod(name: String, method: UInt16)
    case encrypted(name: String)
    case sizeMismatch(name: String)

    /// Errors that mean the archive is hostile or unusable as a whole (as opposed to one bad entry).
    public var rejectsArchive: Bool {
        switch self {
        case .notAZip, .notASkin, .zip64, .tooManyEntries, .archiveTooLarge, .entryTooLarge, .totalTooLarge: return true
        case .corrupt, .unsupportedMethod, .encrypted, .sizeMismatch: return false
        }
    }

    /// Stable short identifier for reports and `state.json`.
    public var kind: String {
        switch self {
        case .notAZip: return "notAZip"
        case .notASkin: return "notASkin"
        case .corrupt: return "corrupt"
        case .zip64: return "zip64"
        case .tooManyEntries: return "tooManyEntries"
        case .archiveTooLarge: return "archiveTooLarge"
        case .entryTooLarge: return "entryTooLarge"
        case .totalTooLarge: return "totalTooLarge"
        case .unsupportedMethod: return "unsupportedMethod"
        case .encrypted: return "encrypted"
        case .sizeMismatch: return "sizeMismatch"
        }
    }

    public var description: String {
        switch self {
        case .notAZip: return "not a zip archive"
        case .notASkin: return "no skin files (bitmaps, viscolor.txt, pledit.txt or region.txt) in the archive"
        case .corrupt(let why): return "corrupt archive: \(why)"
        case .zip64: return "zip64 archives are not supported"
        case .tooManyEntries(let n): return "too many entries (\(n))"
        case .archiveTooLarge(let n): return "archive too large (\(n) bytes)"
        case .entryTooLarge(let name, let n): return "entry \(name) too large (\(n) bytes)"
        case .totalTooLarge(let n): return "entries too large in total (\(n) bytes)"
        case .unsupportedMethod(let name, let m): return "entry \(name) uses unsupported method \(m)"
        case .encrypted(let name): return "entry \(name) is encrypted"
        case .sizeMismatch(let name): return "entry \(name) does not inflate to its declared size"
        }
    }
}

public struct ZipArchive: Sendable {
    public struct Entry: Sendable, Hashable {
        /// Full path inside the archive, decoded as UTF-8 (flag bit 11) or CP437.
        public let path: String
        public let method: UInt16
        public let flags: UInt16
        public let crc32: UInt32
        public let compressedSize: Int
        public let uncompressedSize: Int
        let localHeaderOffset: Int

        public var isDirectory: Bool { path.hasSuffix("/") || path.hasSuffix("\\") }
        public var isEncrypted: Bool { flags & 0x1 != 0 }
        public var isUTF8: Bool { flags & 0x800 != 0 }
        /// Last path component, with `/` or `\` as separators (Windows tools write either).
        public var basename: String {
            let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            return parts.last.map(String.init) ?? ""
        }
    }

    public let entries: [Entry]
    public let limits: ZipLimits
    private let data: Data

    public init(data: Data, limits: ZipLimits = .skin) throws {
        guard data.count <= limits.maxArchiveBytes else { throw ZipError.archiveTooLarge(bytes: data.count) }
        // Rebase so integer offsets index from 0 even for sliced Data.
        self.data = data.startIndex == 0 ? data : Data(data)
        self.limits = limits
        entries = try Self.readCentralDirectory(self.data, limits: limits)
    }

    /// Reads a file after checking its size on disk, so a huge file is never loaded.
    public init(contentsOf url: URL, limits: ZipLimits = .skin) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= limits.maxArchiveBytes else { throw ZipError.archiveTooLarge(bytes: size) }
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe), limits: limits)
    }

    /// The entry's bytes. Declared sizes are checked against the caps before any buffer is allocated, and
    /// inflation can never write more than the declared size.
    public func contents(of entry: Entry) throws -> Data {
        guard entry.uncompressedSize <= limits.maxEntryBytes else {
            throw ZipError.entryTooLarge(name: entry.path, bytes: entry.uncompressedSize)
        }
        guard entry.compressedSize <= limits.maxEntryBytes else {
            throw ZipError.entryTooLarge(name: entry.path, bytes: entry.compressedSize)
        }
        guard !entry.isEncrypted else { throw ZipError.encrypted(name: entry.path) }
        guard entry.method == 0 || entry.method == 8 else {
            throw ZipError.unsupportedMethod(name: entry.path, method: entry.method)
        }

        let header = entry.localHeaderOffset
        guard header >= 0, header + 30 <= data.count, u32(header) == 0x0403_4B50 else {
            throw ZipError.corrupt("bad local header for \(entry.path)")
        }
        let start = header + 30 + Int(u16(header + 26)) + Int(u16(header + 28))
        guard start <= data.count, entry.compressedSize <= data.count - start else {
            throw ZipError.corrupt("entry \(entry.path) runs past the end of the archive")
        }

        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else { throw ZipError.sizeMismatch(name: entry.path) }
            return data.subdata(in: start..<(start + entry.compressedSize))
        default:
            return try inflate(entry, from: start)
        }
    }

    /// Extracts several entries after checking that their declared sizes fit the total cap together.
    public func contents(of entries: [Entry]) throws -> [Result<Data, ZipError>] {
        for entry in entries where entry.uncompressedSize > limits.maxEntryBytes || entry.compressedSize > limits.maxEntryBytes {
            throw ZipError.entryTooLarge(name: entry.path, bytes: max(entry.uncompressedSize, entry.compressedSize))
        }
        let total = entries.reduce(0) { $0 + $1.uncompressedSize }
        guard total <= limits.maxTotalBytes else { throw ZipError.totalTooLarge(bytes: total) }
        return entries.map { entry in
            do { return .success(try contents(of: entry)) } catch let error as ZipError {
                return .failure(error)
            } catch {
                return .failure(.corrupt("\(error)"))
            }
        }
    }

    // MARK: - Private

    private func inflate(_ entry: Entry, from start: Int) throws -> Data {
        let expected = entry.uncompressedSize
        if expected == 0 { return Data() }
        // One spare byte: if it gets written, the stream inflates past its declared size (a lying header).
        let capacity = expected + 1
        var output = Data(count: capacity)
        let written: Int = data.withUnsafeBytes { raw in
            let source = raw.baseAddress!.advanced(by: start).assumingMemoryBound(to: UInt8.self)
            return output.withUnsafeMutableBytes { out in
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what ZIP stores. Decoding stops when the
                // destination is full, so a bomb costs at most `capacity` bytes and that much work.
                compression_decode_buffer(
                    out.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                    source, entry.compressedSize, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { throw ZipError.sizeMismatch(name: entry.path) }
        output.count = expected
        return output
    }

    private func u16(_ at: Int) -> UInt16 { Self.u16(data, at) }
    private func u32(_ at: Int) -> UInt32 { Self.u32(data, at) }

    private static func u16(_ data: Data, _ at: Int) -> UInt16 {
        UInt16(data[at]) | UInt16(data[at + 1]) << 8
    }

    private static func u32(_ data: Data, _ at: Int) -> UInt32 {
        UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
    }

    private static func readCentralDirectory(_ data: Data, limits: ZipLimits) throws -> [Entry] {
        // The end-of-central-directory record is the last 22 bytes, plus up to 64 KB of comment.
        guard data.count >= 22 else { throw ZipError.notAZip }
        let earliest = max(0, data.count - 22 - 0xFFFF)
        var end: Int?
        var at = data.count - 22
        while at >= earliest {
            if u32(data, at) == 0x0605_4B50 {
                end = at
                break
            }
            at -= 1
        }
        guard let end else { throw ZipError.notAZip }

        let diskNumber = u16(data, end + 4), cdDisk = u16(data, end + 6)
        let countOnDisk = Int(u16(data, end + 8)), count = Int(u16(data, end + 10))
        let cdSize = Int(u32(data, end + 12)), cdOffset = Int(u32(data, end + 16))
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF || cdSize == 0xFFFF_FFFF { throw ZipError.zip64 }
        guard diskNumber == 0, cdDisk == 0, countOnDisk == count else { throw ZipError.corrupt("multi-disk archive") }
        // The entry cap is checked before a single entry is parsed or stored.
        guard count <= limits.maxEntries else { throw ZipError.tooManyEntries(count) }
        guard cdOffset <= end, cdSize <= end - cdOffset else { throw ZipError.corrupt("central directory out of range") }

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var offset = cdOffset
        for _ in 0..<count {
            guard offset + 46 <= end, u32(data, offset) == 0x0201_4B50 else {
                throw ZipError.corrupt("bad central directory entry")
            }
            let flags = u16(data, offset + 8)
            let nameLength = Int(u16(data, offset + 28))
            let extraLength = Int(u16(data, offset + 30))
            let commentLength = Int(u16(data, offset + 32))
            let compressed = u32(data, offset + 20), uncompressed = u32(data, offset + 24)
            let localOffset = u32(data, offset + 42)
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ZipError.zip64
            }
            guard offset + 46 + nameLength <= end else { throw ZipError.corrupt("entry name out of range") }
            let nameBytes = data[(offset + 46)..<(offset + 46 + nameLength)]
            let name = flags & 0x800 != 0 ? String(decoding: nameBytes, as: UTF8.self) : CP437.decode(nameBytes)
            entries.append(Entry(
                path: name, method: u16(data, offset + 10), flags: flags, crc32: u32(data, offset + 16),
                compressedSize: Int(compressed), uncompressedSize: Int(uncompressed),
                localHeaderOffset: Int(localOffset)))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }
}
