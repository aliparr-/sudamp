// SPDX-License-Identifier: GPL-3.0-or-later
// Renders the website's media from the app's own visualiser code: a short clip and a poster of every scene over the
// generated artwork, and pixel sprite sheets of the Dancing Toast. Built by `render-media.sh` together with the
// scene sources (ModernTheme, ModernPlayerState, Visualizer/**), so the pictures are exactly what the app draws.
//
//   site-media scenes --frames <json> --out <dir> [--only a,b,c]   clips (.mp4) and posters (.jpg)
//   site-media toast  --frames <json> --out <dir>                  sprite sheets, poster and manifest
//   site-media check  --video <mp4> --out <png> --times 0,3.9,7.5  decoded frames side by side (for eyeballing)
//   site-media seeds                                               which toast each seed makes
//
// The music is the preview's synthesised loop: 124 bpm, 16 bars (30.97 s); bars 8–11 are a breakdown and the drop
// lands on bar 12. Analyser frames come 60 a second (frame k is music time (k+1)/60); scenes move on once per frame
// with dt = 1/60, as the app's contact sheets drive them, and the videos keep every second frame (30 fps).

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Music

nonisolated enum Music {
    static let beat = 60.0 / 124
    static let bar = 4 * beat
    /// 60 fps analyser frames in one pass of the 16-bar loop, and how far into the second pass the seam is moved
    /// (the second pass has a warmed-up analyser, so frame `seam` of it follows frame 1857 of the first smoothly).
    static let loopFrames = 1858
    static let seam = 62
    /// The first analyser frame at or after the drop (bar 12): music time (k + 1) / 60 ≥ 12 bars.
    static let dropFrame = Int((12 * bar * 60).rounded(.up)) - 1

    /// One seamless pass of the loop, 60 frames a second.
    static func loop(_ frames: [ModernVisualizerFrame?]) -> [ModernVisualizerFrame?] {
        (0..<loopFrames).map { $0 < seam ? frames[loopFrames + $0] : frames[$0] }
    }
}

// MARK: - Images

nonisolated let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

nonisolated func makeContext(_ width: Int, _ height: Int, bgra: Bool = false) -> CGContext {
    let info = bgra ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        : CGImageAlphaInfo.premultipliedLast.rawValue
    return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
                     bitmapInfo: info)!
}

nonisolated func write(_ image: CGImage, to url: URL, type: UTType, quality: Double? = nil) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        throw Failure("can't write \(url.path)")
    }
    var properties: [CFString: Any] = [:]
    if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw Failure("can't write \(url.path)") }
}

nonisolated struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Artwork

