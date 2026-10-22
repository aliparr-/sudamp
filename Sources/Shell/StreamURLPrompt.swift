// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Catalog

/// Open Stream URL… (Eject, ⌘L, DESIGN §3): a sheet on the player window with one text field, pre-filled from the
/// clipboard when it holds a link. The text goes through `AppContext.openStream` (the canonicaliser); a refused link
/// says why and keeps the prompt's text for another try.
enum StreamURLPrompt {
    static func run(context: AppContext, window: NSWindow?, automation: Bool, initial: String? = nil) {
        guard !automation else { return }
        let alert = NSAlert()
        alert.messageText = "Open Stream URL"
        alert.informativeText = "Paste a YouTube, SoundCloud or Mixcloud link, or an internet radio stream."
        alert.addButton(withTitle: "Play")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://"
        field.stringValue = initial ?? clipboardLink() ?? ""
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.usesSingleLineMode = true
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue
            if case .failure(let error) = context.openStream(text, origin: "prompt") {
                let refusal = NSAlert()
                refusal.messageText = "sudamp can't play that link"
                refusal.informativeText = StreamURLOpener.explanation(error)
                refusal.addButton(withTitle: "Try Again")
                refusal.addButton(withTitle: "Cancel")
                let retry: (NSApplication.ModalResponse) -> Void = { again in
                    if again == .alertFirstButtonReturn { run(context: context, window: window, automation: false, initial: text) }
                }
                present(refusal, on: window, then: retry)
            }
        }
        present(alert, on: window, then: finish)
    }

    /// A window-modal sheet when the window is on screen, else an app-modal alert.
    static func present(_ alert: NSAlert, on window: NSWindow?, then completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { completion(response) } }
        } else {
            NSApp.activate()
            completion(alert.runModal())
        }
    }

    /// The clipboard's text when it looks like a link.
    static func clipboardLink() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count <= 2048, text.contains("://") || text.hasPrefix("www.") || text.hasPrefix("youtu"),
              (try? Canonicaliser.parse(text)) != nil else { return nil }
        return text
    }
}
