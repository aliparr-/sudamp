// SPDX-License-Identifier: GPL-3.0-or-later
// `sudamp --modern-preview [--appearance auto|light|dark] [--tint <name>] [--panels equalizer,stations]
//                          [--state playing|paused|idle|live|tuning|failed|engine] [--backdrop]
//                          [--capture <file.png>] [--capture-delay <seconds>] [--exit-after <seconds>] [--probe-hits]
//                          [--open-later|--close-later equalizer|stations]`
//
// Opens the modern skin with an animated fake player state (ticking time, a fake visualiser), the way
// `--skin-preview` does for the classic skins: no audio, no network, nothing persisted. Every ModernEvent is logged
// to stderr and its obvious local effect applied. `--backdrop` puts a colourful stand-in wallpaper behind the
// window, so the glass has something to refract; `--capture` writes what the screen shows of both windows (own
// windows need no Screen Recording permission) and quits. `--probe-hits` prints where a click on the player would
// go, as WindowServer routes it (which window) and as AppKit does (which view), and clicks Next through AppKit.

import AppKit
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
    }

    static let states = ["playing", "paused", "idle", "live", "tuning", "failed", "engine"]
    static let usage = "usage: sudamp --modern-preview [--appearance auto|light|dark] [--tint "
        + ModernTint.allCases.map(\.rawValue).joined(separator: "|") + "] [--panels equalizer,stations] [--state "
        + states.joined(separator: "|") + "] [--backdrop] [--capture <file.png>] [--capture-delay <s>] [--exit-after <s>]"

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
    private var phase = 0.0
    /// Events seen while probing.
    private var probedEvents: [String] = []

    init(options: ModernPreview.Options) {
        self.options = options
        state = ModernPreview.state(options.state)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = options.artworkSheet { return showArtworkSheet(capture: path) }
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
        if options.capture != nil { player.pausesWhenOccluded = false }
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
        if let seconds = options.exitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    private func tick() {
        guard state.playback == .playing, !state.working else { return }
        state.elapsed += 1
        player?.state = state
    }

    /// Bars that look like music: a kick, a bassline and hats moving at different rates.
    private func fakeFrame() -> ModernVisualizerFrame {
        phase += 1.0 / 30
        let t = phase
        let kick = Float(pow(max(0, sin(t * 2 * .pi * 2.05)), 6))
        let bars = (0..<ModernVisualizerFrame.barCount).map { i -> Float in
            let x = Float(i) / Float(ModernVisualizerFrame.barCount - 1)
            let body = 0.55 * (1 - x) * (0.6 + 0.4 * Float(sin(t * 1.7 + Double(i) * 0.6)))
            let hats = x > 0.6 ? 0.35 * Float(pow(max(0, sin(t * 2 * .pi * 4.1 + Double(i))), 4)) : 0
            return min(1, body + kick * (1 - x) * 0.55 + hats + 0.06)
        }
        let scope = (0..<ModernVisualizerFrame.scopeCount).map { i -> Float in
            let x = Double(i) / 75
            return Float(0.55 * sin(x * 2 * .pi * 2 + t * 6) * (0.5 + 0.5 * Double(kick)) + 0.2 * sin(x * 2 * .pi * 9 + t * 11))
        }
        return ModernVisualizerFrame(bars: bars, scope: scope)
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
            let all = ModernPlayerState.Visualizer.allCases
            state.visualizer = all[((all.firstIndex(of: state.visualizer) ?? 0) + 1) % all.count]
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
