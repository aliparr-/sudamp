// SPDX-License-Identifier: GPL-3.0-or-later
// `sudamp --modern-preview [--appearance auto|light|dark] [--tint <name>] [--panels equalizer,stations]
//                          [--state playing|paused|idle|live|tuning|failed|engine] [--visualizer <mode>]
//                          [--interval <s>] [--colors genre|window|cycle|source] [--backdrop]
//                          [--capture <file.png>] [--capture-delay <seconds>] [--capture-burst <dir> [--burst-count n]]
//                          [--ignore-occlusion] [--exit-after <seconds>] [--probe-hits]
//                          [--open-later|--close-later equalizer|stations]`
// `sudamp --modern-preview --dump-frames <file.json>`
// `sudamp --modern-preview --scene-sheet <file.png> --visualizer <scene> [--frames <file.json>] [--style <name>]`
//
// Opens the modern skin with an animated fake player state (ticking time, a visualiser fed synthesised music through
// the real analyser), the way `--skin-preview` does for the classic skins: no audio, no network, nothing persisted.
// Every ModernEvent is logged to stderr and its obvious local effect applied. `--backdrop` puts a colourful stand-in
// wallpaper behind the window, so the glass has something to refract; `--capture` writes what the screen shows of
// both windows (own windows need no Screen Recording permission) and quits; `--capture-burst` writes a run of frames.
// `--probe-hits` prints where a click on the player would go, as WindowServer routes it (which window) and as AppKit
// does (which view), and clicks Next through AppKit. `--dump-frames` writes 32 s of analyser frames of the synthesised
// music; `--scene-sheet` plays one scene through them offscreen and writes a contact sheet with its cost per frame.

import AppKit
import Audio
import ModernUI

enum ModernPreview {
    struct Options: Equatable {
        var appearance: ModernAppearance = .default
        var tint: ModernTint = .default
        var panels: Set<ModernPanel> = []
        var state = "playing"
        var backdrop = false
        var capture: String?
        var captureDelay: Double = 1.6
        var exitAfter: Double?
        /// Captures a contact sheet of genre artworks instead of the player.
        var artworkSheet: String?
        /// Opens the appearance popover.
        var popover = false
        /// Opens this panel (animated) a second after launch.
        var openLater: ModernPanel?
        /// Closes this panel (animated) a second after launch.
        var closeLater: ModernPanel?
        /// Prints which window WindowServer would send a click to at points on the player, then quits.
        var probeHits = false
        /// Captures a run of frames into this directory (motion checks), then quits.
        var captureBurst: String?
        var burstCount = 90
        var visualizer: ModernPlayerState.Visualizer?
        var colors: ArtworkColors?
        var interval: Double?
        /// Writes this many seconds of analyser frames (synthesised music) as JSON, then quits.
        var dumpFrames: String?
        /// Renders a contact sheet of `--visualizer` offscreen, then quits.
        var sceneSheet: String?
        var sheetFrames: String?
        var sheetStyle = "genre:deep-house"
        /// Keep animating while covered (CPU measurements).
        var ignoreOcclusion = false
    }

    static let states = ["playing", "paused", "idle", "live", "tuning", "failed", "engine"]
    static let usage = "usage: sudamp --modern-preview [--appearance auto|light|dark] [--tint "
        + ModernTint.allCases.map(\.rawValue).joined(separator: "|") + "] [--panels equalizer,stations] [--state "
        + states.joined(separator: "|") + "] [--visualizer "
        + ModernPlayerState.Visualizer.allCases.map(\.rawValue).joined(separator: "|") + "] [--interval <s>] [--colors "
        + ArtworkColors.allCases.map(\.rawValue).joined(separator: "|") + "] [--backdrop] [--capture <file.png>] "
        + "[--capture-delay <s>] [--capture-burst <dir> [--burst-count n]] [--ignore-occlusion] [--exit-after <s>]\n"
        + "       sudamp --modern-preview --dump-frames <file.json>\n"
        + "       sudamp --modern-preview --scene-sheet <file.png> --visualizer <scene> [--frames <file.json>] "
        + "[--style dark|light|genre:<key>|source:<name>|cycle:<0…1>] [--tint <name>]"

