// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Audio
import Catalog
import Playback
import SkinKit
import SkinUI

/// The classic windows' own menus: the View items (scales, windows, shade, region shaping, skin font) and the
/// playlist's bottom-bar buttons. Every other menu is `PlayerUIBase`'s; the Skins menu is `PlayerStyleHost`'s.
extension SkinnedPlayerUI {
    // MARK: View (shared by the context menu and the menu bar)

    /// Scales, Always on Top, the windows, shade, time, visualiser, font, region shaping.
    @objc override dynamic func viewItems() -> [NSMenuItem] {
        let holder = NSMenu()
        // ⌘D (Winamp's double size, 1x ↔ 2x) keeps working without an item of its own: Scale 2x is the same thing.
        let double = add(holder, "Double Size", #selector(viewToggleScale(_:)), key: "d")
        double.isHidden = true
        double.allowsKeyEquivalentWhenHidden = true
        for scale in SkinScale.allowed {
            // ⌘⌥1, ⌘⌥2 and ⌘⌥3 for the whole scales.
            let key = SkinScale.isWhole(scale) ? "\(Int(scale))" : ""
            let item = add(holder, "Scale \(SkinScale.label(scale))", #selector(viewSetScale(_:)), key: key,
                           modifiers: [.command, .option])
            item.representedObject = scale
            item.state = manager.scale == scale ? .on : .off
        }
        add(holder, "Always on Top", #selector(viewAlwaysOnTop(_:)), key: "a", modifiers: [.command, .option]).state =
            manager.alwaysOnTop ? .on : .off
        holder.addItem(.separator())
        add(holder, "Equalizer", #selector(viewToggleEqualizer(_:)), key: "g", modifiers: [.command, .option]).state =
            manager.isOpen(.equalizer) ? .on : .off
        add(holder, "Playlist", #selector(viewTogglePlaylist(_:)), key: "e", modifiers: [.command, .option]).state =
            manager.isOpen(.playlist) ? .on : .off
        add(holder, "Window Shade", #selector(viewToggleShade(_:)), key: "w", modifiers: [.command, .option]).state =
            manager.isShaded(.main) ? .on : .off
        add(holder, "Regroup Windows", #selector(viewRegroup(_:)))
        holder.addItem(.separator())
        add(holder, "Time Remaining", #selector(viewTimeRemaining(_:))).state = context.settings.timeRemaining ? .on : .off
        let vis = NSMenuItem(title: "Visualizer", action: nil, keyEquivalent: "")
        vis.submenu = visualizerMenu()
        holder.addItem(vis)
        add(holder, "Always Use Skin Font", #selector(viewSkinFont(_:))).state = context.settings.alwaysSkinFont ? .on : .off
        add(holder, "Shaped Windows (region.txt)", #selector(viewRegion(_:))).state = manager.regionEnabled ? .on : .off
        let items = holder.items
        holder.removeAllItems()
        return items
    }

    @objc func viewToggleScale(_ sender: Any?) { toggleScale() }
    @objc func viewSetScale(_ sender: NSMenuItem) {
        guard let scale = sender.representedObject as? Double else { return }
        setScale(scale)
    }
    @objc func viewAlwaysOnTop(_ sender: Any?) {
        manager.setAlwaysOnTop(!manager.alwaysOnTop)
        publishDebugState()
    }
    @objc func viewToggleEqualizer(_ sender: Any?) { manager.toggleOpen(.equalizer) }
    @objc func viewTogglePlaylist(_ sender: Any?) { manager.toggleOpen(.playlist) }
    @objc func viewToggleShade(_ sender: Any?) { manager.toggleShade(.main) }
    @objc func viewRegroup(_ sender: Any?) { manager.regroup() }
    @objc func viewTimeRemaining(_ sender: Any?) {
        context.updateSettings { $0.timeRemaining.toggle() }
        render()
        publishDebugState()
    }
    @objc func viewSkinFont(_ sender: Any?) { setAlwaysSkinFont(!context.settings.alwaysSkinFont) }
    @objc func viewRegion(_ sender: Any?) { setRegionEnabled(!manager.regionEnabled) }

    // MARK: Playlist buttons

    func playlistMenu(_ button: PlaylistMenuButton) -> NSMenu {
        let menu = NSMenu(title: "Playlist")
        menu.autoenablesItems = false
        let s = context.controller.snapshot
        switch button {
        case .add:
            add(menu, "Open Stream URL…", #selector(contextOpenURL(_:)), key: "l")
            add(menu, "Add to Favourites", #selector(contextFavourite(_:)), key: "f").isEnabled = s.stream != nil && !s.isFavourite
        case .remove:
            add(menu, "Never Play This", #selector(contextBan(_:)), key: "\u{8}").isEnabled = s.stream != nil
            let recent = NSMenuItem(title: "Recently Banned", action: nil, keyEquivalent: "")
            recent.submenu = AppMenus.recentlyBannedMenu(context: context, target: self, action: #selector(unbanChosen(_:)))
            menu.addItem(recent)
        case .select:
            add(menu, "Play Selected", #selector(playSelectedRow(_:))).isEnabled =
                !(manager.windows[.playlist]?.skinView.selectedRows.isEmpty ?? true)
            add(menu, "Show Current", #selector(showCurrentRow(_:))).isEnabled = lastState?.currentRow != nil
        case .misc:
            add(menu, "Copy Link", #selector(contextCopyLink(_:)), key: "c", modifiers: [.command, .option]).isEnabled = s.stream != nil
            add(menu, s.isFavourite ? "Remove from Favourites" : "Add to Favourites", #selector(contextFavourite(_:)), key: "f")
                .isEnabled = s.stream != nil
        case .list:
            break
        }
        return menu
    }

    @objc func playSelectedRow(_ sender: Any?) {
        guard let row = manager.windows[.playlist]?.skinView.selectedRows.first else { return }
        perform(.playRow(row))
    }

    @objc func showCurrentRow(_ sender: Any?) {
        guard let row = lastState?.currentRow else { return }
        manager.scrollPlaylist(toRow: max(0, row - PlaylistLayout.visibleRows / 2))
    }
}
