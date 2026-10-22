// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Playback
import SkinKit

/// One skin the Skins menu lists.
nonisolated struct SkinEntry: Equatable, Sendable {
    enum Origin: String, Sendable {
        /// sudamp Dark, generated in code (SkinKit's `SudampDark`): always there, the default and every fallback.
        case builtIn
        /// Shipped in `Contents/Resources/Skins` (AndAmp Dark and Light, CC BY 4.0).
        case bundled
        /// Added by the user: `<profile>/Skins` (Open Skin…, drag-and-drop, a `.wsz` argument, or copied there).
        case user
    }

    /// `sudamp-dark`, `andamp-dark`, `user:<file name>`: what settings.json and state.json `.skin.id` hold.
    var id: String
    var name: String
    var origin: Origin
    var url: URL?
    /// Attribution shown with the skin (DESIGN §8.3: AndAmp ships with credits).
    var credit: String?
}

/// Why a skin was refused (state.json `.lastError.kind == "skinRejected"`, PLAN M5).
nonisolated struct SkinRejection: Error, Equatable, Sendable {
    /// SkinKit's ZipError kind (`entryTooLarge`, `notASkin`, …) or `unreadable`.
    var reason: String
    var message: String
    var file: String
}

/// The skins sudamp can show (DESIGN §8.2 loading, PLAN M5 "Skins"): sudamp Dark built in, AndAmp Dark and Light
/// bundled, and the user's in `<profile>/Skins`. Loading goes through SkinKit's capped loader, so a zip bomb or a
/// stray archive is refused before anything is allocated or copied.
final class SkinLibrary {
    static let builtInID = "sudamp-dark"
    static let builtInName = "sudamp Dark"
    static let andAmpCredit = "AndAmp skin by Mattix (mattix.nl), CC BY 4.0"
    static let userPrefix = "user:"

    let bundledDirectory: URL?
    let userDirectory: URL
    private var cache: [String: Skin] = [:]

    init(bundledDirectory: URL?, userDirectory: URL) {
        self.bundledDirectory = bundledDirectory
        self.userDirectory = userDirectory
    }

    /// `Contents/Resources/Skins` in the app; in a debug build run from SwiftPM, the repository's `Fixtures/skins`.
    static func defaultBundledDirectory(bundle: Bundle = .main) -> URL? {
        if let resources = bundle.resourceURL?.appending(path: "Skins", directoryHint: .isDirectory),
           FileManager.default.fileExists(atPath: resources.path) {
            return resources
        }
        #if DEBUG
        let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/skins", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: repo.path) { return repo }
        #endif
        return nil
    }

    static var builtIn: SkinEntry {
        SkinEntry(id: builtInID, name: builtInName, origin: .builtIn, url: nil, credit: nil)
    }

    /// Built in first, then bundled, then the user's, each sorted by name.
    func entries() -> [SkinEntry] {
        var out = [Self.builtIn]
        out += scan(bundledDirectory, origin: .bundled)
        out += scan(userDirectory, origin: .user)
        return out
    }

    func entry(id: String) -> SkinEntry? { entries().first { $0.id == id } }