    static func parse(_ arguments: [String]) -> Result<Options, SkinPreview.UsageError> {
        var options = Options()
        var i = arguments.firstIndex(of: "--modern-preview").map { $0 + 1 } ?? arguments.count
        func value() -> String? {
            guard i + 1 < arguments.count else { return nil }
            i += 1
            return arguments[i]
        }
        func fail(_ message: String) -> Result<Options, SkinPreview.UsageError> { .failure(.init(message: message)) }
        while i < arguments.count {
            switch arguments[i] {
            case "--appearance":
                guard let v = value(), let a = ModernAppearance(rawValue: v) else { return fail("bad --appearance") }
                options.appearance = a
            case "--tint":
                guard let v = value(), let t = ModernTint(rawValue: v) else { return fail("bad --tint") }
                options.tint = t
            case "--panels":
                guard let v = value() else { return fail("--panels needs a list") }
                let names = v.split(separator: ",").map(String.init)
                let panels = names.compactMap(ModernPanel.init(rawValue:))
                guard panels.count == names.count else { return fail("bad --panels \(v)") }
                options.panels = Set(panels)
            case "--state":
                guard let v = value(), states.contains(v) else { return fail("bad --state") }
                options.state = v
            case "--backdrop": options.backdrop = true
            case "--ignore-occlusion": options.ignoreOcclusion = true
            case "--popover": options.popover = true
            case "--probe-hits": options.probeHits = true
            case "--open-later":
                guard let v = value(), let panel = ModernPanel(rawValue: v) else { return fail("bad --open-later") }
                options.openLater = panel
            case "--close-later":
                guard let v = value(), let panel = ModernPanel(rawValue: v) else { return fail("bad --close-later") }
                options.closeLater = panel
            case "--artwork-sheet":
                guard let v = value() else { return fail("--artwork-sheet needs a file") }
                options.artworkSheet = v
            case "--capture":
                guard let v = value() else { return fail("--capture needs a file") }
                options.capture = v
            case "--capture-burst":
                guard let v = value() else { return fail("--capture-burst needs a directory") }
                options.captureBurst = v
            case "--burst-count":
                guard let v = value(), let n = Int(v), n > 0 else { return fail("bad --burst-count") }
                options.burstCount = n
            case "--visualizer":
                guard let v = value(), let mode = ModernPlayerState.Visualizer(rawValue: v) else { return fail("bad --visualizer") }
                options.visualizer = mode
            case "--colors":
                guard let v = value(), let c = ArtworkColors(rawValue: v) else { return fail("bad --colors") }
                options.colors = c
            case "--interval":
                guard let v = value(), let d = Double(v), d > 0 else { return fail("bad --interval") }
                options.interval = d
            case "--dump-frames":
                guard let v = value() else { return fail("--dump-frames needs a file") }
                options.dumpFrames = v
            case "--scene-sheet":
                guard let v = value() else { return fail("--scene-sheet needs a file") }
                options.sceneSheet = v
            case "--frames":
                guard let v = value() else { return fail("--frames needs a file") }
                options.sheetFrames = v
            case "--style":
                guard let v = value() else { return fail("--style needs a name") }
                options.sheetStyle = v
            case "--capture-delay":
                guard let v = value(), let d = Double(v), d >= 0 else { return fail("bad --capture-delay") }
                options.captureDelay = d
            case "--exit-after":
                guard let v = value(), let d = Double(v), d > 0 else { return fail("bad --exit-after") }
                options.exitAfter = d
            default:
                return fail("unknown argument \(arguments[i])")
            }
            i += 1
        }
        return .success(options)
    }

    private static var controller: ModernPreviewController?