/// The generated artwork behind a scene, as the app's ArtworkView layers it: the base gradient, three blobs of light
/// (the first added with a screen blend) that drift slowly and swell with the bass, the shade, the scene with its
/// glow, then the gloss over the top. No film grain, rim or rounded corners (the page rounds them).
nonisolated struct Artwork {
    let palette: ArtworkPalette
    let side: CGFloat
    let scale: CGFloat
    /// The first blob (the highlight) adds light with a screen blend, as the app's layer does.
    var screen = true
    static let anchors = [CGPoint(x: 0.18, y: 0.15), CGPoint(x: 0.92, y: 0.42), CGPoint(x: 0.35, y: 0.98)]

    /// Where blob `i` has drifted `t` seconds into a loop `period` long. The app sends each blob round a slow loop
    /// (0.16 of the artwork across, 15, 19.5 and 24 s); here each goes round once per clip, at the app's speed (so a
    /// smaller loop), and the clip loops seamlessly.
    func drift(_ i: Int, at t: Double, period: Double) -> CGPoint {
        let appPeriod = 15 + Double(i) * 4.5
        let a = side * 0.16 * CGFloat(min(1, period / appPeriod))
        let angle = 2 * Double.pi * t / period + Double(i) * 2.1
        return CGPoint(x: a * CGFloat(cos(angle)), y: a * 0.8 * CGFloat(sin(angle)))
    }

    /// Everything under the scene, into `ctx` (pixels, CG's bottom-left origin), with the blobs offset by `drift`
    /// and swollen by `swell` (1 at rest). As in the app, the swell scales the blobs' layer about its bottom-right
    /// corner (a sublayer transform about the centre, applied relative to the layer's anchor, which is the centre).
    func drawUnder(in ctx: CGContext, drift: [CGPoint], swell: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: side * scale)
        ctx.scaleBy(x: scale, y: -scale)
        let size = CGSize(width: side, height: side)
        if let base = CGGradient(colorsSpace: sRGB, colors: [palette.base.0.cgColor, palette.base.1.cgColor] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        let pivot = CGPoint(x: side, y: side)
        for (i, (color, anchor)) in zip(palette.blobs, Self.anchors).enumerated() {
            let alpha = i == 0 ? 0.7 : 0.62
            let colors = [color.cgColor(alpha: alpha), color.cgColor(alpha: alpha * 0.45), color.cgColor(alpha: 0)] as CFArray
            guard let gradient = CGGradient(colorsSpace: sRGB, colors: colors, locations: [0, 0.4, 1]) else { continue }
            let offset = i < drift.count ? drift[i] : .zero
            let c0 = CGPoint(x: side * anchor.x + offset.x, y: side * anchor.y + offset.y)
            let c = CGPoint(x: pivot.x + (c0.x - pivot.x) * swell, y: pivot.y + (c0.y - pivot.y) * swell)
            ctx.saveGState()
            if i == 0, screen { ctx.setBlendMode(.screen) }
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: side * 0.65 * swell,
                                   options: [])
            ctx.restoreGState()
        }
        let shadeAlpha = palette.isLight ? 0.06 : 0.32
        if let shade = CGGradient(colorsSpace: sRGB, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: shadeAlpha)] as CFArray,
                                  locations: [0.45, 1]) {
            ctx.drawLinearGradient(shade, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        ctx.restoreGState()
    }

    /// The scene's frame with the artwork's glow round it (as the contact sheets draw it).
    func drawScene(_ image: CGImage, glow: Double, in ctx: CGContext) {
        ctx.saveGState()
        if glow > 0 {
            ctx.setShadow(offset: .zero, blur: 4 * scale, color: palette.glow.cgColor(alpha: (palette.isLight ? 0.3 : 0.5) * glow))
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side * scale, height: side * scale))
        ctx.restoreGState()
    }

    /// The gloss across the top, over the scene (the app layers it above the visualiser).
    func drawOver(in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: side * scale)
        ctx.scaleBy(x: scale, y: -scale)
        if let gloss = CGGradient(colorsSpace: sRGB, colors: [CGColor(gray: 1, alpha: 0.26), CGColor(gray: 1, alpha: 0)] as CFArray,
                                  locations: [0, 1]) {
            ctx.drawLinearGradient(gloss, start: .zero, end: CGPoint(x: 0, y: side * 0.55), options: [])
        }
        ctx.restoreGState()
    }
}

// MARK: - Video

/// An H.264 MP4 written a frame at a time from a BGRA bitmap context.
nonisolated final class ClipWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let width: Int, height: Int
    private(set) var count = 0

    init(url: URL, width: Int, height: Int, bitrate: Int, fps: Int = 30) throws {
        try? FileManager.default.removeItem(at: url)
        self.width = width
        self.height = height
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoExpectedSourceFrameRateKey: fps,
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failure("can't add the video input") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure("can't start writing: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
    }

    /// Appends the BGRA context's pixels as the next frame.
    func append(_ ctx: CGContext) throws {
        while !input.isReadyForMoreMediaData { usleep(500) }
        guard let pool = adaptor.pixelBufferPool else { throw Failure("no pixel buffer pool: \(String(describing: writer.error))") }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let buffer = made, let source = ctx.data else { throw Failure("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let target = CVPixelBufferGetBaseAddress(buffer)!
        let targetRow = CVPixelBufferGetBytesPerRow(buffer), sourceRow = ctx.bytesPerRow
        for y in 0..<height { memcpy(target + y * targetRow, source + y * sourceRow, width * 4) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(count), timescale: 30)) else {
            throw Failure("append failed: \(String(describing: writer.error))")
        }
        count += 1
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure("writing failed: \(String(describing: writer.error))") }
    }
}

