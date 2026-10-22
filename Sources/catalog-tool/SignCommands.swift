// SPDX-License-Identifier: GPL-3.0-or-later
import Feeds
import Foundation

/// `keygen`, `sign` and `verify` (DESIGN §7.2): raw Ed25519 detached signatures with CryptoKit (LibreSSL has no
/// Ed25519). Key and signature formats: docs/catalog.md "Keys and signatures".
enum SignCommands {
    static let keygenUsage = """
    usage: catalog-tool keygen --out <prefix>
      Writes <prefix>.key (ed25519-private:<base64>, mode 0600) and <prefix>.pub (ed25519-public:<base64>), and prints
      the line to add to FeedTrust.productionKeys. Never overwrites a file.
    """

    static func keygen(_ args: ToolArgs) -> Int32 {
        guard let prefix = args.string("out") else { stderr(keygenUsage); return 64 }
        let keyURL = URL(filePath: prefix + ".key"), pubURL = URL(filePath: prefix + ".pub")
        let fm = FileManager.default
        for u in [keyURL, pubURL] where fm.fileExists(atPath: u.path) {
            stderr("keygen: \(u.path) exists; refusing to overwrite a key")
            return 1
        }
        let key = FeedSigningKey()
        guard let pub = key.publicKey else { stderr("keygen: CryptoKit returned no public key"); return 1 }
        guard fm.createFile(atPath: keyURL.path, contents: Data(key.fileText.utf8), attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: pubURL.path, contents: Data(pub.fileText.utf8)) else {
            stderr("keygen: cannot write \(prefix).{key,pub}")
            return 1
        }
        print("""
        wrote \(keyURL.path) (private, 0600) and \(pubURL.path)
        key id \(pub.keyID)
        add to FeedTrust.productionKeys (Sources/Feeds/FeedTrust.swift):  "\(pub.base64)",
        """)
        return 0
    }

    static let signUsage = """
    usage: catalog-tool sign --key <file|-> [<feed.json>] [--out <feed.json.sig>]
      Signs the exact bytes of feed.json (default catalog/feed.json) and writes the 64-byte raw signature to
      <feed.json>.sig. --key - reads the key line from stdin (e.g. from the Keychain:
      security find-generic-password -s sudamp-feed-key -w | catalog-tool sign --key -).
    """

    static func sign(_ args: ToolArgs) -> Int32 {
        guard let keyArg = args.string("key"), let feedURL = feedFile(args) else { stderr(signUsage); return 64 }
        let keyText: String
        if keyArg == "-" {
            keyText = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        } else {
            guard let t = try? String(contentsOf: URL(filePath: keyArg), encoding: .utf8) else {
                stderr("sign: cannot read \(keyArg)")
                return 1
            }
            keyText = t
        }
        guard let key = FeedSigningKey(text: keyText), let pub = key.publicKey else {
            stderr("sign: \(keyArg) is not an ed25519-private:<base64> key file")
            return 1
        }
        guard let body = try? Data(contentsOf: feedURL) else { stderr("sign: cannot read \(feedURL.path)"); return 1 }
        let sigURL = args.string("out").map { URL(filePath: $0) } ?? URL(filePath: feedURL.path + ".sig")
        do {
            let signature = try key.sign(body)
            guard pub.isValidSignature(signature, for: body) else { stderr("sign: self-check failed"); return 1 }
            try signature.write(to: sigURL, options: .atomic)
        } catch {
            stderr("sign: \(error)")
            return 1
        }
        let trusted = FeedTrust.production.keys.contains(pub) ? "a production key"
            : pub.base64 == FeedTrust.testKey ? "the TEST key (debug builds only)" : "NOT embedded in this build"
        print("signed \(feedURL.path) (\(body.count) bytes) → \(sigURL.path) with key \(pub.keyID), \(trusted)")
        return 0
    }

    static let verifyUsage = """
    usage: catalog-tool verify (--pub <file> | --embedded | --production) [<feed.json>] [--sig <file>]
      Exit 0 when the signature (default <feed.json>.sig; raw 64 bytes or base64) verifies over feed.json.
      --embedded: this build's trusted keys (debug builds include the test key); --production: production keys only.
    """

    static func verify(_ args: ToolArgs) -> Int32 {
        guard let feedURL = feedFile(args) else { stderr(verifyUsage); return 64 }
        let trust: FeedTrust
        if let pubPath = args.string("pub") {
            guard let text = try? String(contentsOf: URL(filePath: pubPath), encoding: .utf8),
                  let pub = FeedPublicKey(text: text) else {
                stderr("verify: \(pubPath) is not an ed25519-public:<base64> key file")
                return 1
            }
            trust = FeedTrust(keys: [pub])
        } else if args.flag("embedded") {
            trust = .embedded
        } else if args.flag("production") {
            trust = .production
        } else {
            stderr(verifyUsage)
            return 64
        }
        let sigURL = args.string("sig").map { URL(filePath: $0) } ?? URL(filePath: feedURL.path + ".sig")
        guard let body = try? Data(contentsOf: feedURL), let sig = try? Data(contentsOf: sigURL) else {
            stderr("verify: cannot read \(feedURL.path) or \(sigURL.path)")
            return 1
        }
        guard FeedSignature.decode(sig) != nil else { stderr("verify: \(sigURL.path) is not a 64-byte Ed25519 signature"); return 1 }
        guard let key = FeedSignature.verify(sig, of: body, trust: trust) else {
            stderr("verify: FAILED: no trusted key (\(trust.keys.map(\.keyID).joined(separator: ", "))) verifies \(sigURL.path)")
            return 1
        }
        print("verified \(feedURL.path) with key \(key.keyID)")
        return 0
    }

    /// The feed file argument, default `catalog/feed.json`.
    static func feedFile(_ args: ToolArgs) -> URL? {
        if let p = args.positionals.first { return URL(filePath: (p as NSString).expandingTildeInPath) }
        return catalogDirectory(nil)?.appending(path: "feed.json")
    }
}
