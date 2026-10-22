// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Catalog
import Core
import Picker
import Playback

/// The M2 walking-skeleton window (PLAN M2 `PlainWindow`): a native AppKit window with the genre dropdown
/// (every genre, disabled ones with their reason, then Surprise Me), Previous / Play-Pause / Next, a volume slider,
/// the title and detail lines, and a status line with the state, source, TTFA and the engine download notice.
/// Text comes from `PlainDisplay`; commands go to `AppContext`. Automation presses these very controls.
final class PlainWindowController: NSObject, NSWindowDelegate, NSMenuDelegate {
    let window: NSWindow
    let context: AppContext
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let titleLabel = NSTextField(labelWithString: PlainDisplay.pickPrompt)
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let engineLabel = NSTextField(labelWithString: "")
    private let previousButton = PlainWindowController.transportButton("backward.fill", "Previous stream (Z)")
    private let playPauseButton = PlainWindowController.transportButton("play.fill", "Play or pause (Space, X / C)")
    private let nextButton = PlainWindowController.transportButton("forward.fill", "Next random stream (B)")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let volumeSlider = NSSlider(value: AppSettings.defaultVolume, minValue: 0, maxValue: 100, target: nil, action: nil)
    private var hoverTask: Task<Void, Never>?
    private var lastDisplay: PlainDisplay?
    private var lastGenre: GenreID?
    private var menuOpen = false
    private var menuStale = false

    static let placeholderTitle = "Pick a genre…"
    static let contentWidth: CGFloat = 440

