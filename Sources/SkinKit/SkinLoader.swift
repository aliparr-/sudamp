// SPDX-License-Identifier: GPL-3.0-or-later
// Loads a .wsz into a `Skin`: ZIP caps, whitelist, sheet decoding, text files, per-sheet fallback, and a report
// of what came from where (sudamp-dev skin-load prints it; the app logs it).

import Foundation

public struct SkinLoadReport: Codable, Sendable, Equatable {
    public struct Sheet: Codable, Sendable, Equatable {
        public var name: String
        public var origin: SkinOrigin
        /// Archive path of the skin's file, when it had one (even if it failed to decode).
        public var path: String?
        public var width: Int?
        public var height: Int?
        /// Why the skin's own file was not used.
        public var error: String?
    }

    public struct Problem: Codable, Sendable, Equatable {
        public var path: String
        public var kind: String
        public var message: String
    }

    public var name: String
    public var archiveBytes: Int
    public var entryCount: Int
    public var ignoredEntries: Int
    public var sheets: [Sheet]
    public var viscolor: SkinOrigin
    public var pledit: SkinOrigin
    /// region.txt sections with at least one polygon.
    public var regionSections: [String]
    public var cursors: [String]
    public var problems: [Problem]
    public var digitSet: Skin.DigitSet
    public var limits: Limits
    public var loadMillis: Double

    public struct Limits: Codable, Sendable, Equatable {
        public var maxEntryBytes: Int
        public var maxTotalBytes: Int
        public var maxEntries: Int
        public var maxArchiveBytes: Int
    }

    /// Sheets whose pixels come from the fallback skin.
    public var fallbackSheets: [String] { sheets.filter { $0.origin == .fallback }.map(\.name) }
}

public struct SkinLoadResult: Sendable {
    public let skin: Skin?
    /// Set when the archive as a whole was refused (not a zip, caps exceeded); `skin` is then nil.
    public let rejection: ZipError?
}

public enum SkinLoader {
    /// Sheets a complete skin provides, in report order (genex is optional and only reported when present).
    public static let reportedSheets: [String] = SpriteSheet.allCases.map(\.fileBase)

    /// Loads `data` (a .wsz) on top of `fallback` (normally `SudampDark.skin`).
    /// The fallback is only built once the archive has passed the caps, so a rejected bomb costs nothing extra.
    public static func load(data: Data, name: String = "skin", fallback: @autoclosure () -> Skin? = SudampDark.skin,
                            limits: ZipLimits = .skin) -> SkinLoadResult {
        let started = Date()
        do {
            let zip = try ZipArchive(data: data, limits: limits)
            let archive = try SkinArchive(zip)
            // A zip with nothing a skin uses (or only entries that failed to extract) is not a skin; refusing it
            // keeps a stray archive from silently "loading" as the fallback skin.
            guard !archive.images.isEmpty || !archive.texts.isEmpty else {
                return SkinLoadResult(skin: nil, rejection: .notASkin)
            }
            let skin = build(archive, name: name, archiveBytes: data.count, fallback: fallback(), limits: limits, started: started)
            return SkinLoadResult(skin: skin, rejection: nil)
        } catch let error as ZipError {
            return SkinLoadResult(skin: nil, rejection: error)
        } catch {
            return SkinLoadResult(skin: nil, rejection: .corrupt("\(error)"))
        }
    }

