// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S1: event pumping, JSON output, permission checks and own-window capture.
import AppKit
import ApplicationServices
import Darwin

/// Runs the AppKit event loop for `seconds` without `NSApp.run()`, so WindowServer and Core Animation
/// catch up (windows ordered in, layers committed, shadows computed) before we measure.
func pump(_ seconds: TimeInterval) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        if let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
    print(String(decoding: data, as: UTF8.self))
}

/// Permission state, read with the non-prompting preflight calls only.
struct Permissions: Codable {
    let accessibility: Bool  // AXIsProcessTrusted(): needed to post synthetic CGEvents
    let postEvents: Bool  // CGPreflightPostEventAccess()
    let screenCapture: Bool  // CGPreflightScreenCaptureAccess()

    static func current() -> Permissions {
        Permissions(
            accessibility: AXIsProcessTrusted(),
            postEvents: CGPreflightPostEventAccess(),
            screenCapture: CGPreflightScreenCaptureAccess()
        )
    }
}

/// Cocoa screen rect → CoreGraphics global rect (origin top-left of the main display, y down).
func cgGlobalRect(_ r: NSRect) -> CGRect {
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
}

func cgGlobalPoint(_ p: NSPoint) -> CGPoint {
    CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
}

/// Whose window `number` is, and its layer. Deliberately no app names: reports are committed, and
/// which apps the owner has open is none of the report's business.
func windowOwner(_ number: Int) -> String {
    guard number > 0,
          let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
          let first = info.first else { return "no window" }
    let pid = first[kCGWindowOwnerPID as String] as? Int32 ?? 0
    let layer = first[kCGWindowLayer as String] as? Int ?? 0
    return pid == getpid() ? "own window, layer \(layer)" : "another process's window, layer \(layer)"
}

private typealias CreateImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

/// Captures one of our own windows, shadow included, over `rect` (CG global coordinates).
///
/// `CGWindowListCreateImage` is obsoleted in the macOS 15 SDK in favour of ScreenCaptureKit, but it is
/// still exported; the spike looks it up at run time because ScreenCaptureKit would need Screen
/// Recording permission, which we must not prompt for. Returns nil if the lookup or capture fails.
func captureOwnWindow(_ windowID: Int, rect: CGRect) -> CGImage? {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }  // -2 = RTLD_DEFAULT
    let create = unsafeBitCast(symbol, to: CreateImageFunction.self)
    return create(
        rect, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(windowID),
        CGWindowImageOption.bestResolution.rawValue
    )?.takeRetainedValue()
}

/// Straight RGBA8 pixels of a CGImage, row 0 at the top, for alpha sampling.
struct RGBAPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        bytes = buffer
    }

    func alpha(_ x: Int, _ y: Int) -> Int {
        guard x >= 0, y >= 0, x < width, y < height else { return -1 }
        return Int(bytes[(y * width + x) * 4 + 3])
    }
}

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
