// SPDX-License-Identifier: GPL-3.0-or-later
// Contact sheets of the visualiser's scenes, drawn offscreen: a scene played through a run of analyser frames, with
// a snapshot every few frames over a stand-in for the artwork (its gradient, light and shade). For checking how a
// scene looks and moves without a window (`sudamp --modern-preview --scene-sheet`), and how long it takes to draw.

import CoreGraphics
import Foundation

nonisolated enum SceneSheet {
    struct Options {
        /// Seconds of frames to play before the first snapshot.
        var start: Double = 2
        var snapshots = 16
        /// Frames between snapshots (frames are 1/60 s).
        var every = 6
        var columns = 8
        /// The artwork's size in points, and pixels per point.
        var size: CGFloat = 92
        var scale: CGFloat = 2
        var seed: UInt64 = 1
        /// The finish over the scene, and what is playing (for a scene that writes it out).
        var effect = ModernPlayerState.VisualizerEffect.none
        var caption = ""
    }

    struct Result {
        var image: CGImage?
        /// Mean and worst time to update and draw one frame, in milliseconds.
        var meanMilliseconds: Double
        var worstMilliseconds: Double
    }

    /// Plays `mode` through `frames` (60 per second; nil entries are silence) and returns the sheet.
    static func render(_ mode: ModernPlayerState.Visualizer, frames: [ModernVisualizerFrame?], palette: ArtworkPalette,
                       options: Options = Options()) -> Result {
        let renderer = SceneRenderer(seed: options.seed)
        renderer.style = SceneStyle(palette)
        renderer.effect = options.effect
        renderer.show(mode, animated: false)
        var features = AudioFeatures()
        features.caption = options.caption
        let size = CGSize(width: options.size, height: options.size)
        let cell = Int((options.size * options.scale).rounded())
        let gap = 6
        let columns = max(1, options.columns)
        let rows = (options.snapshots + columns - 1) / columns
        let sheetWidth = columns * (cell + gap) + gap, sheetHeight = rows * (cell + gap) + gap
        guard let sheet = CGContext(data: nil, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Result(image: nil, meanMilliseconds: 0, worstMilliseconds: 0)
        }
        sheet.setFillColor(CGColor(gray: 0.16, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
        let backdrop = artwork(palette: palette, size: size, scale: options.scale)
        let dt = 1.0 / 60
        let startFrame = Int(options.start * 60)
        let total = startFrame + options.snapshots * max(1, options.every)
        var taken = 0
        var times: [Double] = []
        for i in 0..<total {
            let frame = frames.isEmpty ? nil : frames[i % frames.count]
            let begin = DispatchTime.now().uptimeNanoseconds
            renderer.update(features.next(frame, dt: dt), dt: dt)
            let image = renderer.image(size: size, scale: options.scale)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6)
            guard i >= startFrame, (i - startFrame) % max(1, options.every) == 0, taken < options.snapshots else { continue }
            let col = taken % columns, row = taken / columns
            let rect = CGRect(x: gap + col * (cell + gap), y: sheetHeight - (row + 1) * (cell + gap), width: cell, height: cell)
            sheet.saveGState()
            sheet.addPath(CGPath(roundedRect: rect, cornerWidth: CGFloat(cell) * 0.15, cornerHeight: CGFloat(cell) * 0.15,
                                 transform: nil))
            sheet.clip()
            if let backdrop { sheet.draw(backdrop, in: rect) }
            if let image {
                // The artwork's glow, roughly: the scene drawn blurred under itself.
                if renderer.glow > 0 {
                    sheet.setShadow(offset: .zero, blur: 4 * options.scale,
                                    color: palette.glow.cgColor(alpha: (palette.isLight ? 0.3 : 0.5) * renderer.glow))
                }
                sheet.draw(image, in: rect)
            }
            sheet.restoreGState()
            taken += 1
        }
        let measured = times.dropFirst(10)
        let mean = measured.isEmpty ? 0 : measured.reduce(0, +) / Double(measured.count)
        return Result(image: sheet.makeImage(), meanMilliseconds: mean, worstMilliseconds: measured.max() ?? 0)
    }

    /// The artwork as it rests: the base gradient, the three blobs of light, the shade and the gloss.
    static func artwork(palette: ArtworkPalette, size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        if let base = CGGradient(colorsSpace: space, colors: [palette.base.0.cgColor, palette.base.1.cgColor] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        let anchors = [CGPoint(x: 0.18, y: 0.15), CGPoint(x: 0.92, y: 0.42), CGPoint(x: 0.35, y: 0.98)]
        for (i, (color, anchor)) in zip(palette.blobs, anchors).enumerated() {
            let alpha = i == 0 ? 0.7 : 0.62
            let colors = [color.cgColor(alpha: alpha), color.cgColor(alpha: alpha * 0.45), color.cgColor(alpha: 0)] as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.4, 1]) else { continue }
            let c = CGPoint(x: size.width * anchor.x, y: size.height * anchor.y)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: size.width * 0.65, options: [])
        }
        let shadeAlpha = palette.isLight ? 0.06 : 0.32
        if let shade = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: shadeAlpha)] as CFArray,
                                  locations: [0.45, 1]) {
            ctx.drawLinearGradient(shade, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        if let gloss = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.26), CGColor(gray: 1, alpha: 0)] as CFArray,
                                  locations: [0, 1]) {
            ctx.drawLinearGradient(gloss, start: .zero, end: CGPoint(x: 0, y: size.height * 0.55), options: [])
        }
        return ctx.makeImage()
    }

    /// Analyser frames from JSON: `[{"bars": [...], "peaks": [...], "scope": [...]}, …]`.
    static func frames(json data: Data) throws -> [ModernVisualizerFrame?] {
        struct Frame: Decodable {
            var bars: [Float]
            var peaks: [Float]?
            var scope: [Float]
        }
        return try JSONDecoder().decode([Frame].self, from: data).map { ModernVisualizerFrame(bars: $0.bars, peaks: $0.peaks, scope: $0.scope) }
    }

    /// The palette a sheet uses for a style name: `dark`, `light` (the window scheme's), `genre:<key>`,
    /// `source:<youtube|soundcloud|mixcloud|radio>`, `cycle:<0...1>`.
    static func palette(named name: String, tint: ModernTint = .default) -> ArtworkPalette? {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "dark": return ArtworkPalette.make(.init(colors: .window, tint: tint, dark: true))
        case "light": return ArtworkPalette.make(.init(colors: .window, tint: tint, dark: false))
        case "genre": return ArtworkPalette.make(.init(colors: .genre, genreKey: parts.count > 1 ? parts[1] : nil, tint: tint, dark: true))
        case "source":
            let tag: ModernPlayerState.SourceTag? = switch parts.count > 1 ? parts[1] : "" {
            case "youtube": .youtube
            case "soundcloud": .soundcloud
            case "mixcloud": .mixcloud
            case "radio": .radio
            default: nil
            }
            return tag.map { ArtworkPalette.make(.init(colors: .source, source: $0, tint: tint, dark: true)) }
        case "cycle":
            return ArtworkPalette.make(.init(colors: .cycle, tint: tint, dark: true), cycle: parts.count > 1 ? Double(parts[1]) ?? 0 : 0)
        default: return nil
        }
    }
}
