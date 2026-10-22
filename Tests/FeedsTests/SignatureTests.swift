// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation
import Testing
@testable import Feeds

@Test func committedTestKeypairMatchesTheEmbeddedTestKey() throws {
    let pubText = try String(contentsOf: repoRoot.appending(path: "Fixtures/keys/test-ed25519.pub"), encoding: .utf8)
    let pub = try #require(FeedPublicKey(text: pubText))
    #expect(testSigningKey.publicKey == pub, "Fixtures/keys/test-ed25519.key and .pub are one pair")
    #expect(pub.base64 == FeedTrust.testKey)
    #expect(pub.fileText == pubText)
    #expect(pub.keyID.count == 16)
    #if DEBUG
    #expect(FeedTrust.embedded.keys.contains(pub), "debug builds trust the committed test key")
    #endif
    #expect(!FeedTrust.production.keys.contains(pub), "release builds never trust it")
    #expect(FeedTrust.productionKeys.count <= 2, "two embedded keys for rotation")
}

@Test func signatureVerifiesAndRejectsTamperingAndWrongKeys() throws {
    let (body, sig) = try signed(doc(revision: 3))
    #expect(sig.count == 64)
    #expect(FeedSignature.verify(sig, of: body, trust: testTrust) == testSigningKey.publicKey)
    // One flipped byte anywhere in the document.
    for index in [0, body.count / 2, body.count - 1] {
        var tampered = body
        tampered[index] ^= 0x01
        #expect(FeedSignature.verify(sig, of: tampered, trust: testTrust) == nil, "byte \(index)")
    }
    // One flipped byte in the signature.
    var badSig = sig
    badSig[10] ^= 0x80
    #expect(FeedSignature.verify(badSig, of: body, trust: testTrust) == nil)
    // Signed with another key.
    let other = FeedSigningKey()
    #expect(FeedSignature.verify(try other.sign(body), of: body, trust: testTrust) == nil)
    // Trusting both (rotation): either key verifies.
    let both = FeedTrust(keys: [testSigningKey.publicKey!, other.publicKey!])
    #expect(FeedSignature.verify(try other.sign(body), of: body, trust: both) == other.publicKey)
    #expect(FeedSignature.verify(sig, of: body, trust: FeedTrust(keys: [])) == nil, "no keys: nothing verifies")
}

@Test func signatureFileFormats() throws {
    let (body, sig) = try signed(doc(revision: 1))
    // Canonical: 64 raw bytes. Also accepted: base64 text with surrounding whitespace.
    #expect(FeedSignature.decode(sig) == sig)
    #expect(FeedSignature.decode(Data((sig.base64EncodedString() + "\n").utf8)) == sig)
    #expect(FeedSignature.verify(Data(("  " + sig.base64EncodedString() + "\r\n").utf8), of: body, trust: testTrust) != nil)
    for bad in [Data(), Data(repeating: 0, count: 63), Data(repeating: 0, count: 65), Data("not base64!".utf8),
                Data(Data(repeating: 1, count: 32).base64EncodedString().utf8), Data(repeating: 0x41, count: 4096)] {
        #expect(FeedSignature.decode(bad) == nil, "\(bad.count) bytes")
    }
}

@Test func keyFileFormats() throws {
    let key = FeedSigningKey()
    let reread = try #require(FeedSigningKey(text: key.fileText))
    #expect(reread.publicKey == key.publicKey)
    #expect(key.fileText.hasPrefix("ed25519-private:") && key.fileText.hasSuffix("\n"))
    let pub = try #require(key.publicKey)
    #expect(FeedPublicKey(text: pub.fileText) == pub)
    #expect(FeedPublicKey(text: pub.base64) == pub, "bare base64 (the embedded form)")
    // A public key file is not a private key, and garbage is neither.
    #expect(FeedSigningKey(text: pub.fileText) == nil)
    #expect(FeedSigningKey(text: pub.base64) == nil)
    #expect(FeedPublicKey(text: "ed25519-public:AAAA") == nil)
    #expect(FeedPublicKey(text: "") == nil)
    // Malformed embedded keys are skipped, never trusted.
    #expect(FeedTrust(base64Keys: ["junk", pub.base64, pub.base64]).keys == [pub])
}

@Test func blockLatestFixtureIsSignedAndPinsAnOlderRelease() throws {
    let dir = repoRoot.appending(path: "Fixtures/feeds/block-latest")
    let body = try Data(contentsOf: dir.appending(path: "feed.json"))
    let sig = try Data(contentsOf: dir.appending(path: "feed.json.sig"))
    #expect(sig.count == FeedSignature.rawLength)
    #expect(FeedSignature.verify(sig, of: body, trust: testTrust) == testSigningKey.publicKey)
    #expect(FeedSignature.verify(sig, of: body, trust: .production) == nil, "release builds never accept it")
    let feed = try BundledFeed.load(data: body, url: dir, origin: .fetched)
    #expect(feed.warnings.isEmpty, "\(feed.warnings)")
    #expect(feed.document.revision == 3)
    #expect(feed.document.engine.block == ["2026.10.21"])
    #expect(feed.document.engine.pin == EnginePin(version: "2026.08.19",
                                                 sha256: "07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8"))
}
