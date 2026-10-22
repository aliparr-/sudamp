// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import MPV

@Suite struct LoadFileOptionsTests {
    @Test func headersAreSortedAndCommasEscaped() throws {
        let o = LoadFileOptions(httpHeaders: ["User-Agent-X": "a,b", "Accept": "*/*"])
        let map = try o.optionMap()
        #expect(map["http-header-fields"] == "Accept: */*,User-Agent-X: a\\,b")
    }

    @Test func headerInjectionIsRejected() {
        #expect(throws: LoadFileOptionsError.self) {
            try LoadFileOptions(httpHeaders: ["X": "a\r\nEvil: 1"]).optionMap()
        }
        #expect(throws: LoadFileOptionsError.invalidHeaderName("Bad Name")) {
            try LoadFileOptions(httpHeaders: ["Bad Name": "v"]).optionMap()
        }
        #expect(throws: LoadFileOptionsError.self) { try LoadFileOptions(userAgent: "ua\n").optionMap() }
    }

    @Test func allPerFileOptionsMap() throws {
        let o = LoadFileOptions(userAgent: "Mozilla/5.0 (X, Y)", mediaTitle: "Deep, House", start: 12.5,
                                httpProxy: "http://127.0.0.1:8899", lavf: [LavfOption("request_size", "10485760"),
                                                                           LavfOption("reconnect", "1")])
        let map = try o.optionMap()
        #expect(map["user-agent"] == "Mozilla/5.0 (X, Y)") // plain string option: no list escaping
        #expect(map["force-media-title"] == "Deep, House")
        #expect(map["start"] == "12.5")
        #expect(map["http-proxy"] == "http://127.0.0.1:8899")
        #expect(map["stream-lavf-o"] == "request_size=10485760,reconnect=1")
    }

    @Test func lavfValuesAreRestricted() {
        #expect(throws: LoadFileOptionsError.self) { try LoadFileOptions(lavf: [LavfOption("a", "x,y=z")]).optionMap() }
        #expect(throws: LoadFileOptionsError.self) { try LoadFileOptions(lavf: [LavfOption("A-B", "1")]).optionMap() }
        #expect(throws: LoadFileOptionsError.self) { try LoadFileOptions(httpProxy: "socks5://h:1").optionMap() }
        #expect(throws: LoadFileOptionsError.self) { try LoadFileOptions(start: -1).optionMap() }
    }

    @Test func presets() throws {
        #expect(try LoadFileOptions.radio().optionMap() == ["stream-lavf-o": "reconnect_streamed=1"])
        let p = try LoadFileOptions.progressive(requestSize: 10_485_760).optionMap()
        #expect(p["stream-lavf-o"] == "request_size=10485760,short_seek_size=10485760,reconnect=1,reconnect_streamed=1,reconnect_delay_max=10")
    }

    @Test func loadfileNodeShape() throws {
        let node = try MPVClient.loadfileNode("https://x.example/s.mp3", mode: .replace,
                                              options: LoadFileOptions(start: 3))
        #expect(node["name"] == .string("loadfile"))
        #expect(node["flags"] == .string("replace"))
        #expect(node["index"] == .int(-1))
        #expect(node["options"]?["start"] == .string("3.0"))
        let bare = try MPVClient.loadfileNode("a.wav", mode: .appendPlay, options: LoadFileOptions())
        #expect(bare["options"] == nil)
        #expect(bare["flags"] == .string("append-play"))
    }
}

@Suite struct MPVOptionTests {
    @Test func defaultsCoverDesignBlock() {
        let names = Set(MPVOptions.defaults.map(\.name))
        for required in ["config", "load-scripts", "ytdl", "osc", "vid", "vo", "audio-display", "ao", "audio-samplerate",
                         "audio-channels", "audio-buffer", "gapless-audio", "volume", "volume-max", "af", "cache",
                         "demuxer-max-bytes", "demuxer-readahead-secs", "network-timeout", "idle",
                         "load-unsafe-playlists", "input-media-keys", "media-controls", "msg-level"] {
            #expect(names.contains(required), "missing \(required)")
        }
        for script in MPVOptions.builtinScriptOptions {
            #expect(MPVOptions.defaults.contains(MPVOption(script, "no")))
        }
        #expect(MPVOptions.defaults.contains(MPVOption("ao", "pcm")))
        #expect(MPVOptions.defaults.count == Set(MPVOptions.defaults.map(\.name)).count, "duplicate option")
    }

