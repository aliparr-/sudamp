// SPDX-License-Identifier: GPL-3.0-or-later
// The player card: the generated artwork (and visualiser), the genre button, the gliding title, the creator, source
// and format badges or a notice, the progress bar (a breathing live bar for live streams and radio), the transport,
// and the volume with the buttons that open the Equalizer, the station list and the appearance popover.
//
//   ┌──────────────────────────────────────────────┐
//   │ ┌────────┐  [ Deep House ⌄ ]             ⋯   │
//   │ │artwork │  Sunset Sessions ⟶ (glides)       │
//   │ │ + vis  │  Solar Crew                        │
//   │ └────────┘  SOUNDCLOUD  128 kbps · 48 kHz     │
//   │ ━━━━━━━━━━━━━━━━━●──────────────────────────  │
//   │ 0:42                                  -61:18  │
//   │      ♡      ⏮      ( ▶ )      ⏭      ⇄        │
//   │ 🔈 ━━━━━━━━━━━○────── 🔊        ≋   ☰   ◐     │
//   └──────────────────────────────────────────────┘

import AppKit
import QuartzCore

final class NowPlayingCard: GlassCard {
    var onEvent: ((ModernEvent) -> Void)?
    var onPanelButton: ((ModernPanel) -> Void)?
    var onAppearanceButton: ((NSView) -> Void)?

    let artwork = ArtworkView()
    let lights = WindowLights()
    let genreButton = CapsuleButton(label: "Pick a Genre")
    let moreButton = GlyphButton(symbol: "ellipsis", pointSize: 14, weight: .bold, label: "More")
    let titleView = MarqueeView()
    let subtitleLabel = makeLabel(size: 13, color: .secondaryLabelColor)
    let sourceBadge = BadgeView()
    let formatLabel = makeLabel(size: 10.5, weight: .medium, color: .tertiaryLabelColor, monospacedDigits: true)
    let noticeIcon = PassiveImageView()
    let noticeLabel = makeLabel(size: 11.5, weight: .medium, color: .secondaryLabelColor)
    let retryButton = CapsuleButton(label: "Retry")
    let progress = ModernSlider(axis: .horizontal, label: "Position")
    let liveBar = LiveBar()
    let elapsedLabel = TimeLabel(alignment: .left)
    let remainingLabel = TimeLabel(alignment: .right)
    let favouriteButton = GlyphButton(symbol: "heart", pointSize: 15, weight: .semibold, label: "Favourite")
    let previousButton = GlyphButton(symbol: "backward.fill", pointSize: 19, weight: .semibold, label: "Previous Stream")
    let playButton = GlyphButton(symbol: "play.fill", pointSize: 22, weight: .bold, style: .prominent, label: "Play")
    let nextButton = GlyphButton(symbol: "forward.fill", pointSize: 19, weight: .semibold, label: "Next Stream")
    let shuffleButton = GlyphButton(symbol: "shuffle", pointSize: 14, weight: .semibold, label: "Shuffle Genres")
    let volumeLow = PassiveImageView()
    let volume = ModernSlider(axis: .horizontal, label: "Volume")
    let volumeHigh = PassiveImageView()
    let equalizerButton = GlyphButton(symbol: "slider.vertical.3", pointSize: 13.5, weight: .semibold, label: "Equalizer")
    let stationsButton = GlyphButton(symbol: "list.bullet", pointSize: 13.5, weight: .semibold, label: "Stations")
    let appearanceButton = GlyphButton(symbol: "circle.lefthalf.filled", pointSize: 13.5, weight: .semibold,
                                       label: "Appearance")