    static func run(arguments: [String]) {
        let options: Options
        switch parse(arguments) {
        case .success(let parsed): options = parsed
        case .failure(let error):
            SkinPreview.log("modern preview: \(error.message)\n\(usage)")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let controller = ModernPreviewController(options: options)
        Self.controller = controller
        app.delegate = controller
        app.run()
    }

    /// A fake state for each `--state`.
    static func state(_ name: String) -> ModernPlayerState {
        var s = ModernPlayerState()
        s.genre = "Deep House"
        s.genreKey = "deep-house"
        s.title = "Sunset Sessions Vol. 7 (Extended Balearic Mix)"
        s.subtitle = "Solar Crew"
        s.source = .soundcloud
        s.format = "128 kbps · 48 kHz"
        s.elapsed = 1342
        s.duration = 3720
        s.canSeek = true
        s.playback = .playing
        s.volume = 0.72
        s.canFavourite = true
        s.isFavourite = true
        s.equalizer = .init(enabled: true, preamp: 2, bands: [4.5, 3.2, 1.5, 0, -1.2, -0.5, 1.4, 3.1, 4.2, 5], preset: "Club")
        s.stationsTitle = "Deep House"
        s.stations = [
            .init(tag: .radio, title: "Deep House Radio", subtitle: "Ibiza Global"),
            .init(tag: .soundcloud, title: "Sunset Sessions Vol. 7", subtitle: "Solar Crew", duration: 3720),
            .init(tag: .youtube, title: "Nightdrive (Extended Mix)", subtitle: "Monolink", duration: 461),
            .init(tag: .mixcloud, title: "Warehouse Session 004", subtitle: "Kerri Chandler", duration: 3492),
            .init(tag: .youtube, title: "Lo-fi Beats to Relax To", subtitle: "Chillhop Music"),
            .init(tag: .soundcloud, title: "Afterhours Tape", subtitle: "Ben Böhmer", duration: 2711),
            .init(tag: .radio, title: "Frisky Deep", subtitle: "Frisky Radio"),
            .init(tag: .youtube, title: "Rooftop Sunset Mix", subtitle: "Cercle", duration: 5400),
        ]
        s.currentStation = 1
        switch name {
        case "paused":
            s.playback = .paused
        case "idle":
            s = ModernPlayerState()
            s.title = "Pick a genre to start listening"
            s.subtitle = "A random stream from a curated list plays right away"
            s.volume = 0.72
            s.stationsTitle = "Stations"
        case "live":
            s.title = "Deep House Radio — Kerri Chandler: Rain"
            s.subtitle = "Ibiza Global Radio"
            s.source = .radio
            s.isLive = true
            s.duration = nil
            s.canSeek = false
            s.elapsed = 754
            s.isFavourite = false
            s.format = "320 kbps · 44 kHz"
            s.currentStation = 0
        case "tuning":
            s.working = true
            s.title = "Tuning…"
            s.subtitle = "Deep House"
            s.format = nil
            s.elapsed = 0
            s.duration = nil
        case "failed":
            s.playback = .stopped
            s.title = "Can't reach streams"
            s.subtitle = "Deep House"
            s.notice = .problem("Five streams failed in a row")
            s.offersRetry = true
            s.format = nil
            s.elapsed = 0
        case "engine":
            s.source = .radio
            s.isLive = true
            s.duration = nil
            s.canSeek = false
            s.title = "Deep House Radio"
            s.subtitle = "Ibiza Global Radio"
            s.notice = .info("Preparing stream engine 63% · radio meanwhile")
        default:
            break
        }
        return s
    }
}

final class ModernPreviewController: NSObject, NSApplicationDelegate {
    private let options: ModernPreview.Options
    private var player: ModernPlayer?
    private var backdrop: NSWindow?
    private var state: ModernPlayerState
    private var timer: Timer?
    /// Events seen while probing.
    private var probedEvents: [String] = []

