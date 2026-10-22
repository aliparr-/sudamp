// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Audio
import Catalog
import Core
import Feeds
import Foundation
import Picker
import Playback
import os

enum AppContextError: Error, CustomStringConvertible {
    case feed(FeedLoadError)
    case engine(any Error)
    case usage(String)

    var description: String {
        switch self {
        case .feed(let e): "sudamp can't read its station list: \(e)"
        case .engine(let e): "sudamp can't start its audio engine: \(e)"
        case .usage(let m): m
        }
    }
}

/// The composition root (DESIGN §4: "only Shell wires them together"): the profile, the feed, the
/// PlaybackController over the live stack, settings, the instance socket, and the one place every UI surface
/// (window, menus, status item, Dock, media keys, URL scheme, forwarded launches, automation) sends commands to.
final class AppContext {
    let launch: LaunchArguments
    let paths: Paths
    /// The active feed (bundled, cached or fetched; DESIGN §7.2).
    var feed: LoadedFeed { controller.feed }
    /// The bundled snapshot, the `<profile>/feed/` cache and the remote feed (M7).
    let feeds: FeedService
    let controller: PlaybackController
    /// Mixer volume forced to 0 (`--mute`, `SUDAMP_MUTE=1`, the debug sentinel).
    let muted: Bool
    private(set) var settings: AppSettings
    /// The genre menu's enabled/disabled state (refreshed on engine and phase changes and when a menu opens).
    private(set) var availability: [GenreID: GenreAvailability] = [:]

    /// The quit path (AppDelegate installs it).
    var onQuit: ((String) -> Void)?
    /// Bring the player window forward.
    var onShow: (() -> Void)?
    /// URLs from a forwarded launch go through the delegate, which holds them until the launch has settled.
    var onURLs: (([String], String) -> Void)?
    /// Skin files (absolute paths) from a forwarded launch or LaunchServices; the front end loads them.
    var onSkinFiles: (([String], String) -> Void)?
    /// Open Stream URL… (⌘L, Eject) asked for; the front end shows its prompt.
    var onOpenStreamURL: (() -> Void)?
    /// The front end should show the genre menu (Play with nothing chosen yet).
    var onPickGenre: (() -> Void)?
    /// Undo for "Never play this" (⌘⌫), reached from every window through the responder chain.
    let undoManager = UndoManager()

    private let lock: InstanceLock
    private var server: InstanceServer?
    private var snapshotObservers: [(PlayerSnapshot) -> Void] = []
    private var availabilityObservers: [() -> Void] = []
    private var availabilityTask: Task<Void, Never>?
    private var availabilityTimer: Task<Void, Never>?
    private var lastAvailabilityTrigger: String?
    private var settingsSave: Task<Void, Never>?
    private var feedRefresh: Task<Void, Never>?
    private(set) var isShutDown = false
    private let log = Log.logger("app")

    init(launch: LaunchArguments, paths: Paths, lock: InstanceLock) throws(AppContextError) {
        self.launch = launch
        self.paths = paths
        self.lock = lock
        muted = launch.isMuted()
        settings = AppSettings.load(paths)

        var override: URL?
        #if DEBUG
        override = launch.feed.map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
        #endif
        let bundled: LoadedFeed
        do { bundled = try BundledFeed.loadDefault(override: override) } catch { throw .feed(error) }

        var config = PlaybackConfiguration(paths: paths)
        config.engineMode = .install
        config.volume = settings.volume
        #if DEBUG
        if let list = launch.sources {
            let kinds = list.compactMap(SourceKind.init(rawValue:))
            guard kinds.count == list.count else { throw .usage("unknown --source \(list.joined(separator: ","))") }
            config.allowedSources = Set(kinds)
        }
        #endif
        do {
            controller = try PlaybackController.live(
                configuration: config, feed: bundled,
                options: LivePlaybackOptions(silent: muted, quickJS: PlaybackController.defaultQuickJS()))
        } catch {
            throw .engine(error)
        }
        // M7 (DESIGN §7.2): a verified cached copy newer than the bundled one is active before any network traffic;
        // the launch refresh (5 s budget) runs in parallel with radio and before the first engine version choice.
        feeds = FeedService.live(paths: paths, bundled: bundled, metrics: controller.metrics)
        controller.onSnapshot = { [weak self] s in self?.snapshotChanged(s) }
        controller.applyFeed(feeds.active)
        controller.feedBeforeEngineChoice = { [feeds] in
            _ = await feeds.launchRefresh(budget: .seconds(5))
            return feeds.active
        }
        feeds.setOnChange { [weak self] feed in Task { @MainActor in self?.feedChanged(feed) } }
        // Returning launch (DESIGN §3): EQ, balance, shuffle and repeat are restored before the first sound.
        controller.setEqualizer(settings.equalizer)
        if settings.balance != 0 { controller.setBalance(settings.balance) }
        controller.setShuffleGenres(settings.shuffle)
        controller.setRepeatStream(settings.repeat)
        controller.metrics?.record("app.launch", [
            "version": BuildInfo.version, "muted": muted, "automation": launch.automation != nil,
            "feedRevision": feed.document.revision, "profile": paths.isProfile, "pid": Int(getpid()),
        ])
        log.info("launch: profile \(paths.appSupport.path, privacy: .public), muted \(self.muted), feed r\(self.feed.document.revision)")
        startFeedRefresh()
    }

