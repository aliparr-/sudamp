// SPDX-License-Identifier: GPL-3.0-or-later
// `sudamp --skin-preview [--skin <wsz>] [--scale 1|1.2|1.5|2|2.5|3] [--exit-after <seconds>] [--verify-capture]`
//
// Opens Main + Equalizer + Playlist docked, with an animated fake player state (scrolling title, ticking time,
// fake visualiser), so the owner can try a skin before M5 wires SkinUI to playback. Every SkinControlEvent is
// logged to stderr and the obvious local effects are applied (transport, sliders, EQ, toggles, time mode,
// visualiser mode, station rows); window-level events (shade, scale, always on top, EQ/PL toggles, minimise)
// are handled by WindowManager. Menus at the genre-menu anchors (marquee click, options button, right-click)
// show a stand-in genre menu. No audio, no network, nothing persisted.
//
// `--exit-after` quits after the given time (for terminal gates); `--ignore-occlusion` keeps animating while the
// windows are covered (e.g. by the lock screen), for CPU measurements. Debug builds only: `--exercise` drives the
// windows with synthetic in-process mouse events (drag Main's docked cluster, drag and re-dock the EQ, shade by
// double-click, EQ toggle, volume drag, clutter D) and checks the results against AppKit and WindowServer;
// `--verify-capture` captures the preview's own windows before quitting and checks every skin pixel is a
// uniform block equal to the composer frame (own-window capture needs no Screen Recording permission, S1).
// The exit status is 0 only when the requested checks pass.

import AppKit
import SkinKit
import SkinUI

enum SkinPreview {
    struct Options: Equatable {
        var skinPath: String?
        var scale: Double?
        var exitAfter: Double?
        var verifyCapture = false
        var exercise = false
        var ignoreOcclusion = false
    }

    static let usage = "usage: sudamp --skin-preview [--skin <file.wsz>] [--scale 1|1.2|1.5|2|2.5|3] [--exit-after <seconds>] [--verify-capture] [--exercise] [--ignore-occlusion]"

    struct UsageError: Error, Equatable {
        let message: String
    }

    static func parse(_ arguments: [String]) -> Result<Options, UsageError> {
        var options = Options()
        var i = arguments.firstIndex(of: "--skin-preview").map { $0 + 1 } ?? arguments.count
        func value(_ flag: String) -> String? {
            guard i + 1 < arguments.count else { return nil }
            i += 1
            return arguments[i]
        }
        while i < arguments.count {
            let argument = arguments[i]
            switch argument {
            case "--skin":
                guard let path = value(argument) else { return .failure(UsageError(message: "--skin needs a path")) }
                options.skinPath = path
            case "--scale":
                guard let text = value(argument), let scale = Double(text), SkinScale.allowed.contains(scale) else {
                    let scales = SkinScale.allowed.map { SkinScale.label($0).dropLast() }.joined(separator: ", ")
                    return .failure(UsageError(message: "--scale must be one of \(scales)"))
                }
                options.scale = scale
            case "--exit-after":
                guard let text = value(argument), let seconds = Double(text), seconds > 0 else {
                    return .failure(UsageError(message: "--exit-after needs a positive number of seconds"))
                }
                options.exitAfter = seconds
            case "--verify-capture":
                options.verifyCapture = true
            case "--exercise":
                options.exercise = true
            case "--ignore-occlusion":
                options.ignoreOcclusion = true
            default:
                return .failure(UsageError(message: "unknown argument \(argument)"))
            }
            i += 1
        }
        return .success(options)
    }

    /// Kept alive for the life of the app (NSApplication.delegate is weak).
    private static var controller: PreviewController?

    static func run(arguments: [String]) {
        let options: Options
        switch parse(arguments) {
        case .success(let parsed): options = parsed
        case .failure(let error):
            log("skin preview: \(error.message)\n\(usage)")
            exit(2)
        }
        let skin: Skin
        if let path = options.skinPath {
            let result = SkinLoader.load(url: URL(fileURLWithPath: path))
            guard let loaded = result.skin else {
                log("skin preview: skin rejected: \(result.rejection.map { "\($0)" } ?? "unknown error")")
                exit(3)
            }
            skin = loaded
        } else {
            skin = SudampDark.skin
        }
        log("skin preview: skin=\"\(skin.name)\" fallbackSheets=\(skin.report.fallbackSheets) regions=\(skin.report.regionSections)")
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let controller = PreviewController(skin: skin, options: options)
        Self.controller = controller
        app.delegate = controller
        app.run()
    }

