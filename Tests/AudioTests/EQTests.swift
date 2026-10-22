// SPDX-License-Identifier: GPL-3.0-or-later
// EQ model, presets, the .eqf codec and the offline-rendered EQ (DESIGN §5.4, §9; PLAN M3). The codec cases
// extend hfyeomans/MacAmp @ cb0c77f `Tests/MacAmpTests/EQCodecTests.swift` (MIT © 2025-2026 Hank Yeomans; notice
// in Sources/Audio/EQPresets.swift): short data rejected, out-of-range stored values clamped, presets clamped.
import Foundation
import Testing
@testable import Audio

@Suite struct EQSettingsTests {
    @Test func clampsAndNormalisesBandCount() {
        let s = EQSettings(enabled: false, preamp: 40, bands: [-20, 3, .nan] + Array(repeating: 1, count: 12))
        #expect(s.preamp == 12 && !s.enabled)
        #expect(s.bands.count == 10)
        #expect(s.bands[0] == -12 && s.bands[1] == 3 && s.bands[2] == 0 && s.bands[9] == 1)
        #expect(EQSettings(bands: [1]).bands == [1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(EQSettings.flat.isFlat && EQSettings.flat.enabled)
    }

    @Test func decodesLeniently() throws {
        let json = #"{"preamp": 99, "bands": [1, 2]}"#
        let s = try JSONDecoder().decode(EQSettings.self, from: Data(json.utf8))
        #expect(s.enabled && s.preamp == 12 && s.bands == [1, 2, 0, 0, 0, 0, 0, 0, 0, 0])
        let back = try JSONDecoder().decode(EQSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}

@Suite struct EQPresetTests {
    @Test func seventeenBuiltInsWithUniqueNamesInRange() {
        #expect(EQPresets.builtIn.count == 17)
        #expect(Set(EQPresets.builtIn.map(\.name)).count == 17)
        for p in EQPresets.builtIn {
            #expect(p.bands.count == 10)
            #expect((p.bands + [p.preamp]).allSatisfy { (-12...12).contains($0) })
        }
        #expect(EQPresets.flat.bands == [Float](repeating: 0, count: 10) && EQPresets.flat.preamp == 0)
        #expect(EQPresets.named("rock")?.name == "Rock")
        #expect(EQPresets.named("FLAT") == EQPresets.flat)
        #expect(EQPresets.named("nope") == nil)
    }

    @Test func winampValuesMapToDecibels() throws {
        // Classical: preamp 33 (0 dB), bands 33×6 then 20, 20, 20, 16.
        let classical = try #require(EQPresets.named("Classical"))
        #expect(classical.preamp == 0)
        #expect(classical.bands.prefix(6).allSatisfy { $0 == 0 })
        #expect(abs(classical.bands[6] - (-13 * 12 / 32)) < 1e-6)
        #expect(abs(classical.bands[9] - (-17 * 12 / 32)) < 1e-6)
        let treble = try #require(EQPresets.named("Full Treble"))
        #expect(abs(treble.bands[9] - Float(27) * 12 / 31) < 1e-6) // value 60
    }

    @Test func presetClampsLikeMacAmp() {
        let p = EQPreset(name: "Test", preamp: 20, bands: Array(repeating: -20, count: 12))
        #expect(p.preamp == 12 && p.bands.count == 10 && p.bands.allSatisfy { $0 == -12 })
    }

    @Test func settingsRoundTrip() {
        let rock = EQPresets.builtIn[8]
        #expect(EQPreset(name: rock.name, settings: rock.settings()) == rock)
        #expect(!rock.settings(enabled: false).enabled)
    }
}

@Suite struct EQFCodecTests {
    @Test func valueGridHasExactAnchorsAndInverts() {
        #expect(EQF.decibels(forValue: 33) == 0)
        #expect(EQF.decibels(forValue: 64) == 12)
        #expect(EQF.decibels(forValue: 1) == -12)
        #expect(EQF.decibels(forValue: 0) == -12 && EQF.decibels(forValue: 99) == 12) // clamped
        for v in EQF.valueRange { #expect(EQF.value(forDecibels: EQF.decibels(forValue: v)) == v) }
        #expect(EQF.value(forDecibels: 0.1) == 33)
        #expect(EQF.value(forDecibels: 50) == 64 && EQF.value(forDecibels: -50) == 1)
    }

    @Test func builtInPresetsRoundTripExactly() throws {
        let data = EQF.encode(EQPresets.builtIn)
        #expect(data.count == 31 + 17 * 268)
        let decoded = try EQF.decode(data)
        #expect(decoded == EQPresets.builtIn) // names, preamp and every band gain equal
    }

    @Test func arbitraryGainsRoundTripWithinHalfAStep() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let preset = EQPreset(name: "r", preamp: .random(in: -12...12, using: &rng),
                                  bands: (0..<10).map { _ in .random(in: -12...12, using: &rng) })
            let back = try #require(try EQF.decode(EQF.encode(preset)).first)
            for (a, b) in zip(preset.bands + [preset.preamp], back.bands + [back.preamp]) {
                #expect(abs(a - b) <= 12.0 / 31 / 2 + 1e-5)
            }
            // A second trip is exact: the first one landed on the grid.
            #expect(try EQF.decode(EQF.encode(back)).first == back)
        }
    }

    @Test func handBuiltFileDecodes() throws {
        var bytes = [UInt8]("Winamp EQ library file v1.1".utf8) + [0x1A] + [UInt8]("!--".utf8)
        var name = [UInt8]("Entry1".utf8)
        name += [UInt8](repeating: 0, count: 257 - name.count)
        bytes += name
        bytes += [0, 31, 63, 31, 31, 31, 31, 31, 31, 31] // 60 Hz top, 310 Hz bottom
        bytes += [31] // preamp
        let presets = try EQF.decode(Data(bytes))
        #expect(presets.count == 1)
        #expect(presets[0].name == "Entry1")
        #expect(presets[0].bands[0] == 12 && presets[0].bands[1] == 0 && presets[0].bands[2] == -12)
        #expect(presets[0].preamp == 0)
    }

    @Test func rejectsShortOrForeignDataAndClampsBytes() throws {
        #expect(throws: EQF.DecodeError.badHeader) { try EQF.decode(Data()) }
        #expect(throws: EQF.DecodeError.badHeader) { try EQF.decode(Data("Winamp EQ library file v1.0\u{1A}!--".utf8)) }
        let header = Data("Winamp EQ library file v1.1".utf8) + Data([0x1A, 0x21, 0x2D, 0x2D])
        #expect(throws: EQF.DecodeError.noPresets) { try EQF.decode(header) }
        #expect(throws: EQF.DecodeError.noPresets) { try EQF.decode(header + Data(count: 267)) }
        // Out-of-range stored bytes (MacAmp's case) read as the bottom of the slider.
        var entry = Data(count: 257)
        entry.append(contentsOf: [UInt8](repeating: 255, count: 11))
        let clamped = try EQF.decode(header + entry)
        #expect(clamped[0].bands.allSatisfy { $0 == -12 } && clamped[0].preamp == -12)
        // A trailing partial entry is ignored.
        #expect(try EQF.decode(header + entry + Data(count: 100)).count == 1)
    }

    @Test func namesAreWindows1252AndTruncated() throws {
        let accented = EQPreset(name: "Café Électro", preamp: 0, bands: [])
        #expect(try EQF.decode(EQF.encode(accented)).first?.name == "Café Électro")
        let long = EQPreset(name: String(repeating: "x", count: 400), preamp: 0, bands: [])
        let data = EQF.encode(long)
        #expect(data.count == 31 + 268)
        #expect(data[31 + 256] == 0) // always NUL-terminated
        #expect(try EQF.decode(data).first?.name.count == 256)
        #expect(try EQF.decode(EQF.encode(EQPreset(name: "雪", preamp: 0, bands: []))).first?.name == "?")
    }
}

@Suite struct EQResponseTests {
    @Test func singleBandPeaksAtItsCentre() {
        for (i, f) in EQResponse.frequencies.enumerated() {
            var bands = [Float](repeating: 0, count: 10)
            bands[i] = 12
            #expect(abs(EQResponse.gainDB(at: f, bands: bands) - 12) < 1e-9)
            #expect(abs(EQResponse.peakGainDB(bands: bands) - 12) < 1e-6)
        }
    }