    init(options: ModernPreview.Options) {
        self.options = options
        state = ModernPreview.state(options.state)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = options.artworkSheet { return showArtworkSheet(capture: path) }
        if let path = options.dumpFrames { return dumpFrames(to: path) }
        if let path = options.sceneSheet { return renderSceneSheet(to: path) }
        if let mode = options.visualizer { state.visualizer = mode }
        if let colors = options.colors { state.artworkColors = colors }
        if let interval = options.interval { state.visualizerInterval = interval }
        var configuration = ModernPlayer.Configuration()
        configuration.appearance = options.appearance
        configuration.tint = options.tint
        configuration.initialPanels = options.panels
        let player = ModernPlayer(configuration: configuration)
        self.player = player
        player.state = state
        player.visualizerProvider = { [weak self] in self?.fakeFrame() }
        player.onEvent = { [weak self] event in self?.handle(event) }
        // A capture runs unattended, often behind other windows: keep animating anyway.
        if options.capture != nil || options.captureBurst != nil || options.ignoreOcclusion { player.pausesWhenOccluded = false }
        if options.backdrop { showBackdrop(behind: player.window) }
        player.show(activate: true)
        NSApp.activate()
        if options.popover {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak player] in
                MainActor.assumeIsolated { player?.showAppearancePopover() }
            }
        }
        for (panel, open) in [(options.openLater, true), (options.closeLater, false)] {
            guard let panel else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak player] in
                MainActor.assumeIsolated { player?.setPanel(panel, open: open) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if options.probeHits {
            // Above every other app's windows, so only ours can answer.
            player.window.level = .screenSaver
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.probeHits() }
            }
        }
        if let path = options.capture {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.captureDelay) { [weak self] in
                MainActor.assumeIsolated { self?.capture(to: path) }
            }
        }
        if let dir = options.captureBurst {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.captureDelay) { [weak self] in
                MainActor.assumeIsolated { self?.captureBurst(into: dir, remaining: self?.options.burstCount ?? 0, index: 0) }
            }
        }
        if let seconds = options.exitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    private func tick() {
        guard state.playback == .playing, !state.working else { return }
        state.elapsed += 1
        player?.state = state
    }

    private let analyser = VisualiserAnalyser(bridge: nil)
    /// 32 s of synthesised music, made once: per frame the analyser reads its newest 1024 samples, as it reads the
    /// ring when a stream plays (so the preview costs what the app does).
    private lazy var track: [Float] = {
        var music = SyntheticMusic(step: 48_000)
        var samples: [Float] = []
        samples.reserveCapacity(48_000 * 32)
        for _ in 0..<32 { samples += music.next(count: 48_000) }
        return samples
    }()
    private var trackStart: CFTimeInterval?

    /// Synthesised music (a kick, a bassline, hats, a pad) through the real analyser, so the bars jump and fall as
    /// they do when a stream plays.
    private func fakeFrame() -> ModernVisualizerFrame {
        let now = CACurrentMediaTime()
        if trackStart == nil { trackStart = now }
        let n = VisualiserAnalyser.windowSize
        let end = n + Int((now - (trackStart ?? now)) * 48_000) % (track.count - n)
        let frame = track.withUnsafeBufferPointer {
            analyser.analyse(samples: UnsafeBufferPointer(rebasing: $0[(end - n)..<end]), nowNanos: UInt64(now * 1e9))
        }
        return ModernVisualizerFrame(bars: frame.bars, peaks: frame.peaks, scope: frame.scope)
    }

    private func handle(_ event: ModernEvent) {
        SkinPreview.log("modern preview: event \(event)")
        probedEvents.append(event.description)
        switch event {
        case .playPause:
            state.playback = state.playback == .playing ? .paused : .playing
        case .stop:
            state.playback = .stopped
        case .volume(let v): state.volume = v
        case .seek(let f): state.elapsed = (state.duration ?? 0) * f
        case .favourite: state.isFavourite.toggle()
        case .toggleShuffle: state.shuffle.toggle()
        case .toggleTimeDisplay: state.showsRemaining.toggle()
        case .cycleVisualizer:
            if state.visualizer != .rotate { state.visualizer = state.visualizer.nextScene }
        case .setVisualizer(let mode): state.visualizer = mode
        case .setVisualizerInterval(let seconds): state.visualizerInterval = seconds
        case .setArtworkColors(let colors): state.artworkColors = colors
        case .eqEnabled(let on): state.equalizer.enabled = on
        case .eqBand(let i, let db):
            state.equalizer.bands[i] = db
            state.equalizer.preset = nil
        case .preamp(let db): state.equalizer.preamp = db
        case .eqReset:
            state.equalizer.bands = [Double](repeating: 0, count: 10)
            state.equalizer.preamp = 0
            state.equalizer.preset = "Flat"
        case .playStation(let row):
            state.currentStation = row
            let station = state.stations[row]
            state.title = station.title
            state.subtitle = station.subtitle
            state.source = station.tag
            state.duration = station.duration
            state.isLive = station.duration == nil
            state.canSeek = station.duration != nil
            state.elapsed = 0
            state.playback = .playing
        case .setAppearance(let a): player?.appearance = a
        case .setTint(let t): player?.tint = t
        case .genreMenu(let point), .moreMenu(let point), .contextMenu(let point):
            let menu = NSMenu()
            for name in ["Deep House", "Techno", "Lo-fi", "Jazz", "Ambient", "Drum & Bass"] {
                menu.addItem(withTitle: name, action: nil, keyEquivalent: "")
            }
            menu.popUp(positioning: nil, at: point, in: nil)
        case .close: NSApp.terminate(nil)
        default: break
        }
        player?.state = state
    }

    private func capture(to path: String) {
        guard let player else { return }
        let image = player.capture(below: backdrop != nil)
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            SkinPreview.log("modern preview: capture failed")
            exit(1)
        }
        do {
            try png.write(to: URL(filePath: path))
            SkinPreview.log("modern preview: captured \(image.width)x\(image.height) to \(path); visualizer running "
                            + "\(player.isVisualizerRunning), \(player.visualizerTicks) ticks (\(player.visualizerDiagnostics)); title scrolling \(player.isTitleScrolling)")
            exit(0)
        } catch {
            SkinPreview.log("modern preview: \(error)")
            exit(1)
        }
    }

    /// 32 seconds of synthesised music through the analyser at 60 frames a second, as JSON for `--scene-sheet`.
    private func dumpFrames(to path: String) {
        var music = SyntheticMusic(step: 48_000 / 60)
        let analyser = VisualiserAnalyser(bridge: nil)
        var nanos: UInt64 = 1_000_000_000
        var frames: [[String: [Float]]] = []
        for _ in 0..<(32 * 60) {
            let samples = music.next(count: VisualiserAnalyser.windowSize)
            nanos += 16_666_667
            let f = samples.withUnsafeBufferPointer { analyser.analyse(samples: $0, nowNanos: nanos) }
            func rounded(_ v: [Float]) -> [Float] { v.map { ($0 * 1000).rounded() / 1000 } }
            frames.append(["bars": rounded(f.bars), "peaks": rounded(f.peaks), "scope": rounded(f.scope)])
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: frames)
            try data.write(to: URL(filePath: path))
            SkinPreview.log("modern preview: wrote \(frames.count) frames to \(path)")
            exit(0)
        } catch {
            SkinPreview.log("modern preview: \(error)")
            exit(1)
        }
    }

    private func renderSceneSheet(to path: String) {
        let mode = options.visualizer ?? .spectrum
        do {
            let json = try options.sheetFrames.map { try Data(contentsOf: URL(filePath: $0)) }
            let result = try ModernDebug.sceneSheet(mode, framesJSON: json, style: options.sheetStyle, tint: options.tint)
            guard let png = result.png else { throw SkinPreview.UsageError(message: "the sheet could not be drawn") }
            try png.write(to: URL(filePath: path))
            SkinPreview.log(String(format: "modern preview: %@ sheet to %@; %.3f ms a frame (worst %.3f)", mode.rawValue, path,
                                   result.mean, result.worst))
            exit(0)
        } catch {
            SkinPreview.log("modern preview: \(error)")
            exit(1)
        }
    }

    /// One frame every 20 ms or so (as fast as captures go), numbered, then quits.
    private func captureBurst(into dir: String, remaining: Int, index: Int) {
        guard let player else { return }
        guard remaining > 0 else {
            SkinPreview.log("modern preview: captured \(index) frames to \(dir)")
            exit(0)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let image = player.capture(below: backdrop != nil),
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(filePath: dir).appending(path: String(format: "frame-%03d.png", index)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            MainActor.assumeIsolated { self?.captureBurst(into: dir, remaining: remaining - 1, index: index + 1) }
        }
    }

    private func showArtworkSheet(capture path: String) {
        let keys: [String?] = [nil, "deep-house", "house", "techno", "lo-fi", "ambient", "drum-and-bass", "jazz"]
        let sheet = ModernDebug.artworkSheet(genreKeys: keys, tint: options.tint)
        let window = NSWindow(contentRect: sheet.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(white: 0.5, alpha: 1)
        window.contentView = sheet
        window.center()
        window.orderFront(nil)
        backdrop = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { exit(1) }
                typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                let create = unsafeBitCast(symbol, to: Create.self)
                let f = window.frame
                let h = NSScreen.screens.first?.frame.height ?? 0
                guard let image = create(CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height),
                                         CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber),
                                         CGWindowImageOption.bestResolution.rawValue)?.takeRetainedValue(),
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
                try? png.write(to: URL(filePath: path))
                exit(0)
            }
        }
    }

    /// Which window a mouse-down at each point would reach (WindowServer's own hit test), skipping the login window's
    /// shield when the screen is locked.
    private func probeHits() {
        guard let window = player?.window else { exit(1) }
        // Clear of anything floating mid-screen (a notification alert sits there on a locked screen).
        window.setFrameOrigin(NSPoint(x: 40, y: 200))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func hit(_ p: CGPoint) -> String {
            var below = 0
            for _ in 0..<8 {
                let n = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: below)
                let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(n)) as? [[String: Any]])?.first
                let owner = info?[kCGWindowOwnerName as String] as? String ?? "?"
                if owner == "loginwindow" { below = n; continue }
                return n == window.windowNumber ? "OURS" : "\(owner)#\(n)"
            }
            return "?"
        }
        let f = window.frame
        let m = Double(ModernGeometry.cardInset)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let points: [(String, CGPoint)] = [
            ("play button", CGPoint(x: f.minX + m + 190, y: f.maxY - m - 184)),
            ("card background", CGPoint(x: f.minX + m + 300, y: f.maxY - m - 40)),
            ("artwork", CGPoint(x: f.minX + m + 60, y: f.maxY - m - 60)),
            ("clear margin", CGPoint(x: f.minX + 6, y: f.maxY - 6)),
        ]
        SkinPreview.log("probe: window \(window.windowNumber) frame \(f) alpha \(window.alphaValue) ignoresMouseEvents \(window.ignoresMouseEvents)")
        // In-process: what AppKit's own routing hits (it starts at the frame view, the content view's superview).
        if let content = window.contentView, let frameView = content.superview {
            for (name, p) in [("play button", CGPoint(x: m + 190, y: f.height - m - 184)), ("card background", CGPoint(x: m + 300, y: f.height - m - 40))] {
                var chain: [String] = []
                var v = frameView.hitTest(p)
                while let view = v, chain.count < 8 {
                    chain.append(String(describing: type(of: view)))
                    v = view.superview
                }
                SkinPreview.log("probe: frame-view hitTest at \(name) → \(chain.joined(separator: " < "))")
            }
            SkinPreview.log("probe: frame view \(type(of: frameView)), subviews \(frameView.subviews.map { String(describing: type(of: $0)) })")
            // A click on Next through AppKit's routing (the mouse-up queued first, for the button's tracking loop).
            let next = CGPoint(x: m + 190 + 72, y: f.height - m - 184)
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: next, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                   pressure: type == .leftMouseUp ? 0 : 1)
            }
            if let down = event(.leftMouseDown), let up = event(.leftMouseUp) {
                probedEvents = []
                NSApp.postEvent(up, atStart: false)
                window.sendEvent(down)
                SkinPreview.log("probe: click on Next delivered \(probedEvents)")
            }
        }
        for (name, p) in points { SkinPreview.log("probe: \(name) → \(hit(p))") }
        player?.checkClickRoutingForProbe(at: points[1].1)
        SkinPreview.log("probe: click routing \(player?.clickRouting ?? "-")")
        exit(0)
    }

    /// A stand-in wallpaper: soft colour fields and some shapes and type for the glass to bend.
    private func showBackdrop(behind window: NSWindow) {
        let frame = window.frame.insetBy(dx: -20, dy: -20)
        let backdrop = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let base = CAGradientLayer()
        base.frame = view.bounds
        base.colors = [NSColor(srgbRed: 0.98, green: 0.55, blue: 0.36, alpha: 1).cgColor,
                       NSColor(srgbRed: 0.85, green: 0.28, blue: 0.52, alpha: 1).cgColor,
                       NSColor(srgbRed: 0.22, green: 0.3, blue: 0.75, alpha: 1).cgColor]
        base.startPoint = CGPoint(x: 0, y: 1)
        base.endPoint = CGPoint(x: 1, y: 0)
        view.layer?.addSublayer(base)
        for (i, color) in [NSColor.systemYellow, .systemTeal, .white, .systemPurple, .black, .systemGreen].enumerated() {
            let blob = CALayer()
            let size = CGFloat(90 + (i * 37) % 120)
            blob.frame = CGRect(x: CGFloat((i * 151) % Int(frame.width)), y: CGFloat((i * 211) % Int(frame.height)), width: size,
                                height: size)
            blob.cornerRadius = size / 2
            blob.backgroundColor = color.withAlphaComponent(0.85).cgColor
            view.layer?.addSublayer(blob)
        }
        for row in 0..<6 {
            let text = CATextLayer()
            text.string = "SUDAMP  SUDAMP  SUDAMP"
            text.fontSize = 46
            text.font = NSFont.systemFont(ofSize: 46, weight: .black)
            text.foregroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
            text.contentsScale = 2
            text.frame = CGRect(x: -30 + CGFloat(row % 2) * 60, y: CGFloat(row) * 130 + 20, width: frame.width + 100, height: 60)
            view.layer?.addSublayer(text)
        }
        backdrop.contentView = view
        backdrop.order(.below, relativeTo: window.windowNumber)
        self.backdrop = backdrop
    }
}

