// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Catalog
import Playback

/// What a genre-menu item plays. Each item's `representedObject` is the choice's `tag`; the target reads it back
/// with `GenreMenuChoice(item)`.
nonisolated enum GenreMenuChoice: Equatable, Sendable {
    case genre(GenreID)
    case surpriseMe
    /// ★ Favourites: the favourites at random.
    case favourites
    /// A specific stream (Recently Played ▸, the favourites list).
    case stream(StreamID)

    private static let surpriseTag = "surprise"
    private static let favouritesTag = "favourites"
    private static let streamPrefix = "stream:"

    @MainActor init?(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String else { return nil }
        self.init(tag: raw)
    }

    init?(tag raw: String) {
        if raw == Self.surpriseTag {
            self = .surpriseMe
        } else if raw == Self.favouritesTag {
            self = .favourites
        } else if raw.hasPrefix(Self.streamPrefix), let id = StreamID(rawValue: String(raw.dropFirst(Self.streamPrefix.count))) {
            self = .stream(id)
        } else if let g = GenreID(rawValue: raw) {
            self = .genre(g)
        } else {
            return nil
        }
    }

    var tag: String {
        switch self {
        case .genre(let g): g.rawValue
        case .surpriseMe: Self.surpriseTag
        case .favourites: Self.favouritesTag
        case .stream(let id): Self.streamPrefix + id.rawValue
        }
    }
}

/// Everything the full genre menu shows (DESIGN §3): the genre rows (ticked, disabled with the reason), then
/// ★ Favourites, Surprise Me and Recently Played ▸. Pure, so the menu tree is tested without AppKit.
nonisolated struct GenreMenuContent: Equatable, Sendable {
    struct StreamRow: Equatable, Sendable {
        var id: StreamID
        var title: String
        var tag: String
    }

    /// `GenreMenuModel.items`: genres, a separator, Surprise Me.
    var rows: [GenreMenuItem]
    var favouritesCount: Int
    var favouritesActive: Bool
    var recent: [StreamRow]

    static let favouritesTitle = "★ Favourites"
    static let recentTitle = "Recently Played"
    static let noFavourites = "Press ⌘F while a stream plays to add it"
    static let nothingRecent = "Nothing played yet"

    static func streamRow(_ s: StreamRef) -> StreamRow {
        let title = s.isRadio ? PlainDisplay.stationName(StreamInfo(s)) : "\(s.creator) - \(s.title)"
        return StreamRow(id: s.id, title: title, tag: s.source.tag)
    }
}

/// The one NSMenu builder for genres (DESIGN §3): the skinned marquee, options button and right-click `Genre ▸`, the
/// menu bar's Genre menu, the status item, the Dock menu and the plain window's dropdown all show its items.
enum GenreMenuBuilder {
    /// Marks every item this builder makes, so the menus dump can pick the genre menu out of mixed menus (status
    /// item, Dock) and compare anchors.
    static let itemTag = 0x5E_1A

    /// Menu items for `rows` alone (the plain window's dropdown). `shortcuts` adds ⌘1…⌘9 / ⌘0 where the model has
    /// them; `checks` ticks the current genre (the dropdown shows its selection instead).
    static func items(_ rows: [GenreMenuItem], target: AnyObject, action: Selector, shortcuts: Bool = false,
                      checks: Bool = true) -> [NSMenuItem] {
        rows.map { row in
            let choice: GenreMenuChoice
            switch row.kind {
            case .separator:
                let separator = NSMenuItem.separator()
                separator.tag = itemTag
                return separator
            case .genre(let g): choice = .genre(g)
            case .surpriseMe: choice = .surpriseMe
            }
            let item = NSMenuItem(title: row.title, action: action, keyEquivalent: shortcuts ? row.keyEquivalent ?? "" : "")
            if shortcuts, row.keyEquivalent != nil { item.keyEquivalentModifierMask = [.command] }
            item.target = target
            item.representedObject = choice.tag
            item.tag = itemTag
            item.isEnabled = row.isEnabled
            item.state = checks && row.isChecked ? .on : .off
            if let subtitle = row.subtitle {
                item.subtitle = subtitle
                item.toolTip = subtitle
            }
            if case .surpriseMe = choice { item.image = NSImage(systemSymbolName: "shuffle", accessibilityDescription: nil) }
            item.setAccessibilityLabel(row.subtitle.map { "\(row.title), \($0)" } ?? row.title)
            return item
        }
    }

    /// The full genre menu's items: genres, separator, ★ Favourites, Surprise Me, Recently Played ▸.
    static func items(_ content: GenreMenuContent, target: AnyObject, action: Selector, shortcuts: Bool) -> [NSMenuItem] {
        var out = items(content.rows, target: target, action: action, shortcuts: shortcuts)
        let surprise = out.firstIndex { GenreMenuChoice($0) == .surpriseMe } ?? out.endIndex

        let favourites = NSMenuItem(title: GenreMenuContent.favouritesTitle, action: action, keyEquivalent: "")
        favourites.target = target
        favourites.representedObject = GenreMenuChoice.favourites.tag
        favourites.tag = itemTag
        favourites.isEnabled = content.favouritesCount > 0
        favourites.state = content.favouritesActive ? .on : .off
        if content.favouritesCount == 0 {
            favourites.subtitle = GenreMenuContent.noFavourites
            favourites.toolTip = GenreMenuContent.noFavourites
        } else {
            favourites.toolTip = "Your \(content.favouritesCount) favourite\(content.favouritesCount == 1 ? "" : "s"), at random"
        }
        out.insert(favourites, at: surprise)

        let recent = NSMenuItem(title: GenreMenuContent.recentTitle, action: nil, keyEquivalent: "")
        recent.tag = itemTag
        let submenu = NSMenu(title: GenreMenuContent.recentTitle)
        submenu.autoenablesItems = false
        if content.recent.isEmpty {
            let none = submenu.addItem(withTitle: GenreMenuContent.nothingRecent, action: nil, keyEquivalent: "")
            none.isEnabled = false
            none.tag = itemTag
        }
        for row in content.recent {
            let item = submenu.addItem(withTitle: "\(row.title)  [\(row.tag)]", action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = GenreMenuChoice.stream(row.id).tag
            item.tag = itemTag
        }
        recent.submenu = submenu
        out.append(recent)
        return out
    }

    /// A stand-alone genre menu (the skinned anchors and the context menu's `Genre ▸`).
    static func menu(_ content: GenreMenuContent, target: AnyObject, action: Selector, shortcuts: Bool = false,
                     delegate: (any NSMenuDelegate)? = nil) -> NSMenu {
        let menu = NSMenu(title: "Genre")
        menu.autoenablesItems = false
        menu.delegate = delegate
        for item in items(content, target: target, action: action, shortcuts: shortcuts) { menu.addItem(item) }
        return menu
    }

    /// Replaces `menu`'s items. Menus that mix genres with other items rebuild themselves around this.
    static func fill(_ menu: NSMenu, with rows: [GenreMenuItem], target: AnyObject, action: Selector,
                     shortcuts: Bool = false) {
        menu.removeAllItems()
        for item in items(rows, target: target, action: action, shortcuts: shortcuts) { menu.addItem(item) }
    }

    static func fill(_ menu: NSMenu, with content: GenreMenuContent, target: AnyObject, action: Selector,
                     shortcuts: Bool = false) {
        menu.removeAllItems()
        for item in items(content, target: target, action: action, shortcuts: shortcuts) { menu.addItem(item) }
    }
}