// MARK: - Scene clips

nonisolated struct Clip {
    var name: String
    var mode: ModernPlayerState.Visualizer
    var style: String
    var effect = ModernPlayerState.VisualizerEffect.none
    /// The renderer's seed (`SceneRenderer.show` mixes it before making the scene).
    var seed: UInt64 = 1

    static let frameCount = 232
    static let side: CGFloat = 92
    static let scale: CGFloat = 6
    static let caption = "Sunset Sessions · Solar Crew"
    /// Output frames into the clip to take the poster from (default 0, the drop itself).
    static let posterDelay: [String: Int] = ["demoscene": 30]

    static var all: [Clip] {
        let styles: [ModernPlayerState.Visualizer: String] = [
            .spectrum: "genre", .oscilloscope: "genre:ambient", .leds: "genre:techno", .vuMeters: "genre:lo-fi",
            .heartbeat: "genre:drum-and-bass", .turntable: "genre:deep-house", .speaker: "genre:house",
            .halo: "genre:drum-and-bass", .waterfall: "genre:deep-house", .tunnel: "genre:techno", .spiral: "genre:techno",
            .loops: "genre:ambient", .pendulums: "genre:deep-house", .cells: "genre:techno", .starfield: "genre:techno",
            .synthwave: "genre:deep-house", .skyline: "genre:deep-house", .fireworks: "genre:house", .aurora: "genre:ambient",
            .rain: "genre:ambient", .campfire: "genre:lo-fi", .lava: "genre:house", .pixelDJ: "genre:house",
            .toast: "genre:house", .breakfastBand: "genre:lo-fi", .drummingCat: "genre:lo-fi", .rally: "genre:drum-and-bass",
            .demoscene: "genre:drum-and-bass",
        ]
        // The toast clip shows the mascot (golden, butter, no shades).
        let mascot = ToastLooks.mascotSeed &- 0x9E37_79B9
        var clips = ModernPlayerState.Visualizer.scenes.map { mode in
            Clip(name: mode.rawValue, mode: mode, style: styles[mode] ?? "genre", seed: mode == .toast ? mascot : 1)
        }
        clips.append(Clip(name: "synthwave-vhs", mode: .synthwave, style: "genre:deep-house", effect: .vhs))
        clips.append(Clip(name: "synthwave-kaleidoscope", mode: .synthwave, style: "genre:deep-house", effect: .kaleidoscope))
        return clips
    }
}

