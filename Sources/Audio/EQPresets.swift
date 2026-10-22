// SPDX-License-Identifier: GPL-3.0-or-later
// EQ presets and the Winamp `.eqf` codec (DESIGN §5.4). Pure: no AVFoundation.
//
// Ported from hfyeomans/MacAmp @ cb0c77f `MacAmpApp/Models/EQPreset.swift` (the 17 built-in presets, as Winamp
// slider values) and `MacAmpApp/Models/EQF.swift` (the `.eqf` layout: header, Ctrl-Z "!--", 257-byte names, 11
// inverted value bytes). Changes: one dB mapping shared by presets and the codec (MacAmp used two that disagree by
// up to 0.19 dB), with value 33 exactly 0 dB and 1/64 exactly -12/+12 dB; multi-entry library files; Windows-1252
// names; typed errors.
//
// MacAmp notice:
//
// MIT License
//
// Copyright (c) 2025-2026 Hank Yeomans
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
import Foundation

/// A named preamp + 10-band setting.
public struct EQPreset: Sendable, Equatable, Hashable, Codable {
    public var name: String
    /// dB, ±12.
    public var preamp: Float
    /// 10 band gains in dB, ±12.
    public var bands: [Float]

    public init(name: String, preamp: Float, bands: [Float]) {
        self.name = name
        self.preamp = EQSettings.clamp(preamp)
        self.bands = EQSettings.normalize(bands)
    }

    /// From Winamp slider values (1...64, 33 = 0 dB; `EQF.decibels(forValue:)`), preamp first as in MacAmp's table.
    public init(name: String, winampValues values: [Int]) {
        self.init(name: name, preamp: EQF.decibels(forValue: values.first ?? EQF.zeroValue),
                  bands: values.dropFirst().map(EQF.decibels(forValue:)))
    }

    /// These gains with the EQ switched on (or as given).
    public func settings(enabled: Bool = true) -> EQSettings {
        EQSettings(enabled: enabled, preamp: preamp, bands: bands)
    }

    public init(name: String, settings: EQSettings) {
        self.init(name: name, preamp: settings.preamp, bands: settings.bands)
    }
}

public enum EQPresets {
    /// Every band and the preamp at 0 dB.
    public static let flat = EQPreset(name: "Flat", preamp: 0, bands: [])

    /// MacAmp's 17 built-in presets (Winamp's defaults minus Flat), values preamp-first in Winamp slider units.
    public static let builtIn: [EQPreset] = [
        EQPreset(name: "Classical", winampValues: [33, 33, 33, 33, 33, 33, 33, 20, 20, 20, 16]),
        EQPreset(name: "Club", winampValues: [33, 33, 33, 38, 42, 42, 42, 38, 33, 33, 33]),
        EQPreset(name: "Dance", winampValues: [33, 48, 44, 36, 32, 32, 22, 20, 20, 32, 32]),
        EQPreset(name: "Laptop speakers/headphones", winampValues: [33, 40, 50, 41, 26, 28, 35, 40, 48, 53, 56]),
        EQPreset(name: "Large hall", winampValues: [33, 49, 49, 42, 42, 33, 24, 24, 24, 33, 33]),
        EQPreset(name: "Party", winampValues: [33, 44, 44, 33, 33, 33, 33, 33, 33, 44, 44]),
        EQPreset(name: "Pop", winampValues: [33, 29, 40, 44, 45, 41, 30, 28, 28, 29, 29]),
        EQPreset(name: "Reggae", winampValues: [33, 33, 33, 31, 22, 33, 43, 43, 33, 33, 33]),
        EQPreset(name: "Rock", winampValues: [33, 45, 40, 23, 19, 26, 39, 47, 50, 50, 50]),
        EQPreset(name: "Soft", winampValues: [33, 40, 35, 30, 28, 30, 39, 46, 48, 50, 52]),
        EQPreset(name: "Ska", winampValues: [33, 28, 24, 25, 31, 39, 42, 47, 48, 50, 48]),
        EQPreset(name: "Full Bass", winampValues: [33, 48, 48, 48, 42, 35, 25, 18, 15, 14, 14]),
        EQPreset(name: "Soft Rock", winampValues: [33, 39, 39, 36, 31, 25, 23, 26, 31, 37, 47]),
        EQPreset(name: "Full Treble", winampValues: [33, 16, 16, 16, 25, 37, 50, 58, 58, 58, 60]),
        EQPreset(name: "Full Bass & Treble", winampValues: [33, 44, 42, 33, 20, 24, 35, 46, 50, 52, 52]),
        EQPreset(name: "Live", winampValues: [33, 24, 33, 39, 41, 42, 42, 39, 37, 37, 36]),
        EQPreset(name: "Techno", winampValues: [33, 45, 42, 33, 23, 24, 33, 45, 48, 48, 47]),
    ]