    @Test func mergeReplacesInPlaceAndAppends() {
        let merged = MPVOptions.merged([MPVOption("a", "1"), MPVOption("b", "2")],
                                       overrides: [MPVOption("b", "3"), MPVOption("c", "4")])
        #expect(merged == [MPVOption("a", "1"), MPVOption("b", "3"), MPVOption("c", "4")])
    }
}

@Suite struct MPVValueTests {
    @Test func nodeRoundTripsThroughC() {
        let node = MPVNode.map(["s": .string("é,x"), "i": .int(-7), "d": .double(0.25), "f": .flag(true),
                                "a": .array([.string("x"), .none, .map([:])])])
        let back = node.withCNode { MPVNode($0.pointee) }
        #expect(back == node)
    }

    @Test func audioParamsParseAndGuard() {
        let node = MPVNode.map(["format": .string("floatp"), "samplerate": .int(48000), "channels": .string("stereo"),
                                "channel-count": .int(2)])
        let p = AudioParams(node: node)
        #expect(p == AudioParams(format: "floatp", samplerate: 48000, channels: "stereo", channelCount: 2))
        #expect(p?.isPullAOFormat == true)
        #expect(AudioParams(format: "float", samplerate: 48000, channels: "stereo", channelCount: 2).isPullAOFormat == false)
        #expect(AudioParams(format: "floatp", samplerate: 44100, channels: "stereo", channelCount: 2).isPullAOFormat == false)
        #expect(AudioParams(node: .string("x")) == nil)
    }

    @Test func guardsReportEachFailure() {
        let good = EngineGuards(mpvVersion: "mpv v0.41.0", aoInitCount: 1, aoErrorCount: 0,
                                audioOutParams: AudioParams(format: "floatp", samplerate: 48000, channels: "stereo", channelCount: 2))
        #expect(good.ok)
        let bad = EngineGuards(mpvVersion: "mpv v0.40.0", aoInitCount: 0, aoErrorCount: 3, audioOutParams: nil)
        #expect(!bad.versionOK && !bad.firstFileOK && !bad.readsOK)
        #expect(bad.failures.count == 4)
    }

    @Test func snapshotAppliesObservedProperties() {
        var s = PlaybackSnapshot()
        s.apply(property: "pause", value: .flag(true))
        s.apply(property: "time-pos", value: .double(1.5))
        s.apply(property: "metadata", value: .map(["icy-title": .string("Artist - Song"), "N": .int(1)]))
        s.apply(property: "audio-out-params", value: .map(["format": .string("floatp"), "samplerate": .int(48000)]))
        #expect(s.pause == true && s.timePos == 1.5)
        #expect(s.icyTitle == "Artist - Song")
        #expect(s.audioOutParams?.samplerate == 48000)
    }
}

@Suite struct RampFixtureTests {
    @Test func wavIsDeterministicAndWellFormed() {
        let a = RampFixture.wavData(sampleRate: 44100, seconds: 0.5)
        let b = RampFixture.wavData(sampleRate: 44100, seconds: 0.5)
        #expect(a == b)
        #expect(a.count == 44 + 22050 * 8)
        #expect(String(decoding: a.prefix(4), as: UTF8.self) == "RIFF")
        #expect(a[20] == 3) // IEEE float
    }

    @Test func positionDecodesRamp() {
        #expect(abs(RampFixture.position(fromRight: -0.9) - 0) < 1e-6)
        #expect(abs(RampFixture.position(fromRight: 0) - 30) < 1e-4)
        #expect(abs(RampFixture.position(fromRight: 0.9) - 60) < 1e-4)
    }
}