nonisolated func renderClip(_ clip: Clip, frames: [ModernVisualizerFrame?], out: URL, bitrate: Int) async throws {
    guard let palette = SceneSheet.palette(named: clip.style) else { throw Failure("unknown style \(clip.style)") }
    let renderer = SceneRenderer(seed: clip.seed)
    renderer.style = SceneStyle(palette)
    renderer.effect = clip.effect
    renderer.show(clip.mode, animated: false)
    var features = AudioFeatures()
    features.caption = Clip.caption
    let size = CGSize(width: Clip.side, height: Clip.side)
    let pixels = Int(Clip.side * Clip.scale)
    let artwork = Artwork(palette: palette, side: Clip.side, scale: Clip.scale)
    let ctx = makeContext(pixels, pixels, bgra: true)
    let writer = try ClipWriter(url: out.appendingPathComponent(clip.name + ".mp4"), width: pixels, height: pixels, bitrate: bitrate)
    let dt = 1.0 / 60
    let first = Music.dropFrame, last = first + (Clip.frameCount - 1) * 2
    let period = Double(Clip.frameCount) / 30
    var bassLevel: Float = 0
    var drops: [Int] = []
    var milliseconds = 0.0
    for k in 0...last {
        let input = features.next(frames[k], dt: dt)
        if input.drop { drops.append(k) }
        renderer.update(input, dt: dt)
        // The light swells with the bass (ArtworkView.step).
        bassLevel += (input.bass - bassLevel) * Float(1 - pow(0.6, dt * 30))
        let begin = DispatchTime.now().uptimeNanoseconds
        // Drawn every frame, as the app and the contact sheets do (some scenes and effects keep state as they draw).
        guard let image = renderer.image(size: size, scale: Clip.scale) else { throw Failure("no image for \(clip.name)") }
        milliseconds += Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6
        guard k >= first, (k - first) % 2 == 0 else { continue }
        let t = Double(k - first) / 60
        ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        artwork.drawUnder(in: ctx, drift: (0..<3).map { artwork.drift($0, at: t, period: period) },
                          swell: 1 + CGFloat(bassLevel) * 0.16)
        artwork.drawScene(image, glow: renderer.glow, in: ctx)
        artwork.drawOver(in: ctx)
        // The poster is the drop, except where the drop's flash washes the frame out.
        let posterFrame = first + 2 * (Clip.posterDelay[clip.name] ?? 0)
        if k == posterFrame, let poster = ctx.makeImage() {
            try write(poster, to: out.appendingPathComponent(clip.name + ".jpg"), type: .jpeg, quality: 0.82)
        }
        try writer.append(ctx)
    }
    try await writer.finish()
    // AVAssetWriter can leave its temporary copy behind (`<name>.mp4.sb-…`) when the process ends straight after.
    for file in (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? [] where file.hasPrefix(clip.name + ".mp4.sb-") {
        try? FileManager.default.removeItem(at: out.appendingPathComponent(file))
    }
    // Rewritten as a fresh file: the writer leaves about twice the file's size allocated on disk.
    let url = out.appendingPathComponent(clip.name + ".mp4")
    try Data(contentsOf: url).write(to: url)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: out.appendingPathComponent(clip.name + ".mp4").path)[.size] as? Int) ?? 0
    print(String(format: "%@: %d frames, %.0f KB, %.2f ms a frame to draw, drops at frames %@", clip.name, writer.count,
                 Double(bytes) / 1024, milliseconds / Double(last + 1), drops.map(String.init).joined(separator: ",")))
}

// MARK: - Toast

nonisolated enum ToastLooks {
    static let tones = ["light", "golden", "well done", "wholemeal"]

    /// The look a `ToastScene(seed:)` gets: its first draws from the seed (as `ToastScene.Look.init` takes them).
    static func look(_ seed: UInt64) -> (tone: Int, jam: Bool, shades: Bool, shoe: Int) {
        var random = SceneRandom(seed: seed)
        let tone = random.int(4)
        let jam = random.chance(0.4)
        let shades = random.chance(0.34)
        let shoe = random.int(4)
        return (tone, jam, shades, shoe)
    }

    static func describe(_ seed: UInt64) -> String {
        let l = look(seed)
        return "\(tones[l.tone]), \(l.jam ? "jam" : "butter")" + (l.shades ? ", sunglasses" : "")
    }

    /// The first seed with this look.
    static func first(tone: Int, jam: Bool, shades: Bool, shoe: Int? = nil, after: UInt64 = 0) -> UInt64 {
        var seed = after + 1
        while true {
            let l = look(seed)
            if l.tone == tone, l.jam == jam, l.shades == shades, shoe == nil || l.shoe == shoe { return seed }
            seed += 1
        }
    }

    static var mascotSeed: UInt64 { first(tone: 1, jam: false, shades: false) }

    /// The variants on the page: the mascot first.
    static var variants: [UInt64] {
        [mascotSeed,
         first(tone: 0, jam: false, shades: false),
         first(tone: 2, jam: true, shades: false),
         first(tone: 3, jam: false, shades: false),
         first(tone: 1, jam: true, shades: true)]
    }
}

