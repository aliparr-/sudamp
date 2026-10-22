// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// An Ed25519 public key that may sign `feed.json` (DESIGN §7.2).
///
/// Key files (`catalog-tool keygen`, `Fixtures/keys/test-ed25519.pub`) hold one line, `ed25519-public:<base64>`, where
/// `<base64>` is standard base64 of the 32-byte raw key (CryptoKit's `rawRepresentation`). The bare base64 form is
/// accepted too: it is how keys are embedded in `FeedTrust`.
public struct FeedPublicKey: Sendable, Hashable, CustomStringConvertible {
    public static let filePrefix = "ed25519-public:"

    /// The 32-byte raw key.
    public let rawRepresentation: Data

    public init?(rawRepresentation: Data) {
        guard rawRepresentation.count == 32,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: rawRepresentation)) != nil else { return nil }
        self.rawRepresentation = rawRepresentation
    }

    /// `ed25519-public:<base64>` or bare base64 (surrounding whitespace ignored).
    public init?(text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(Self.filePrefix) { s.removeFirst(Self.filePrefix.count) }
        guard let raw = Data(base64Encoded: s) else { return nil }
        self.init(rawRepresentation: raw)
    }

    /// Standard base64 of the raw key (the form embedded in `FeedTrust`).
    public var base64: String { rawRepresentation.base64EncodedString() }

    /// The key-file line.
    public var fileText: String { Self.filePrefix + base64 + "\n" }

    /// First 8 bytes of SHA-256 of the raw key, in hex: logged and recorded so the owner can tell keys apart.
    public var keyID: String { SHA256.hash(data: rawRepresentation).prefix(8).map { String(format: "%02x", $0) }.joined() }

    public var description: String { "ed25519:\(keyID)" }

    /// Whether `signature` (64 raw bytes) signs `message` under this key.
    public func isValidSignature(_ signature: Data, for message: Data) -> Bool {
        guard signature.count == FeedSignature.rawLength,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawRepresentation) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

/// An Ed25519 private key for `catalog-tool sign`. Never embedded in the app.
///
/// Key files hold one line, `ed25519-private:<base64>` (standard base64 of CryptoKit's 32-byte `rawRepresentation`),
/// and should be mode 0600. Keeping the production key in the Keychain instead is the owner's choice (docs/catalog.md).
public struct FeedSigningKey: Sendable {
    public static let filePrefix = "ed25519-private:"

    private let key: Curve25519.Signing.PrivateKey

    /// A fresh random key (`catalog-tool keygen`).
    public init() {
        key = Curve25519.Signing.PrivateKey()
    }

    public init?(rawRepresentation: Data) {
        guard rawRepresentation.count == 32,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation) else { return nil }
        self.key = key
    }

    /// `ed25519-private:<base64>`. The prefix is required, so a public key file can't be mistaken for a private one.
    public init?(text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(Self.filePrefix), let raw = Data(base64Encoded: String(s.dropFirst(Self.filePrefix.count))) else {
            return nil
        }
        self.init(rawRepresentation: raw)
    }

    /// The key-file line.
    public var fileText: String { Self.filePrefix + key.rawRepresentation.base64EncodedString() + "\n" }

    /// The matching public key (nil only if CryptoKit returned a malformed key, which it does not).
    public var publicKey: FeedPublicKey? { FeedPublicKey(rawRepresentation: key.publicKey.rawRepresentation) }

    /// Signs `message`; the result is the 64-byte raw signature. CryptoKit's Ed25519 signatures are randomised, so
    /// signing the same bytes twice gives two different (both valid) signatures.
    public func sign(_ message: Data) throws -> Data {
        try key.signature(for: message)
    }
}

/// `feed.json.sig`: a detached Ed25519 signature over the exact bytes of `feed.json` (DESIGN §7.2).
///
/// **Format.** The canonical file is the **64 raw signature bytes** and nothing else (what `catalog-tool sign`
/// writes). Readers also accept the same 64 bytes as standard base64 text (88 characters, surrounding whitespace
/// ignored), for hosts or editors that mangle binary files; the two forms can't be confused by length.
public enum FeedSignature {
    public static let rawLength = 64
    /// Anything larger is not a signature file (the fetcher's cap).
    public static let maxFileBytes = 1024

    /// The raw signature in a `.sig` file's contents, or nil if it is neither form.
    public static func decode(_ file: Data) -> Data? {
        if file.count == rawLength { return file }
        guard file.count <= maxFileBytes, let text = String(data: file, encoding: .utf8) else { return nil }
        guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count == rawLength else { return nil }
        return raw
    }

    /// The first trusted key that verifies `signatureFile` over `document`, or nil.
    public static func verify(_ signatureFile: Data, of document: Data, trust: FeedTrust) -> FeedPublicKey? {
        guard let signature = decode(signatureFile) else { return nil }
        return trust.keys.first { $0.isValidSignature(signature, for: document) }
    }
}
