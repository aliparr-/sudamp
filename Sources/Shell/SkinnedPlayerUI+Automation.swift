// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Core
import Playback
import SkinKit
import SkinUI

/// `--automation` for the skinned windows (PLAN M5): menus are opened at their anchors and their items chosen
/// through the menu (`PlayerUIBase`); controls are pressed and sliders dragged through SkinUI's pointer state
/// machine; skins load through the same code as Open Skin…. Nothing takes focus from the owner, and no menu stays
/// open for long.
extension SkinnedPlayerUI: PlayerFrontEnd {
    var modeName: String { "skinned" }

    // MARK: Core steps

    func automationPress(_ control: AutomationScript.Control) {
        let main = manager.windows[.main]?.skinView
        switch control {
        case .play: main?.press(.play)
        case .pause: main?.press(.pause)
        case .stop: main?.press(.stop)
        case .next: main?.press(.next)
        case .previous: main?.press(.previous)
        case .playPause: main?.press(context.controller.snapshot.phase == .playing ? .pause : .play)
        case .retry: context.retry()
        }
    }

    func automationSetVolume(_ v: Double) {
        manager.windows[.main]?.skinView.dragSlider(.volume, toFraction: v / 100)
    }

    /// Main's picture (base + marquee + visualiser) at the current scale, as a PNG.
    func snapshot(to url: URL) throws {
        guard let view = manager.windows[.main]?.skinView, let picture = SkinPicture.composite(view) else {
            throw SkinPicture.Failure(description: "no frame drawn yet")
        }
        guard let png = SkinPicture.resized(picture, to: SkinScale.intSize(view.kind, scale: view.scale)).pngData() else {
            throw SkinPicture.Failure(description: "PNG encoding failed")
        }
        try png.write(to: url, options: .atomic)
    }

    var automationReport: [String: Any] {
        var report = menuReport
        report["skinId"] = skinEntry.id
        report["skinClass"] = "classic"
        return report
    }

    func automationDidFinish() {
        cancelMenuTracking()
        if let main = manager.windows[.main], let sheet = main.attachedSheet { main.endSheet(sheet) }
        manager.close()
    }

    // MARK: Skinned steps

    func perform(_ step: ShellAutomationScript.SkinStep) async -> (Bool, String?) {
        if let result = await performMenuStep(step) { return result }
        switch step {
        case let .pressControl(name, window):
            guard let control = Control(rawValue: name), let role = SkinWindowRole(rawValue: window),
                  let view = manager.windows[role]?.skinView else { return (false, "unknown control \(name)") }
            guard Layout.rect(of: control, in: view.kind) != nil else { return (false, "\(name) is not in \(view.kind)") }
            return view.press(control) ? (true, nil) : (false, "\(name) did nothing")
        case let .dragSlider(name, value, window):
            guard let control = Control(rawValue: name), let role = SkinWindowRole(rawValue: window),
                  let view = manager.windows[role]?.skinView else { return (false, "unknown slider \(name)") }
            let fraction: Double
            switch control {
            case .volume, .position, .playlistScrollbar: fraction = value
            case .balance: fraction = SliderValues.balanceFraction(value)
            default: fraction = SliderValues.eqFraction(decibels: value)
            }
            return view.dragSlider(control, toFraction: fraction) ? (true, nil) : (false, "\(name) is not a working slider here")
        case let .loadSkin(spec, expectRejection):
            let before = context.controller.snapshot.lastError
            if library.entry(id: spec) != nil {
                _ = selectSkin(id: spec, origin: "automation")
            } else {
                loadSkinFiles([spec], origin: "automation")
            }
            let after = context.controller.snapshot.lastError
            let rejected = after != before && after?.kind == "skinRejected"
            let note = rejected ? "rejected: \(after?.message ?? "")" : "skin \(skinEntry.id)"
            return (rejected == expectRejection, note)
        case .showWindows:
            showWithoutActivating()
            return (true, nil)
        case .playRow(let row):
            manager.handle(.playlistRowActivated(index: row), from: .playlist)
            return (true, nil)
        default:
            return (false, "\(step) is not handled")
        }
    }
}