/// A sheet of `count` cells (`cell` pixels square), `columns` across, row-major, transparent.
nonisolated struct SpriteSheet {
    let cell: Int, columns: Int, count: Int
    let ctx: CGContext

    init(cell: Int, columns: Int, count: Int) {
        self.cell = cell
        self.columns = columns
        self.count = count
        let rows = (count + columns - 1) / columns
        ctx = makeContext(columns * cell, rows * cell)
        ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    }

    /// Copies a frame's pixels into cell `i` byte for byte (no resampling).
    func put(_ frame: CGContext, at i: Int) {
        guard let source = frame.data, let target = ctx.data else { return }
        let x = (i % columns) * cell, y = (i / columns) * cell
        for row in 0..<cell {
            memcpy(target + (y + row) * ctx.bytesPerRow + x * 4, source + row * frame.bytesPerRow, cell * 4)
        }
    }
}

nonisolated func renderToast(frames: [ModernVisualizerFrame?], out: URL) throws {
    guard let palette = SceneSheet.palette(named: "genre:house") else { throw Failure("no palette") }
    let loop = Music.loop(frames)
    let dt = 1.0 / 60
    let grid = 46, columns = 32
    let size = CGSize(width: 92, height: 92)
    let danceCount = Music.loopFrames / 2, idleCount = 180
    var manifest: [[String: Any]] = []
    var problems = 0
    for (index, seed) in ToastLooks.variants.enumerated() {
        let n = index + 1
        let renderer = SceneRenderer(seed: seed &- 0x9E37_79B9)
        renderer.style = SceneStyle(palette)
        renderer.show(.toast, animated: false)
        var features = AudioFeatures()
        let frame = makeContext(grid, grid)
        /// The renderer's frame at the scene's own grid: 92 points at half a pixel each. Checked against the frame at
        /// 1 pixel a point every so often, which must be the same pixels doubled.
        func draw(check: Bool) throws {
            if check {
                guard let big = renderer.image(size: size, scale: 1) else { throw Failure("no image") }
                let doubled = makeContext(92, 92)
                doubled.clear(CGRect(x: 0, y: 0, width: 92, height: 92))
                doubled.draw(big, in: CGRect(x: 0, y: 0, width: 92, height: 92))
                guard let small = renderer.image(size: size, scale: 0.5) else { throw Failure("no image") }
                drawExact(small, into: frame)
                let a = frame.data!.assumingMemoryBound(to: UInt32.self), b = doubled.data!.assumingMemoryBound(to: UInt32.self)
                for y in 0..<92 {
                    for x in 0..<92 where b[y * 92 + x] != a[(y / 2) * grid + x / 2] { problems += 1 }
                }
            } else {
                guard let small = renderer.image(size: size, scale: 0.5) else { throw Failure("no image") }
                drawExact(small, into: frame)
            }
        }
        // Warm up: the music from the top, once through, as if it had just started.
        for k in 0..<Music.loopFrames {
            renderer.update(features.next(frames[k], dt: dt), dt: dt)
            try draw(check: false)
        }
        // The loop, every second frame: cell j is music time (j + 1) / 30 (mod the loop).
        let dance = SpriteSheet(cell: grid, columns: columns, count: danceCount)
        var gloves: [(j: Int, height: Int, mouth: Int)] = []
        for k in 0..<Music.loopFrames {
            renderer.update(features.next(loop[k], dt: dt), dt: dt)
            let j = (k - 1) / 2
            try draw(check: k % 2 == 1 && j % 7 == 0)
            guard k % 2 == 1 else { continue }
            dance.put(frame, at: j)
            if n == 1 { gloves.append((j, lowestGlove(frame), count(0xFF12_1E5A, in: frame))) }
        }
        // Then the music stops.
        let idle = SpriteSheet(cell: grid, columns: columns, count: idleCount)
        // The first frame from which nothing visibly changes (no channel moves more than 2 levels a frame).
        var still = 0
        var previous: [UInt8] = []
        for k in 0..<(idleCount * 2) {
            renderer.update(features.next(nil, dt: dt), dt: dt)
            try draw(check: false)
            guard k % 2 == 1 else { continue }
            let j = (k - 1) / 2
            idle.put(frame, at: j)
            let now = Array(UnsafeBufferPointer(start: frame.data!.assumingMemoryBound(to: UInt8.self), count: grid * grid * 4))
            if previous.isEmpty || zip(now, previous).contains(where: { abs(Int($0) - Int($1)) > 2 }) { still = j }
            previous = now
        }
        try write(dance.ctx.makeImage()!, to: out.appendingPathComponent("dance-\(n).png"), type: .png)
        try write(idle.ctx.makeImage()!, to: out.appendingPathComponent("idle-\(n).png"), type: .png)
        print("toast \(n): seed \(seed), \(ToastLooks.describe(seed)), shoe \(ToastLooks.look(seed).shoe); idle still from frame \(still)")
        manifest.append(["n": n, "seed": seed, "look": ToastLooks.describe(seed), "dance": "dance-\(n).png",
                         "idle": "idle-\(n).png", "frames": danceCount, "idleFrames": idleCount, "columns": columns,
                         "cell": grid, "fps": 30, "idleStillFrom": still])
        if n == 1 {
            // The poster: from the breakdown (arms up, swaying; no sparkles yet), both hands highest, singing.
            let breakdown = Int((8 * Music.bar * 30).rounded(.up))..<Int((12 * Music.bar * 30).rounded(.down)) - 1
            let best = gloves.filter { breakdown.contains($0.j) }.min { ($0.height, -$0.mouth) < ($1.height, -$1.mouth) }!
            print("poster: dance frame \(best.j) (gloves' lower one at row \(best.height), \(best.mouth) mouth pixels)")
            let x = (best.j % columns) * grid, y = (best.j / columns) * grid
            if let sheet = dance.ctx.makeImage(),
               let cell = sheet.cropping(to: CGRect(x: x, y: y, width: grid, height: grid)) {
                try write(cell, to: out.appendingPathComponent("toast-poster.png"), type: .png)
            }
            manifest[0]["posterFrame"] = best.j
        }
    }
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: out.appendingPathComponent("manifest.json"))
    print(problems == 0 ? "pixels: every checked frame is the 1x frame halved exactly" : "pixels: \(problems) mismatches")
}

