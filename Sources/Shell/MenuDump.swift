// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// A menu as plain data, for `--automation` `dumpMenus` (PLAN M5: every DESIGN §3 entry point is present and every
/// anchor opens the same genre menu).
nonisolated struct MenuNode: Codable, Equatable, Sendable {
    var title: String
    var enabled: Bool
    var checked: Bool
    var separator: Bool
    /// `⌘1`, `⌘⌫`, `x`, …
    var key: String?
    var subtitle: String?
    var children: [MenuNode]?

    /// The same item without its key equivalent (only the menu bar's genre items have ⌘1–⌘9).
    var withoutKeys: MenuNode {
        var copy = self
        copy.key = nil
        copy.children = children?.map(\.withoutKeys)
        return copy
    }
}

enum MenuDump {
    /// The items a user sees (hidden ones, such as the View menu's ⌘D, are left out).
    static func nodes(_ menu: NSMenu, only tag: Int? = nil) -> [MenuNode] {
        menu.items.compactMap { item in
            if item.isHidden { return nil }
            if let tag, item.tag != tag { return nil }
            return node(item, tag: tag)
        }
    }

    static func node(_ item: NSMenuItem, tag: Int? = nil) -> MenuNode {
        MenuNode(title: item.isSeparatorItem ? "-" : item.title, enabled: item.isEnabled, checked: item.state == .on,
                 separator: item.isSeparatorItem, key: key(item), subtitle: item.subtitle,
                 children: item.submenu.map { nodes($0, only: tag) })
    }

    /// The genre builder's items of a menu, without key equivalents: what every anchor must agree on.
    static func genreNodes(_ menu: NSMenu) -> [MenuNode] {
        nodes(menu, only: GenreMenuBuilder.itemTag).map(\.withoutKeys)
    }

    static func key(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var s = ""
        let m = item.keyEquivalentModifierMask
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        switch item.keyEquivalent {
        case "\u{8}": s += "⌫"
        case "\u{7F}": s += "⌦"
        case String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!): s += "↑"
        case String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!): s += "↓"
        default: s += item.keyEquivalent
        }
        return s
    }

    /// Finds an item by a `/`-separated title path (`Genre/Deep House`, `Recently Played/…`); a title matches
    /// case-insensitively, ignoring a trailing `…`, or as a prefix when nothing matches exactly.
    static func find(_ path: String, in menu: NSMenu) -> NSMenuItem? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }
        var current: NSMenu? = menu
        var found: NSMenuItem?
        for (i, part) in parts.enumerated() {
            guard let m = current, let item = match(part, in: m) else { return nil }
            found = item
            current = item.submenu
            if i < parts.count - 1, current == nil { return nil }
        }
        return found
    }

    private static func normalised(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("…") { t.removeLast() }
        if t.hasSuffix("...") { t.removeLast(3) }
        return t.lowercased()
    }

    private static func match(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        let want = normalised(title)
        let items = menu.items.filter { !$0.isSeparatorItem }
        return items.first { normalised($0.title) == want } ?? items.first { normalised($0.title).hasPrefix(want) }
    }
}