/// A few seconds of dance music, synthesised a frame at a time: 124 bpm four-to-the-floor kick, an off-beat bassline,
/// open hats and a slow pad. Deterministic.
struct SyntheticMusic {
    private var t = 0
    private let rate = 48_000.0
    private var noise: UInt64 = 0x2545_F491_4F6C_DD1D
    private var window: [Float] = []
    /// Samples per frame.
    private let step: Int

    init(step: Int = 48_000 / 30) { self.step = step }

    /// The newest `count` samples after advancing one frame.
    mutating func next(count: Int) -> [Float] {
        for _ in 0..<step {
            window.append(sample(t))
            t += 1
        }
        if window.count > count { window.removeFirst(window.count - count) }
        return window
    }

    private mutating func sample(_ i: Int) -> Float {
        let time = Double(i) / rate
        let beat = 60.0 / 124
        let inBeat = time.truncatingRemainder(dividingBy: beat)
        // Sixteen bars: eight with the kick, four of breakdown (no kick, the pad up), four with the kick again.
        let bar = Int(time / (beat * 4)) % 16
        let breakdown = (8..<12).contains(bar)
        // Kick: a falling sine with a fast decay.
        let kickFreq = 45 + 90 * exp(-inBeat * 30)
        let kick = breakdown ? 0 : sin(2 * .pi * kickFreq * inBeat) * exp(-inBeat * 9)
        // Bass on the off-beat.
        let off = (time + beat / 2).truncatingRemainder(dividingBy: beat)
        let notes = [55.0, 55, 65.4, 49]
        let note = notes[Int(time / (beat * 4)) % notes.count]
        let bass = 0.5 * sin(2 * .pi * note * time) * exp(-off * 5) * (off < beat * 0.45 ? 1 : 0.2)
        // Hats: noise bursts on the off-beat eighths.
        noise ^= noise << 13
        noise ^= noise >> 7
        noise ^= noise << 17
        let white = Double(Int64(bitPattern: noise)) / Double(Int64.max)
        let eighth = time.truncatingRemainder(dividingBy: beat / 2)
        let hat = 0.18 * white * exp(-eighth * 40)
        // Pad: a slow chord with a filter that opens and closes.
        let swell = breakdown ? 1 : 0.5 + 0.5 * sin(2 * .pi * time / 8)
        let pad = 0.08 * swell * (sin(2 * .pi * 220 * time) + sin(2 * .pi * 277.2 * time) + 0.6 * sin(2 * .pi * 1318 * time))
        return Float(max(-1, min(1, 0.55 * kick + bass + hat + pad)))
    }
}