/// Draws `image` (the same size as `ctx`) with no resampling and no blending.
nonisolated func drawExact(_ image: CGImage, into ctx: CGContext) {
    ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    ctx.saveGState()
    ctx.interpolationQuality = .none
    ctx.setBlendMode(.copy)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    ctx.restoreGState()
}

/// How many pixels of the frame are exactly `pixel` (RGBA bytes read as a little-endian word).
nonisolated func count(_ pixel: UInt32, in ctx: CGContext) -> Int {
    let p = ctx.data!.assumingMemoryBound(to: UInt32.self)
    var n = 0
    for i in 0..<(ctx.width * ctx.height) where p[i] == pixel { n += 1 }
    return n
}

/// The row of the lower of the two white gloves (2×2 blocks of opaque white), or a big number if one is missing.
nonisolated func lowestGlove(_ ctx: CGContext) -> Int {
    let w = ctx.width, h = ctx.height
    let p = ctx.data!.assumingMemoryBound(to: UInt32.self)
    func white(_ x: Int, _ y: Int) -> Bool { x < w && y < h && p[y * w + x] == 0xFFFF_FFFF }
    var blocks: [(x: Int, y: Int)] = []
    for y in 0..<(h - 1) {
        for x in 0..<(w - 1) where white(x, y) && white(x + 1, y) && white(x, y + 1) && white(x + 1, y + 1) {
            if !blocks.contains(where: { abs($0.x - x) <= 1 && abs($0.y - y) <= 1 }) { blocks.append((x, y)) }
        }
    }
    guard blocks.count >= 2 else { return 1000 }
    return blocks.map(\.y).sorted()[1]
}

// MARK: - Check

