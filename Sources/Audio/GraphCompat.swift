// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation

/// Every AVAudioEngine call the macOS 27 SDK deprecates lives here (DESIGN §9 warnings policy). On macOS 27 the
/// throwing replacements are used; below it, the old calls. With the macOS 15 deployment target neither branch
/// warns today; if a future SDK starts warning, the allowlist entry points at this one file.
///
/// The replacements exist only in the macOS 27 SDK, which ships with Swift 6.4 (Xcode 27, CLT 27): `#available` is a
/// runtime check and cannot hide them from an older SDK, so `#if compiler(>=6.4)` keeps Swift 6.2/6.3 builds working.
enum GraphCompat {
    static func connect(_ engine: AVAudioEngine, _ source: AVAudioNode, to destination: AVAudioNode,
                        format: AVAudioFormat?) throws {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            try engine.connectNode(source, to: destination, format: format)
            return
        }
        #endif
        engine.connect(source, to: destination, format: format)
    }

    /// A tap on output bus 0 in the node's own format (tools only; the visualiser reads the C ring instead).
    static func installTap(_ node: AVAudioNode, bufferSize: AVAudioFrameCount,
                           block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        node.installTap(onBus: 0, bufferSize: bufferSize, format: nil, block: block)
    }

    static func removeTap(_ node: AVAudioNode) { node.removeTap(onBus: 0) }
}