    private(set) var state = ModernPlayerState()
    private var palette: ModernPalette?
    private var trackingArea: NSTrackingArea?
    /// The thumb's position while the user scrubs, shown in the time labels.
    private var scrubbing: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        naturalHeight = Metrics.nowPlayingHeight
        artwork.cornerRadius = Metrics.concentric(inset: Metrics.padding)
        artwork.onClick = { [weak self] in
            guard let self else { return }
            // Rotating: the artwork skips to its next scene itself; otherwise the app picks the next one.
            if self.state.visualizer == .rotate { self.artwork.skipScene() }
            self.onEvent?(.cycleVisualizer)
        }
        lights.onClose = { [weak self] in self?.onEvent?(.close) }
        lights.onMinimize = { [weak self] in self?.onEvent?(.minimize) }
        genreButton.toolTip = "Pick a genre: a random stream from it plays"
        genreButton.onPress = { [weak self] in
            guard let self else { return }
            self.onEvent?(.genreMenu(self.genreButton.menuAnchorBelow))
        }
        moreButton.tone = .secondary
        moreButton.onPress = { [weak self] in
            guard let self else { return }
            self.onEvent?(.moreMenu(self.moreButton.menuAnchorBelow))
        }
        titleView.font = .systemFont(ofSize: 17, weight: .semibold)
        noticeIcon.imageScaling = .scaleNone
        retryButton.style = .neutral
        retryButton.showsChevron = false
        retryButton.setAccessibilityRole(.button)
        retryButton.titleFont = .systemFont(ofSize: 11, weight: .semibold)
        retryButton.onPress = { [weak self] in self?.onEvent?(.retry) }
        progress.knobAlwaysVisible = false
        progress.scrollWheelAdjusts = false
        progress.knobDiameter = 13
        progress.trackThickness = 5
        progress.accessibilityValueText = { [weak self] v in
            guard let self, let d = self.state.duration else { return "" }
            return ModernPlayerState.clock(v * d)
        }
        progress.onChange = { [weak self] value, phase in self?.scrubbed(value, phase) }
        for label in [elapsedLabel, remainingLabel] {
            label.onClick = { [weak self] in self?.onEvent?(.toggleTimeDisplay) }
        }
        favouriteButton.onPress = { [weak self] in self?.onEvent?(.favourite) }
        previousButton.onPress = { [weak self] in self?.onEvent?(.previous) }
        playButton.onPress = { [weak self] in self?.onEvent?(.playPause) }
        nextButton.onPress = { [weak self] in self?.onEvent?(.next) }
        shuffleButton.onPress = { [weak self] in self?.onEvent?(.toggleShuffle) }
        shuffleButton.tone = .secondary
        favouriteButton.tone = .secondary
        let small = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        volumeLow.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)?.withSymbolConfiguration(small)
        volumeHigh.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)?.withSymbolConfiguration(small)
        for icon in [volumeLow, volumeHigh] {
            icon.imageScaling = .scaleNone
            icon.contentTintColor = .tertiaryLabelColor
        }
        volume.knobDiameter = 14
        volume.step = 0.05
        volume.onChange = { [weak self] value, _ in self?.onEvent?(.volume(value)) }
        equalizerButton.onPress = { [weak self] in self?.onPanelButton?(.equalizer) }
        stationsButton.onPress = { [weak self] in self?.onPanelButton?(.stations) }
        appearanceButton.onPress = { [weak self] in
            guard let self else { return }
            self.onAppearanceButton?(self.appearanceButton)
        }
        for button in [equalizerButton, stationsButton, appearanceButton] { button.tone = .secondary }
        for button in [favouriteButton, shuffleButton, equalizerButton, stationsButton] { button.isToggle = true }
        for view: NSView in [artwork, genreButton, moreButton, titleView, subtitleLabel, sourceBadge, formatLabel, noticeIcon,
                             noticeLabel, retryButton, progress, liveBar, elapsedLabel, remainingLabel, favouriteButton,
                             previousButton, playButton, nextButton, shuffleButton, volumeLow, volume, volumeHigh,
                             equalizerButton, stationsButton, appearanceButton, lights] {
            content.addSubview(view)
        }
        apply(state: state, force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Look

    override func apply(_ palette: ModernPalette) {
        super.apply(palette)
        self.palette = palette
        for button in [moreButton, favouriteButton, previousButton, playButton, nextButton, shuffleButton, equalizerButton,
                       stationsButton, appearanceButton] {
            button.apply(palette)
        }
        genreButton.apply(palette)
        retryButton.apply(palette)
        sourceBadge.apply(palette)
        progress.apply(palette)
        volume.apply(palette)
        liveBar.apply(palette)
        artwork.paletteKey = artworkKey(state, palette)
        updateNotice()
    }

    /// What colours the artwork: the chosen scheme with the genre, source, tint and light or dark.
    private func artworkKey(_ s: ModernPlayerState, _ palette: ModernPalette) -> ArtworkPalette.Key {
        ArtworkPalette.Key(colors: s.artworkColors, genreKey: s.genreKey, source: s.source, tint: palette.tint, dark: palette.isDark)
    }

    /// Reduce Motion changed: the moving parts start or stop to match.
    func refreshMotion() {
        titleView.refreshMotion()
        artwork.refreshMotion()
        liveBar.refreshMotion()
    }

    func setPanelOpen(_ panel: ModernPanel, _ open: Bool) {
        (panel == .equalizer ? equalizerButton : stationsButton).isOn = open
    }

    // MARK: State

    func apply(state new: ModernPlayerState, force: Bool = false) {
        let old = state
        state = new
        if force || new.title != old.title { titleView.text = new.title.isEmpty ? " " : new.title }
        if force || new.subtitle != old.subtitle { subtitleLabel.stringValue = new.subtitle }
        titleView.isScrolling = new.playback == .playing
        if force || new.genre != old.genre {
            if let genre = new.genre {
                genreButton.style = .chip
                genreButton.title = genre
                genreButton.leadingSymbol = nil
            } else {
                genreButton.style = .prompt
                genreButton.title = "Pick a Genre"
                genreButton.leadingSymbol = "sparkles"
            }
            needsLayout = true
        }
        if let palette { artwork.paletteKey = artworkKey(new, palette) }
        artwork.rotationInterval = new.visualizerInterval
        artwork.effect = new.visualizerEffect
        artwork.caption = new.playback == .stopped ? ""
            : [new.title, new.subtitle].filter { !$0.isEmpty }.joined(separator: " · ")
        artwork.mode = new.visualizer
        artwork.isAnimating = new.isAnimating
        if let tag = new.source { sourceBadge.kind = .source(tag) }
        formatLabel.stringValue = new.format ?? ""
        if force || new.notice != old.notice || new.offersRetry != old.offersRetry || new.source != old.source { updateNotice() }
        // Transport.
        let playing = new.playback == .playing || new.working
        playButton.setSymbol(playing ? "pause.fill" : "play.fill", animated: !force)
        playButton.setAccessibilityLabel(playing ? "Pause" : "Play")
        playButton.toolTip = playing ? "Pause (C)" : "Play (X)"
        playButton.isWorking = new.working
        favouriteButton.isEnabled = new.canFavourite
        if new.isFavourite != old.isFavourite || force {
            favouriteButton.setSymbol(new.isFavourite ? "heart.fill" : "heart", animated: !force)
            favouriteButton.isOn = new.isFavourite
            favouriteButton.setAccessibilityLabel(new.isFavourite ? "Remove from Favourites" : "Favourite")
            if new.isFavourite, !force { favouriteButton.bounce() }
        }
        shuffleButton.isOn = new.shuffle
        if !volume.isDragging { volume.value = new.volume }
        // Progress.
        let live = new.isLive && new.playback != .stopped
        progress.isHidden = live
        liveBar.isHidden = !live
        liveBar.isAnimating = live && new.playback == .playing
        progress.isEnabled = new.canSeek
        if !progress.isDragging { progress.value = new.progress ?? 0 }
        updateTimes()
        if force || new.isLive != old.isLive || new.source != old.source || new.notice != old.notice
            || new.genre != old.genre || (new.format == nil) != (old.format == nil) {
            needsLayout = true
        }
    }

    private func updateTimes() {
        let s = state
        if s.isLive, s.playback != .stopped {
            elapsedLabel.text = ModernPlayerState.clock(s.elapsed)
            remainingLabel.text = "LIVE"
            remainingLabel.isAccent = true
            elapsedLabel.toolTip = "Listening time"
            return
        }
        remainingLabel.isAccent = false
        guard let duration = s.duration else {
            elapsedLabel.text = s.playback == .stopped ? "0:00" : ModernPlayerState.clock(s.elapsed)
            remainingLabel.text = "--:--"
            return
        }
        let elapsed = scrubbing.map { $0 * duration } ?? s.elapsed
        elapsedLabel.text = ModernPlayerState.clock(elapsed)
        remainingLabel.text = s.showsRemaining ? "-" + ModernPlayerState.clock(max(0, duration - elapsed))
            : ModernPlayerState.clock(duration)
        elapsedLabel.toolTip = "Click to show the time remaining"
        remainingLabel.toolTip = elapsedLabel.toolTip
    }

    private func scrubbed(_ value: Double, _ phase: ModernSlider.Phase) {
        switch phase {
        case .began, .changed:
            scrubbing = value
            updateTimes()
        case .ended:
            scrubbing = nil
            if state.canSeek { onEvent?(.seek(value)) }
            updateTimes()
        }
    }

    private func updateNotice() {
        guard let notice = state.notice else {
            noticeIcon.isHidden = true
            noticeLabel.isHidden = true
            retryButton.isHidden = true
            sourceBadge.isHidden = state.source == nil
            formatLabel.isHidden = false
            return
        }
        noticeIcon.isHidden = false
        noticeLabel.isHidden = false
        retryButton.isHidden = !state.offersRetry
        sourceBadge.isHidden = true
        formatLabel.isHidden = true
        let symbol = notice.isProblem ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        noticeIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let problem = palette?.isDark ?? false ? RGB(hex: 0xFFB340) : RGB(hex: 0xC76A00)
        noticeIcon.contentTintColor = notice.isProblem ? problem.nsColor : palette?.accentColor
        noticeLabel.stringValue = notice.text
        noticeLabel.textColor = notice.isProblem ? problem.nsColor : .secondaryLabelColor
        needsLayout = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width
        let p = Metrics.padding
        let art = Metrics.artwork
        artwork.frame = CGRect(x: p, y: p, width: art, height: art)
        lights.frame = CGRect(origin: CGPoint(x: p + 9, y: p + 9), size: WindowLights.size)
        let x0 = p + art + 14
        let column = w - x0 - p
        moreButton.frame = CGRect(x: w - p - 26, y: p, width: 28, height: 26)
        genreButton.frame = CGRect(x: x0, y: p, width: min(genreButton.fittingWidth, column - 34), height: 26)
        titleView.frame = CGRect(x: x0, y: p + 33, width: column, height: 23)
        subtitleLabel.frame = CGRect(x: x0, y: p + 57, width: column, height: 18)
        let metaY = p + 79
        var mx = x0
        if !sourceBadge.isHidden {
            let bw = sourceBadge.fittingWidth
            sourceBadge.frame = CGRect(x: mx, y: metaY, width: bw, height: 17)
            mx += bw + 8
        }
        formatLabel.frame = CGRect(x: mx, y: metaY + 1, width: max(0, x0 + column - mx), height: 15)
        if !noticeIcon.isHidden {
            noticeIcon.frame = CGRect(x: x0, y: metaY, width: 14, height: 17)
            let retryWidth: CGFloat = retryButton.isHidden ? 0 : retryButton.fittingWidth
            noticeLabel.frame = CGRect(x: x0 + 18, y: metaY + 1, width: column - 18 - (retryWidth > 0 ? retryWidth + 6 : 0), height: 16)
            retryButton.frame = CGRect(x: x0 + column - retryWidth, y: metaY - 2, width: retryWidth, height: 21)
        }
        let barY = p + art + 16
        progress.frame = CGRect(x: p, y: barY, width: w - p * 2, height: 16)
        liveBar.frame = CGRect(x: p, y: barY + 5, width: w - p * 2, height: 6)
        elapsedLabel.frame = CGRect(x: p, y: barY + 18, width: 80, height: 14)
        remainingLabel.frame = CGRect(x: w - p - 80, y: barY + 18, width: 80, height: 14)
        let centerY = barY + 18 + 14 + 28
        let cx = w / 2
        playButton.frame = CGRect(x: cx - 27, y: centerY - 27, width: 54, height: 54)
        previousButton.frame = CGRect(x: cx - 72 - 21, y: centerY - 21, width: 42, height: 42)
        nextButton.frame = CGRect(x: cx + 72 - 21, y: centerY - 21, width: 42, height: 42)
        favouriteButton.frame = CGRect(x: cx - 138 - 17, y: centerY - 17, width: 34, height: 34)
        shuffleButton.frame = CGRect(x: cx + 138 - 17, y: centerY - 17, width: 34, height: 34)
        let rowY = centerY + 27 + 14
        let buttonSize: CGFloat = 30
        let buttonsX = w - p - buttonSize * 3 - 2 * 2 + 5
        for (i, button) in [equalizerButton, stationsButton, appearanceButton].enumerated() {
            button.frame = CGRect(x: buttonsX + CGFloat(i) * (buttonSize + 2), y: rowY - 4, width: buttonSize, height: buttonSize)
        }
        volumeLow.frame = CGRect(x: p - 1, y: rowY, width: 16, height: 22)
        let volumeEnd = buttonsX - 34
        volume.frame = CGRect(x: p + 20, y: rowY, width: volumeEnd - (p + 20), height: 22)
        volumeHigh.frame = CGRect(x: volumeEnd + 4, y: rowY, width: 20, height: 22)
    }


    // MARK: Hover (the window lights)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { lights.setVisible(true) }
    override func mouseExited(with event: NSEvent) { lights.setVisible(false) }
}

