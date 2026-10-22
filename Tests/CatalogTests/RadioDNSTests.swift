// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Catalog

@Test(arguments: [
    ("127.0.0.1", false), ("127.255.0.9", false), ("10.1.2.3", false), ("172.16.0.1", false), ("172.31.255.255", false),
    ("172.32.0.1", true), ("192.168.1.1", false), ("169.254.169.254", false), ("100.64.0.1", false), ("100.128.0.1", true),
    ("0.0.0.0", false), ("224.0.0.1", false), ("239.255.255.250", false), ("255.255.255.255", false), ("240.0.0.1", false),
    ("192.0.2.5", false), ("198.18.0.1", false), ("198.51.100.7", false), ("203.0.113.9", false),
    ("8.8.8.8", true), ("1.1.1.1", true), ("216.235.82.21", true),
    ("::1", false), ("::", false), ("fe80::1", false), ("fc00::1", false), ("fd12:3456::1", false), ("ff02::1", false),
    ("fec0::1", false), ("2001:db8::1", false), ("3fff::1", false), ("2001:0:4136:e378::1", false),
    ("::ffff:127.0.0.1", false), ("::ffff:10.0.0.1", false), ("::ffff:8.8.8.8", true),
    ("64:ff9b::a00:1", false), ("64:ff9b::808:808", true), ("2002:a00:1::1", false), ("2002:808:808::1", true),
    ("2606:4700:4700::1111", true), ("2001:4860:4860::8888", true), ("2a01:4f8:c014:ea17::1", true),
])
func classifiesAddresses(address: String, isPublic: Bool) throws {
    let ip = try #require(IPAddress(address), "\(address) should parse")
    #expect(ip.isPublic == isPublic, "\(address)")
}

@Test func parsesAndPrintsAddresses() {
    #expect(IPAddress("216.235.82.21")?.description == "216.235.82.21")
    #expect(IPAddress("2001:db8::1")?.description == "2001:db8::1")
    #expect(IPAddress(bytes: [10, 0, 0, 1]) == IPAddress("10.0.0.1"))
    for bad in ["127.1", "0x7f.0.0.1", "256.0.0.1", "1.2.3", "localhost", "", "::g"] { #expect(IPAddress(bad) == nil, "\(bad)") }
}

@Test func dnsCheckRejectsNonPublicAnswers() throws {
    #expect(throws: CanonicalError.unresolvable) { try RadioHostCheck.validate(addresses: []) }
    #expect(throws: CanonicalError.nonPublicAddress("127.0.0.1")) { try RadioHostCheck.validate(addresses: [IPAddress("127.0.0.1")!]) }
    // A rebinding-style answer mixing a public and a private address is refused.
    #expect(throws: CanonicalError.nonPublicAddress("10.0.0.7")) {
        try RadioHostCheck.validate(addresses: [IPAddress("8.8.8.8")!, IPAddress("10.0.0.7")!])
    }
    try RadioHostCheck.validate(addresses: [IPAddress("8.8.8.8")!, IPAddress("2606:4700:4700::1111")!])
}

struct FakeResolver: HostResolving {
    let answers: [String: [String]]
    struct NXDomain: Error {}
    func addresses(for host: String) async throws -> [IPAddress] {
        guard let a = answers[host] else { throw NXDomain() }
        return a.compactMap(IPAddress.init)
    }
}

@Test func dnsCheckUsesInjectedResolver() async throws {
    let resolver = FakeResolver(answers: [
        "stream.example.com": ["195.66.134.40", "2001:67c:2464:100::40"],
        "rebind.example.com": ["127.0.0.1"],
        "lan.example.com": ["192.168.0.10"],
        "meta.example.com": ["169.254.169.254"],
        "v6.example.com": ["fd00::1"],
    ])
    let ok = try await RadioHostCheck.check(URL(string: "https://Stream.Example.com/hd#x")!, resolver: resolver)
    #expect(ok.absoluteString == "https://stream.example.com/hd")
    for host in ["rebind", "lan", "meta", "v6"] {
        await #expect(throws: CanonicalError.self, "\(host)") {
            _ = try await RadioHostCheck.check(URL(string: "http://\(host).example.com:8000/")!, resolver: resolver)
        }
    }
    await #expect(throws: CanonicalError.unresolvable) {
        _ = try await RadioHostCheck.check(URL(string: "http://missing.example.com/")!, resolver: resolver)
    }
    // URL rules run before DNS: an IP literal never reaches the resolver.
    await #expect(throws: CanonicalError.ipLiteral) {
        _ = try await RadioHostCheck.check(URL(string: "http://8.8.8.8/")!, resolver: resolver)
    }
}

@Test func systemResolverFindsLoopback() async throws {
    // `localhost` resolves without the network; the policy must still refuse it.
    let addrs = try await SystemHostResolver().addresses(for: "localhost")
    #expect(!addrs.isEmpty)
    #expect(addrs.allSatisfy { !$0.isPublic })
}
