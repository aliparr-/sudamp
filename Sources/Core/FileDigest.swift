// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// SHA-256 helpers, lower-case hex like `shasum -a 256` and upstream `SHA2-256SUMS` files.
public enum FileDigest {
    /// Streams the file in 1 MiB chunks, so a 54 MB engine zip never sits in memory.
    public static func sha256(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    public static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// True for exactly 64 lower-case hex characters (DESIGN §7.2 `sha256` rule).
    public static func isSHA256Hex(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
