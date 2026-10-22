// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Catalog

@Test func clientListRule() {
    for ok in ["visionos", "visionos,tv_samsung", "web_embedded", "a,b,c"] { #expect(EngineValidation.isValidClientList(ok), "\(ok)") }
    for bad in ["", "visionos;rm -rf", "visionos, tv", "Visionos", "visionos,", ",visionos", "tv-samsung", "web\nx", "a,,b"] {
        #expect(!EngineValidation.isValidClientList(bad), "\(bad)")
    }
}

@Test func formatRule() {
    for ok in EngineConfig.defaults.formats.values.sorted() + ["bestaudio", "ba[abr>=128]/ba", "hls-192/http/bestaudio", "251/140", "b[height<=?480]+ba"] {
        #expect(EngineValidation.isValidFormat(ok), "\(ok)")
    }
    for bad in ["", "-f", "--exec=rm", "-bestaudio", "best audio", "ba;id", "ba|sh", "ba$(id)", "ba`id`", "ba&x", "ba'", "ba\"", "ba\n", "ba(x)", "ba{x}",
                String(repeating: "b", count: 257)] {
        #expect(!EngineValidation.isValidFormat(bad), "\(bad)")
    }
}

@Test func extractorArgRule() {
    for ok in ["soundcloud:formats=hls_aac", "youtube:player_client=visionos,tv_samsung", "youtube:skip=dash"] {
        #expect(EngineValidation.isValidExtractorArg(ok), "\(ok)")
    }
    for bad in ["soundcloud:formats", "youtube:player_client=visionos;x", "YouTube:a=b", "youtube:a=b c", "youtube:a=B", ":a=b", "youtube:a=", "youtube:a-b=c",
                "youtube:player_skip=webpage,configs\n--exec"] {
        #expect(!EngineValidation.isValidExtractorArg(bad), "\(bad)")
    }
}

@Test func mediaHostVersionAndHashRules() {
    for ok in ["googlevideo.com", "mixcloud.stream", "media-streaming.soundcloud.cloud"] { #expect(EngineValidation.isValidMediaHost(ok)) }
    for bad in ["com", "GoogleVideo.com", ".googlevideo.com", "googlevideo.com.", "*.googlevideo.com", "a..b", "-a.com", "a_b.com", "x.com/path"] {
        #expect(!EngineValidation.isValidMediaHost(bad), "\(bad)")
    }
    for ok in ["2026.10.21", "2026.10.21.1", "2025.01.02.123456"] { #expect(EngineValidation.isValidEngineVersion(ok)) }
    for bad in ["2026.10.2", "26.10.21", "2026.10.21.", "2026-10-21", "v2026.10.21", "2026.10.21.x", "nightly"] {
        #expect(!EngineValidation.isValidEngineVersion(bad), "\(bad)")
    }
    #expect(EngineValidation.isValidSHA256(String(repeating: "a1", count: 32)))
    for bad in [String(repeating: "A1", count: 32), String(repeating: "a", count: 63), String(repeating: "g", count: 64), ""] {
        #expect(!EngineValidation.isValidSHA256(bad))
    }
    #expect(EngineValidation.isValidAppVersion("0.1.0") && !EngineValidation.isValidAppVersion("0.1") && !EngineValidation.isValidAppVersion("0.1.0-dev"))
}

private func engine(_ json: String, previous: EngineConfig = .defaults) throws -> (EngineConfig, [EngineIssue]) {
    EngineConfig.decode(try JSONValue.parse(Data(json.utf8)), previous: previous)
}

@Test func validEngineValuesAreTaken() throws {
    let sha = String(repeating: "0f", count: 32)
    let (c, issues) = try engine("""
    {"minAppVersion":"0.2.0","pin":{"version":"2026.10.21","sha256":"\(sha)"},"block":["2026.10.01"],
     "sources":{"youtube":false,"mixcloud":true},"nightlyEscalation":false,"fastStartRank":["radio","youtube"],
     "clients":["visionos"],"formats":{"mixcloud":"hls-64/http"},"extractorArgs":{"soundcloud":"soundcloud:formats=hls_aac"},
     "mediaHosts":["googlevideo.com"],"canary":["yt:bk6Xst6euQk","sc:platform/misskittin"]}
    """)
    #expect(issues.isEmpty)
    #expect(c.minAppVersion == "0.2.0")
    #expect(c.pin == EnginePin(version: "2026.10.21", sha256: sha))
    #expect(c.block == ["2026.10.01"])
    #expect(!c.isSourceEnabled(.youtube) && !c.isSourceEnabled(.youtubeLive) && c.isSourceEnabled(.mixcloud) && c.isSourceEnabled(.radio))
    #expect(c.nightlyEscalation == false)
    #expect(c.fastStartPosition(of: .radio) == 0 && c.fastStartPosition(of: .youtubeLive) == 1 && c.fastStartPosition(of: .mixcloud) == 2)
    #expect(c.clients == ["visionos"])
    #expect(c.format(for: .mixcloud) == "hls-64/http")
    #expect(c.format(for: .youtube) == EngineConfig.defaults.format(for: .youtube))
    #expect(c.extractorArgs[.soundcloud] == ["soundcloud:formats=hls_aac"])
    #expect(c.canary.map(\.rawValue) == ["yt:bk6Xst6euQk", "sc:platform/misskittin"])
}

@Test func failingEngineValuesKeepTheirPreviousValues() throws {
    var previous = EngineConfig.defaults
    previous.clients = ["visionos,tv_samsung"]
    previous.pin = EnginePin(version: "2026.09.01", sha256: String(repeating: "ab", count: 32))
    let (c, issues) = try engine("""
    {"minAppVersion":"latest","pin":{"version":"2026.10.21","sha256":"XYZ"},"block":["2026.10.01","rm -rf /"],
     "sources":{"youtube":"no","vimeo":true},"nightlyEscalation":1,"fastStartRank":["radio","radio"],
     "clients":["visionos","tv;curl evil"],"formats":{"youtube":"-o /tmp/x","soundcloud":"hls_aac_160k","radio":"x"},
     "extractorArgs":{"youtube":["youtube:player_client=web;x"]},"mediaHosts":["evil.com/","googlevideo.com"],
     "canary":["yt:bk6Xst6euQk","radio:x"]}
    """, previous: previous)
    #expect(c.minAppVersion == nil)
    #expect(c.pin == previous.pin)
    #expect(c.block == [])
    #expect(c.isSourceEnabled(.youtube))
    #expect(c.nightlyEscalation == true)
    #expect(c.fastStartRank == previous.fastStartRank)
    #expect(c.clients == ["visionos,tv_samsung"])
    #expect(c.format(for: .youtube) == previous.format(for: .youtube))
    #expect(c.format(for: .soundcloud) == "hls_aac_160k")          // map fields are judged per key
    #expect(c.extractorArgs == previous.extractorArgs)
    #expect(c.mediaHosts == previous.mediaHosts)
    #expect(c.canary == [])
    let fields = Set(issues.map(\.field))
    #expect(fields == ["minAppVersion", "pin", "block", "sources.youtube", "sources.vimeo", "nightlyEscalation", "fastStartRank",
                       "clients", "formats.youtube", "formats.radio", "extractorArgs.youtube", "mediaHosts", "canary"])
}

@Test func absentEngineKeepsPreviousAndNullPinClears() throws {
    var previous = EngineConfig.defaults
    previous.pin = EnginePin(version: "2026.09.01", sha256: String(repeating: "ab", count: 32))
    #expect(EngineConfig.decode(nil, previous: previous).0 == previous)
    let (c, issues) = try engine(#"{"pin":null}"#, previous: previous)
    #expect(c.pin == nil && issues.isEmpty)
    #expect(try engine("[]").1.count == 1)
}