    static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// Drives the preview: fake state, event log, local effects, menus.
final class PreviewController: NSObject, NSApplicationDelegate {
    private let skin: Skin
    private let options: SkinPreview.Options
    private var manager: WindowManager?
    private var state = PreviewController.initialState()
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()
    private var eventCount = 0
    private var exerciseTask: Task<Bool, Never>?

    init(skin: Skin, options: SkinPreview.Options) {
        self.skin = skin
        self.options = options
    }

    static let genres = ["Deep House", "Techno", "Lo-fi"]

    static let stations: [SkinPlayerState.PlaylistRow] = [
        .init(tag: .radio, title: "Deep House Radio"),
        .init(tag: .youtube, title: "Solar Crew - Sunset Sessions", duration: 3720),
        .init(tag: .soundcloud, title: "Nightdrive (Extended Mix)", duration: 461),
        .init(tag: .mixcloud, title: "Warehouse Session 004", duration: 3492),
        .init(tag: .youtube, title: "Lo-fi Beats 24/7"),
        .init(tag: .radio, title: "Techno Live FM"),
        .init(tag: .soundcloud, title: "Afterhours Tape", duration: 2711),
        .init(tag: .youtube, title: "Rainy Window Lo-fi Mix", duration: 5400),
        .init(tag: .mixcloud, title: "Berlin Basement 12", duration: 4210),
        .init(tag: .radio, title: "Chillout Lounge FM"),
        .init(tag: .youtube, title: "Analog Dreams - Live Set", duration: 3305),
        .init(tag: .soundcloud, title: "Midnight Garage", duration: 389),
        .init(tag: .youtube, title: "Deep Focus Radio"),
        .init(tag: .mixcloud, title: "Sunday Morning Selections", duration: 3600),
        .init(tag: .radio, title: "Minimal Waves"),
        .init(tag: .youtube, title: "Coastal Drive - House Mix", duration: 2980),
    ]

    static func initialState() -> SkinPlayerState {
        var s = SkinPlayerState()
        s.playlist = stations
        s.currentRow = 1
        s.title = "[DEEP HOUSE] SOLAR CREW - SUNSET SESSIONS (SKIN PREVIEW)"
        s.playState = .playing
        s.elapsed = 83
        s.duration = 3720
        s.kbps = 128
        s.khz = 48
        s.stereo = true
        s.volume = 0.75
        s.equalizer.bands = [3, 4.5, 2, 0, -1.5, -2, 0, 2.5, 4, 5]
        s.equalizer.preamp = 1.5
        return s
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        var configuration = WindowManager.Configuration()
        configuration.scale = options.scale
        configuration.initialOpen = [.main, .equalizer, .playlist]
        let manager = WindowManager(skin: skin, configuration: configuration)
        self.manager = manager
        manager.playerState = state
        manager.visualizerProvider = { [weak self] in self?.fakeVisualizer() }
        manager.onEvent = { [weak self] event, role in self?.handle(event, from: role) }
        manager.pausesWhenOccluded = !options.ignoreOcclusion
        manager.show()
        NSApp.activate()
        let backing = NSScreen.main?.backingScaleFactor ?? 0
        SkinPreview.log("skin preview: windows created (scale \(SkinScale.label(manager.scale)), display backing \(backing)x):\n"
                        + manager.describeFrames())
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        #if DEBUG
        if options.exercise {
            exerciseTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                return await PreviewExercise.run(manager)
            }
        }
        #else
        if options.exercise { SkinPreview.log("skin preview: --exercise needs a debug build") }
        #endif
        if let seconds = options.exitAfter {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                await self?.finish()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        manager?.close()
    }

    private func finish() async {
        guard let manager else { return }
        let exercised = await exerciseTask?.value ?? true
        let ticks = SkinWindowRole.allCases.map { role -> String in
            guard let window = manager.windows[role] else { return "\(role)=?" }
            let occluded = !window.occlusionState.contains(.visible)
            return "\(role)=\(window.skinView.displayTicks)\(occluded ? " (occluded)" : "")"
        }
        SkinPreview.log("skin preview: \(eventCount) events; display-link ticks \(ticks.joined(separator: " ")); final frames:\n"
                        + manager.describeFrames())
        var captured = true
        #if DEBUG
        if options.verifyCapture {
            // Freeze the fake clock and the display links so the frames stop changing, let them commit, capture.
            timer?.invalidate()
            timer = nil
            for window in manager.windows.values {
                window.skinView.stopDisplayLink()
                window.skinView.tick()
            }
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(500))
            captured = CaptureCheck.run(manager)
        }
        #else
        if options.verifyCapture { SkinPreview.log("skin preview: --verify-capture needs a debug build") }
        #endif
        exitPreview(ok: exercised && captured)
    }

