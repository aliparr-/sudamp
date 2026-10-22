// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Core

/// Fixture dictionaries in the shape `CFNetworkCopySystemProxySettings` returns (PLAN M3: "system-proxy fixture
/// dictionaries map to the expected yt-dlp argv and mpv options (PAC-only or SOCKS-only to none)").
@Suite struct SystemProxyTests {
    @Test func noProxyConfigured() {
        #expect(SystemProxy.resolve(settings: [:]) == .direct)
        #expect(SystemProxy.resolve(settings: ["HTTPEnable": 0, "HTTPProxy": "proxy.corp.test", "HTTPPort": 3128]) == .direct)
        #expect(SystemProxy.resolve(settings: ["ExceptionsList": ["*.local", "169.254/16"], "FTPPassive": 1]) == .direct)
    }

    @Test func httpProxy() {
        let r = SystemProxy.resolve(settings: ["HTTPEnable": 1, "HTTPProxy": "proxy.example.net", "HTTPPort": 3128])
        #expect(r.url?.absoluteString == "http://proxy.example.net:3128")
        #expect(r.origin == .system && r.unsupported == nil)
    }

    @Test func httpsProxyWinsOverHTTP() {
        let r = SystemProxy.resolve(settings: [
            "HTTPEnable": 1, "HTTPProxy": "plain.example.net", "HTTPPort": 8080,
            "HTTPSEnable": 1, "HTTPSProxy": "secure.example.net", "HTTPSPort": 8443,
        ])
        // Still an http:// URL: the client speaks plain HTTP to the proxy and tunnels HTTPS with CONNECT.
        #expect(r.url?.absoluteString == "http://secure.example.net:8443")
    }

    @Test func numbersArriveAsNSNumberOrStrings() {
        let r = SystemProxy.resolve(settings: ["HTTPSEnable": NSNumber(value: 1), "HTTPSProxy": "10.0.0.2",
                                               "HTTPSPort": NSNumber(value: 8899)])
        #expect(r.url?.absoluteString == "http://10.0.0.2:8899")
        let s = SystemProxy.resolve(settings: ["HTTPEnable": "1", "HTTPProxy": "p.example.net", "HTTPPort": "81"])
        #expect(s.url?.absoluteString == "http://p.example.net:81")
    }

    @Test func ipv6ProxyIsBracketed() {
        let r = SystemProxy.resolve(settings: ["HTTPEnable": 1, "HTTPProxy": "fd00::1", "HTTPPort": 3128])
        #expect(r.url?.absoluteString == "http://[fd00::1]:3128")
    }

    @Test func pacOnlyAndSOCKSOnlyMapToNoneWithAReason() {
        let pac = SystemProxy.resolve(settings: ["ProxyAutoConfigEnable": 1,
                                                 "ProxyAutoConfigURLString": "http://wpad.example.net/proxy.pac"])
        #expect(pac.url == nil && pac.unsupported?.contains("PAC") == true)
        let wpad = SystemProxy.resolve(settings: ["ProxyAutoDiscoveryEnable": 1])
        #expect(wpad.url == nil && wpad.unsupported?.contains("PAC") == true)
        let socks = SystemProxy.resolve(settings: ["SOCKSEnable": 1, "SOCKSProxy": "socks.example.net", "SOCKSPort": 1080])
        #expect(socks.url == nil && socks.unsupported?.contains("SOCKS") == true)
        // An HTTP(S) proxy next to a PAC file is used.
        let both = SystemProxy.resolve(settings: ["ProxyAutoConfigEnable": 1, "HTTPEnable": 1, "HTTPProxy": "p.example.net",
                                                  "HTTPPort": 3128])
        #expect(both.url?.absoluteString == "http://p.example.net:3128")
    }

    @Test func malformedEntriesAreRefused() {
        let noPort = SystemProxy.resolve(settings: ["HTTPEnable": 1, "HTTPProxy": "p.example.net"])
        #expect(noPort.url == nil && noPort.unsupported != nil)
        let badPort = SystemProxy.resolve(settings: ["HTTPEnable": 1, "HTTPProxy": "p.example.net", "HTTPPort": 70000])
        #expect(badPort.url == nil)
        let injected = SystemProxy.resolve(settings: ["HTTPEnable": 1, "HTTPProxy": "evil.test/x?y", "HTTPPort": 80])
        #expect(injected.url == nil && injected.unsupported != nil)
        let userinfo = SystemProxy.resolve(settings: ["HTTPEnable": 1, "HTTPProxy": "user@p.example.net", "HTTPPort": 80])
        #expect(userinfo.url == nil)
        let emptyHost = SystemProxy.resolve(settings: ["HTTPSEnable": 1, "HTTPSProxy": "", "HTTPSPort": 443,
                                                       "HTTPEnable": 1, "HTTPProxy": "p.example.net", "HTTPPort": 3128])
        #expect(emptyHost.url?.host == "p.example.net", "an empty HTTPS entry falls through to HTTP")
    }

    @Test func debugOverride() {
        #if DEBUG
        let o = SystemProxy.override(environment: ["SUDAMP_PROXY": "http://127.0.0.1:8899"])
        #expect(o == ProxyResolution(url: URL(string: "http://127.0.0.1:8899"), origin: .override))
        #expect(SystemProxy.current(environment: ["SUDAMP_PROXY": "http://127.0.0.1:8899"]).url?.port == 8899)
        #expect(SystemProxy.override(environment: ["SUDAMP_PROXY": "direct"]) == ProxyResolution(url: nil, origin: .override))
        #expect(SystemProxy.override(environment: ["SUDAMP_PROXY": "socks5://127.0.0.1:1080"])?.url == nil)
        #expect(SystemProxy.override(environment: ["SUDAMP_PROXY": "socks5://127.0.0.1:1080"])?.unsupported != nil)
        #expect(SystemProxy.override(environment: [:]) == nil)
        #else
        #expect(SystemProxy.override(environment: ["SUDAMP_PROXY": "http://127.0.0.1:8899"]) == nil)
        #endif
    }
}