/// Decoded frames of a clip at `times`, side by side.
nonisolated func check(video: URL, times: [Double], out: URL) async throws {
    let asset = AVURLAsset(url: video)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    var images: [CGImage] = []
    for t in times {
        let (image, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
        images.append(image)
    }
    guard let first = images.first else { return }
    let ctx = makeContext(first.width * images.count + 8 * (images.count - 1), first.height)
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    for (i, image) in images.enumerated() {
        ctx.draw(image, in: CGRect(x: i * (first.width + 8), y: 0, width: image.width, height: image.height))
    }
    try write(ctx.makeImage()!, to: out, type: .png)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    if let track = tracks.first {
        let (rate, size, duration) = try await (track.load(.estimatedDataRate), track.load(.naturalSize), asset.load(.duration))
        print(String(format: "%@: %.0fx%.0f, %.3f s, %.0f kbps", video.lastPathComponent, size.width, size.height,
                     duration.seconds, rate / 1000))
    }
}

// MARK: - Main

@main
struct SiteMedia {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) } catch {
            FileHandle.standardError.write(Data("site-media: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ args: [String]) async throws {
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func frames() throws -> [ModernVisualizerFrame?] {
            guard let path = option("--frames") else { throw Failure("--frames <json> is needed") }
            let frames = try SceneSheet.frames(json: Data(contentsOf: URL(fileURLWithPath: path)))
            guard frames.count >= Music.loopFrames + Music.seam else { throw Failure("too few frames: \(frames.count)") }
            return frames
        }
        func outDir() throws -> URL {
            guard let path = option("--out") else { throw Failure("--out <dir> is needed") }
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        switch args.first {
        case "scenes":
            let frames = try frames(), out = try outDir()
            let only = option("--only").map { Set($0.split(separator: ",").map(String.init)) }
            let bitrate = Int(option("--bitrate") ?? "") ?? 1_350_000
            for clip in Clip.all where only?.contains(clip.name) ?? true {
                try await renderClip(clip, frames: frames, out: out, bitrate: bitrate)
            }
        case "toast":
            try renderToast(frames: try frames(), out: try outDir())
        case "check":
            guard let video = option("--video"), let out = option("--out") else { throw Failure("--video and --out are needed") }
            let times = (option("--times") ?? "0,3.8,7.6").split(separator: ",").compactMap { Double($0) }
            try await check(video: URL(fileURLWithPath: video), times: times, out: URL(fileURLWithPath: out))
        case "seeds":
            for seed in UInt64(1)...40 { print(seed, ToastLooks.describe(seed), "shoe", ToastLooks.look(seed).shoe) }
            print("variants:", ToastLooks.variants.map { "\($0) (\(ToastLooks.describe($0)))" }.joined(separator: "; "))
        case "list":
            print(Clip.all.map(\.name).joined(separator: " "))
        case "stats":
            // Mean colour of rectangles in an image: --rects "x,y,w,h;x,y,w,h" (top-left origin).
            guard let path = option("--image"), let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure("--image <png> is needed") }
            let ctx = makeContext(image.width, image.height)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
            for rect in (option("--rects") ?? "0,0,\(image.width),\(image.height)").split(separator: ";") {
                let v = rect.split(separator: ",").compactMap { Int($0) }
                guard v.count == 4 else { continue }
                var sum = [0.0, 0.0, 0.0, 0.0]
                for y in v[1]..<(v[1] + v[3]) {
                    for x in v[0]..<(v[0] + v[2]) {
                        for c in 0..<4 { sum[c] += Double(p[y * ctx.bytesPerRow + x * 4 + c]) }
                    }
                }
                let n = Double(v[2] * v[3])
                print(rect, sum.map { String(format: "%.0f", $0 / n) }.joined(separator: " "))
            }
        case "contact":
            // A contact sheet of images: --out <png> --cell <px> --columns <n> [--nearest] [--backdrop gray] files…
            guard let out = option("--out") else { throw Failure("--out is needed") }
            let cell = Int(option("--cell") ?? "") ?? 184, columns = Int(option("--columns") ?? "") ?? 8
            let gray = Double(option("--backdrop") ?? "") ?? 0.16
            var files: [String] = []
            var i = 1
            while i < args.count {
                if ["--out", "--cell", "--columns", "--backdrop"].contains(args[i]) { i += 2; continue }
                if !args[i].hasPrefix("--") { files.append(args[i]) }
                i += 1
            }
            let gap = 4, rows = (files.count + columns - 1) / columns
            let ctx = makeContext(columns * (cell + gap) + gap, rows * (cell + gap) + gap)
            ctx.setFillColor(CGColor(gray: gray, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            ctx.interpolationQuality = args.contains("--nearest") ? .none : .high
            for (n, file) in files.enumerated() {
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                let x = gap + (n % columns) * (cell + gap), y = ctx.height - (n / columns + 1) * (cell + gap)
                ctx.draw(image, in: CGRect(x: x, y: y, width: cell, height: cell))
            }
            try write(ctx.makeImage()!, to: URL(fileURLWithPath: out), type: .png)
        case "cells":
            // Chosen cells of a sprite sheet, magnified with no smoothing on a dark backdrop:
            // --sheet <png> --pick a,b,c|a-b --zoom 4 --columns 32 --cell 46 --across 8 --out <png>
            guard let path = option("--sheet"), let out = option("--out"),
                  let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure("--sheet and --out are needed") }
            let cell = Int(option("--cell") ?? "") ?? 46, columns = Int(option("--columns") ?? "") ?? 32
            let zoom = Int(option("--zoom") ?? "") ?? 4, across = Int(option("--across") ?? "") ?? 8
            var picks: [Int] = []
            for part in (option("--pick") ?? "0-7").split(separator: ",") {
                let ends = part.split(separator: "-").compactMap { Int($0) }
                if ends.count == 2 { picks += Array(ends[0]...ends[1]) } else if let one = ends.first { picks.append(one) }
            }
            let side = cell * zoom, gap = 6, rows = (picks.count + across - 1) / across
            let ctx = makeContext(across * (side + gap) + gap, rows * (side + gap) + gap)
            ctx.setFillColor(CGColor(red: 0.12, green: 0.1, blue: 0.16, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            ctx.interpolationQuality = .none
            for (n, j) in picks.enumerated() {
                guard let image = sheet.cropping(to: CGRect(x: (j % columns) * cell, y: (j / columns) * cell, width: cell, height: cell)) else { continue }
                let x = gap + (n % across) * (side + gap), y = ctx.height - (n / across + 1) * (side + gap)
                ctx.draw(image, in: CGRect(x: x, y: y, width: side, height: side))
            }
            try write(ctx.makeImage()!, to: URL(fileURLWithPath: out), type: .png)
        case "diff":
            // Pixels that differ between two cells of a sheet: --sheet <png> --a j --b k
            guard let path = option("--sheet"), let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil), let a = Int(option("--a") ?? ""),
                  let b = Int(option("--b") ?? "") else { throw Failure("--sheet, --a and --b are needed") }
            func pixels(_ j: Int) -> [UInt8] {
                let ctx = makeContext(46, 46)
                drawExact(sheet.cropping(to: CGRect(x: (j % 32) * 46, y: (j / 32) * 46, width: 46, height: 46))!, into: ctx)
                return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: 46 * 46 * 4))
            }
            let pa = pixels(a), pb = pixels(b)
            for i in stride(from: 0, to: pa.count, by: 4) where pa[i..<(i + 4)] != pb[i..<(i + 4)] {
                print("x \(i / 4 % 46) y \(i / 4 / 46): \(Array(pa[i..<(i + 4)])) -> \(Array(pb[i..<(i + 4)]))")
            }
        case "artwork":
            // The artwork at rest (no scene), for comparing with a capture of the app.
            guard let palette = SceneSheet.palette(named: option("--style") ?? "genre"), let out = option("--out") else {
                throw Failure("--style and --out are needed")
            }
            let scale = CGFloat(Double(option("--scale") ?? "") ?? 1)
            var artwork = Artwork(palette: palette, side: 92, scale: scale)
            let ctx = makeContext(Int(92 * scale), Int(92 * scale))
            artwork.screen = !args.contains("--no-screen")
            artwork.drawUnder(in: ctx, drift: [], swell: 1)
            artwork.drawOver(in: ctx)
            try write(ctx.makeImage()!, to: URL(fileURLWithPath: out), type: .png)
        default:
            throw Failure("usage: site-media scenes|toast|check|seeds|list …")
        }
    }
}