    // MARK: Feed (M7)

    /// The launch refresh (the engine gate shares it), then every 12 h (1 h after a failure) until quit.
    private func startFeedRefresh() {
        guard feeds.isFetching else { return }
        feedRefresh = Task { [feeds] in
            _ = await feeds.launchRefresh(budget: .seconds(5))
            await feeds.runPeriodicRefresh()
        }
    }

    /// A new active document (a late launch fetch or a periodic refresh): swap the catalog, keep the bags.
    private func feedChanged(_ new: LoadedFeed) {
        guard !isShutDown else { return }
        controller.applyFeed(new)
        refreshAvailability()
    }

    // MARK: Observation

    func observeSnapshots(_ f: @escaping (PlayerSnapshot) -> Void) {
        snapshotObservers.append(f)
        f(controller.snapshot)
    }

    func observeAvailability(_ f: @escaping () -> Void) { availabilityObservers.append(f) }

    private func snapshotChanged(_ s: PlayerSnapshot) {
        for f in snapshotObservers { f(s) }
        // Eligibility moves with the engine (radio only until it is ready) and with failures.
        let trigger = "\(s.engine.state.rawValue)/\(s.phase.rawValue)/\(s.failuresInARow)"
        if trigger != lastAvailabilityTrigger {
            lastAvailabilityTrigger = trigger
            refreshAvailability()
        }
    }