    private func exitPreview(ok: Bool) {
        SkinPreview.log("skin preview: exiting (\(ok ? "ok" : "a check FAILED"))")
        manager?.close()
        exit(ok ? 0 : 1)
    }

    // MARK: Fake player

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        if state.playState == .playing {
            state.elapsed += dt
            if let duration = state.duration, state.elapsed >= duration { state.elapsed = 0 }
        }
        push()
    }

    private func push() {
        manager?.playerState = state
    }

    /// 19 bars from drifting sines, a two-tone scope.
    private func fakeVisualizer() -> VisualizerSnapshot? {
        guard state.playState == .playing else { return .silent }
        let t = CACurrentMediaTime()
        let bars: [Float] = (0..<VisualizerSnapshot.barCount).map { i in
            let x = Double(i)
            let level = 0.55 + 0.35 * sin(t * 3.1 + x * 0.7) * cos(t * 1.3 - x * 0.2) - x * 0.012
            return Float(max(0, min(1, level * state.volume * 1.3)))
        }
        let scope: [Float] = (0..<VisualizerSnapshot.scopeCount).map { i in
            let x = Double(i) / Double(VisualizerSnapshot.scopeCount)
            return Float(0.6 * sin(2 * .pi * (x * 3 + t * 0.9)) + 0.25 * sin(2 * .pi * (x * 11 - t * 2.3)))
        }
        return VisualizerSnapshot(bars: bars, scope: scope)
    }

    private func handle(_ event: SkinControlEvent, from role: SkinWindowRole) {
        eventCount += 1
        SkinPreview.log("event: \(event) [\(role)]")
        switch event {
        case .play:
            if state.playState == .stopped { state.elapsed = 0 }
            state.playState = .playing
        case .pause:
            state.playState = state.playState == .playing ? .paused : (state.playState == .paused ? .playing : .stopped)
        case .stop:
            state.playState = .stopped
            state.elapsed = 0
        case .next: select(row: ((state.currentRow ?? -1) + 1) % state.playlist.count)
        case .previous: select(row: ((state.currentRow ?? 1) - 1 + state.playlist.count) % state.playlist.count)
        case .seek(let fraction):
            if let duration = state.duration { state.elapsed = fraction * duration }
        case .volume(let v): state.volume = v
        case .balance(let b): state.balance = b
        case .eqBand(let index, let db): state.equalizer.bands[index] = db
        case .preamp(let db): state.equalizer.preamp = db
        case .eqToggle: state.equalizer.enabled.toggle()
        case .eqAuto: state.equalizer.auto.toggle()
        case .eqSetAll(let db): state.equalizer.bands = [Double](repeating: db, count: 10)
        case .shuffle: state.shuffle.toggle()
        case .repeat: state.repeat.toggle()
        case .timeModeToggle: state.timeDisplay = state.timeDisplay == .elapsed ? .remaining : .elapsed
        case .visualizerModeToggle:
            state.visualizerMode = switch state.visualizerMode {
            case .spectrum: .oscilloscope
            case .oscilloscope: .off
            case .off: .spectrum
            }
        case .playlistRowActivated(let index): select(row: index)
        case .marqueeClick(let point), .optionsMenu(let point), .clutter(.options, let point):
            popUp(genreMenu(), at: point)
        case .contextMenu(let point):
            popUp(contextMenu(), at: point)
        case .presetsMenu(let point):
            popUp(presetsMenu(), at: point)
        case .close(.main):
            NSApp.terminate(nil)
        default:
            break
        }
        push()
    }

    private func select(row: Int) {
        guard row >= 0, row < state.playlist.count else { return }
        let station = state.playlist[row]
        state.currentRow = row
        state.duration = station.duration
        state.elapsed = 0
        state.playState = .playing
        state.title = "[\(Self.genres[row % Self.genres.count].uppercased())] \(station.title.uppercased())"
        manager?.scrollPlaylist(toRow: max(0, row - 6))
    }

    // MARK: Menus

    private func popUp(_ menu: NSMenu, at screenPoint: CGPoint) {
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    private func item(_ title: String, _ action: Selector, tag: Int = 0, on: Bool = false, key: String = "",
                      represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.tag = tag
        item.representedObject = represented
        item.state = on ? .on : .off
        return item
    }

    private func genreMenu() -> NSMenu {
        let menu = NSMenu(title: "Genre")
        for (index, genre) in Self.genres.enumerated() {
            menu.addItem(item(genre, #selector(pickGenre(_:)), tag: index))
        }
        menu.addItem(.separator())
        menu.addItem(item("Surprise Me", #selector(pickGenre(_:)), tag: -1))
        return menu
    }

    private func presetsMenu() -> NSMenu {
        let menu = NSMenu(title: "Presets")
        menu.addItem(item("Flat", #selector(flatPreset(_:))))
        return menu
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "sudamp")
        let genre = NSMenuItem(title: "Genre", action: nil, keyEquivalent: "")
        genre.submenu = genreMenu()
        menu.addItem(genre)
        menu.addItem(.separator())
        for item in viewItems() { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(NSApplication.terminate(_:))))
        menu.items.last?.target = NSApp
        return menu
    }

    private func viewItems() -> [NSMenuItem] {
        guard let manager else { return [] }
        // ⌘D (double size) has no visible item: Scale 2x is the same thing.
        let doubleSize = item("Double Size", #selector(toggleScale(_:)), key: "d")
        doubleSize.keyEquivalentModifierMask = .command
        doubleSize.isHidden = true
        doubleSize.allowsKeyEquivalentWhenHidden = true
        let scales = SkinScale.allowed.map { scale in
            item("Scale \(SkinScale.label(scale))", #selector(setScale(_:)), on: manager.scale == scale, represented: scale)
        }
        return [doubleSize] + scales + [
            item("Always on Top", #selector(toggleOnTop(_:)), on: manager.alwaysOnTop),
            item("Window Shade", #selector(toggleShade(_:)), on: manager.isShaded(.main)),
            item("Equalizer", #selector(toggleEqualizer(_:)), on: manager.isOpen(.equalizer)),
            item("Playlist", #selector(togglePlaylist(_:)), on: manager.isOpen(.playlist)),
            item("Region Shaping", #selector(toggleRegion(_:)), on: manager.regionEnabled),
            item("Regroup Windows", #selector(regroup(_:))),
        ]
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Skin Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.delegate = self
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        NSApp.mainMenu = main
    }

    @objc private func pickGenre(_ sender: NSMenuItem) {
        let index = sender.tag >= 0 ? sender.tag : Int.random(in: 0..<Self.genres.count)
        SkinPreview.log("menu: genre \(Self.genres[index])")
        select(row: index)
        push()
    }

    @objc private func flatPreset(_ sender: NSMenuItem) {
        state.equalizer.bands = [Double](repeating: 0, count: 10)
        state.equalizer.preamp = 0
        push()
    }

    @objc private func toggleScale(_ sender: NSMenuItem) { manager?.toggleScale(); logFrames() }
    @objc private func setScale(_ sender: NSMenuItem) {
        guard let scale = sender.representedObject as? Double else { return }
        manager?.setScale(scale)
        logFrames()
    }
    @objc private func toggleOnTop(_ sender: NSMenuItem) { manager.map { $0.setAlwaysOnTop(!$0.alwaysOnTop) } }
    @objc private func toggleShade(_ sender: NSMenuItem) { manager?.toggleShade(.main) }
    @objc private func toggleEqualizer(_ sender: NSMenuItem) { manager?.toggleOpen(.equalizer) }
    @objc private func togglePlaylist(_ sender: NSMenuItem) { manager?.toggleOpen(.playlist) }
    @objc private func toggleRegion(_ sender: NSMenuItem) { manager.map { $0.setRegionEnabled(!$0.regionEnabled) } }
    @objc private func regroup(_ sender: NSMenuItem) { manager?.regroup(); logFrames() }

    private func logFrames() {
        if let manager { SkinPreview.log("frames:\n\(manager.describeFrames())") }
    }
}

extension PreviewController: NSMenuDelegate {
    /// Rebuilds the View menu with current check marks each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in viewItems() { menu.addItem(item) }
    }
}

#if DEBUG
/// Own-window capture check (debug only): with the display links stopped, every on-screen skin pixel must be a
/// uniform block of device pixels whose colour matches the composite of the base frame and the marquee and
/// visualiser layers (within colour-management rounding), and region.txt pixels must be transparent.
enum CaptureCheck {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func run(_ manager: WindowManager) -> Bool {
        // CGWindowListCreateImage is obsoleted in the macOS 15 SDK but still exported; looked up at run time like
        // spike S1, because ScreenCaptureKit would need Screen Recording permission.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            SkinPreview.log("capture: CGWindowListCreateImage not found")
            return false
        }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        guard SkinScale.isWhole(manager.scale) else {
            SkinPreview.log("capture: needs scale 1x, 2x or 3x; at \(SkinScale.label(manager.scale)) skin pixels are not "
                            + "uniform blocks")
            return false
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var ok = true
        for role in SkinWindowRole.allCases {
            guard let window = manager.windows[role], window.isVisible, let base = window.skinView.baseBitmap else { continue }
            let f = window.frame
            let rect = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            let options = CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
            guard let image = create(rect, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber),
                                     options)?.takeRetainedValue() else {
                SkinPreview.log("capture: \(role): no image")
                ok = false
                continue
            }
            // Only pixels on a display can be captured; a 3x stack can run off a 1080p screen.
            let onScreen = NSScreen.screens.map { $0.frame.intersection(f) }.filter { !$0.isNull && !$0.isEmpty }
            let s = CGFloat(window.skinView.scale)
            let skinRects = onScreen.map { r in
                IntRect(Int(((r.minX - f.minX) / s).rounded(.up)), Int(((f.maxY - r.maxY) / s).rounded(.up)),
                        Int((r.width / s).rounded(.down)), Int((r.height / s).rounded(.down)))
            }
            let result = compare(image, base: base, view: window.skinView, within: skinRects)
            SkinPreview.log("capture: \(role) \(image.width)x\(image.height) px for \(base.width)x\(base.height) skin px "
                            + "(\(skinRects.map(\.description)) on screen) at scale "
                            + "\(SkinScale.label(window.skinView.scale)): \(result.nonUniform) non-uniform blocks, max channel delta \(result.maxDelta), "
                            + "\(result.checked) pixels checked (marquee and visualiser layers included), "
                            + "\(result.transparent) region pixels transparent with \(result.regionLeaks) leaks"
                            + (result.mismatches.isEmpty ? "" : "; first mismatches at skin px \(result.mismatches)"))
            if result.nonUniform > 0 || result.maxDelta > 3 || result.checked == 0 || result.regionLeaks > 0 { ok = false }
        }
        return ok
    }

    struct Result {
        var checked = 0
        var nonUniform = 0
        var maxDelta = 0
        /// Skin pixels differing by more than 3 per channel (first few, for the log).
        var mismatches: [IntPoint] = []
        /// region.txt pixels (alpha 0) checked, and how many showed anything on screen.
        var transparent = 0
        var regionLeaks = 0
    }

    /// What the layer tree should show at 1x: the base frame with the marquee and visualiser layers on top.
    static func expectedComposite(_ base: Bitmap, view: SkinView) -> (bitmap: Bitmap, skip: [IntRect]) {
        var composite = base
        var skip: [IntRect] = []
        if view.kind == .main {
            if let marquee = view.marqueeBitmap { composite.draw(marquee, at: MainLayout.marqueeText.origin) }
            if view.isTitleOverlayShown { skip.append(MainLayout.marqueeText) }  // Core Text is not pixel art
        }
        let visRect = view.kind == .main ? MainLayout.visualizer : ShadeLayout.visualizer
        if (view.kind == .main || view.kind == .shade), view.isVisualizerShown, let vis = view.visualizerBitmap {
            composite.draw(vis, at: visRect.origin)
        }
        return (composite, skip)
    }

    static func compare(_ image: CGImage, base: Bitmap, view: SkinView, within: [IntRect]) -> Result {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        var result = Result()
        guard drawn, base.width > 0, w % base.width == 0, w / base.width == h / base.height else { return result }
        let block = w / base.width
        let (expectedFrame, skip) = expectedComposite(base, view: view)
        for sy in 0..<base.height {
            for sx in 0..<base.width where !skip.contains(where: { $0.contains(IntPoint(sx, sy)) })
                && within.contains(where: { $0.contains(IntPoint(sx, sy)) }) {
                let expected = expectedFrame[sx, sy]
                let first = (sy * block * w + sx * block) * 4
                if expected.a == 0 {
                    // region.txt: transparent on screen too (clicks pass through there, S1).
                    result.transparent += 1
                    if pixels[first + 3] != 0 { result.regionLeaks += 1 }
                    continue
                }
                var uniform = true
                for dy in 0..<block {
                    for dx in 0..<block {
                        let i = ((sy * block + dy) * w + sx * block + dx) * 4
                        if pixels[i] != pixels[first] || pixels[i + 1] != pixels[first + 1] || pixels[i + 2] != pixels[first + 2]
                            || pixels[i + 3] != pixels[first + 3] {
                            uniform = false
                        }
                    }
                }
                if !uniform { result.nonUniform += 1 }
                let delta = max(abs(Int(pixels[first]) - Int(expected.r)), abs(Int(pixels[first + 1]) - Int(expected.g)),
                                abs(Int(pixels[first + 2]) - Int(expected.b)), abs(Int(pixels[first + 3]) - 255))
                result.maxDelta = max(result.maxDelta, delta)
                if delta > 3, result.mismatches.count < 8 { result.mismatches.append(IntPoint(sx, sy)) }
                result.checked += 1
            }
        }
        return result
    }
}

/// Drives the preview's windows with synthetic mouse events sent through `NSWindow.sendEvent` (in-process: no
/// Accessibility permission, nothing posted to other apps) and checks what AppKit and WindowServer report.
@MainActor enum PreviewExercise {
    static func run(_ manager: WindowManager) async -> Bool {
        guard let main = manager.windows[.main], let eq = manager.windows[.equalizer],
              let playlist = manager.windows[.playlist] else { return false }
        var ok = true
        func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
            SkinPreview.log("exercise: \(name): \(passed ? "ok" : "FAILED") \(passed ? "" : detail())")
            if !passed { ok = false }
        }
        func settle() async {
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(200))
        }
        func screenPoint(_ window: SkinWindow, skin: CGPoint) -> CGPoint {
            let f = SkinScale.pointsPerSkinPixel(window.skinView.kind, scale: window.skinView.scale)
            let inWindow = window.skinView.convert(CGPoint(x: skin.x * f.x, y: skin.y * f.y), to: nil)
            return window.convertPoint(toScreen: inWindow)
        }
        func send(_ type: NSEvent.EventType, _ window: SkinWindow, at screen: CGPoint, clicks: Int = 1) {
            guard let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screen),
                                                 modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
            else { return }
            window.sendEvent(event)
        }
        func click(_ window: SkinWindow, skin: CGPoint, clicks: Int = 1) {
            let at = screenPoint(window, skin: skin)
            for n in 1...clicks {
                send(.leftMouseDown, window, at: at, clicks: n)
                send(.leftMouseUp, window, at: at, clicks: n)
            }
        }
        /// Presses at a skin point, drags by `delta` points in steps, releases; returns whether children were attached.
        func drag(_ window: SkinWindow, skin: CGPoint, by delta: CGVector) -> Int {
            let start = screenPoint(window, skin: skin)
            send(.leftMouseDown, window, at: start)
            var attached = 0
            for k in 1...6 {
                let t = CGFloat(k) / 6
                send(.leftMouseDragged, window, at: CGPoint(x: start.x + delta.dx * t, y: start.y + delta.dy * t))
                attached = max(attached, main.childWindows?.count ?? 0)
            }
            send(.leftMouseUp, window, at: CGPoint(x: start.x + delta.dx, y: start.y + delta.dy))
            return attached
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func serverFrame(_ window: NSWindow) -> CGRect? {
            guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]],
                  let bounds = info.first?[kCGWindowBounds as String], let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary)
            else { return nil }
            return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        func frames() -> [CGRect] { [main.frame, eq.frame, playlist.frame] }

        // 1. Dragging Main's title bar carries the docked EQ and Playlist (attached only during the drag).
        let before = frames()
        let attached = drag(main, skin: CGPoint(x: 150, y: 5), by: CGVector(dx: 60, dy: -40))
        await settle()
        let after = frames()
        check("main drag moves the docked cluster",
              zip(before, after).allSatisfy { $1.origin == CGPoint(x: $0.minX + 60, y: $0.minY - 40) && $1.size == $0.size },
              "\(before) -> \(after)")
        check("cluster attached as child windows during the drag only", attached == 2 && (main.childWindows ?? []).isEmpty,
              "attached \(attached), after \(main.childWindows?.count ?? 0)")
        let server = [main, eq, playlist].map(serverFrame)
        check("WindowServer reports the same frames", zip(server, after).allSatisfy { $0 == $1 }, "\(server)")

        // 2. The EQ drags alone, then snaps back under Main from 8 points away.
        let mainFrame = main.frame, playlistFrame = playlist.frame
        _ = drag(eq, skin: CGPoint(x: 150, y: 5), by: CGVector(dx: 300, dy: 0))
        await settle()
        check("equalizer drags alone", eq.frame.minX == mainFrame.minX + 300 && main.frame == mainFrame
              && playlist.frame == playlistFrame, "eq \(eq.frame)")
        _ = drag(eq, skin: CGPoint(x: 150, y: 5), by: CGVector(dx: -294, dy: -2))
        await settle()
        check("equalizer snaps back under Main (15 px)", eq.frame.minX == mainFrame.minX && eq.frame.maxY == mainFrame.minY,
              "eq \(eq.frame), main \(mainFrame)")

        // 3. Double-clicking the title bar shades Main; what hangs below follows its bottom edge.
        click(main, skin: CGPoint(x: 150, y: 5), clicks: 2)
        await settle()
        let s = SkinScale.pointsPerSkinPixel(.main, scale: manager.scale).x
        let shadeHeight = SkinScale.pointSize(.shade, scale: manager.scale).height
        check("double-click shades Main", manager.isShaded(.main) && main.frame.height == shadeHeight
              && main.frame.maxY == mainFrame.maxY
              && eq.frame.maxY == main.frame.minY && playlist.frame.maxY == eq.frame.minY, "main \(main.frame) eq \(eq.frame)")
        click(main, skin: CGPoint(x: 40, y: 7), clicks: 2)  // the strip's own title area ((150, 5) is its mini time)
        await settle()
        check("double-click unshades Main", !manager.isShaded(.main) && main.frame == mainFrame && eq.frame.maxY == main.frame.minY)

        // 4. Main's EQ button closes and reopens the equalizer window.
        let toggle = MainLayout.eqToggle
        let eqButton = CGPoint(x: Double(toggle.x) + Double(toggle.width) / 2, y: Double(toggle.y) + Double(toggle.height) / 2)
        click(main, skin: eqButton)
        await settle()
        check("EQ button hides the equalizer", !eq.isVisible && !manager.isOpen(.equalizer))
        click(main, skin: eqButton)
        await settle()
        check("EQ button shows it again", eq.isVisible && manager.isOpen(.equalizer))

        // 5. The volume thumb drags the volume down; the preview applies it and the thumb is redrawn there.
        let volume = manager.playerState.volume
        let thumb = CGPoint(x: Double(MainLayout.volume.x) + 51 * volume + 7, y: 63)
        _ = drag(main, skin: thumb, by: CGVector(dx: -20 * s, dy: 0))
        await settle()
        let expected = max(0, volume - 20.0 / 51)
        check("volume slider drag", abs(manager.playerState.volume - expected) < 0.01
              && main.skinView.baseState?.volume == Int((expected * 100).rounded()),
              "volume \(manager.playerState.volume), expected \(expected)")

        // 6. Clutter D toggles the scale; docked windows stay docked.
        let scale = manager.scale
        click(main, skin: CGPoint(x: 14, y: 51))
        await settle()
        func mainWidth(_ scale: Double) -> CGFloat { SkinScale.pointSize(.main, scale: scale).width }
        check("clutter D toggles the scale", manager.scale != scale && main.frame.width == mainWidth(manager.scale)
              && eq.frame.maxY == main.frame.minY && playlist.frame.maxY == eq.frame.minY, "scale \(manager.scale)")
        click(main, skin: CGPoint(x: 14, y: 51))
        await settle()
        let back: Double = scale >= 2 ? 2 : 1  // the toggle is 1x <-> 2x; from 2x and up it goes 1x, then 2x
        check("and back", manager.scale == back && main.frame.width == mainWidth(back), "scale \(manager.scale)")
        SkinPreview.log("exercise: \(ok ? "all checks passed" : "some checks FAILED")")
        return ok
    }
}
#endif
