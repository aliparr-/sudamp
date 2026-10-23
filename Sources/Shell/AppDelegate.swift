// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Core
import Darwin
import Playback
import os

/// The app's lifecycle (DESIGN §4): builds the AppContext, the front end (the modern or classic skin through
/// `PlayerStyleHost` by default, M2's plain window with `--plain`), menus, status item and Now Playing; routes `sudamp://` URLs and skin files; runs the first
/// and returning launch (DESIGN §3); and owns the one quit path that ⌘Q, `sudamp://quit`, closing Main and
/// SIGTERM/SIGINT all take.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The whole quit sequence must finish within the PLAN's 2 s; past this, exit anyway (session.json is flushed
    /// first, so only the engine teardown can be cut short).
    static let quitDeadline: TimeInterval = 1.8

    private let launch: LaunchArguments
    private let shellArguments: ShellArguments
    private let paths: Paths
    private let lock: InstanceLock
    private let script: ShellAutomationScript?
    private var context: AppContext?
    private var frontEnd: (any PlayerFrontEnd)?
    /// The modern or classic skin (nil with `--plain`).
    private var styles: PlayerStyleHost?
    private var menus: AppMenus?
    private var nowPlaying: NowPlayingController?
    private var signals: SignalWatcher?
    private var pendingURLs: [String]
    private var pendingSkinFiles: [String] = []
    private var ready = false
    private var quitRequested = false
    private var quitting = false
    private var mayTerminate = false
    private let log = Log.logger("app")

    init(launch: LaunchArguments, shellArguments: ShellArguments, paths: Paths, lock: InstanceLock,
         script: ShellAutomationScript?) {
        self.launch = launch
        self.shellArguments = shellArguments
        self.paths = paths
        self.lock = lock
        self.script = script
        pendingURLs = launch.urls
        super.init()
    }

    private var isAutomation: Bool { script != nil }

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        let context: AppContext
        do {
            context = try AppContext(launch: launch, paths: paths, lock: lock)
        } catch {
            fail(error.description)
        }
        self.context = context
        context.onQuit = { [weak self] reason in self?.quit(reason: reason) }
        context.onShow = { [weak self] in
            guard let self, !self.isAutomation else { return }
            self.frontEnd?.show(activate: true)
        }
        context.onURLs = { [weak self] urls, origin in self?.receive(urls, origin: origin) }
        context.onSkinFiles = { [weak self] files, origin in self?.receiveSkins(files, origin: origin) }
        context.onOpenStreamURL = { [weak self] in self?.frontEnd?.promptForStreamURL() }
        context.onPickGenre = { [weak self] in self?.frontEnd?.pickGenre() }
        // SIGTERM and SIGINT take the quit path (DESIGN §4: a Core DispatchSource; Shell's handler terminates).
        signals = SignalWatcher { [weak self] sig in
            Task { @MainActor in self?.quit(reason: sig == SIGTERM ? "SIGTERM" : "SIGINT") }
        }
        let menus = AppMenus(context: context)
        self.menus = menus
        context.startInstanceServer()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let context else { return }
        let frontEnd: any PlayerFrontEnd
        if launch.plain {
            let window = PlainWindowController(context: context)
            frontEnd = window
            menus?.onVolumeChanged = { [weak window] in window?.syncVolume() }
        } else {
            let override = (shellArguments.style ?? script?.style).flatMap(SkinClass.init(rawValue:))
            let host = PlayerStyleHost(context: context, arguments: shellArguments, automation: isAutomation,
                                       styleOverride: override)
            host.appMenus = menus
            styles = host
            frontEnd = host
            menus?.styles = host
        }
        self.frontEnd = frontEnd
        menus?.frontEnd = frontEnd
        menus?.installMainMenu(skinned: styles != nil)
        frontEnd.publishDebugState()
        if let script {
            ready = true
            runAutomation(script, context: context, frontEnd: frontEnd)
            return
        }
        menus?.installStatusItem()
        nowPlaying = NowPlayingController(context: context)
        frontEnd.show(activate: true)
        Task { [weak self] in
            await context.controller.prepare()
            context.refreshAvailability()
            self?.finishLaunch(context: context, frontEnd: frontEnd)
        }
    }

    /// After `prepare()`: URLs from the launch win over auto-resume; otherwise the returning launch resumes and the
    /// first launch opens the genre menu once (DESIGN §3).
    private func finishLaunch(context: AppContext, frontEnd: any PlayerFrontEnd) {
        ready = true
        if !pendingSkinFiles.isEmpty {
            let files = pendingSkinFiles
            pendingSkinFiles = []
            frontEnd.loadSkinFiles(files, origin: "launch")
        }
        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs = []
            for url in urls { context.handle(url: url, origin: "launch") }
            return
        }
        let firstLaunch = context.isFirstLaunch
        let plan = context.autoResume()
        if case .none = plan, firstLaunch { frontEnd.openGenreMenuSoon() }
    }

    private func runAutomation(_ script: ShellAutomationScript, context: AppContext, frontEnd: any PlayerFrontEnd) {
        let runner = AutomationRunner(script: script, context: context, frontEnd: frontEnd)
        Task {
            let (output, ok) = await runner.run()
            FileHandle.standardOutput.write(output)
            fflush(stdout)
            await context.shutdown()
            exit(ok ? 0 : 1)
        }
    }

    private func fail(_ message: String) -> Never {
        log.fault("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("sudamp: \(message)\n".utf8))
        if !isAutomation {
            let alert = NSAlert()
            alert.messageText = "sudamp can't start"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
        }
        exit(1)
    }

    // MARK: URLs, Dock, reopen

    /// `sudamp://…` from LaunchServices (`open 'sudamp://genre/deep-house'`): AppKit's default GetURL handler. Skin
    /// files opened with sudamp (`open -a sudamp x.wsz`, a drop on the Dock icon) arrive here too.
    func application(_ application: NSApplication, open urls: [URL]) {
        let skins = urls.filter { $0.isFileURL && ShellArguments.isSkinPath($0.path) }.map(\.path)
        let others = urls.filter { !($0.isFileURL && ShellArguments.isSkinPath($0.path)) }
        if !skins.isEmpty { receiveSkins(skins, origin: "openFile") }
        if !others.isEmpty { receive(others.map(\.absoluteString), origin: "urlScheme") }
    }

    /// Skin files wait for the launch to settle like URLs, then go to the front end.
    private func receiveSkins(_ files: [String], origin: String) {
        guard ready, let frontEnd else {
            pendingSkinFiles += files
            return
        }
        frontEnd.loadSkinFiles(files, origin: origin)
    }

    /// URLs from LaunchServices or a forwarded launch. Until the launch has settled they wait, and then win over
    /// the auto-resume.
    private func receive(_ urls: [String], origin: String) {
        guard ready, let context else {
            pendingURLs += urls
            return
        }
        for url in urls { context.handle(url: url, origin: origin) }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { menus?.dockMenu() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !isAutomation { frontEnd?.show(activate: true) }
        return true
    }

    /// The window's close quits through the quit path itself (so it isn't asked twice).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Quit path

    /// Every quit request lands here (⌘Q, `sudamp://quit`, window close, SIGTERM, SIGINT).
    func quit(reason: String) {
        guard !quitRequested, !quitting else { return }
        quitRequested = true
        log.info("quit: \(reason, privacy: .public)")
        context?.controller.metrics?.record("app.quitRequested", ["reason": reason])
        // Not `NSApp.terminate(nil)` here: callers run inside a main-actor job (a main-queue block), and AppKit's
        // `.terminateLater` wait is a nested run loop that cannot drain the main queue from inside one, so the
        // shutdown Task would never start. A zero-delay perform enters terminate from the run loop instead, in
        // every mode (an open menu tracks in its own mode), after closing any open menu.
        frontEnd?.cancelMenuTracking()
        NSApp.mainMenu?.cancelTracking()
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0, inModes: [.common])
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if mayTerminate { return .terminateNow }
        guard !quitting else { return .terminateCancel }
        quitting = true
        log.info("quit path: terminate requested")
        armQuitWatchdog()
        Task { [weak self] in
            self?.nowPlaying?.shutdown()
            self?.styles?.close()
            await self?.context?.shutdown()
            self?.log.info("quit path: done")
            self?.mayTerminate = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Last resort for the 2 s quit budget: a wedged engine teardown must not keep the process alive.
    private func armQuitWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + Self.quitDeadline)
        timer.setEventHandler {
            Logger(subsystem: BuildInfo.logSubsystem, category: "app").fault("quit path over its deadline: exiting")
            _exit(0)
        }
        timer.resume()
        quitWatchdog = timer
    }

    private var quitWatchdog: (any DispatchSourceTimer)?
}