    init(context: AppContext) {
        self.context = context
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 200),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "sudamp"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        buildContent()
        rebuildGenreMenu()
        context.observeSnapshots { [weak self] s in self?.render(s) }
        context.observeAvailability { [weak self] in self?.rebuildGenreMenu() }
    }

    // MARK: Layout

    private func buildContent() {
        popup.target = self
        popup.action = #selector(genrePicked(_:))
        popup.autoenablesItems = false
        popup.controlSize = .large
        popup.menu?.delegate = self
        popup.setAccessibilityLabel("Genre")
        popup.toolTip = "Pick a genre: a random stream from it plays"

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        engineLabel.font = .systemFont(ofSize: 11)
        engineLabel.textColor = .tertiaryLabelColor
        for label in [titleLabel, detailLabel, statusLabel, engineLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.allowsDefaultTighteningForTruncation = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        statusLabel.setAccessibilityLabel("Status")

        for (button, action) in [(previousButton, #selector(previousPressed(_:))), (playPauseButton, #selector(playPausePressed(_:))),
                                 (nextButton, #selector(nextPressed(_:)))] {
            button.target = self
            button.action = action
        }
        playPauseButton.keyEquivalent = " "

        retryButton.target = self
        retryButton.action = #selector(retryPressed(_:))
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.isHidden = true

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.isContinuous = true
        volumeSlider.doubleValue = context.settings.volume
        volumeSlider.setAccessibilityLabel("Volume")
        volumeSlider.toolTip = "Volume"
        volumeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let transport = NSStackView(views: [previousButton, playPauseButton, nextButton, spacer,
                                            symbolView("speaker.fill"), volumeSlider, symbolView("speaker.wave.3.fill")])
        transport.orientation = .horizontal
        transport.spacing = 8
        transport.alignment = .centerY

        let separator = NSBox()
        separator.boxType = .separator
        let statusRow = NSStackView(views: [statusLabel, retryButton])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8

        let stack = NSStackView(views: [popup, titleLabel, detailLabel, transport, separator, statusRow, engineLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        stack.setCustomSpacing(14, after: popup)
        stack.setCustomSpacing(14, after: detailLabel)
        stack.setCustomSpacing(12, after: transport)
        stack.setCustomSpacing(8, after: separator)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ]
        for view in [popup, titleLabel, detailLabel, transport, separator, statusRow, engineLabel] as [NSView] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36))
        }
        NSLayoutConstraint.activate(constraints)
        window.contentView = content
        window.setContentSize(content.fittingSize)
    }

    private static func transportButton(_ symbol: String, _ label: String) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
            ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }

    private func symbolView(_ name: String) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        view.contentTintColor = .secondaryLabelColor
        view.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        return view
    }

    // MARK: Showing

    func show(activate: Bool) {
        if !window.isVisible {
            window.center()
            window.setFrameAutosaveName("sudamp.PlainWindow")
            resizeToFit()
        }
        window.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate() }
    }

    /// First launch (DESIGN §3): the genre menu opens once by itself, after the window has settled.
    func openGenreMenuSoon() {
        perform(#selector(openGenreMenuNow), with: nil, afterDelay: 0.5)
    }

    @objc private func openGenreMenuNow() {
        guard window.isVisible, !context.isShutDown else { return }
        context.markGenreMenuShown()
        popup.performClick(nil)
    }

    @objc private func openGenreMenu() {
        guard window.isVisible, !context.isShutDown else { return }
        popup.performClick(nil)
    }

    /// Closes the dropdown if it is open (quit path; a genre picked another way).
    func cancelMenuTracking() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(openGenreMenuNow), object: nil)
        popup.menu?.cancelTracking()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { context.undoManager }

    func windowWillClose(_ notification: Notification) {
        // DESIGN §3: closing the main window quits, through the quit path.
        context.onQuit?("window closed")
    }

    // MARK: Rendering

    private func render(_ s: PlayerSnapshot) {
        let remembered = s.genre == nil && s.phase == .idle ? context.rememberedGenre : nil
        let display = PlainDisplay(s, muted: context.muted,
                                   lastGenreName: remembered.flatMap { context.controller.catalog.genre($0)?.name })
        if display != lastDisplay {
            lastDisplay = display
            titleLabel.stringValue = display.title
            titleLabel.toolTip = display.title
            detailLabel.stringValue = display.detail
            statusLabel.stringValue = display.status
            statusLabel.textColor = display.isProblem ? .systemOrange : .secondaryLabelColor
            engineLabel.stringValue = display.engineNotice ?? ""
            let hideEngine = display.engineNotice == nil
            if engineLabel.isHidden != hideEngine {
                engineLabel.isHidden = hideEngine
                resizeToFit()
            }
            engineLabel.textColor = s.engine.state == .failed ? .systemOrange : .tertiaryLabelColor
            engineLabel.toolTip = s.engine.message
            retryButton.isHidden = !display.offersRetry
            let symbol = display.showsPause ? "pause.fill" : "play.fill"
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            playPauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: display.showsPause ? "Pause" : "Play")?
                .withSymbolConfiguration(config)
            playPauseButton.setAccessibilityLabel(display.showsPause ? "Pause" : "Play")
        }
        if s.genre != lastGenre {
            lastGenre = s.genre
            window.subtitle = s.genreName ?? ""
            // Chosen elsewhere (URL, menu bar, media key): the auto-opened dropdown has done its job.
            if menuOpen { cancelMenuTracking() }
            syncSelection()
        }
    }

    /// Fits the window to its content, keeping the top edge where it is (the engine line comes and goes).
    private func resizeToFit() {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    /// Rebuilds the dropdown from the shared model (in place while it is open, so tracking isn't disturbed).
    func rebuildGenreMenu() {
        guard let menu = popup.menu else { return }
        let rows = context.menuItems(shortcuts: false)
        if menuOpen {
            // Update titles and enabled state of the items already shown; rebuild after it closes.
            for item in menu.items {
                guard let choice = GenreMenuChoice(item) else { continue }
                let row = rows.first { r in
                    switch (r.kind, choice) {
                    case (.genre(let a), .genre(let b)): a == b
                    case (.surpriseMe, .surpriseMe): true
                    default: false
                    }
                }
                guard let row else { continue }
                item.isEnabled = row.isEnabled
                item.subtitle = row.subtitle
                item.toolTip = row.subtitle
            }
            menuStale = true
            return
        }
        menu.removeAllItems()
        let placeholder = NSMenuItem(title: Self.placeholderTitle, action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        menu.addItem(placeholder)
        for item in GenreMenuBuilder.items(rows, target: self, action: #selector(genrePicked(_:)), checks: false) {
            // In a popup the button's own action runs when an item has none; with `autoenablesItems` off,
            // `isEnabled` alone decides what can be chosen.
            item.action = nil
            item.target = nil
            menu.addItem(item)
        }
        syncSelection()
    }

    private func syncSelection() {
        guard let menu = popup.menu else { return }
        let placeholder = menu.items.first
        if let g = lastGenre, let item = menu.items.first(where: { GenreMenuChoice($0) == .genre(g) }) {
            placeholder?.isHidden = true
            popup.select(item)
        } else {
            placeholder?.isHidden = false
            popup.select(placeholder)
        }
    }

    // MARK: Menu delegate (hover pre-resolve, live availability)

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        context.refreshAvailability()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        hoverTask?.cancel()
        if menuStale {
            menuStale = false
            // After the selection action has run.
            DispatchQueue.main.async { [weak self] in self?.rebuildGenreMenu() }
        }
    }

    /// DESIGN §3: hovering a genre for 300 ms pre-resolves its next pick.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        hoverTask?.cancel()
        guard let item, case .genre(let g)? = GenreMenuChoice(item), item.isEnabled else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.context.controller.preresolve(genre: g)
        }
    }

    // MARK: Actions

    @objc private func genrePicked(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        pick(item, origin: "dropdown")
    }

    private func pick(_ item: NSMenuItem, origin: String) {
        if let choice = GenreMenuChoice(item) { context.perform(choice, origin: origin) }
        // Surprise Me (or a refused pick) shows the real genre once the snapshot says which.
        DispatchQueue.main.async { [weak self] in self?.syncSelection() }
    }

    @objc private func previousPressed(_ sender: Any?) { context.perform(.previous, origin: "button") }
    @objc private func playPausePressed(_ sender: Any?) {
        let s = context.controller.snapshot
        if s.genre == nil, s.phase == .idle, context.rememberedGenre == nil, window.isVisible {
            // Nothing to play yet: Play means "pick a genre". (From the run loop, not inside this action.)
            perform(#selector(openGenreMenu), with: nil, afterDelay: 0)
            return
        }
        context.perform(.toggle, origin: "button")
    }
    @objc private func nextPressed(_ sender: Any?) { context.perform(.next, origin: "button") }
    @objc private func retryPressed(_ sender: Any?) { context.retry() }
    @objc private func volumeChanged(_ sender: NSSlider) { context.setVolume(sender.doubleValue) }

    /// The slider follows volume changes made elsewhere (menu shortcuts).
    func syncVolume() { volumeSlider.doubleValue = context.settings.volume }

    // MARK: Automation (the same controls a click reaches)

    /// Chooses `genre` in the dropdown and sends its action, as a click would. False when it isn't there or is
    /// disabled.
    func selectInDropdown(_ choice: GenreMenuChoice) -> Bool {
        guard let item = popup.menu?.items.first(where: { GenreMenuChoice($0) == choice }), item.isEnabled else { return false }
        popup.select(item)
        return popup.sendAction(popup.action, to: popup.target)
    }

    func automationPress(_ control: AutomationScript.Control) {
        switch control {
        case .playPause: playPauseButton.sendAction(playPauseButton.action, to: playPauseButton.target)
        case .next: nextButton.sendAction(nextButton.action, to: nextButton.target)
        case .previous: previousButton.sendAction(previousButton.action, to: previousButton.target)
        case .retry: retryButton.sendAction(retryButton.action, to: retryButton.target)
        case .play: context.perform(.play, origin: "automation")
        case .pause: context.perform(.pause, origin: "automation")
        case .stop: context.perform(.stop, origin: "automation")
        }
    }

    struct SnapshotError: Error, CustomStringConvertible {
        var description: String
    }

    /// Renders the window's content to a PNG: an agent's way to look at the layout, even off screen.
    func snapshot(to url: URL) throws {
        guard let view = window.contentView else { throw SnapshotError(description: "no content view") }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SnapshotError(description: "no bitmap for \(view.bounds)")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError(description: "PNG encoding failed")
        }
        try png.write(to: url, options: .atomic)
    }

    func automationSetVolume(_ v: Double) {
        volumeSlider.doubleValue = v
        volumeSlider.sendAction(volumeSlider.action, to: volumeSlider.target)
    }
}
