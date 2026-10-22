// SPDX-License-Identifier: GPL-3.0-or-later
import Audio
import Catalog
import Core
import Feeds
import Foundation
import MPV
import Picker
import Resolver
import os

/// The playback stack's composition and effect executor (DESIGN §4): user actions and engine, resolver and network
/// events go into the pure `SessionMachine`; the controller executes the effects it returns (pick, resolve, load,
/// pause, stop, prefetch, persist, now playing, flash, outcomes) and publishes a `PlayerSnapshot` for UIs.
///
/// Main-actor bound; everything slow (yt-dlp, DNS, the pause ramp) is awaited off the main actor. Typical use:
/// `let c = try PlaybackController.live(…); await c.prepare(); c.start(genre: g)`, observe `c.snapshots()`, and
/// `await c.shutdown()` on quit.
public final class PlaybackController {
    public let configuration: PlaybackConfiguration
    /// The active feed: bundled at first, then a verified cached or fetched document (`applyFeed`, M7).
    public private(set) var feed: LoadedFeed
    /// The feed's catalog (picks are additionally limited by `configuration.allowedSources`).
    public private(set) var catalog: FeedCatalog
    /// The feed's engine section with `allowedSources` applied as kill switches.
    public private(set) var engineConfig: EngineConfig
    /// M7 (DESIGN §7.2): awaited once, before the first engine version choice, so the launch feed refresh (5 s
    /// budget, in parallel with radio) decides `pin`/`block`. Its result is applied with `applyFeed`.
    public var feedBeforeEngineChoice: (@Sendable () async -> LoadedFeed)?

    private let resolver: any StreamResolving
    private let player: any PlayerEngine
    private let engines: (any EngineProviding)?
    private let network: (any NetworkPathObserving)?
    private let scheduler: any PlaybackScheduler
    private let time: any TimeSource
    /// The profile's `metrics.jsonl` (Shell records app events into the same log).
    public let metrics: MetricsLog?
    private let hosts: any HostResolving
    private let proxyProvider: @Sendable () -> ProxyResolution
    private let redirectFetcher: any RedirectFetching
    private let log = Log.logger("playback")

    private var picker: Picker
    /// DESIGN §6.4 source breakers, persisted in session.json.
    public private(set) var breakers: SourceBreakers
    public private(set) var library: Library
    private var session = SessionState()
    private var rng: PlaybackRandom
    /// The previous launch's session (auto-resume is M2's).
    public let resumedFrom: LastSession?

    private struct Trigger {
        var name: String
        var nanos: UInt64
        var reload = false
    }

    private enum Stage { case resolving, loading, playing }

    /// The stream being resolved, loaded or played, with what started it (for TTFA) and its timers.
    private struct Attempt {
        let generation: UInt64
        let stream: StreamRef
        let trigger: Trigger
        let attemptNanos: UInt64
        let prefetched: Bool
        var stage: Stage = .resolving
        var resolution: StreamResolution?
        var task: Task<Void, Never>?
        var loadID: PlayerLoadID?
        var timer: ScheduledWork?
        /// The URL mpv was given.
        var loadedURL: URL?
        /// When first audio arrived, for the recovery minimum.
        var playingSince: Date?
        /// The background re-resolve before expiry, and its result (DESIGN §6.3).
        var refreshWork: ScheduledWork?
        var refreshTask: Task<Void, Never>?
        var refreshed: StreamResolution?
        var refreshTries = 0
        /// `SUDAMP_FAULT=stream:expire`'s injected mid-stream 403.
        var faultWork: ScheduledWork?
        /// Radio: redirects followed so far for this load (ours, FFmpeg follows none), and the options used.
        var radioHops = 0
        var radioRetries = 0
        var radioOptions: LoadFileOptions?
    }

    private struct Prefetch {
        enum State { case resolving, ready, unresolved }
        let genre: GenreID
        let stream: StreamRef
        var state: State
        var task: Task<Void, Never>?
    }

    private var engineStatus = EngineStatus(state: .unknown)
    private var audioFault: String?
    private var networkStatus: NetworkPathStatus?
    private var attempt: Attempt?
    private var generation: UInt64 = 0
    private var pendingTrigger: Trigger?
    private var pendingPick: (id: StreamID, trigger: Trigger, prefetched: Bool)?
    private var pickToken = 0
    /// Bumped by every user action, so an async Surprise Me that finishes after a later action stands down.
    private var userSerial = 0
    private var prefetch: Prefetch?
    private var prefetchWork: ScheduledWork?
    private var pausedAt: Date?
    private var suspendWork: ScheduledWork?
    private var persistWork: ScheduledWork?
    private var debugWork: ScheduledWork?
    private var tickWork: ScheduledWork?
    private var backStack: [StreamID] = []
    private var deferralsInARow = 0
    /// `SKIPPING - UNAVAILABLE` outlives the `TUNING…` flash of the pick that follows it.
    private var skippedAt: Date?
    private var lastPosition = PlayerPosition()
    private var counters = PlaybackDebugState.Counters()
    private var recentTTFA: [TTFAInfo] = []
    private var lastError: PlaybackErrorInfo?
    private var lastProxy: ProxyResolution?
    private var volume: Double
    private var balance: Double = 0
    private var queue: [SessionEvent] = []
    private var draining = false
    private var preparation: Task<Void, Never>?
    private var background: [Task<Void, Never>] = []
    private var installTask: Task<Void, Never>?
    /// Tags install attempts, so a late progress hop of a finished attempt is ignored.
    private var installGeneration: UInt64 = 0
    private var engineRetryWork: ScheduledWork?
    private var engineFailures = 0
    /// One update check at a time (DESIGN §6.1), plus the launch and daily timers.
    private var updateTask: Task<Void, Never>?
    private var launchUpdateWork: ScheduledWork?
    private var dailyUpdateWork: ScheduledWork?
    private var warmUpDone = false
    private var lastUpdate: EngineUpdateOutcome?
    private var lastWarmUp: EngineWarmUp?
    /// The network path went away: the session goes offline once it has stayed away for `offlineDebounce`.
    private var offlineWork: ScheduledWork?
    /// The stream that was playing when the network went away (its restart is a reload, not a new start).
    private var offlineInterrupted: StreamID?
    /// Mid-stream recoveries per stream, for `recoveryLimit` per `recoveryWindow`.
    private var recoveryLog: [StreamID: [Date]] = [:]
    /// A recovery reload in flight: what to compare its first audio with.
    private var recovering: (id: StreamID, savedPosition: Double?, reason: String)?
    /// Streams `stream:expire` has already failed once (the fault fires once per stream).
    private var expireFaulted: Set<StreamID> = []
    /// How many redirects each station took last time (session.json), so the walk costs no extra request.
    private var radioHops: [StreamID: Int]
    /// A VOD resumed at its saved position (DESIGN §3): applied to that stream's next load only.
    private var pendingStart: (id: StreamID, seconds: Double)?
    private var didAutoResume = false
    /// The EQ applied to the engine (Shell restores it from settings.json at launch, DESIGN §3 "Returning launch").
    public private(set) var equalizer = EQSettings()
    /// Shuffle, as a radio player means it ("Surprise-genre mode"): Next and auto-advance at the end of a mix move to
    /// a random genre, weighted like Surprise Me, instead of staying in the current one.
    public private(set) var shuffleGenres = false
    /// Repeat: a mix that ends plays again from the start (live streams and radio never end).
    public private(set) var repeatStream = false
    /// ★ Favourites is playing: every pick (first, Next, auto-advance) is a random eligible favourite.
    public private(set) var favouritesMode = false
    /// What Shell shows, for state.json (`.skin`, `.ui`).
    public private(set) var shellSkin: AppSkinDebugInfo?
    public private(set) var shellUI: AppUIDebugInfo?
    /// The returning-launch decision passed to `resume(_:)`.
    public private(set) var resumePlan: ResumePlan?
    /// What Shell last published to the system's Now Playing (`state.json` `.nowPlaying`).
    public private(set) var publishedNowPlaying: NowPlayingInfo?
    public private(set) var isShutDown = false
    private var subscribers: [UUID: AsyncStream<PlayerSnapshot>.Continuation] = [:]

    /// The latest published snapshot.
    public private(set) var snapshot = PlayerSnapshot()
    /// Called on every published change (in addition to `snapshots()`).
    public var onSnapshot: ((PlayerSnapshot) -> Void)?
    /// The `.nowPlaying` effect (Shell maps it to MPNowPlayingInfoCenter in M2).
    public var onNowPlaying: ((PlaybackPhase, StreamRef?) -> Void)?

    public init(configuration: PlaybackConfiguration, dependencies d: PlaybackDependencies) {
        self.configuration = configuration
        feed = d.feed
        let document = d.feed.document
        engineConfig = Self.effectiveEngine(document.engine, allowedSources: configuration.allowedSources)
        catalog = document.catalog
        resolver = d.resolver
        player = d.player
        engines = d.engines
        network = d.network
        scheduler = d.scheduler
        time = d.time
        metrics = d.metrics
        hosts = d.hosts
        proxyProvider = d.proxy
        redirectFetcher = d.redirects
        volume = min(max(configuration.volume, 0), 100)

        var random = PlaybackRandom(seed: configuration.randomSeed)
        let saved = configuration.persistState
            ? StateFile.load(SessionFile.self, from: configuration.paths.sessionFile, maxVersion: SessionFile.currentVersion)
            : nil
        picker = Picker(catalog: document.catalog, revision: document.revision, restoring: saved?.picker, using: &random)
        breakers = saved?.breakers ?? SourceBreakers()
        radioHops = saved?.radioRedirectHops ?? [:]
        rng = random
        library = (configuration.persistState
            ? StateFile.load(Library.self, from: configuration.paths.libraryFile, maxVersion: Library.currentVersion) : nil)
            ?? Library()
        resumedFrom = saved?.last
        player.setVolume(volume)
        snapshot = makeSnapshot()
    }

    // MARK: Lifecycle

    /// Checks the startup guard, starts listening to the engine and the network, and checks the stream engine
    /// (re-hashing its tree). Idempotent; user actions wait for it.
    public func prepare() async {
        if let preparation { return await preparation.value }
        let task = Task { await self.bootstrap() }
        preparation = task
        await task.value
    }

    private func bootstrap() async {
        let startup = player.startupGuardFailures()
        if !startup.isEmpty { raiseAudioFault(startup.joined(separator: "; ")) }
        let events = player.events
        background.append(Task { [weak self] in
            for await event in events { self?.handle(event) }
        })
        if let network {
            let updates = network.updates()
            background.append(Task { [weak self] in
                for await status in updates { self?.networkChanged(status) }
            })
        }
        await refreshEngine()
        metrics?.record("playback.ready", ["engine": engineStatus.state.rawValue, "feedRevision": feed.document.revision,
                                           "streams": catalog.streams.count])
        publish()
    }

