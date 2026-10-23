// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CryptoKit
import Foundation
import SkinKit
@testable import SkinUI

/// Paths inside the repository, located from this file so tests run from any working directory.
enum Repo {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func url(_ relative: String) -> URL { root.appending(path: relative) }

    static func data(_ relative: String) throws -> Data { try Data(contentsOf: url(relative)) }

    static func fixtureState(_ name: String) throws -> WindowState {
        try JSONDecoder().decode(WindowState.self, from: data("Fixtures/states/\(name).json"))
    }

    static func golden(_ skin: String, _ state: String) throws -> String? {
        let goldens = try JSONDecoder().decode([String: [String: String]].self, from: data("Fixtures/states/goldens.json"))
        return goldens[skin]?[state]
    }
}

/// A temporary directory removed when the guard goes away.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "skinui-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

@MainActor enum TestApp {
    /// Windows need the shared application object; nothing is ever ordered on screen by the tests.
    static func prepare() {
        _ = NSApplication.shared
    }
}

/// One 1440x900 display with a 25-point menu bar, in top-left space.
let testScreen = DockScreen(frame: IntRect(0, -900, 1440, 900), visible: IntRect(0, -875, 1440, 875))

/// Screens a test can change after the manager exists (a display change).
@MainActor final class ScreenBox {
    var screens: [DockScreen]
    init(_ screens: [DockScreen]) { self.screens = screens }
}

/// A headless WindowManager: windows are real but never ordered on screen; screens are injected.
@MainActor func makeManager(scale: Double? = 1, open: Set<SkinWindowRole> = [.main, .equalizer, .playlist],
                            layoutURL: URL? = nil, screens: ScreenBox = ScreenBox([testScreen]),
                            skin: Skin = SudampDark.skin) -> WindowManager {
    TestApp.prepare()
    var configuration = WindowManager.Configuration()
    configuration.scale = scale
    configuration.initialOpen = open
    configuration.layoutURL = layoutURL
    configuration.ordersWindows = false
    configuration.screens = { screens.screens }
    return WindowManager(skin: skin, configuration: configuration)
}

/// A frame in top-left space from AppKit coordinates (tests keep upstream numbers recognisable).
func tl(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> IntRect {
    DockingGeometry.topLeft(CGRect(x: x, y: y, width: w, height: h))
}

/// The exact RGBA8 bytes behind a CGImage that SkinUI made from a Bitmap (no redraw, no colour conversion).
func rawRGBA(_ image: CGImage) -> [UInt8]? {
    guard image.bitsPerPixel == 32, image.bytesPerRow == image.width * 4,
          let data = image.dataProvider?.data as Data? else { return nil }
    return [UInt8](data)
}

func sha256(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

/// The centre of a control's hit rect in fractional skin pixels.
func centre(_ control: Control, in kind: WindowKind) -> CGPoint {
    let r = Layout.rect(of: control, in: kind)!
    return CGPoint(x: Double(r.x) + Double(r.width) / 2, y: Double(r.y) + Double(r.height) / 2)
}

/// A pointer at a skin point, with the screen point at `scale` points per skin pixel from a window at the origin.
func pointer(_ skin: CGPoint, scale: Double = 2, clickCount: Int = 1) -> SkinPointer {
    SkinPointer(skin: skin, screen: CGPoint(x: skin.x * scale, y: -skin.y * scale), clickCount: clickCount)
}

func events(_ outputs: [SkinInteractionOutput]) -> [SkinControlEvent] {
    outputs.compactMap { if case .event(let e) = $0 { return e } else { return nil } }
}
