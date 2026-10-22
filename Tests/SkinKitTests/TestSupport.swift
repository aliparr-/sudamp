// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import SkinKit

/// Paths inside the repository, located from this file so tests run from any working directory.
enum Repo {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func url(_ relative: String) -> URL { root.appending(path: relative) }

    static func data(_ relative: String) throws -> Data { try Data(contentsOf: url(relative)) }

    static func text(_ relative: String) throws -> String {
        let data = try data(relative)
        return String(decoding: data, as: UTF8.self)
    }
}

/// A small solid-colour BMP, written with sudamp's own encoder.
func solidBMP(width: Int, height: Int, _ color: RGBA) -> Data {
    BMPWriter.encode(Bitmap(width: width, height: height, fill: color))
}

/// A temporary directory removed when the returned guard goes away.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "skinkit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
