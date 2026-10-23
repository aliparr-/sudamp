// SPDX-License-Identifier: GPL-3.0-or-later
// The station list: the genre's streams (or the favourites) in a table on glass. Each row shows its source badge,
// title, creator and length (or LIVE); the playing row is washed in the tint with little equaliser bars dancing in
// place of its badge. Double-click or Return plays a row. A native NSTableView underneath keeps keyboard navigation,
// type-select and VoiceOver.

import AppKit
import QuartzCore

final class StationsCard: GlassCard, NSTableViewDataSource, NSTableViewDelegate {
    var onEvent: ((ModernEvent) -> Void)?

    private let titleLabel = makeLabel(size: 13, weight: .semibold)
    private let countLabel = makeLabel(size: 11.5, weight: .medium, color: .tertiaryLabelColor)
    private let scroll = NSScrollView()
    private let table = StationsTable()
    private let emptyLabel = makeLabel("Pick a genre to see its stations", size: 12, color: .tertiaryLabelColor)
    private let topFade = StillGradientLayer()
    private var palette: ModernPalette?
    private(set) var stations: [ModernPlayerState.Station] = []
    private(set) var current: Int?
    private var isPlaying = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        naturalHeight = Metrics.stationsHeight
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("station"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 42
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activate(_:))
        table.onReturn = { [weak self] in self?.activate(nil) }
        table.setAccessibilityLabel("Stations")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        scroll.contentView.drawsBackground = false
        countLabel.alignment = .right
        emptyLabel.alignment = .center
        for view: NSView in [titleLabel, countLabel, scroll, emptyLabel] { content.addSubview(view) }
        apply(stations: [], current: nil, title: "", playing: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Reduce Motion changed: the playing row's bars follow.
    func refreshMotion() {
        table.enumerateAvailableRowViews { _, row in
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? StationCell)?.refreshMotion()
        }
    }