    private func scan(_ directory: URL?, origin: SkinEntry.Origin) -> [SkinEntry] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { ["wsz", "zip"].contains($0.pathExtension.lowercased()) }
            .compactMap { url -> SkinEntry? in
                let stem = url.deletingPathExtension().lastPathComponent
                let key = stem.lowercased()
                // sudamp Dark's .wsz is shipped too, but the built-in copy is the same pixels.
                if origin == .bundled, key == Self.builtInID { return nil }
                let id = origin == .user ? Self.userPrefix + key : key
                let credit = key.hasPrefix("andamp") ? Self.andAmpCredit : nil
                return SkinEntry(id: id, name: Self.displayName(stem), origin: origin, url: url, credit: credit)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `AndAmp-Dark` → `AndAmp Dark`.
    static func displayName(_ stem: String) -> String {
        stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }

    /// The skin for an entry (decoded once, then cached).
    func load(_ entry: SkinEntry) -> Result<Skin, SkinRejection> {
        if entry.origin == .builtIn { return .success(SudampDark.skin) }
        if let cached = cache[entry.id] { return .success(cached) }
        guard let url = entry.url else {
            return .failure(SkinRejection(reason: "unreadable", message: "no file", file: entry.name))
        }
        let result = Self.loadFile(url)
        if case .success(let skin) = result { cache[entry.id] = skin }
        return result
    }

    static func loadFile(_ url: URL) -> Result<Skin, SkinRejection> {
        let result = SkinLoader.load(url: url)
        if let skin = result.skin { return .success(skin) }
        let error = result.rejection ?? .notASkin
        return .failure(SkinRejection(reason: error.kind, message: explanation(error), file: url.lastPathComponent))
    }

    /// A skin file from outside the library (Open Skin…, a drop, a `.wsz` argument): validated first, then copied
    /// into `<profile>/Skins` so it is listed and restored next time. A copy of a bundled skin is that skin.
    func importSkin(at url: URL) -> Result<(SkinEntry, Skin), SkinRejection> {
        let skin: Skin
        switch Self.loadFile(url) {
        case .success(let loaded): skin = loaded
        case .failure(let rejection): return .failure(rejection)
        }
        let all = entries()
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if let known = all.first(where: { $0.url?.standardizedFileURL.resolvingSymlinksInPath() == resolved }) {
            cache[known.id] = skin
            return .success((known, skin))
        }
        let digest = Self.digest(url)
        if let same = all.first(where: { $0.origin == .bundled && $0.url.map(Self.digest) == digest && digest != nil }) {
            cache[same.id] = skin
            return .success((same, skin))
        }
        do {
            try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
            let stem = url.deletingPathExtension().lastPathComponent
            var target = userDirectory.appending(path: stem + ".wsz")
            if FileManager.default.fileExists(atPath: target.path) {
                if Self.digest(target) != digest {
                    target = userDirectory.appending(path: stem + "-" + String(UUID().uuidString.prefix(6)) + ".wsz")
                }
            }
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: url, to: target)
            }
            let key = target.deletingPathExtension().lastPathComponent
            let entry = SkinEntry(id: Self.userPrefix + key.lowercased(), name: Self.displayName(key), origin: .user,
                                  url: target, credit: key.lowercased().hasPrefix("andamp") ? Self.andAmpCredit : nil)
            cache[entry.id] = skin
            return .success((entry, skin))
        } catch {
            // Showing it still works; it just won't be listed next launch.
            let entry = SkinEntry(id: Self.userPrefix + url.deletingPathExtension().lastPathComponent.lowercased(),
                                  name: Self.displayName(url.deletingPathExtension().lastPathComponent), origin: .user,
                                  url: url, credit: nil)
            cache[entry.id] = skin
            return .success((entry, skin))
        }
    }

    private static func digest(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What the rejection sheet says.
    static func explanation(_ error: ZipError) -> String {
        switch error {
        case .entryTooLarge, .totalTooLarge, .archiveTooLarge, .tooManyEntries:
            "It is larger than any classic skin (\(error.description)), so sudamp refused to unpack it."
        case .notASkin:
            "It is a ZIP archive, but it holds none of the files a classic skin has."
        case .notAZip:
            "It is not a ZIP archive, so it can't be a classic .wsz skin."
        case .zip64, .unsupportedMethod, .encrypted:
            "It uses a ZIP feature classic skins never do (\(error.description))."
        case .corrupt, .sizeMismatch:
            "The archive is damaged (\(error.description))."
        }
    }

    /// state.json `.skin`.
    static func debugInfo(_ entry: SkinEntry, skin: Skin) -> AppSkinDebugInfo {
        AppSkinDebugInfo(id: entry.id, name: entry.name, origin: entry.origin.rawValue, path: entry.url?.path,
                         fallbackSheets: entry.origin == .builtIn ? [] : skin.report.fallbackSheets,
                         regions: skin.report.regionSections)
    }
}