    public static func load(url: URL, fallback: @autoclosure () -> Skin? = SudampDark.skin, limits: ZipLimits = .skin) -> SkinLoadResult {
        let name = url.deletingPathExtension().lastPathComponent
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= limits.maxArchiveBytes else {
                return SkinLoadResult(skin: nil, rejection: .archiveTooLarge(bytes: size))
            }
            return load(data: try Data(contentsOf: url, options: .mappedIfSafe), name: name, fallback: fallback(), limits: limits)
        } catch {
            return SkinLoadResult(skin: nil, rejection: .corrupt("unreadable file: \(error.localizedDescription)"))
        }
    }

    /// Builds a skin from files already selected (used for the generated sudamp Dark, before zipping).
    static func build(_ archive: SkinArchive, name: String, archiveBytes: Int, fallback: Skin?,
                      limits: ZipLimits = .skin, started: Date = Date()) -> Skin {
        var problems = archive.entryErrors.map {
            SkinLoadReport.Problem(path: $0.path, kind: $0.error.kind, message: $0.error.description)
        }
        var sheets: [String: Bitmap] = [:]
        var sheetErrors: [String: String] = [:]
        for (base, file) in archive.images.sorted(by: { $0.key < $1.key }) {
            do {
                sheets[base] = try SheetDecoder.decode(file.data)
            } catch {
                sheetErrors[base] = "\(error)"
                problems.append(.init(path: file.path, kind: "undecodable", message: "\(error)"))
            }
        }
        for failed in archive.entryErrors {
            let base = failed.path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map { String($0).lowercased() } ?? ""
            let stem = base.split(separator: ".").first.map(String.init) ?? base
            if sheetErrors[stem] == nil, SkinArchive.imageNames.contains(stem) { sheetErrors[stem] = failed.error.description }
        }

        let fallbackSheets = fallback.map { $0.sheets.merging($0.fallbackSheets) { own, _ in own } } ?? [:]
        let defaults = fallback?.viscolors ?? SudampDarkTheme.palette.viscolors
        let viscolorFile = archive.texts[.viscolor]
        let viscolors = viscolorFile.map { ViscolorParser.parse(SkinTextDecoding.decode($0.data), defaults: defaults) } ?? defaults
        let styleDefaults = fallback?.playlistStyle ?? SudampDarkTheme.palette.playlistStyle
        let pleditFile = archive.texts[.pledit]
        let style = pleditFile.map { PleditParser.parse(SkinTextDecoding.decode($0.data), defaults: styleDefaults) } ?? styleDefaults
        let regions = archive.texts[.region].map { RegionParser.parse(SkinTextDecoding.decode($0.data)) } ?? [:]

        var names = reportedSheets
        if archive.images["genex"] != nil || sheetErrors["genex"] != nil { names.append("genex") }
        let sheetReports = names.map { base -> SkinLoadReport.Sheet in
            if let own = sheets[base] {
                return .init(name: base, origin: .skin, path: archive.images[base]?.path, width: own.width, height: own.height)
            }
            let fb = fallbackSheets[base]
            return .init(name: base, origin: fb == nil ? .missing : .fallback, path: archive.images[base]?.path,
                         width: fb?.width, height: fb?.height, error: sheetErrors[base])
        }

        var report = SkinLoadReport(
            name: name, archiveBytes: archiveBytes, entryCount: archive.entryCount, ignoredEntries: archive.ignoredCount,
            sheets: sheetReports,
            viscolor: viscolorFile != nil ? .skin : (fallback != nil ? .fallback : .missing),
            pledit: pleditFile != nil ? .skin : (fallback != nil ? .fallback : .missing),
            regionSections: regions.keys.sorted(), cursors: archive.cursors.keys.sorted(), problems: problems,
            digitSet: .numsEx,
            limits: .init(maxEntryBytes: limits.maxEntryBytes, maxTotalBytes: limits.maxTotalBytes,
                          maxEntries: limits.maxEntries, maxArchiveBytes: limits.maxArchiveBytes),
            loadMillis: 0)
        var skin = Skin(name: name, sheets: sheets, fallbackSheets: fallbackSheets, viscolors: viscolors,
                        playlistStyle: style, regions: regions, report: report)
        report.digitSet = skin.digitSet
        report.loadMillis = (Date().timeIntervalSince(started) * 1000 * 10).rounded() / 10
        skin = Skin(name: name, sheets: sheets, fallbackSheets: fallbackSheets, viscolors: viscolors,
                    playlistStyle: style, regions: regions, report: report)
        return skin
    }
}