    override func apply(_ palette: ModernPalette) {
        super.apply(palette)
        self.palette = palette
        table.palette = palette
        table.enumerateAvailableRowViews { rowView, row in
            (rowView as? StationRowView)?.palette = palette
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? StationCell)?.apply(palette)
        }
    }

    func apply(stations new: [ModernPlayerState.Station], current: Int?, title: String, playing: Bool) {
        let changed = new != stations
        let rowChanged = current != self.current
        let currentChanged = rowChanged || playing != isPlaying
        stations = new
        self.current = current
        isPlaying = playing
        titleLabel.stringValue = title.isEmpty ? "Stations" : title
        countLabel.stringValue = new.isEmpty ? "" : (new.count == 1 ? "1 station" : "\(new.count) stations")
        emptyLabel.isHidden = !new.isEmpty
        if changed {
            table.reloadData()
        } else if currentChanged {
            table.enumerateAvailableRowViews { rowView, row in self.configure(rowView: rowView, row: row) }
        }
        // Play/pause and rebuffering don't move the list; a new stream or a new list does.
        if changed || rowChanged, let current, current < new.count {
            scrollToVisible(current)
        }
    }

    func scrollToVisible(_ row: Int) {
        guard row >= 0, row < stations.count else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.reduced ? 0 : 0.3
            context.allowsImplicitAnimation = true
            table.scrollRowToVisible(row)
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let p = Metrics.padding
        titleLabel.frame = CGRect(x: p + 2, y: p + 3, width: w - p * 2 - 100, height: 18)
        countLabel.frame = CGRect(x: w - p - 100, y: p + 4, width: 98, height: 16)
        scroll.frame = CGRect(x: 8, y: p + 28, width: w - 16, height: naturalHeight - p - 28 - 8)
        table.tableColumns.first?.width = scroll.contentSize.width
        emptyLabel.frame = CGRect(x: p, y: naturalHeight / 2 - 8, width: w - p * 2, height: 18)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { stations.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = StationRowView()
        rowView.palette = palette
        configure(rowView: rowView, row: row)
        return rowView
    }

    private func configure(rowView: NSTableRowView, row: Int) {
        guard let rowView = rowView as? StationRowView else { return }
        rowView.isCurrent = row == current
        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? StationCell {
            cell.setCurrent(row == current, playing: isPlaying)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("StationCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? StationCell ?? StationCell()
        cell.identifier = id
        if let palette { cell.apply(palette) }
        cell.configure(stations[row])
        cell.setCurrent(row == current, playing: isPlaying)
        return cell
    }

    @objc private func activate(_ sender: Any?) {
        let row = sender == nil ? table.selectedRow : table.clickedRow
        guard row >= 0, row < stations.count else { return }
        onEvent?(.playStation(row))
    }

    /// Automation: the row a double-click would play.
    func play(row: Int) -> Bool {
        guard row >= 0, row < stations.count else { return false }
        onEvent?(.playStation(row))
        return true
    }

    static var preferredHeight: CGFloat { Metrics.stationsHeight }
}

/// Return plays the selected row.
final class StationsTable: NSTableView {
    var onReturn: (() -> Void)?
    var palette: ModernPalette?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A row's rounded wash: the tint for the playing row, a hover wash, the selection. A layer, not drawing: the row
/// itself stays clear on the glass.
final class StationRowView: NSTableRowView {
    var palette: ModernPalette? { didSet { updateWash() } }
    var isCurrent = false { didSet { if isCurrent != oldValue { updateWash() } } }
    private var hovering = false
    private var trackingArea: NSTrackingArea?
    private let wash = StillLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        wash.cornerRadius = 11
        wash.cornerCurve = .continuous
        layer?.addSublayer(wash)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = .clear }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}

    override var isSelected: Bool {
        didSet { updateWash() }
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func layout() {
        super.layout()
        wash.frame = bounds.insetBy(dx: 4, dy: 0)
    }

    private func updateWash() {
        guard let palette else { return }
        if isCurrent {
            wash.backgroundColor = palette.accent.cgColor(alpha: palette.isDark ? 0.24 : 0.16)
        } else if isSelected {
            wash.backgroundColor = palette.pressed
        } else if hovering {
            wash.backgroundColor = palette.hover
        } else {
            wash.backgroundColor = nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateWash()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateWash()
    }
}

/// Badge, title over creator, length.
final class StationCell: NSTableCellView {
    private let badge = BadgeView()
    private let bars = PlayingBars()
    private let title = makeLabel(size: 13, weight: .medium)
    private let subtitle = makeLabel(size: 11, color: .secondaryLabelColor)
    private let duration = makeLabel(size: 11, weight: .medium, color: .tertiaryLabelColor, monospacedDigits: true)
    private var palette: ModernPalette?
    private var station: ModernPlayerState.Station?
    private var isCurrent = false

    init() {
        super.init(frame: .zero)
        duration.alignment = .right
        badge.compact = true
        bars.isHidden = true
        for view: NSView in [badge, bars, title, subtitle, duration] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(_ palette: ModernPalette) {
        self.palette = palette
        badge.apply(palette)
        bars.color = palette.accent
        updateColors()
    }

    func configure(_ station: ModernPlayerState.Station) {
        self.station = station
        if let tag = station.tag { badge.kind = .source(tag) }
        badge.isHidden = station.tag == nil || isCurrent
        title.stringValue = station.title
        subtitle.stringValue = station.subtitle
        subtitle.isHidden = station.subtitle.isEmpty
        duration.stringValue = station.duration.map(ModernPlayerState.clock) ?? "LIVE"
        setAccessibilityLabel([station.title, station.subtitle, station.tag?.name ?? "",
                               station.duration.map(ModernPlayerState.clock) ?? "live"].filter { !$0.isEmpty }.joined(separator: ", "))
        needsLayout = true
    }

    /// Reduce Motion changed.
    func refreshMotion() { bars.refreshMotion() }

    func setCurrent(_ current: Bool, playing: Bool) {
        isCurrent = current
        bars.isHidden = !current
        bars.isAnimating = current && playing
        badge.isHidden = current || station?.tag == nil
        updateColors()
        needsLayout = true
    }

    private func updateColors() {
        title.textColor = isCurrent ? (palette?.accentColor ?? .controlAccentColor) : .labelColor
        title.font = .systemFont(ofSize: 13, weight: isCurrent ? .semibold : .medium)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let badgeWidth: CGFloat = 30
        badge.frame = CGRect(x: 14, y: (h - 16) / 2, width: badgeWidth, height: 16)
        bars.frame = CGRect(x: 14 + (badgeWidth - 16) / 2, y: (h - 14) / 2, width: 16, height: 14)
        let x = 14 + badgeWidth + 10
        let durationWidth: CGFloat = 54
        let textWidth = bounds.width - x - durationWidth - 14
        if subtitle.isHidden {
            title.frame = CGRect(x: x, y: (h - 17) / 2, width: textWidth, height: 17)
        } else {
            title.frame = CGRect(x: x, y: h / 2 - 16, width: textWidth, height: 17)
            subtitle.frame = CGRect(x: x, y: h / 2 + 1, width: textWidth, height: 15)
        }
        duration.frame = CGRect(x: bounds.width - durationWidth - 14, y: (h - 15) / 2, width: durationWidth, height: 15)
    }
}

/// Three little bars bouncing out of phase: the playing row's mark.
final class PlayingBars: NSView {
    var color = RGB(hex: 0x2DD4BF) { didSet { for bar in bars { bar.backgroundColor = color.cgColor } } }
    var isAnimating = false { didSet { if isAnimating != oldValue { update() } } }
    private var bars: [StillLayer] = []
    private var laidOutFor: CGRect = .null

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for _ in 0..<3 {
            let bar = StillLayer()
            bar.backgroundColor = color.cgColor
            bar.anchorPoint = CGPoint(x: 0.5, y: 1)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w: CGFloat = 3
        let gap = (bounds.width - w * 3) / 2
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            bar.position = CGPoint(x: w / 2 + CGFloat(i) * (w + gap), y: bounds.height)
            bar.cornerRadius = w / 2
        }
        // Table rows lay out often: restart the bounce only when the bars actually moved.
        guard bounds != laidOutFor else { return }
        laidOutFor = bounds
        update()
    }

    func refreshMotion() { update() }

    private func update() {
        for (i, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            bar.transform = CATransform3DMakeScale(1, isAnimating ? 1 : [0.45, 0.7, 0.35][i], 1)
            guard isAnimating, !Motion.reduced else { continue }
            let bounce = CAKeyframeAnimation(keyPath: "transform.scale.y")
            bounce.setKeyframes([[0.3, 1, 0.5, 0.85, 0.3], [0.8, 0.35, 1, 0.45, 0.8], [0.5, 0.9, 0.3, 1, 0.5]][i])
            bounce.duration = [0.9, 1.1, 0.8][i]
            bounce.repeatCount = .infinity
            bounce.calculationMode = .cubic
            bar.add(bounce, forKey: "bounce")
        }
    }
}