    @Test func matchesValuesMeasuredFromAVAudioUnitEQ() {
        // Measured offline on macOS 27 (docs/spikes/M3-audio.md): the 16 kHz band at +12 dB is prewarped.
        var bands = [Float](repeating: 0, count: 10)
        bands[9] = 12
        #expect(abs(EQResponse.gainDB(at: 8000, bands: bands) - 4.228) < 0.002)
        #expect(abs(EQResponse.gainDB(at: 11_314, bands: bands) - 7.619) < 0.002)
        bands = [Float](repeating: 0, count: 10)
        bands[4] = 12
        #expect(abs(EQResponse.gainDB(at: 707, bands: bands) - 6.002) < 0.002)
    }

    @Test func overlappingBandsAddAndCutsStayBelowZero() {
        let top = EQResponse.peakGainDB(bands: [0, 0, 0, 0, 0, 0, 0, 12, 12, 12])
        #expect(top > 25 && top < 36)
        #expect(EQResponse.peakGainDB(bands: [Float](repeating: -6, count: 10)) < 0)
        #expect(EQResponse.peakGainDB(bands: [Float](repeating: 0, count: 10)) == 0)
    }

    @Test func headroomCapLowersOnlyThePreamp() {
        let one = EQSettings(bands: [0, 0, 0, 0, 12, 0, 0, 0, 0, 0])
        #expect(abs(EQHeadroom.default.appliedPreamp(for: one) - (-6)) < 1e-4)
        #expect(EQHeadroom.off.appliedPreamp(for: one) == 0)
        #expect(EQHeadroom.default.appliedPreamp(for: EQSettings(preamp: 6)) == 6)
        #expect(EQHeadroom.default.appliedPreamp(for: EQSettings(preamp: 12)) == 6)
        #expect(EQHeadroom.default.appliedPreamp(for: EQSettings(preamp: -12)) == -12)
        let rock = EQPresets.named("Rock")!.settings()
        let applied = EQHeadroom.default.appliedPreamp(for: rock)
        #expect(Double(applied) + EQResponse.peakGainDB(bands: rock.bands) <= 6 + 1e-4)
    }
}

@Suite struct OfflineEQTests {
    /// PLAN M3 / DESIGN §9: the eq-selftest gates on the real graph rendered offline (no device).
    @Test func offlineGatesPass() async throws {
        let report = try await offPool { try EQMeasurement.offlineGates() }
        #expect(report.mode == "offline")
        #expect(report.gates.count == 22)
        for check in report.gates + report.extra {
            #expect(check.pass, "\(check.name): \(check.measured) (expected \(check.expected) ± \(check.tolerance))")
        }
    }

    @Test func engineEQStateAndCap() throws {
        let engine = try AudioEngine(volume: 0, renderingMode: .offline(maximumFrameCount: 1024))
        #expect(engine.eqHeadroom == .default && engine.eqSettings == .flat)
        engine.setEQEnabled(false)
        engine.apply(preset: EQPresets.named("Full Bass")!)
        #expect(!engine.eqSettings.enabled) // a preset doesn't switch the EQ on
        #expect(engine.eqBandGains == EQPresets.named("Full Bass")!.bands)
        #expect(engine.eq.bypass)
        engine.apply(EQSettings(preamp: 3, bands: [0, 0, 0, 0, 12, 0, 0, 0, 0, 0]))
        #expect(abs(engine.appliedPreamp - (-6)) < 1e-4 && engine.eqSettings.preamp == 3)
        engine.setEQHeadroom(.off)
        #expect(engine.appliedPreamp == 3)
        engine.setEQBand(99, gain: 5) // ignored
        engine.setEQBand(0, gain: 5)
        #expect(engine.eq.bands[0].gain == 5 && engine.eqBandGains[0] == 5)
    }
}