    /// Quit path (DESIGN §4): the 5 ms fade, the engine shutdown order, then a flush of session.json and
    /// library.json (and state.json). Idempotent.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        for work in [prefetchWork, suspendWork, debugWork, tickWork, persistWork, engineRetryWork, attempt?.timer,
                     launchUpdateWork, dailyUpdateWork, offlineWork] {
            work?.cancel()
        }
        cancelAttemptWork()
        attempt?.task?.cancel()
        prefetch?.task?.cancel()
        installTask?.cancel()
        updateTask?.cancel()
        for task in background { task.cancel() }
        if session.phase == .playing { await player.pause() }
        player.shutdown()
        persistNow()
        if configuration.writeDebugState { await writeDebugStateNow() }
        for c in subscribers.values { c.finish() }
        subscribers = [:]
        metrics?.record("playback.shutdown", ["streamsStarted": counters.streamsStarted, "failures": counters.failures,
                                              "unhandledErrors": counters.unhandledErrors])
    }

    // MARK: User actions

    /// The genres in menu order.
    public var genres: [Genre] { catalog.genres }

    /// Picks a stream in `genre` and plays it (DESIGN §3's one action that matters).
    public func start(genre: GenreID) {
        guard catalog.genre(genre) != nil, !refusedByFault() else { return }
        favouritesMode = false
        user("selectGenre") { dispatch(.selectGenre(genre)) }
    }

    /// A genre weighted by its eligible streams (DESIGN §7.3), then `start(genre:)`.
    public func surpriseMe() {
        guard !refusedByFault() else { return }
        favouritesMode = false
        ensurePrepared()
        userSerial += 1
        let serial = userSerial
        Task { [weak self] in
            guard let self else { return }
            await self.preparation?.value
            let status = await self.resolver.status()
            // A pick, Next or URL after Surprise Me wins over it.
            guard serial == self.userSerial, !self.isShutDown else { return }
            if let genre = self.picker.surpriseGenre(context: self.context(status), using: &self.rng) {
                self.start(genre: genre)
            } else {
                self.note(kind: "unavailable", message: "no genre has a playable stream", stream: nil, stage: "pick")
                self.publish()
            }
        }
    }

    /// Hovering a genre in the menu for 300 ms (DESIGN §3): pre-resolve its next pick, so choosing it starts fast.
    /// Spends a YouTube token only while ≥ 2 remain (purpose `.hover`); never replaces a prefetch in flight.
    public func preresolve(genre: GenreID) {
        guard catalog.genre(genre) != nil, audioFault == nil, !isShutDown, session.genre != genre else { return }
        if let p = prefetch, p.genre == genre || p.state == .resolving { return }
        ensurePrepared()
        let token = pickToken
        Task { [weak self] in
            guard let self else { return }
            await self.preparation?.value
            let status = await self.resolver.status()
            guard token == self.pickToken, !self.isShutDown, self.session.genre != genre else { return }
            if let p = self.prefetch, p.genre == genre || p.state == .resolving { return }
            guard let s = self.picker.next(genre: genre, context: self.context(status, background: true), fastStart: true,
                                           using: &self.rng) else {
                return
            }
            self.startPrefetch(s, genre: genre, purpose: .hover)
        }
    }

    /// Another random stream in the genre (prefetched when possible); with shuffle on, a random genre's.
    public func next() {
        guard !refusedByFault() else { return }
        if shuffleGenres, !favouritesMode, session.genre != nil, session.phase != .offline { return surpriseMe() }
        user("next") { dispatch(.next) }
    }

    /// The previously played stream (this session's history, then library.json's).
    public func previous() {
        guard !refusedByFault(), let target = previousStream() else { return }
        user("previous") { dispatch(.playStream(target)) }
    }

    /// Plays a specific catalog stream (Playlist double-click, Recently Played, favourites), a VOD optionally from
    /// `startAt` seconds (a pasted link's `t=`).
    public func play(stream id: StreamID, startAt: Double? = nil) {
        guard !refusedByFault(), let stream = catalog[id] else { return }
        favouritesMode = false
        pendingStart = startAt.flatMap { stream.isRadio || stream.kind.isLive || $0 <= 0 ? nil : (id, $0) }
        user("playStream") { dispatch(.playStream(stream)) }
    }

    /// Plays a stream that is not in the catalog: a URL pasted into Open Stream URL (⌘L), already canonicalised.
    public func play(adHoc stream: StreamRef, startAt: Double? = nil) {
        guard !refusedByFault() else { return }
        if catalog[stream.id] != nil { return play(stream: stream.id, startAt: startAt) }
        favouritesMode = false
        pendingStart = startAt.flatMap { stream.isRadio || stream.kind.isLive || $0 <= 0 ? nil : (stream.id, $0) }
        metrics?.record("openURL", ["streamId": stream.id.rawValue, "source": stream.source.rawValue])
        user("openURL") { dispatch(.playStream(stream)) }
    }

    /// Resume, or start the genre again after stop/failure. Live streams paused over 30 s rejoin the live edge.
    public func play() {
        guard !refusedByFault() else { return }
        if session.phase == .paused { return resumeFromPause() }
        user("play") { dispatch(.play) }
    }

    public func pause() { dispatch(.pause) }

    public func togglePause() {
        if session.phase == .playing { pause() } else { play() }
    }

    public func stop() { dispatch(.stop) }

    /// "CAN'T REACH STREAMS - CLICK TO RETRY".
    public func retry() {
        guard !refusedByFault() else { return }
        user("retry") { dispatch(.retry) }
    }

    /// The 1.5 s launch fade of an auto-resume (DESIGN §3).
    public static let launchFadeSeconds = 1.5

    /// Returning launch (DESIGN §3): plays `plan` (from `ResumePolicy`) behind the launch fade. A genre plan picks its
    /// next bag item; a stream plan replays that stream, live at the live edge or a VOD from `startAt`. `.resumed`
    /// in state.json turns true. Call after `prepare()`.
    public func resume(_ plan: ResumePlan, fadeSeconds: Double = PlaybackController.launchFadeSeconds) {
        resumePlan = plan
        guard !refusedByFault() else { return }
        switch plan {
        case .none:
            scheduleDebugState()
        case .genre(let g):
            guard catalog.genre(g) != nil else { return }
            didAutoResume = true
            player.fadeIn(seconds: fadeSeconds)
            metrics?.record("resume", ["plan": "genre", "genre": g.rawValue])
            user("resume") { dispatch(.selectGenre(g)) }
        case let .stream(g, id, startAt):
            guard catalog.genre(g) != nil, let s = catalog[id] else { return resume(.genre(g), fadeSeconds: fadeSeconds) }
            didAutoResume = true
            player.fadeIn(seconds: fadeSeconds)
            pendingStart = startAt.flatMap { s.isRadio || s.kind.isLive ? nil : (id, $0) }
            var fields: [String: any Sendable] = ["plan": "stream", "genre": g.rawValue, "streamId": id.rawValue]
            if let startAt { fields["startAt"] = startAt.rounded() }
            metrics?.record("resume", fields)
            user("resume") {
                let trigger = pendingTrigger
                dispatch(.selectGenre(g))
                // The genre's own pick is superseded: we know what to play.
                pickToken += 1
                pendingTrigger = trigger
                dispatch(.playStream(s))
            }
        }
    }

    /// Shell reports what it published to MPNowPlayingInfoCenter (state.json `.nowPlaying`).
    public func recordPublishedNowPlaying(_ info: NowPlayingInfo) {
        guard info != publishedNowPlaying else { return }
        publishedNowPlaying = info
        scheduleDebugState()
    }

    /// Eligible and total streams per genre right now, for the genre menu (DESIGN §3: a genre with no playable
    /// streams is disabled, with the reason).
    public func genreAvailability() async -> [GenreID: GenreAvailability] {
        let status = await resolver.status()
        let ctx = context(status)
        var out: [GenreID: GenreAvailability] = [:]
        for g in catalog.genres {
            let n = picker.eligibleCount(genre: g.id, context: ctx)
            out[g.id] = GenreAvailability(eligible: n, total: catalog.streams(in: g.id).count,
                                          reason: n == 0 ? picker.unavailableReason(genre: g.id, context: ctx) : nil)
        }
        return out
    }

    /// 0...100 (mixer gain `(v/100)²`).
    public func setVolume(_ v: Double) {
        volume = min(max(v.isFinite ? v : 0, 0), 100)
        player.setVolume(volume)
        publish()
    }

    /// -1 (left) ... +1 (right).
    public func setBalance(_ b: Double) {
        balance = min(max(b.isFinite ? b : 0, -1), 1)
        player.setBalance(balance)
        publish()
    }

    /// Forgets every cached resolution (cold-pick measurements, `sudamp-dev ttfa`).
    public func clearResolutionCache() async {
        prefetch?.task?.cancel()
        prefetch = nil
        await resolver.clearCache()
    }

    /// Eligible streams in a genre right now (the menu disables a genre at 0).
    public func eligibleCount(genre: GenreID) async -> Int {
        let status = await resolver.status()
        return picker.eligibleCount(genre: genre, context: context(status))
    }

    public func unavailableReason(genre: GenreID) async -> Ineligibility? {
        let status = await resolver.status()
        return picker.unavailableReason(genre: genre, context: context(status))
    }

    /// The stream being resolved, loaded or played.
    public var currentStream: StreamRef? { session.current }
    public var phase: PlaybackPhase { session.phase }
    /// Every TTFA measured this session, oldest first (at most 200).
    public private(set) var ttfaHistory: [TTFAInfo] = []
    public var debugCounters: PlaybackDebugState.Counters { counters }
    /// Render-callback and AO counters (tools measure resume audibility with them).
    public func playerDiagnostics() -> PlayerDiagnostics { player.diagnostics() }

    // MARK: Seek, EQ, shuffle, repeat (PLAN M5 controls)

    /// The length the position slider spans: mpv's, else the feed's.
    private var seekDuration: Double? {
        if let d = lastPosition.duration, d.isFinite, d > 0 { return d }
        return session.current?.durationSec.map(Double.init)
    }

    /// Seeking works on a playing or paused VOD with a known length (DESIGN §3: "seek on VOD only").
    public var canSeek: Bool {
        guard [.playing, .paused].contains(session.phase), let s = session.current, !s.isRadio, !s.kind.isLive,
              lastPosition.seekable != false else { return false }
        return seekDuration != nil
    }

    /// Seeks to `fraction` (0...1) of the current VOD. Ignored for live streams and radio.
    public func seek(toFraction fraction: Double) {
        guard let d = seekDuration, fraction.isFinite else { return }
        seek(toSeconds: min(max(fraction, 0), 1) * d)
    }

    public func seek(toSeconds seconds: Double) {
        guard canSeek, seconds.isFinite, let d = seekDuration, let s = session.current else { return }
        let target = min(max(0, seconds), max(0, d - 1))
        player.seek(to: target)
        lastPosition.timePos = target
        metrics?.record("seek", ["streamId": s.id.rawValue, "to": target.rounded()])
        schedulePersist()
        publish()
    }

    /// The ten-band EQ, preamp and on/off, applied at once (DESIGN §5.4). Shell persists it.
    public func setEqualizer(_ settings: EQSettings) {
        let s = EQSettings(enabled: settings.enabled, preamp: settings.preamp, bands: settings.bands)
        guard s != equalizer else { return }
        equalizer = s
        player.applyEqualizer(s)
        scheduleDebugState()
    }

    public func setShuffleGenres(_ on: Bool) {
        guard on != shuffleGenres else { return }
        shuffleGenres = on
        metrics?.record("shuffle", ["on": on])
        publish()
    }

    public func setRepeatStream(_ on: Bool) {
        guard on != repeatStream else { return }
        repeatStream = on
        metrics?.record("repeat", ["on": on])
        publish()
    }

    /// A finished file: repeat it (a mix that played for a while), move to a random genre (shuffle), or let the
    /// session machine pick the next stream in the genre.
    private func endOfFile(_ a: Attempt) {
        if repeatStream, !a.stream.isRadio, !a.stream.kind.isLive, (lastPosition.timePos ?? 0) >= Self.repeatMinimumSeconds {
            return user("repeat") { dispatch(.playStream(a.stream)) }
        }
        if shuffleGenres, !favouritesMode { return surpriseMe() }
        dispatch(.endOfFile(a.stream.id))
    }

    /// A file that ends sooner than this is not repeated (a broken file would otherwise loop).
    public static let repeatMinimumSeconds: Double = 5

    // MARK: Library: favourites, bans, history (DESIGN §3: ⌘F, ⌘⌫ undoable, Recently Played)

    public func isFavourite(_ id: StreamID) -> Bool { library.favourites.contains(id) }

    /// Toggles a favourite (the current stream by default). Returns whether it is a favourite now; nil when there
    /// was nothing to toggle.
    @discardableResult
    public func toggleFavourite(_ id: StreamID? = nil) -> Bool? {
        guard let id = id ?? session.current?.id else { return nil }
        library.toggleFavourite(id)
        let on = library.favourites.contains(id)
        metrics?.record("favourite", ["streamId": id.rawValue, "on": on])
        if favouritesMode, library.favourites.isEmpty { favouritesMode = false }
        schedulePersist()
        publish()
        scheduleDebugState()
        return on
    }

    /// Favourite catalog streams, oldest first.
    public var favouriteStreams: [StreamRef] { library.favourites.compactMap { catalog[$0] } }

    /// "Never play this" (⌘⌫) for the current stream: banned in library.json, and skipped at once. Returns the
    /// banned stream (Shell registers the undo).
    @discardableResult
    public func banCurrent() -> StreamID? {
        guard let s = session.current else { return nil }
        ban(s.id)
        if [.tuning, .buffering, .playing, .paused].contains(session.phase) { next() }
        return s.id
    }

    public func ban(_ id: StreamID) {
        library.ban(id)
        metrics?.record("ban", ["streamId": id.rawValue])
        schedulePersist()
        publish()
        scheduleDebugState()
    }

    /// Undoes the newest ban, or a specific one. Returns the stream let back in.
    @discardableResult
    public func unban(_ id: StreamID? = nil) -> StreamID? {
        guard let released = library.unban(id) else { return nil }
        metrics?.record("unban", ["streamId": released.rawValue])
        schedulePersist()
        publish()
        scheduleDebugState()
        return released
    }

    /// The newest distinct catalog streams played, newest first.
    public func recentlyPlayed(limit: Int = 10) -> [StreamRef] {
        var seen = Set<StreamID>()
        var out: [StreamRef] = []
        for entry in library.history.reversed() where !seen.contains(entry.stream) {
            seen.insert(entry.stream)
            guard let s = catalog[entry.stream] else { continue }
            out.append(s)
            if out.count >= limit { break }
        }
        return out
    }

    /// The newest bans, newest first.
    public func recentlyBanned(limit: Int = 10) -> [StreamRef] {
        Array(library.banned.reversed().compactMap { catalog[$0] }.prefix(limit))
    }

    /// ★ Favourites (DESIGN §3 genre menu): plays the favourites at random until a genre is chosen again.
    public func startFavourites() {
        guard !refusedByFault(), !library.favourites.isEmpty,
              let genre = session.genre ?? favouriteStreams.first?.genres.first ?? catalog.genres.first?.id else { return }
        favouritesMode = true
        prefetchWork?.cancel()
        prefetch?.task?.cancel()
        prefetch = nil
        metrics?.record("favourites.start", ["count": library.favourites.count])
        user("favourites") { dispatch(.selectGenre(genre)) }
    }

    /// A random eligible favourite, avoiding the one that just played while there is another.
    private func nextFavourite(_ ctx: PickContext) -> StreamRef? {
        let favourites = favouriteStreams
        guard !favourites.isEmpty else { return nil }
        let eligible = favourites.filter { Eligibility.isEligible($0, health: picker.health(of: $0.id), context: ctx) }
        let last = backStack.last
        let fresh = eligible.filter { $0.id != last }
        return (fresh.isEmpty ? eligible : fresh).randomElement(using: &rng)
    }

    // MARK: Shell state (state.json `.skin`, `.ui`, `.lastError` from the front end)

    /// Shell reports what it shows; state.json follows within its debounce.
    public func setShellState(skin: AppSkinDebugInfo?, ui: AppUIDebugInfo?) {
        guard skin != shellSkin || ui != shellUI else { return }
        shellSkin = skin
        shellUI = ui
        scheduleDebugState()
    }

    /// A front-end problem for `.lastError` (e.g. `skinRejected`), logged and in metrics like playback failures.
    public func noteShellError(kind: String, message: String, stage: String) {
        note(kind: kind, message: message, stream: nil, stage: stage)
        publish()
        scheduleDebugState()
    }

    /// The render bridge whose ring feeds the visualiser (nil for engines without audio output).
    public var renderBridge: RenderBridge? { player.renderBridge }

    // MARK: Stream engine

    /// Installs yt-dlp in the background (feed `pin`/`block` honoured) unless it is ready, installing or disabled
    /// (M2's first launch; radio plays meanwhile). Progress is in `snapshot.engine`. A failed install is retried
    /// with backoff (`engineRetryBackoff`; at once when the network comes back after `unreachable`), and its failure
    /// stays on screen until a retry's download is under way.
    public func ensureEngine() {
        guard configuration.engineMode != .disabled, let engines, installTask == nil, !engineStatus.isReady,
              !isShutDown else { return }
        engineRetryWork?.cancel()
        engineRetryWork = nil
        let gate = feedBeforeEngineChoice
        feedBeforeEngineChoice = nil
        if engineStatus.state == .failed {
            engineStatus.retryAt = nil
        } else {
            engineStatus = EngineStatus(state: .installing, progress: 0, download: "choosing")
        }
        publish()
        installGeneration += 1
        let generation = installGeneration
        installTask = Task { [weak self] in
            if let gate {
                let fresh = await gate()
                self?.applyFeed(fresh)
            }
            guard let policy = self.map({ EngineInstallPolicy(feed: $0.feed.document.engine) }) else { return }
            do {
                let readiness = try await engines.install(policy: policy) { [weak self] phase in
                    Task { @MainActor in self?.installProgress(phase, generation: generation) }
                }
                await self?.apply(readiness)
                // DESIGN §6.1: "Updates run right after a `pin` first install" — the pin only picks the first build.
                if readiness.isReady, await engines.lastInstallReason() == .pin {
                    self?.runUpdateCheck(.afterPinInstall)
                }
            } catch {
                self?.installFailed(error, generation: generation)
            }
            if self?.installGeneration == generation { self?.installTask = nil }
        }
    }

    /// Reinstalls a build whose launch re-hash failed (else rolls back to the kept previous one), radio playing
    /// meanwhile (PLAN M6 `engine:corrupt`). Runs in `.automatic` mode too: the engine was installed on purpose.
    private func repairEngine(reason: String) {
        guard configuration.engineMode != .disabled, let engines, installTask == nil, !isShutDown else { return }
        engineStatus = EngineStatus(state: .installing, progress: 0, download: "choosing", message: reason)
        engineStatus.purpose = "repair"
        publish()
        installGeneration += 1
        let generation = installGeneration
        log.error("stream engine corrupt (\(reason, privacy: .public)): reinstalling")
        installTask = Task { [weak self] in
            guard let policy = self.map({ EngineInstallPolicy(feed: $0.feed.document.engine) }) else { return }
            let readiness = await engines.repair(policy: policy) { [weak self] phase in
                Task { @MainActor in self?.installProgress(phase, generation: generation) }
            }
            guard let self, self.installGeneration == generation else { return }
            self.installTask = nil
            if readiness.isReady {
                await self.apply(readiness)
            } else {
                self.installFailed(EngineStoreError.badLayout("repair failed: \(readiness)"), generation: generation)
            }
        }
    }

    // MARK: Engine updates (DESIGN §6.1, PLAN M6)

    /// The update check's inputs from the active feed: its `block` (never its `pin`), nightly escalation, the canary
    /// items as catalog streams, and the engine strings.
    private func updateRequest(_ trigger: EngineUpdateTrigger) -> EngineUpdateRequest {
        let engine = feed.document.engine
        let canary = engine.canary.compactMap { catalog[$0] }
        return EngineUpdateRequest(trigger: trigger, policy: EngineInstallPolicy(feed: engine),
                                   nightlyEscalation: engine.nightlyEscalation, canary: canary,
                                   settings: ResolverSettings(engine: engine))
    }

    /// Runs one check in the background (one at a time); a switch re-points the resolver at the new build.
    private func runUpdateCheck(_ trigger: EngineUpdateTrigger) {
        guard configuration.engineUpdates, configuration.engineMode != .disabled, let engines, updateTask == nil,
              !isShutDown else { return }
        let request = updateRequest(trigger)
        counters.updateChecks += 1
        engineStatus.update = "checking"
        publish()
        updateTask = Task { [weak self] in
            guard await engines.updateDue(trigger) else {
                self?.updateTask = nil
                self?.engineStatus.update = self?.lastUpdate?.result.rawValue
                self?.publish()
                return
            }
            let outcome = await engines.checkForUpdate(request)
            guard let self, !self.isShutDown else { return }
            self.updateTask = nil
            self.lastUpdate = outcome
            self.engineStatus.update = outcome.result.rawValue
            if outcome.canary.contains(where: \.botCheck) {
                self.tripBotCheckFromCanary()
            }
            if outcome.result == .switched {
                await self.apply(await engines.readiness())
            }
            self.publish()
            self.scheduleDebugState()
        }
    }

    /// The canary hit a bot check: YouTube pauses exactly as if a pick had (DESIGN §6.4).
    private func tripBotCheckFromCanary() {
        guard let probe = feed.document.engine.canary.first(where: { $0.source.platform == .youtube })
            ?? StreamID(rawValue: "yt:canaryprobe") else { return }
        let event = breakers.recordFailure(.youtube, stream: probe, failure: .botCheck, now: time.now)
        breakerChanged(event)
    }

    /// The engine is ready: warm it up once, then schedule the launch check (if 24 h have passed) and the daily one.
    private func engineBecameReady() {
        guard let engines, !warmUpDone, !isShutDown else { return }
        warmUpDone = true
        let resolver = self.resolver
        let version = engineStatus.version
        // Through the resolver's serial gate: never beside a resolve, and a user pick kills it (DESIGN §6.3).
        Task { [weak self] in
            guard let warm = await resolver.warmUp(version: version) else { return }
            await engines.noteWarmUp(warm)
            self?.lastWarmUp = warm
        }
        guard configuration.engineUpdates, configuration.engineMode != .disabled else { return }
        launchUpdateWork?.cancel()
        launchUpdateWork = scheduler.schedule(after: configuration.timings.launchUpdateDelay) { [weak self] in
            self?.launchUpdateWork = nil
            self?.runUpdateCheck(.launch)
        }
        scheduleDailyUpdate()
    }

    private func scheduleDailyUpdate() {
        dailyUpdateWork?.cancel()
        dailyUpdateWork = scheduler.schedule(after: configuration.timings.dailyUpdateInterval) { [weak self] in
            self?.runUpdateCheck(.daily)
            self?.scheduleDailyUpdate()
        }
    }

    /// Two engine-class failures in a row on one platform (DESIGN §6.4): roll back a recent switch, else ask for a
    /// failure-triggered update check (at most every 2 h; the floor lives in updates.json).
    private func engineFailuresInARow(_ platform: SourceKind) {
        guard let engines, configuration.engineMode != .disabled, !isShutDown else { return }
        Task { [weak self] in
            if let rolled = await engines.rollbackAfterEngineFailures() {
                self?.metrics?.record("engine.rollback.applied", ["to": rolled.version ?? "", "platform": platform.rawValue])
                await self?.apply(rolled)
                return
            }
            self?.runUpdateCheck(.engineFailures)
        }
    }

    // MARK: Feed

    /// Swaps in a new active feed (M7: a verified cached or fetched document, at launch or from the 12 h refresh).
    /// Bags merge (`Picker.update`: new IDs at random positions after the cursor, removed IDs dropped), the resolver
    /// takes the new engine strings from its next resolve, and what is playing keeps playing even if it was removed.
    public func applyFeed(_ new: LoadedFeed) {
        guard !isShutDown, new.document != feed.document else { return }
        let previous = feed.document.revision
        feed = new
        catalog = new.document.catalog
        engineConfig = Self.effectiveEngine(new.document.engine, allowedSources: configuration.allowedSources)
        picker.update(catalog: catalog, revision: new.document.revision, using: &rng)
        let engine = engineConfig
        let resolver = self.resolver
        Task { await resolver.setEngineConfig(engine) }
        if engineStatus.isReady, let version = engineStatus.version, engineBlockedByFeed(version), let engines {
            // The new feed blocks the build in use (M6): re-apply its readiness, which replaces it.
            Task { [weak self] in await self?.apply(await engines.readiness()) }
        }
        schedulePersist()
        metrics?.record("feed.applied", ["from": previous, "to": new.document.revision, "origin": new.origin.rawValue,
                                         "genres": catalog.genres.count, "streams": catalog.streams.count])
        log.info("feed r\(previous) → r\(new.document.revision) (\(new.origin.rawValue, privacy: .public))")
        publish()
    }

    /// The feed's engine section with `allowedSources` (debug `--source`) applied as kill switches.
    nonisolated static func effectiveEngine(_ engine: EngineConfig, allowedSources: Set<SourceKind>?) -> EngineConfig {
        var out = engine
        if let allowed = allowedSources {
            for kind in SourceKind.allCases { out.sources[kind] = allowed.contains(kind) && engine.isSourceEnabled(kind) }
        }
        return out
    }

    /// Retries a failed engine install now (the status line's Retry).
    public func retryEngine() {
        guard engineStatus.state == .failed else { return }
        ensureEngine()
    }

    /// Delays between automatic retries of a failed engine install (then the last one, repeated).
    public static let engineRetryBackoff: [TimeInterval] = [15, 60, 300, 900, 1800]

    private func refreshEngine() async {
        guard configuration.engineMode != .disabled, let engines else {
            engineStatus = EngineStatus(state: configuration.engineMode == .disabled ? .disabled : .missing)
            await resolver.setEngine(nil)
            return
        }
        engineStatus = EngineStatus(state: .checking)
        let readiness = await engines.readiness()
        await apply(readiness)
        if case .corrupt(let reason) = readiness {
            repairEngine(reason: reason)
        } else if !readiness.isReady, configuration.engineMode == .install {
            ensureEngine()
        }
    }

    private func apply(_ readiness: EngineReadiness) async {
        switch readiness {
        case let .ready(version, _) where engineBlockedByFeed(version):
            // DESIGN §6.1 "always honouring `block`": a build the active feed blocks is never run, even if it is
            // installed and verifies; the pin or the newest allowed release replaces it, radio playing meanwhile.
            await resolver.setEngine(nil)
            engineStatus = EngineStatus(state: .missing, version: version, message: "blocked by the feed")
            log.error("stream engine \(version, privacy: .public) is blocked by the feed: replacing it")
            metrics?.record("engine.blocked", ["version": version])
            publish()
            ensureEngine()
            return
        case let .ready(version, executable):
            await resolver.setEngine(executable)
            let update = engineStatus.update
            engineStatus = EngineStatus(state: .ready, version: version)
            engineStatus.update = update
            engineFailures = 0
            engineRetryWork?.cancel()
            engineRetryWork = nil
            metrics?.record("engine.ready", ["version": version])
            engineBecameReady()
        case .missing:
            await resolver.setEngine(nil)
            engineStatus = EngineStatus(state: .missing)
        case .corrupt(let reason):
            await resolver.setEngine(nil)
            engineStatus = EngineStatus(state: .corrupt, message: reason)
            log.error("stream engine corrupt: \(reason, privacy: .public)")
            metrics?.record("engine.corrupt", ["reason": reason])
        }
        publish()
    }

    private func engineBlockedByFeed(_ version: String) -> Bool {
        EngineInstallPolicy(feed: feed.document.engine).validated().config.isBlocked(version)
    }

    private func installProgress(_ phase: EngineInstallPhase, generation: UInt64) {
        guard generation == installGeneration, installTask != nil, !isShutDown else { return }
        if engineStatus.state == .failed {
            // A retry: keep the failure on screen until bytes flow.
            guard case .downloading = phase else { return }
            engineStatus = EngineStatus(state: .installing, progress: 0, download: "downloading",
                                        attempts: engineStatus.attempts)
        }
        guard engineStatus.state == .installing else { return }
        switch phase {
        case .choosing: engineStatus.download = "choosing"
        case let .downloading(onDisk, expected):
            engineStatus.download = "downloading"
            if let expected, expected > 0 { engineStatus.progress = min(1, Double(onDisk) / Double(expected)) }
        case .verifying: engineStatus.download = "verifying"; engineStatus.progress = 1
        case .unpacking: engineStatus.download = "unpacking"
        case .recording: engineStatus.download = "recording"
        case .testing: engineStatus.download = "testing"
        case .switching: engineStatus.download = "switching"
        }
        publish()
    }

    private func installFailed(_ error: any Error, generation: UInt64) {
        guard generation == installGeneration, !isShutDown, !(error is CancellationError) else { return }
        let kind: String
        switch error as? EngineStoreError {
        case .unreachable?: kind = "unreachable"
        case .insufficientSpace?: kind = "noSpace"
        default: kind = "failed"
        }
        engineFailures += 1
        let delay = Self.engineRetryBackoff[min(engineFailures, Self.engineRetryBackoff.count) - 1]
        engineStatus = EngineStatus(state: .failed, download: kind, message: "\(error)",
                                    retryAt: time.now.addingTimeInterval(delay), attempts: engineFailures)
        log.error("engine install failed (\(kind, privacy: .public), attempt \(self.engineFailures)): \(error, privacy: .public); retry in \(Int(delay)) s")
        metrics?.record("engine.installFailed", ["kind": kind, "error": "\(error)", "attempt": engineFailures,
                                                 "retryInSec": delay])
        engineRetryWork?.cancel()
        engineRetryWork = scheduler.schedule(after: delay) { [weak self] in
            self?.engineRetryWork = nil
            self?.ensureEngine()
        }
        publish()
    }

    // MARK: Dispatch

    private func ensurePrepared() {
        if preparation == nil { preparation = Task { await self.bootstrap() } }
    }

    /// Runs a user action with its TTFA trigger time (cleared afterwards, so it never leaks to a later pick).
    private func user(_ name: String, reload: Bool = false, _ body: () -> Void) {
        ensurePrepared()
        userSerial += 1
        pendingTrigger = Trigger(name: name, nanos: monotonicNanos(), reload: reload)
        body()
        pendingTrigger = nil
    }

    private func takeTrigger() -> Trigger {
        defer { pendingTrigger = nil }
        return pendingTrigger ?? Trigger(name: "auto", nanos: monotonicNanos())
    }

    private func refusedByFault() -> Bool {
        guard audioFault != nil else { return false }
        publish()
        return true
    }

    /// Feeds one event through the reducer and executes its effects. Effects may dispatch further events; they
    /// queue and run in order.
    private func dispatch(_ event: SessionEvent) {
        guard !isShutDown else { return }
        queue.append(event)
        guard !draining else { return }
        draining = true
        while !queue.isEmpty {
            let e = queue.removeFirst()
            let before = session.phase
            let (next, effects) = SessionMachine.reduce(session, e)
            session = next
            if before != next.phase { phaseChanged(from: before, to: next.phase) }
            for effect in effects { execute(effect) }
        }
        draining = false
        publish()
    }

    private func execute(_ effect: SessionEffect) {
        switch effect {
        case let .pick(genre, fastStart): performPick(genre, fastStart: fastStart)
        case let .resolve(stream): performResolve(stream)
        case let .load(stream): performLoad(stream)
        case .pause(true): performPause()
        case .pause(false): performResume()
        case .stop: performStop()
        case let .prefetch(genre): schedulePrefetch(genre)
        case .persist: schedulePersist()
        case let .nowPlaying(phase, stream): onNowPlaying?(phase, stream)
        case let .flash(message):
            // TUNING…, OFFLINE and CAN'T REACH STREAMS follow from the phase; only the skip notice is timed.
            if message == .skipping { skippedAt = time.now }
        case let .recordOutcome(id, outcome): record(id, outcome)
        }
    }

    private func phaseChanged(from old: PlaybackPhase, to new: PlaybackPhase) {
        suspendWork?.cancel()
        suspendWork = nil
        if [.paused, .idle, .failed].contains(new) {
            suspendWork = scheduler.schedule(after: configuration.timings.suspendOutputAfter) { [weak self] in
                guard let self, [.paused, .idle, .failed].contains(self.session.phase) else { return }
                self.player.suspendOutput()
            }
        }
        if old == .paused, new != .paused, new != .offline { pausedAt = nil }
        tickWork?.cancel()
        tickWork = nil
        if new == .playing { scheduleTick() }
        if new != .playing, new != .paused { lastPosition = PlayerPosition() }
    }

    // MARK: Pick

    private func performPick(_ genre: GenreID, fastStart: Bool) {
        cancelAttempt()
        pickToken += 1
        let token = pickToken
        let trigger = takeTrigger()
        Task { [weak self] in
            guard let self else { return }
            await self.preparation?.value
            guard token == self.pickToken, !self.isShutDown else { return }
            let status = await self.resolver.status()
            guard token == self.pickToken, !self.isShutDown else { return }
            self.finishPick(genre, fastStart: fastStart, status: status, trigger: trigger)
        }
    }

    private func finishPick(_ genre: GenreID, fastStart: Bool, status: ResolverStatus, trigger: Trigger) {
        let ctx = context(status)
        var chosen: StreamRef?
        var fromPrefetch = false
        if let p = prefetch {
            if p.genre == genre, Eligibility.isEligible(p.stream, health: picker.health(of: p.stream.id), context: ctx) {
                chosen = p.stream
                fromPrefetch = true
            }
            prefetch = nil
        }
        prefetchWork?.cancel()
        if favouritesMode {
            chosen = nextFavourite(ctx)
            fromPrefetch = false
        } else if chosen == nil {
            chosen = picker.next(genre: genre, context: ctx, fastStart: fastStart, using: &rng)
        }
        if let s = chosen {
            pendingPick = (s.id, trigger, fromPrefetch)
            if breakers.state(s.source, now: time.now) == .halfOpen {
                breakers.notePicked(s.source, stream: s.id, now: time.now)
                metrics?.record("breaker", ["platform": s.source.platform.rawValue, "change": "probe",
                                            "streamId": s.id.rawValue])
            }
            metrics?.record("pick", ["streamId": s.id.rawValue, "source": s.source.rawValue, "genre": genre.rawValue,
                                     "fastStart": fastStart, "prefetched": fromPrefetch, "trigger": trigger.name])
        } else {
            let reason = picker.unavailableReason(genre: genre, context: ctx)?.rawValue ?? "none"
            metrics?.record("pick", ["genre": genre.rawValue, "none": true, "reason": reason])
            note(kind: "unavailable", message: "nothing playable in \(genre) (\(reason))", stream: nil, stage: "pick")
        }
        dispatch(.picked(genre, chosen))
    }

    /// - Parameter background: a prefetch or hover pick, which never takes a half-open breaker's one probe.
    private func context(_ status: ResolverStatus, background: Bool = false) -> PickContext {
        var ready = status.readyIDs
        if let p = prefetch, p.state == .resolving { ready.insert(p.stream.id) }
        let open = status.openSources.union(breakers.blocked(now: time.now, background: background))
        return PickContext(now: time.now, banned: library.bannedSet, engine: engineConfig, openBreakers: open,
                           engineReady: engineStatus.isReady, youtubeTokens: status.youtubeTokens,
                           cachedResolutions: ready, feedRevision: feed.document.revision)
    }

    private func previousStream() -> StreamRef? {
        var stack = backStack
        let current = session.current?.id
        if let current, stack.last == current { stack.removeLast() }
        while let id = stack.popLast() {
            guard id != current, let s = catalog[id] else { continue }
            backStack = stack
            return s
        }
        for entry in library.history.reversed() where entry.stream != current {
            if let s = catalog[entry.stream] { return s }
        }
        return nil
    }

    // MARK: Attempts

    /// The attempt for `stream`, reusing one in progress, else a new one carrying the pending trigger.
    private func ensureAttempt(_ stream: StreamRef) -> UInt64 {
        if let a = attempt, a.stream.id == stream.id, a.stage != .playing { return a.generation }
        cancelAttempt()
        generation += 1
        let trigger: Trigger
        var prefetched = false
        if let p = pendingPick, p.id == stream.id {
            trigger = p.trigger
            prefetched = p.prefetched
        } else {
            trigger = takeTrigger()
        }
        pendingPick = nil
        attempt = Attempt(generation: generation, stream: stream, trigger: trigger, attemptNanos: monotonicNanos(),
                          prefetched: prefetched)
        return generation
    }

    private func cancelAttempt() {
        cancelAttemptWork()
        attempt?.task?.cancel()
        attempt?.timer?.cancel()
        if let id = attempt?.stream.id { breakers.releaseProbe(id) }
        attempt = nil
    }

    private func cancelAttemptWork() {
        attempt?.refreshWork?.cancel()
        attempt?.refreshTask?.cancel()
        attempt?.faultWork?.cancel()
    }

    private func isCurrent(_ gen: UInt64) -> Bool { attempt?.generation == gen }

    // MARK: Resolve

    private func performResolve(_ stream: StreamRef) {
        let gen = ensureAttempt(stream)
        attempt?.stage = .resolving
        attempt?.task?.cancel()
        attempt?.timer?.cancel()
        attempt?.timer = scheduler.schedule(after: configuration.timings.resolveTimeout) { [weak self] in
            self?.resolveTimedOut(gen)
        }
        let resolver = self.resolver
        attempt?.task = Task { [weak self] in
            do {
                let resolution = try await resolver.resolve(stream, purpose: .userPick)
                self?.resolveSucceeded(gen, resolution)
            } catch {
                self?.resolveFailed(gen, error)
            }
        }
    }

    private func resolveSucceeded(_ gen: UInt64, _ r: StreamResolution) {
        guard isCurrent(gen), let a = attempt else { return }
        attempt?.timer?.cancel()
        attempt?.resolution = r
        let id = a.stream.id
        switch r.availability {
        case .now:
            dispatch(.resolved(id))
        case .wait(let seconds):
            metrics?.record("availableAt.wait", ["streamId": id.rawValue, "waitSec": seconds])
            attempt?.timer = scheduler.schedule(after: seconds) { [weak self] in
                guard let self, self.isCurrent(gen) else { return }
                self.dispatch(.resolved(id))
            }
        case .deferred(let seconds):
            deferred(a.stream, seconds: seconds, reason: "availableAt")
        }
    }

    private func resolveFailed(_ gen: UInt64, _ error: any Error) {
        guard isCurrent(gen), let a = attempt else { return }
        attempt?.timer?.cancel()
        let s = a.stream
        switch error {
        case is CancellationError:
            return
        case let f as ResolveFailure:
            if f.failureClass == .transient, failureIsOffline() { return }
            note(kind: f.failureClass.rawValue, message: f.description, stream: s, stage: "resolve", reason: f.reason)
            dispatch(.resolveFailed(s.id, FailureClass(f.failureClass)))
        case let e as StreamResolveError:
            switch e {
            case .noToken, .sourceBlocked:
                deferred(s, seconds: 0, reason: "\(e)")
            case .engineMissing:
                note(kind: "engine", message: e.description, stream: s, stage: "resolve")
                dispatch(.resolveFailed(s.id, .engine))
            case .notResolvable:
                counters.unhandledErrors += 1
                note(kind: "internal", message: e.description, stream: s, stage: "resolve")
                dispatch(.resolveFailed(s.id, .unavailable))
            }
        case ResolverError.preempted:
            note(kind: "transient", message: "pre-empted", stream: s, stage: "resolve")
            dispatch(.resolveFailed(s.id, .transient))
        default:
            counters.unhandledErrors += 1
            note(kind: "internal", message: "\(error)", stream: s, stage: "resolve")
            dispatch(.resolveFailed(s.id, .transient))
        }
    }

    private func resolveTimedOut(_ gen: UInt64) {
        guard isCurrent(gen), let a = attempt, a.stage == .resolving else { return }
        attempt?.task?.cancel()
        note(kind: "transient", message: "resolve took over \(Int(configuration.timings.resolveTimeout)) s", stream: a.stream,
             stage: "resolve", reason: "timeout")
        dispatch(.resolveFailed(a.stream.id, .transient))
    }

    /// `available_at` too far ahead, or no YouTube token: keep the resolution, play the next pick (not a failure).
    private func deferred(_ s: StreamRef, seconds: TimeInterval, reason: String) {
        breakers.releaseProbe(s.id)
        counters.deferrals += 1
        deferralsInARow += 1
        metrics?.record("deferred", ["streamId": s.id.rawValue, "source": s.source.rawValue, "waitSec": seconds.rounded(),
                                     "reason": reason])
        note(kind: "deferred", message: reason, stream: s, stage: "resolve")
        if deferralsInARow > configuration.maxDeferralsInARow {
            deferralsInARow = 0
            dispatch(.resolveFailed(s.id, .transient))
        } else {
            dispatch(.resolveDeferred(s.id))
        }
    }

    // MARK: Load

    private func performLoad(_ stream: StreamRef) {
        let gen = ensureAttempt(stream)
        attempt?.stage = .loading
        attempt?.timer?.cancel()
        guard audioFault == nil else { return }
        let proxy = currentProxy()
        let title = LoadPlan.displayTitle(stream)
        if stream.isRadio {
            let hosts = self.hosts
            let walkRedirects = configuration.radioRedirectCheck
            let known = walkRedirects ? (radioHops[stream.id] ?? 0) : 0
            let fetcher = redirectFetcher
            attempt?.task?.cancel()
            attempt?.task = Task { [weak self] in
                var url = stream.url
                var walk: RadioRedirects.Walk?
                do {
                    _ = try await RadioHostCheck.check(stream.url, resolver: hosts)
                    if known > 0 {
                        walk = try await RadioRedirects.walk(stream.url, hosts: hosts, fetch: fetcher, hops: known)
                        url = walk?.url ?? url
                    }
                } catch {
                    self?.radioCheckFailed(gen, error)
                    return
                }
                var options = LoadPlan.radio(title: title, proxy: proxy)
                if walkRedirects { options.lavf.append(LavfOption("max_redirects", "0")) }
                guard let self, self.isCurrent(gen) else { return }
                self.attempt?.radioHops = walk?.hops ?? 0
                self.attempt?.radioOptions = options
                if let walk { self.radioWalked(stream, walk) }
                self.startLoad(gen, url: url, options: options)
            }
        } else {
            guard let r = attempt?.resolution else {
                counters.unhandledErrors += 1
                loadFailed(gen, .transient, "no resolution to load", stage: "load")
                return
            }
            let start = pendingStart?.id == stream.id ? pendingStart?.seconds : nil
            pendingStart = nil
            startLoad(gen, url: r.stream.url, options: LoadPlan.options(for: r.stream, title: title, proxy: proxy, start: start))
        }
    }

    private func radioCheckFailed(_ gen: UInt64, _ error: any Error) {
        let cls: FailureClass = switch error {
        case CanonicalError.nonPublicAddress, RadioRedirects.WalkError.rejectedHop: .unavailable
        default: .transient
        }
        loadFailed(gen, cls, "radio host check: \(error)", stage: "dns")
    }

    private func radioWalked(_ stream: StreamRef, _ walk: RadioRedirects.Walk) {
        metrics?.record("radio.redirects", ["streamId": stream.id.rawValue, "hops": walk.hops, "complete": walk.complete,
                                            "ms": walk.ms, "host": walk.url.host ?? ""])
    }

    /// A station that failed to open with FFmpeg following no redirect: maybe it redirects (once more than last
    /// time). Asks for the redirect target ourselves; a checked target is opened in the same attempt, a refused one
    /// fails the station as unavailable, no redirect means a genuine failure (false: let it fail as usual).
    private func retryRadioRedirect(_ a: Attempt, message: String, cls: FailureClass) -> Bool {
        guard a.stream.isRadio, configuration.radioRedirectCheck, a.stage == .loading, a.radioRetries < 3,
              let loaded = a.loadedURL, let options = a.radioOptions else { return false }
        attempt?.radioRetries += 1
        let gen = a.generation, hops = a.radioHops, stream = a.stream
        let hosts = self.hosts, fetcher = redirectFetcher
        attempt?.task = Task { [weak self] in
            let next: URL?
            do {
                next = try await RadioRedirects.next(after: loaded, hops: hops, hosts: hosts, fetch: fetcher)
            } catch {
                self?.radioCheckFailed(gen, error)
                return
            }
            guard let self, self.isCurrent(gen) else { return }
            guard let next else {
                self.radioHops[stream.id] = nil
                self.note(kind: cls.rawValue, message: message, stream: stream, stage: "load")
                self.dispatch(.playbackFailed(stream.id, cls))
                return
            }
            self.attempt?.radioHops = hops + 1
            self.metrics?.record("radio.redirects", ["streamId": stream.id.rawValue, "hops": hops + 1, "complete": false,
                                                     "host": next.host ?? "", "learned": true])
            self.startLoad(gen, url: next, options: options)
        }
        return true
    }

    private func startLoad(_ gen: UInt64, url: URL, options: LoadFileOptions) {
        guard isCurrent(gen), let a = attempt, session.phase == .buffering, session.current?.id == a.stream.id else { return }
        do {
            let id = try player.load(PlayerLoadRequest(url: url, options: options))
            attempt?.loadID = id
            attempt?.loadedURL = url
            attempt?.timer?.cancel()
            attempt?.timer = scheduler.schedule(after: configuration.timings.firstAudioTimeout) { [weak self] in
                self?.firstAudioTimedOut(gen)
            }
        } catch {
            counters.unhandledErrors += 1
            loadFailed(gen, .transient, "loadfile: \(error)", stage: "load")
        }
    }

    private func loadFailed(_ gen: UInt64, _ cls: FailureClass, _ message: String, stage: String) {
        guard isCurrent(gen), let a = attempt else { return }
        if cls == .transient, failureIsOffline() { return }
        note(kind: cls.rawValue, message: message, stream: a.stream, stage: stage)
        dispatch(.playbackFailed(a.stream.id, cls))
    }

    private func firstAudioTimedOut(_ gen: UInt64) {
        guard isCurrent(gen), let a = attempt, a.stage == .loading else { return }
        player.stop()
        if failureIsOffline() { return }
        note(kind: "transient", message: "no audio within \(Int(configuration.timings.firstAudioTimeout)) s", stream: a.stream,
             stage: "firstAudio", reason: "timeout")
        dispatch(.playbackFailed(a.stream.id, .transient))
    }

    private func currentProxy() -> URL? {
        let p = proxyProvider()
        if p != lastProxy {
            lastProxy = p
            if p.url != nil || p.unsupported != nil {
                log.info("proxy: \(p.description, privacy: .public)")
                metrics?.record("proxy", ["origin": p.origin.rawValue, "url": p.url?.absoluteString ?? "",
                                          "unsupported": p.unsupported ?? ""])
            }
        }
        return p.url
    }

    // MARK: Engine events

    private func handle(_ event: PlayerEvent) {
        switch event {
        case let .firstAudio(loadID, nanos):
            guard let a = attempt, a.loadID == loadID, a.stage == .loading else { return }
            firstAudio(a, nanos: nanos)
        case let .ended(loadID, reason):
            guard let a = attempt, a.loadID == loadID else { return }
            attempt?.timer?.cancel()
            switch reason {
            case .endOfFile:
                metrics?.record("eof", ["streamId": a.stream.id.rawValue])
                if a.stage == .playing, endedEarly(a), recover(a, reason: "prematureEOF", engineClass: false) { return }
                endOfFile(a)
            case let .error(message, cls):
                if failureIsOffline() { return }
                if a.stage == .playing, recover(a, reason: message, engineClass: cls == .engine) { return }
                if retryRadioRedirect(a, message: message, cls: a.stream.isRadio && cls == .engine ? .unavailable : cls) {
                    return
                }
                let c: FailureClass = a.stream.isRadio && cls == .engine ? .unavailable : cls
                note(kind: c.rawValue, message: message, stream: a.stream, stage: a.stage == .playing ? "stream" : "load")
                dispatch(.playbackFailed(a.stream.id, c))
            }
        }
    }

    // MARK: Stream recovery (DESIGN §6.3: re-resolve 10 min before expiry; a mid-stream error reloads at time-pos)

    /// A VOD that stopped well before mpv's own duration: a dead URL can read as end of file.
    private func endedEarly(_ a: Attempt) -> Bool {
        guard !a.stream.isRadio, !a.stream.kind.isLive, let d = lastPosition.duration, d.isFinite, d > 0,
              let pos = lastPosition.timePos else { return false }
        return pos < d - configuration.timings.prematureEndMargin
    }

    /// Reloads a stream that died while playing: a VOD at its position (`start=<time-pos>`), live and radio at the
    /// live edge, from the background re-resolve if one ran, else re-resolved (an engine-class error or an expired URL
    /// evicts the cached one first). One reload per error; at most `recoveryLimit` per stream per `recoveryWindow`,
    /// and only after it has played `recoveryMinimumPlay`. Returns false when the failure should move on instead.
    private func recover(_ a: Attempt, reason: String, engineClass: Bool) -> Bool {
        let t = configuration.timings
        let now = time.now
        guard !isShutDown, session.phase == .playing, session.current?.id == a.stream.id,
              !library.bannedSet.contains(a.stream.id), let since = a.playingSince,
              now.timeIntervalSince(since) >= t.recoveryMinimumPlay else { return false }
        var log = (recoveryLog[a.stream.id] ?? []).filter { now.timeIntervalSince($0) < t.recoveryWindow }
        guard log.count < t.recoveryLimit else {
            metrics?.record("recover", ["streamId": a.stream.id.rawValue, "ok": false, "reason": "limit"])
            return false
        }
        log.append(now)
        recoveryLog[a.stream.id] = log
        counters.recoveries += 1
        let s = a.stream
        let vod = !s.isRadio && !s.kind.isLive
        let position = vod ? (player.position().timePos ?? lastPosition.timePos) : nil
        if let position, position > 0 { pendingStart = (s.id, position) }
        let expired = a.resolution.flatMap(\.stream.expiresAt).map { $0 - 60 < time.now.timeIntervalSince1970 } ?? false
        let refreshed = a.refreshed != nil && a.refreshed?.stream.url != a.loadedURL
        let evict = !s.isRadio && !refreshed && (engineClass || expired)
        recovering = (s.id, position, String(reason.prefix(120)))
        var fields: [String: any Sendable] = ["streamId": s.id.rawValue, "source": s.source.rawValue,
                                              "reason": String(reason.prefix(200)), "refreshed": refreshed,
                                              "evicted": evict]
        if let position { fields["position"] = (position * 10).rounded() / 10 }
        metrics?.record("recover", fields)
        self.log.notice("mid-stream failure on \(s.id.rawValue, privacy: .public) (\(reason, privacy: .public)): reloading")
        player.stop()
        let resolver = self.resolver
        let id = s.id
        Task { [weak self] in
            if evict { await resolver.evict(id) }
            guard let self, self.session.current?.id == id, self.session.phase == .playing else { return }
            self.user("recover", reload: true) { self.dispatch(.reloadCurrent) }
        }
        return true
    }

    /// After first audio of a resolved stream: the background re-resolve 10 min before its URL expires (and the
    /// `stream:expire` fault's version of it, plus its injected 403).
    private func scheduleRefresh(_ gen: UInt64) {
        guard let a = attempt, a.generation == gen, !a.stream.isRadio, let r = a.resolution else { return }
        let fault = configuration.faults.streamExpire && !a.stream.kind.isLive && !expireFaulted.contains(a.stream.id)
        var delay: TimeInterval?
        if fault {
            delay = configuration.faults.expireRefreshAfter
        } else if let expires = r.stream.expiresAt {
            delay = max(1, expires - configuration.timings.refreshBeforeExpiry - time.now.timeIntervalSince1970)
        }
        if let delay {
            attempt?.refreshWork?.cancel()
            attempt?.refreshWork = scheduler.schedule(after: delay) { [weak self] in self?.performRefresh(gen) }
        }
        if fault {
            expireFaulted.insert(a.stream.id)
            attempt?.faultWork?.cancel()
            attempt?.faultWork = scheduler.schedule(after: configuration.faults.expireFailAfter) { [weak self] in
                guard let self, let a = self.attempt, a.generation == gen, a.stage == .playing else { return }
                self.metrics?.record("fault.streamExpire", ["streamId": a.stream.id.rawValue,
                                                            "position": (self.player.position().timePos ?? 0).rounded()])
                self.player.stop()
                let message = "HTTP error 403 Forbidden (SUDAMP_FAULT=stream:expire)"
                if !self.recover(a, reason: message, engineClass: true) {
                    self.note(kind: "engine", message: message, stream: a.stream, stage: "stream")
                    self.dispatch(.playbackFailed(a.stream.id, .engine))
                }
            }
        }
    }

    /// Re-resolves the playing stream in the background (into the cache), so a later mid-stream failure reloads
    /// with a fresh URL. A failure is retried after `refreshRetry`, and never fails the stream by itself.
    private func performRefresh(_ gen: UInt64) {
        guard let a = attempt, a.generation == gen, [.playing, .paused].contains(session.phase) else { return }
        attempt?.refreshWork = nil
        attempt?.refreshTries += 1
        let s = a.stream
        let resolver = self.resolver
        let started = monotonicNanos()
        attempt?.refreshTask = Task { [weak self] in
            // The entry still in the cache is the URL that is about to expire: never hand it back.
            await resolver.evict(s.id)
            let result: Result<StreamResolution, any Error>
            do { result = .success(try await resolver.resolve(s, purpose: .prefetch)) } catch { result = .failure(error) }
            guard let self, let cur = self.attempt, cur.generation == gen else { return }
            let ms = Double(monotonicNanos() - started) / 1e6
            switch result {
            case .success(let r):
                self.attempt?.refreshed = r
                self.counters.refreshes += 1
                self.metrics?.record("refresh", ["streamId": s.id.rawValue, "source": s.source.rawValue, "ok": true,
                                                 "ms": ms.rounded(), "expiresAt": r.stream.expiresAt ?? 0])
            case .failure(let error):
                self.metrics?.record("refresh", ["streamId": s.id.rawValue, "source": s.source.rawValue, "ok": false,
                                                 "ms": ms.rounded(), "error": "\(error)"])
                if error is CancellationError { return }
                if cur.refreshTries < self.configuration.timings.refreshAttempts {
                    self.attempt?.refreshWork = self.scheduler.schedule(after: self.configuration.timings.refreshRetry) {
                        [weak self] in self?.performRefresh(gen)
                    }
                }
            }
        }
    }


    private func firstAudio(_ a: Attempt, nanos: UInt64) {
        attempt?.timer?.cancel()
        attempt?.stage = .playing
        attempt?.playingSince = time.now
        let ms = nanos > a.trigger.nanos ? Double(nanos - a.trigger.nanos) / 1e6 : 0
        let attemptMs = nanos > a.attemptNanos ? Double(nanos - a.attemptNanos) / 1e6 : 0
        let info = TTFAInfo(ms: (ms * 10).rounded() / 10, attemptMs: (attemptMs * 10).rounded() / 10, source: a.stream.source,
                            streamId: a.stream.id, tier: a.resolution?.tier.rawValue, prefetched: a.prefetched,
                            fromCache: a.resolution?.fromCache ?? false, trigger: a.trigger.name, at: time.now)
        recentTTFA.append(info)
        if recentTTFA.count > 50 { recentTTFA.removeFirst(recentTTFA.count - 50) }
        ttfaHistory.append(info)
        if ttfaHistory.count > 200 { ttfaHistory.removeFirst(ttfaHistory.count - 200) }
        var fields: [String: any Sendable] = [
            "ms": ms.rounded(), "attemptMs": attemptMs.rounded(), "source": a.stream.source.rawValue, "streamId": a.stream.id.rawValue,
            "prefetched": a.prefetched, "fromCache": info.fromCache, "trigger": a.trigger.name, "reload": a.trigger.reload,
        ]
        if let tier = info.tier { fields["tier"] = tier }
        if let g = session.genre { fields["genre"] = g.rawValue }
        metrics?.record("ttfa", fields)
        deferralsInARow = 0
        let failures = player.guardFailures()
        if !failures.isEmpty { return raiseAudioFault(failures.joined(separator: "; ")) }
        if !a.trigger.reload {
            counters.streamsStarted += 1
            backStack.append(a.stream.id)
            if backStack.count > 50 { backStack.removeFirst(backStack.count - 50) }
        }
        lastPosition = player.position()
        if a.stream.isRadio, configuration.radioRedirectCheck, radioHops[a.stream.id] ?? 0 != a.radioHops {
            radioHops[a.stream.id] = a.radioHops == 0 ? nil : a.radioHops
            schedulePersist()
        }
        if let r = recovering, r.id == a.stream.id {
            recovering = nil
            var fields: [String: any Sendable] = ["streamId": a.stream.id.rawValue, "ms": ms.rounded(),
                                                  "source": a.stream.source.rawValue, "fromCache": info.fromCache]
            if let saved = r.savedPosition { fields["savedPosition"] = (saved * 10).rounded() / 10 }
            if let now = lastPosition.timePos { fields["resumedPosition"] = (now * 10).rounded() / 10 }
            metrics?.record("recover.resumed", fields)
        }
        dispatch(.started(a.stream.id))
        scheduleRefresh(a.generation)
    }

    /// DESIGN §5.3: a failed runtime guard is logged, shows AUDIO ENGINE ERROR and blocks playback; debug asserts.
    private func raiseAudioFault(_ reason: String) {
        guard audioFault == nil else { return }
        audioFault = reason
        log.fault("AUDIO ENGINE ERROR: \(reason, privacy: .public)")
        metrics?.record("guard", ["ok": false, "failures": reason])
        note(kind: "audioEngine", message: reason, stream: attempt?.stream, stage: "guard")
        cancelAttempt()
        player.stop()
        dispatch(.stop)
        publish()
        if configuration.assertOnGuardFailure { assertionFailure("AUDIO ENGINE ERROR: \(reason)") }
    }

    // MARK: Pause, resume, stop

    private func performPause() {
        pausedAt = time.now
        let player = self.player
        Task { await player.pause() }
    }

    private func performResume() {
        pausedAt = nil
        player.resume(fadeSeconds: 0)
    }

    private func resumeFromPause() {
        guard let current = session.current else { return user("play") { dispatch(.play) } }
        let pausedFor = pausedAt.map { time.now.timeIntervalSince($0) } ?? 0
        guard current.kind.isLive, pausedFor > configuration.timings.liveReloadAfter else {
            return user("play") { dispatch(.play) }
        }
        counters.liveReloads += 1
        metrics?.record("liveReload", ["streamId": current.id.rawValue, "source": current.source.rawValue,
                                       "pausedSec": pausedFor.rounded()])
        log.info("live stream paused \(Int(pausedFor)) s: reloading at the live edge")
        pausedAt = nil
        user("liveReload", reload: true) { dispatch(.reloadCurrent) }
    }

    private func performStop() {
        cancelAttempt()
        prefetchWork?.cancel()
        pausedAt = nil
        player.stop()
    }

    // MARK: Outcomes

    private func record(_ id: StreamID, _ outcome: PickOutcome) {
        let source = attempt?.stream.id == id ? attempt?.stream.source : (catalog[id]?.source ?? id.source)
        switch outcome {
        case .success:
            picker.recordSuccess(id)
            if let source { breakerChanged(breakers.recordSuccess(source, stream: id, now: time.now)) }
            if attempt?.trigger.reload != true { library.recordPlay(id, genre: session.genre, at: time.now) }
        case .failure(let failure):
            counters.failures += 1
            if recovering?.id == id { recovering = nil }
            picker.recordFailure(id, failure, now: time.now)
            if let source { breakerChanged(breakers.recordFailure(source, stream: id, failure: failure, now: time.now)) }
        }
    }

    /// A breaker opened, re-opened or reset: log it, extend YouTube's resolver pause, persist, and react to a run of
    /// engine failures (rollback or update check).
    private func breakerChanged(_ event: BreakerEvent) {
        switch event.change {
        case .tripped:
            counters.breakerTrips += 1
            let until = event.reopenAt ?? time.now
            log.notice("breaker \(event.platform.rawValue, privacy: .public) open (\(event.kind?.rawValue ?? "?", privacy: .public)) until \(until, privacy: .public)")
            metrics?.record("breaker", ["platform": event.platform.rawValue, "change": "open",
                                        "kind": event.kind?.rawValue ?? "", "reopenAt": until.timeIntervalSince1970,
                                        "durationSec": (event.duration ?? 0).rounded(),
                                        "trips": breakers[event.platform].trips[event.kind ?? .engine] ?? 0])
            if event.kind == .botCheck {
                let resolver = self.resolver
                Task { await resolver.blockPlatform(event.platform, until: until) }
            }
            schedulePersist()
        case .reset:
            metrics?.record("breaker", ["platform": event.platform.rawValue, "change": "reset"])
            schedulePersist()
        case .counted, .ignored:
            break
        }
        if event.engineFailuresTripped { engineFailuresInARow(event.platform) }
    }

    private func note(kind: String, message: String, stream: StreamRef?, stage: String, reason: String? = nil) {
        lastError = PlaybackErrorInfo(kind: kind, message: message, streamId: stream?.id, stage: stage, at: time.now)
        guard kind != "deferred" else { return }
        log.notice("\(stage, privacy: .public) \(kind, privacy: .public) \(stream?.id.rawValue ?? "-", privacy: .public): \(message, privacy: .public)")
        var fields: [String: any Sendable] = ["kind": kind, "stage": stage, "message": String(message.prefix(300))]
        if let stream {
            fields["streamId"] = stream.id.rawValue
            fields["source"] = stream.source.rawValue
        }
        if let reason { fields["reason"] = reason }
        metrics?.record("failure", fields)
    }

    // MARK: Prefetch (depth 1, ~10 s after first audio)

    private func schedulePrefetch(_ genre: GenreID) {
        guard configuration.prefetchEnabled, !favouritesMode else { return }
        if let p = prefetch, p.genre == genre { return }
        prefetchWork?.cancel()
        let during = session.current?.id
        prefetchWork = scheduler.schedule(after: configuration.timings.prefetchDelay) { [weak self] in
            self?.performPrefetch(genre, during: during)
        }
    }

    private func performPrefetch(_ genre: GenreID, during id: StreamID?) {
        guard session.phase == .playing, session.genre == genre, session.current?.id == id, prefetch == nil else { return }
        let token = pickToken
        Task { [weak self] in
            guard let self else { return }
            let status = await self.resolver.status()
            guard token == self.pickToken, self.session.phase == .playing, self.session.genre == genre,
                  self.prefetch == nil, !self.isShutDown else { return }
            guard let s = self.picker.next(genre: genre, context: self.context(status, background: true), fastStart: false,
                                           using: &self.rng),
                  s.id != id else { return }
            self.startPrefetch(s, genre: genre, purpose: .prefetch)
        }
    }

    private func startPrefetch(_ s: StreamRef, genre: GenreID, purpose: ResolvePurpose) {
        counters.prefetches += 1
        metrics?.record("prefetch.pick", ["streamId": s.id.rawValue, "source": s.source.rawValue, "genre": genre.rawValue,
                                          "purpose": purpose.rawValue])
        guard !s.isRadio else {
            prefetch = Prefetch(genre: genre, stream: s, state: .ready)
            return
        }
        prefetch = Prefetch(genre: genre, stream: s, state: .resolving)
        let resolver = self.resolver
        prefetch?.task = Task { [weak self] in
            do {
                let r = try await resolver.resolve(s, purpose: purpose)
                self?.prefetchFinished(s, .success(r))
            } catch {
                self?.prefetchFinished(s, .failure(error))
            }
        }
    }

    private func prefetchFinished(_ s: StreamRef, _ result: Result<StreamResolution, any Error>) {
        guard prefetch?.stream.id == s.id else { return }
        switch result {
        case .success(let r):
            prefetch?.state = .ready
            metrics?.record("prefetch", ["streamId": s.id.rawValue, "source": s.source.rawValue, "ok": true,
                                         "ms": r.elapsedMs.rounded(), "tier": r.tier.rawValue, "fromCache": r.fromCache])
        case .failure(let error):
            var fields: [String: any Sendable] = ["streamId": s.id.rawValue, "source": s.source.rawValue, "ok": false,
                                                  "error": "\(error)"]
            if let f = error as? ResolveFailure {
                fields["class"] = f.failureClass.rawValue
                picker.recordFailure(s.id, FailureClass(f.failureClass), now: time.now)
                breakerChanged(breakers.recordFailure(s.source, stream: s.id, failure: FailureClass(f.failureClass),
                                                      now: time.now))
                counters.failures += 1
                prefetch = nil
            } else if case ResolverError.preempted = error {
                prefetch?.state = .unresolved
            } else {
                prefetch = nil
            }
            metrics?.record("prefetch", fields)
        }
    }

    // MARK: Network

    private func networkChanged(_ status: NetworkPathStatus) {
        let change = NetworkPathChange.between(networkStatus, status)
        networkStatus = status
        if change != .unchanged, change != .initial {
            metrics?.record("network", ["change": change.rawValue, "path": status.signature])
        }
        switch change {
        case .initial:
            if !status.isSatisfied { scheduleOffline() }
        case .lost:
            scheduleOffline()
        case .restored:
            if let work = offlineWork {
                // A blip shorter than the debounce: never went offline, but the route (and IP) may have changed.
                work.cancel()
                offlineWork = nil
                dropIPBoundResolutions {}
            } else {
                dropIPBoundResolutions { [weak self] in self?.networkCameBack() }
            }
            if engineStatus.state == .failed, engineStatus.download == "unreachable" { ensureEngine() }
        case .changed:
            dropIPBoundResolutions {}
        case .unchanged:
            break
        }
        publish()
    }

    /// The path is gone: go offline once it has stayed gone for `offlineDebounce` (Wi-Fi roaming blips are ignored),
    /// or `offlineDebouncePlaying` while a stream plays on from its cache.
    private func scheduleOffline() {
        guard offlineWork == nil, session.phase != .offline else { return }
        let t = configuration.timings
        let delay = session.phase == .playing ? t.offlineDebouncePlaying : t.offlineDebounce
        offlineWork = scheduler.schedule(after: delay) { [weak self] in
            self?.offlineWork = nil
            self?.goOffline(reason: "path")
        }
    }

    /// DESIGN §3 "Offline: OFFLINE; resumes by itself": the stream stops (a VOD remembers its position) and the
    /// session waits in `offline` for the path to come back. A paused stream stays paused and loaded.
    private func goOffline(reason: String) {
        offlineWork?.cancel()
        offlineWork = nil
        guard [.tuning, .buffering, .playing, .paused].contains(session.phase) else { return }
        counters.offlineEpisodes += 1
        if session.phase != .paused, let s = session.current {
            if attempt?.stage == .playing { offlineInterrupted = s.id }
            if !s.isRadio, !s.kind.isLive, let pos = player.position().timePos ?? lastPosition.timePos, pos > 1 {
                pendingStart = (s.id, pos)
            }
            prefetch?.task?.cancel()
            prefetch = nil
            cancelAttempt()
            player.stop()
        }
        metrics?.record("offline", ["reason": reason, "streamId": session.current?.id.rawValue ?? "",
                                    "position": pendingStart?.seconds.rounded() ?? 0])
        log.notice("offline (\(reason, privacy: .public))")
        dispatch(.networkLost)
    }

    /// The path is back after an offline episode: the session resumes by itself (DESIGN §3), a VOD at its position.
    private func networkCameBack() {
        guard session.phase == .offline else { return }
        let resumed = offlineInterrupted
        offlineInterrupted = nil
        metrics?.record("online", ["streamId": session.current?.id.rawValue ?? ""])
        if let resumed, session.current?.id == resumed {
            user("networkRestored", reload: true) { dispatch(.networkRestored) }
        } else {
            user("networkRestored") { dispatch(.networkRestored) }
        }
    }

    /// A failure while the path is down is the network's, not the stream's: go offline instead of skipping.
    private func failureIsOffline() -> Bool {
        guard let status = networkStatus, !status.isSatisfied else { return false }
        goOffline(reason: "failure while the path is down")
        return true
    }

    /// YouTube URLs are IP-bound: drop them (and an IP-bound prefetch) before anything is resolved again.
    private func dropIPBoundResolutions(then next: @escaping () -> Void) {
        if prefetch?.stream.source.platform == .youtube {
            prefetch?.task?.cancel()
            prefetch = nil
        }
        let resolver = self.resolver
        Task { [weak self] in
            _ = await resolver.networkPathChanged()
            guard self != nil else { return }
            next()
        }
    }

    // MARK: Persistence and debug state

    private func schedulePersist() {
        guard configuration.persistState, persistWork == nil else { return }
        persistWork = scheduler.schedule(after: configuration.timings.persistDebounce) { [weak self] in
            self?.persistWork = nil
            self?.persistNow()
        }
    }

    /// Writes session.json and library.json now (atomic). The quit path calls it.
    public func persistNow() {
        guard configuration.persistState else { return }
        persistWork?.cancel()
        persistWork = nil
        var last = resumedFrom
        if let genre = session.genre {
            let vod = session.current.map { !$0.kind.isLive } ?? false
            last = LastSession(genre: genre, stream: session.current?.id, positionSec: vod ? lastPosition.timePos : nil,
                               wasPlaying: [.playing, .buffering, .tuning].contains(session.phase), savedAt: time.now)
        }
        do {
            try StateFile.save(SessionFile(picker: picker.state, last: last, breakers: breakers,
                                           radioRedirectHops: radioHops.isEmpty ? nil : radioHops),
                               to: configuration.paths.sessionFile)
            try StateFile.save(library, to: configuration.paths.libraryFile)
        } catch {
            counters.unhandledErrors += 1
            log.error("cannot save session state: \(error, privacy: .public)")
        }
    }

    /// - Parameter soon: a change readers wait for (state, stream, errors, the shell's state); otherwise only the
    ///   playback position moved, which is written at most every `debugStateProgressInterval` (encoding the whole
    ///   document every second while playing cost measurable CPU, PLAN M5).
    private func scheduleDebugState(soon: Bool = true) {
        guard configuration.writeDebugState, !isShutDown else { return }
        if debugWork != nil {
            guard soon, debugWorkIsSlow else { return }
            debugWork?.cancel()
        }
        debugWorkIsSlow = !soon
        let delay = soon ? configuration.timings.debugStateDebounce : configuration.timings.debugStateProgressInterval
        debugWork = scheduler.schedule(after: delay) { [weak self] in
            self?.debugWork = nil
            Task { await self?.writeDebugStateNow() }
        }
    }

    private var debugWorkIsSlow = false

    /// Everything `state.json` holds.
    public func debugState() async -> PlaybackDebugState {
        let status = await resolver.status()
        let s = snapshot
        return PlaybackDebugState(
            state: isShutDown ? "shutdown" : s.stateName, genre: s.genre, source: s.stream?.source, ttfaMs: s.lastTTFA?.ms, stream: s.stream,
            engine: s.engine, lastError: s.lastError, resumed: didAutoResume, resumePlan: resumePlan?.description,
            nowPlaying: publishedNowPlaying, snapshot: s, resolver: status,
            prefetched: prefetch?.stream.id, network: networkStatus, proxy: lastProxy?.description, counters: counters,
            recentTTFA: recentTTFA, player: player.diagnostics(), pid: getpid(), updatedAt: time.now,
            skin: shellSkin, ui: shellUI,
            library: LibraryDebugInfo(favourites: library.favourites, banned: library.banned,
                                      historyCount: library.history.count),
            breakers: breakers.summary(now: time.now), engineUpdate: lastUpdate, engineWarmUp: lastWarmUp)
    }

    /// The source breakers by platform (reports, state.json).
    public func breakerSummary() -> [String: BreakerSummary] { breakers.summary(now: time.now) }
    /// The last engine update check, if one ran.
    public var lastEngineUpdate: EngineUpdateOutcome? { lastUpdate }
    public var engineWarmUp: EngineWarmUp? { lastWarmUp }

    /// Writes `<profile>/debug/state.json` atomically.
    public func writeDebugStateNow() async {
        let state = await debugState()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let url = configuration.paths.debugState
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            log.error("cannot write state.json: \(error, privacy: .public)")
        }
    }

    // MARK: Snapshot

    /// Snapshots from now on, starting with the current one.
    public func snapshots() -> AsyncStream<PlayerSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: PlayerSnapshot.self, bufferingPolicy: .bufferingNewest(32))
        let id = UUID()
        subscribers[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    private func scheduleTick() {
        tickWork = scheduler.schedule(after: configuration.timings.positionRefresh) { [weak self] in
            guard let self, self.session.phase == .playing else { return }
            self.lastPosition = self.player.position()
            // The every-read guard (DESIGN §5.3). The first-file checks ran at first audio; re-running them here
            // could catch mpv between files (no AO params yet) and fault a healthy engine.
            let refused = self.player.diagnostics().aoErrorCount
            if refused != 0 { return self.raiseAudioFault("pull AO refused \(refused) read(s)") }
            self.publish()
            self.scheduleTick()
        }
    }

    private func publish() {
        let s = makeSnapshot()
        guard s != snapshot else { return }
        let progressOnly = s.sameExceptProgress(snapshot)
        snapshot = s
        onSnapshot?(s)
        for c in subscribers.values { c.yield(s) }
        scheduleDebugState(soon: !progressOnly)
    }

    private func makeSnapshot() -> PlayerSnapshot {
        let phase = session.phase
        let showsPosition = [.playing, .paused, .buffering].contains(phase)
        var snapshot = PlayerSnapshot(
            phase: phase, genre: session.genre, genreName: session.genre.flatMap { catalog.genre($0)?.name },
            stream: session.current.map(StreamInfo.init), icyTitle: showsPosition ? lastPosition.icyTitle : nil,
            position: showsPosition ? lastPosition.timePos : nil, duration: showsPosition ? lastPosition.duration : nil,
            seekable: showsPosition ? lastPosition.seekable : nil, engine: engineStatus, radioOnly: !engineStatus.isReady,
            audioEngineError: audioFault, offline: phase == .offline, lastError: lastError, lastTTFA: recentTTFA.last,
            statusText: statusText(), volume: volume, balance: balance, streamsStarted: counters.streamsStarted,
            failuresInARow: session.failuresInARow)
        snapshot.audioFormat = [.playing, .paused].contains(phase) ? AudioFormatInfo(lastPosition) : nil
        snapshot.isFavourite = session.current.map { library.favourites.contains($0.id) } ?? false
        snapshot.favouritesMode = favouritesMode
        snapshot.shuffleGenres = shuffleGenres
        snapshot.repeatStream = repeatStream
        snapshot.canSeek = canSeek
        return snapshot
    }

    /// The marquee/status-line text (DESIGN §3 failure states).
    private func statusText() -> String {
        if audioFault != nil { return PlayerSnapshot.audioEngineErrorText }
        let skipping = skippedAt.map { time.now.timeIntervalSince($0) < configuration.timings.flashDuration } ?? false
        switch session.phase {
        case .offline: return FlashMessage.offline.text
        case .failed: return FlashMessage.cantReachStreams.text
        case .tuning, .buffering:
            return skipping ? FlashMessage.skipping.text : FlashMessage.tuning.text
        case .playing, .paused:
            guard let s = session.current else { return FlashMessage.tuning.text }
            let genre = favouritesMode ? "[FAVOURITES] "
                : session.genre.flatMap { catalog.genre($0)?.name }.map { "[\($0.uppercased())] " } ?? ""
            if s.isRadio, let icy = lastPosition.icyTitle, !icy.isEmpty { return genre + icy }
            return genre + LoadPlan.displayTitle(s).uppercased()
        case .idle:
            if engineStatus.state == .installing, let notice = engineStatus.notice { return notice }
            return PlayerSnapshot.idleText
        }
    }
}