/// A clickable time readout (elapsed ↔ remaining).
final class TimeLabel: NSView {
    var text = "" {
        didSet { if text != oldValue { label.stringValue = text } }
    }
    var isAccent = false {
        didSet { updateColor() }
    }
    var onClick: (() -> Void)?
    private let label = makeLabel(size: 11, weight: .medium, color: .secondaryLabelColor, monospacedDigits: true)
    private var accent: NSColor?

    init(alignment: NSTextAlignment) {
        super.init(frame: .zero)
        label.alignment = alignment
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The whole control takes the click, never the image or text inside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        // `point` is in the superview's coordinates, like `frame`.
        return frame.contains(point) ? self : nil
    }

    func setAccent(_ color: NSColor) {
        accent = color
        updateColor()
    }

    private func updateColor() {
        label.textColor = isAccent ? (NSColor(srgbRed: 1, green: 0.36, blue: 0.37, alpha: 1)) : .secondaryLabelColor
        label.font = .monospacedDigitSystemFont(ofSize: isAccent ? 10 : 11, weight: isAccent ? .bold : .medium)
    }

    override func layout() {
        super.layout()
        label.frame = bounds
    }

    /// Claimed, so the mouse-up comes here (passed up, the card would start a window drag and take it).
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) { onClick?() }

    override func accessibilityLabel() -> String? { text }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// The progress bar of a live stream or a radio station: full, softly coloured, with a highlight sweeping along it