    /// Recomputes genre availability (coalesced), then tells the menus.
    func refreshAvailability() {
        guard availabilityTask == nil, !isShutDown else { return }
        availabilityTask = Task { [weak self] in
            guard let self else { return }
            let fresh = await self.controller.genreAvailability()
            self.availabilityTask = nil
            guard fresh != self.availability else { return }
            self.availability = fresh
            for f in self.availabilityObservers { f() }
        }
        if availabilityTimer == nil {
            // Backoffs and the token bucket change eligibility with time alone.
            availabilityTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    self?.refreshAvailability()
                }
            }
        }
    }

    /// The genre menu rows (one builder for every menu, DESIGN §3).
    func menuItems(shortcuts: Bool) -> [GenreMenuItem] {
        let s = controller.snapshot
        return GenreMenuModel.items(genres: controller.genres, availability: availability,
                                    current: s.favouritesMode ? nil : s.genre, shortcuts: shortcuts)
    }

    /// The full genre menu: the rows plus ★ Favourites and Recently Played (DESIGN §3).
    func genreMenuContent(shortcuts: Bool) -> GenreMenuContent {
        GenreMenuContent(rows: menuItems(shortcuts: shortcuts), favouritesCount: controller.favouriteStreams.count,
                         favouritesActive: controller.snapshot.favouritesMode,
                         recent: controller.recentlyPlayed(limit: 10).map(GenreMenuContent.streamRow))
    }

    /// A genre-menu choice from any anchor.
    func perform(_ choice: GenreMenuChoice, origin: String) {
        switch choice {
        case .genre(let g): perform(RemoteCommand.genre(g.rawValue), origin: origin)
        case .surpriseMe: perform(RemoteCommand.surpriseMe, origin: origin)
        case .favourites:
            log.info("favourites from \(origin, privacy: .public)")
            controller.startFavourites()
        case .stream(let id):
            log.info("stream \(id.rawValue, privacy: .public) from \(origin, privacy: .public)")
            controller.play(stream: id)
        }
    }

    /// The last session's genre (for "Press Play for …" when nothing auto-resumed).
    var rememberedGenre: GenreID? {
        guard let g = controller.resumedFrom?.genre, controller.catalog.genre(g) != nil else { return nil }
        return g
    }

    // MARK: Commands

    /// Every surface's commands end up here.
    func perform(_ command: RemoteCommand, origin: String) {
        guard !isShutDown else { return }
        log.info("command \(command.description, privacy: .public) from \(origin, privacy: .public)")
        controller.metrics?.record("command", ["command": command.description, "origin": origin])
        switch command {
        case .genre(let raw):
            guard let g = GenreID(rawValue: raw), controller.catalog.genre(g) != nil else {
                log.notice("unknown genre \(raw, privacy: .public)")
                return
            }
            controller.start(genre: g)
        case .surpriseMe: controller.surpriseMe()
        case .toggle: togglePlay()
        case .play: play()
        case .pause: controller.pause()
        case .stop: controller.stop()
        case .next: next()
        case .previous: controller.previous()
        case .quit: onQuit?("\(origin) quit")
        case .show: onShow?()
        }
    }

    /// `sudamp://` from the URL scheme, a forwarded launch or automation. Returns false for a URL it can't parse.
    @discardableResult
    func handle(url: String, origin: String) -> Bool {
        guard let command = RemoteCommand(string: url) else {
            log.notice("ignored URL \(url, privacy: .public)")
            return false
        }
        perform(command, origin: origin)
        return true
    }

    /// A second launch forwarded its arguments (DESIGN §4): load its skin files and act on its URLs, else bring the
    /// window forward.
    func handleForwarded(_ message: InstanceMessage) {
        let skins = ShellArguments.skinFiles(in: message.arguments).map { ShellArguments.absolute($0) }
        controller.metrics?.record("instance.forwarded", ["pid": Int(message.pid), "urls": message.urls,
                                                          "arguments": message.arguments.count, "skins": skins.count])
        if !skins.isEmpty { onSkinFiles?(skins, "forwarded") }
        if message.urls.isEmpty {
            if skins.isEmpty { onShow?() }
        } else if let onURLs {
            onURLs(message.urls, "forwarded")
        } else {
            for url in message.urls { handle(url: url, origin: "forwarded") }
        }
    }

    /// Play: resume a pause, retry after a failure, or start the remembered genre when nothing is chosen yet (with
    /// nothing remembered either, the front end opens the genre menu).
    func play() {
        let s = controller.snapshot
        if s.genre == nil, s.phase == .idle {
            if let g = rememberedGenre { controller.start(genre: g) } else { onPickGenre?() }
            return
        }
        if s.phase == .failed { return controller.retry() }
        controller.play()
    }

    /// Pause while playing; stop while still tuning (silence is what a press during TUNING… asks for); else play.
    func togglePlay() {
        switch controller.phase {
        case .playing: controller.pause()
        case .tuning, .buffering: controller.stop()
        default: play()
        }
    }

    func next() {
        if controller.snapshot.genre == nil, let g = rememberedGenre { return controller.start(genre: g) }
        controller.next()
    }

    func retry() {
        if controller.snapshot.engine.state == .failed { controller.retryEngine() }
        if controller.phase == .failed { controller.retry() }
    }

    func setVolume(_ v: Double) {
        let volume = min(max(v.isFinite ? v : 0, 0), 100)
        controller.setVolume(volume)
        settings.volume = volume
        scheduleSettingsSave()
    }

    func markGenreMenuShown() {
        settings.genreMenuShown = true
        scheduleSettingsSave()
    }

    /// Changes settings.json (saved after a 1 s debounce, and at quit).
    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        scheduleSettingsSave()
    }

    func setBalance(_ b: Double) {
        let balance = min(max(b.isFinite ? b : 0, -1), 1)
        controller.setBalance(balance)
        updateSettings { $0.balance = balance }
    }

    /// EQ on/off, preamp and bands, applied and remembered (`preset` names what the presets menu ticks).
    func setEqualizer(_ eq: EQSettings, preset: String?) {
        controller.setEqualizer(eq)
        updateSettings {
            $0.equalizer = controller.equalizer
            $0.eqPreset = preset
        }
    }

    func toggleShuffle() {
        controller.setShuffleGenres(!controller.shuffleGenres)
        updateSettings { $0.shuffle = controller.shuffleGenres }
    }

    func toggleRepeat() {
        controller.setRepeatStream(!controller.repeatStream)
        updateSettings { $0.repeat = controller.repeatStream }
    }

    // MARK: Library (favourites, bans, Copy Link, Open Stream URL)

    /// ⌘F: the current stream in or out of the favourites.
    func toggleFavourite() {
        guard let on = controller.toggleFavourite() else { return }
        log.info("favourite \(on ? "added" : "removed", privacy: .public)")
    }

    /// ⌘⌫ "Never play this": banned and skipped; Edit ▸ Undo lets it back in (DESIGN §3 "undoable").
    func banCurrent() {
        guard let id = controller.banCurrent() else { return }
        registerUnbanUndo(id)
    }

    private func registerUnbanUndo(_ id: StreamID) {
        undoManager.registerUndo(withTarget: self) { context in
            MainActor.assumeIsolated {
                _ = context.controller.unban(id)
                context.undoManager.registerUndo(withTarget: context) { again in
                    MainActor.assumeIsolated {
                        again.controller.ban(id)
                        again.registerUnbanUndo(id)
                    }
                }
                context.undoManager.setActionName("Never Play This")
            }
        }
        undoManager.setActionName("Never Play This")
    }

    /// Recently Banned ▸ item: let one stream back in.
    func unban(_ id: StreamID) {
        _ = controller.unban(id)
    }

    /// Copy Link: the canonical page at the current position, crediting the creator. False when nothing plays.
    @discardableResult
    func copyLink() -> Bool {
        let s = controller.snapshot
        guard let stream = s.stream, let link = CopyLink.link(for: stream, position: s.position) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(link.text, forType: .string)
        board.setString(link.url.absoluteString, forType: .URL)
        log.info("copied link \(link.url.absoluteString, privacy: .public)")
        controller.metrics?.record("copyLink", ["streamId": stream.id.rawValue, "url": link.url.absoluteString])
        return true
    }

    /// Plays a pasted URL (Eject / ⌘L) after canonicalising it; the error explains a refusal.
    func openStream(_ text: String, origin: String) -> Result<Void, CanonicalError> {
        do {
            switch try StreamURLOpener.resolve(text, catalog: controller.catalog, genre: controller.snapshot.genre) {
            case let .catalog(id, start): controller.play(stream: id, startAt: start)
            case let .adHoc(ref, start): controller.play(adHoc: ref, startAt: start)
            }
            log.info("open stream URL from \(origin, privacy: .public)")
            return .success(())
        } catch {
            log.notice("refused stream URL from \(origin, privacy: .public): \(error.description, privacy: .public)")
            controller.metrics?.record("openURL.refused", ["error": error.description, "origin": origin])
            return .failure(error)
        }
    }

    private func scheduleSettingsSave() {
        settingsSave?.cancel()
        settingsSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveSettings()
        }
    }

    private func saveSettings() {
        do { try settings.save(paths) } catch { log.error("cannot save settings.json: \(error, privacy: .public)") }
    }

    // MARK: Launch

    /// Returning launch (DESIGN §3): decide and start the auto-resume. Call after `prepare()`.
    func autoResume() -> ResumePlan {
        let plan = ResumePolicy.plan(last: controller.resumedFrom, catalog: controller.catalog, now: Date(),
                                     enabled: settings.autoResume && !launch.noResume,
                                     engineReady: controller.snapshot.engine.isReady)
        log.info("auto-resume: \(plan.description, privacy: .public)")
        controller.resume(plan)
        return plan
    }

    /// First launch: nothing has ever played and the menu hasn't opened by itself yet.
    var isFirstLaunch: Bool {
        controller.resumedFrom == nil && controller.library.history.isEmpty && !settings.genreMenuShown
    }

    /// Listens on `<profile>/instance.sock` for second launches.
    func startInstanceServer() {
        do {
            server = try InstanceServer(path: paths.instanceSocket) { [weak self] message in
                Task { @MainActor in self?.handleForwarded(message) }
            }
        } catch {
            log.error("instance socket: \(error, privacy: .public)")
            controller.metrics?.record("instance.serverFailed", ["error": "\(error)"])
        }
    }

    // MARK: Quit

    /// The quit path's body (DESIGN §4): flush session.json and library.json first (the cheap, important part),
    /// then the controller's 5 ms fade and engine shutdown order (which flushes again and writes state.json),
    /// then the socket and the profile lock. Idempotent.
    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        availabilityTimer?.cancel()
        availabilityTask?.cancel()
        settingsSave?.cancel()
        feedRefresh?.cancel()
        feeds.setOnChange(nil)
        controller.persistNow()
        saveSettings()
        server?.close()
        await controller.shutdown()
        controller.metrics?.record("app.quit", ["pid": Int(getpid())])
        lock.release()
    }
}