    /// Case-insensitive lookup among `flat` and `builtIn`.
    public static func named(_ name: String) -> EQPreset? {
        ([flat] + builtIn).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Winamp's `.eqf` / `winamp.q1` EQ library format: the ASCII header "Winamp EQ library file v1.1", the bytes
/// Ctrl-Z "!--", then one or more entries of a 257-byte NUL-padded name and 11 value bytes (60 Hz … 16 kHz, then
/// preamp). Each byte stores `64 - value` for a slider value 1...64 (byte 0 is the top of the slider).
public enum EQF {
    public static let header = "Winamp EQ library file v1.1"
    static let marker: [UInt8] = [0x1A, 0x21, 0x2D, 0x2D] // Ctrl-Z "!--"
    public static let nameFieldLength = 257
    static let valueCount = 11
    static let entryLength = nameFieldLength + valueCount
    static let headerLength = header.utf8.count + marker.count

    public enum DecodeError: Error, Sendable, Equatable {
        /// Not a Winamp EQ library file.
        case badHeader
        /// The header is fine but no complete entry follows.
        case noPresets
    }

    /// Slider value for 0 dB.
    public static let zeroValue = 33
    public static let valueRange = 1...64

    /// Slider value 1...64 → dB: 33 is 0 dB, 64 is +12 dB (31 steps up), 1 is -12 dB (32 steps down).
    public static func decibels(forValue value: Int) -> Float {
        let v = min(max(value, valueRange.lowerBound), valueRange.upperBound)
        if v >= zeroValue { return Float(v - zeroValue) * 12 / 31 }
        return -Float(zeroValue - v) * 12 / 32
    }

    /// dB → the nearest slider value (the inverse of `decibels(forValue:)` on its grid).
    public static func value(forDecibels decibels: Float) -> Int {
        let db = EQSettings.clamp(decibels)
        let v = db >= 0 ? zeroValue + Int((db * 31 / 12).rounded()) : zeroValue - Int((-db * 32 / 12).rounded())
        return min(max(v, valueRange.lowerBound), valueRange.upperBound)
    }

    /// Every complete entry. Trailing bytes shorter than one entry are ignored; stored bytes above 63 read as -12 dB.
    public static func decode(_ data: Data) throws(DecodeError) -> [EQPreset] {
        let bytes = [UInt8](data)
        guard bytes.count >= headerLength, Array(bytes[0..<header.utf8.count]) == Array(header.utf8),
              Array(bytes[header.utf8.count..<headerLength]) == marker else { throw .badHeader }
        var presets: [EQPreset] = []
        var i = headerLength
        while i + entryLength <= bytes.count {
            let field = bytes[i..<(i + nameFieldLength)]
            let nameBytes = field.prefix { $0 != 0 }
            let name = String(bytes: nameBytes, encoding: .windowsCP1252)
                ?? String(decoding: nameBytes, as: UTF8.self)
            i += nameFieldLength
            let values = bytes[i..<(i + valueCount)].map { 64 - min(Int($0), 63) }
            i += valueCount
            presets.append(EQPreset(name: name, preamp: decibels(forValue: values[10]),
                                    bands: values.prefix(10).map(decibels(forValue:))))
        }
        guard !presets.isEmpty else { throw .noPresets }
        return presets
    }

    /// A library file holding `presets` in order (gains rounded to the nearest slider value). Names are written as
    /// Windows-1252 (unrepresentable characters become "?"), truncated to 256 bytes so a NUL always follows.
    public static func encode(_ presets: [EQPreset]) -> Data {
        var out = [UInt8](header.utf8) + marker
        for preset in presets {
            let raw = preset.name.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data()
            var name = [UInt8](raw.prefix(nameFieldLength - 1))
            name += [UInt8](repeating: 0, count: nameFieldLength - name.count)
            out += name
            for db in preset.bands + [preset.preamp] { out.append(UInt8(64 - value(forDecibels: db))) }
        }
        return Data(out)
    }

    public static func encode(_ preset: EQPreset) -> Data { encode([preset]) }
}
