// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Core
import Playback

/// The player UI the app shows (PLAN M5: the skinned windows by default, M2's plain window with `--plain`). The app
/// delegate, menus and automation talk to it through this.
protocol PlayerFrontEnd: AnyObject {
    /// `skinned` or `plain` (state.json `.ui.mode`).
    var modeName: String { get }
    /// The window sheets and the URL prompt attach to.
    var mainWindow: NSWindow? { get }
    func show(activate: Bool)
    /// First launch (DESIGN §3): the genre menu opens by itself once.
    func openGenreMenuSoon()
    /// Play with nothing chosen yet: show the genre menu.
    func pickGenre()
    /// Closes any open menu (quit path; a genre chosen elsewhere).
    func cancelMenuTracking()
    /// The volume changed elsewhere (menu shortcuts).
    func syncVolume()
    /// Skin files from LaunchServices, a forwarded launch or the command line.
    func loadSkinFiles(_ paths: [String], origin: String)
    /// Open Stream URL… (Eject, ⌘L).
    func promptForStreamURL()
    /// Pushes `.ui` / `.skin` to state.json.
    func publishDebugState()

    // MARK: Automation (the same controls a click reaches)

    /// Chooses a genre-menu entry as a user would (the plain dropdown, or the skinned genre menu).
    func automationSelect(_ choice: GenreMenuChoice) async -> (Bool, String?)
    func automationPress(_ control: AutomationScript.Control)
    func automationSetVolume(_ v: Double)
    func snapshot(to url: URL) throws
    /// A skinned-UI step (`ShellAutomationScript.SkinStep`).
    func perform(_ step: ShellAutomationScript.SkinStep) async -> (Bool, String?)
    /// Extra top-level keys for the automation report (`menuAutoOpened`, menu selections, menu dumps).
    var automationReport: [String: Any] { get }
    /// Called once before the script's first step.
    func automationWillStart(firstLaunch: Bool)
    /// Called after the last step: close menus and sheets.
    func automationDidFinish()
}

/// M2's plain window as a front end.
extension PlainWindowController: PlayerFrontEnd {
    var modeName: String { "plain" }
    var mainWindow: NSWindow? { window }

    func pickGenre() { openGenreMenuSoon() }

    func loadSkinFiles(_ paths: [String], origin: String) {
        Log.logger("app").notice("skins need the skinned player (started without --plain); ignored \(paths.count) file(s)")
    }

    func promptForStreamURL() {
        StreamURLPrompt.run(context: context, window: window, automation: false)
    }

    func publishDebugState() {
        context.controller.setShellState(skin: nil, ui: AppUIDebugInfo(mode: modeName))
    }

    func automationSelect(_ choice: GenreMenuChoice) async -> (Bool, String?) {
        let ok = selectInDropdown(choice)
        return ok ? (true, nil) : (false, "genre disabled in the dropdown")
    }

    func perform(_ step: ShellAutomationScript.SkinStep) async -> (Bool, String?) {
        switch step {
        case .openStreamURL(let url):
            switch context.openStream(url, origin: "automation") {
            case .success: return (true, nil)
            case .failure(let e): return (false, e.description)
            }
        default:
            return (false, "\(step) needs the skinned player (run without --plain)")
        }
    }

    var automationReport: [String: Any] { [:] }
    func automationWillStart(firstLaunch: Bool) {}
    func automationDidFinish() { cancelMenuTracking() }
}