/// while it plays.
final class LiveBar: NSView {
    var isAnimating = false {
        didSet { if isAnimating != oldValue { updateSweep() } }
    }
    private let track = StillGradientLayer()
    private let sweep = StillGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.startPoint = CGPoint(x: 0, y: 0.5)
        track.endPoint = CGPoint(x: 1, y: 0.5)
        track.masksToBounds = true
        layer?.addSublayer(track)
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.55), CGColor(gray: 1, alpha: 0)]
        track.addSublayer(sweep)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Live")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(_ palette: ModernPalette) {
        track.colors = [palette.accentDeep.cgColor(alpha: 0.75), palette.accent.cgColor(alpha: 0.85)]
    }

    override func layout() {
        super.layout()
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        sweep.frame = CGRect(x: -bounds.width * 0.3, y: 0, width: bounds.width * 0.3, height: bounds.height)
        if isAnimating { updateSweep() }
    }

    func refreshMotion() { updateSweep() }

    private func updateSweep() {
        sweep.removeAllAnimations()
        sweep.isHidden = !isAnimating || Motion.reduced
        guard isAnimating, !Motion.reduced, bounds.width > 0 else { return }
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -bounds.width * 0.15
        move.toValue = bounds.width * 1.15
        move.duration = 2.6
        move.repeatCount = .infinity
        move.timingFunction = Motion.easeInOut
        sweep.add(move, forKey: "sweep")
    }
}
