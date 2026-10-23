// SPDX-License-Identifier: GPL-3.0-or-later
// The About window (PLAN M7 "Credits: About, README, CREDITS and a THIRD_PARTY_NOTICES draft"): name, version and
// build, what sudamp is, the unofficial-client stance (DESIGN §6.5), the licence (§10) and the credits, with buttons
// for the licence, CREDITS.md and THIRD_PARTY_NOTICES.md. Plain native AppKit, never skinned. Trademark hygiene
// (§8.3): "Winamp" appears only nominatively, never as part of sudamp's name.
import AppKit
import Core

/// What About says, as plain values: tests check it without opening a window.
struct AboutContent: Equatable {
    struct Credit: Equatable {
        var name: String
        var by: String
        var role: String
        var licence: String
        var url: String
    }

    var appName = "sudamp"
    var subtitle = "The Sudden Amp"
    var version: String
    var build: String?
    var summary = Self.summaryText
    var stance = Self.stanceText
    var licence = Self.licenceText
    var credits = Self.allCredits
    /// "AndAmp Dark – AndAmp skin by Mattix (mattix.nl), CC BY 4.0", when the current skin carries a credit.
    var currentSkin: String?

    var versionLine: String {
        if let build, !build.isEmpty, build != version { return "Version \(version) (build \(build))" }
        return "Version \(version)"
    }

    static let summaryText = "Pick a genre and hear a stream: DJ mixes, live sets and internet radio, chosen at "
        + "random from a curated catalog, in a player that plays classic Winamp skins."

    static let stanceText = "sudamp is an unofficial client. It is not affiliated with or endorsed by YouTube, "
        + "SoundCloud, Mixcloud, any radio station or Winamp. Streams belong to their creators and broadcasters: "
        + "sudamp plays them without downloading them and credits them in every title."

    static let licenceText = "sudamp is free software under the GNU General Public License, version 3 or later "
        + "(GPL-3.0-or-later); its pull audio output is LGPL-2.1-or-later. It comes with no warranty. The libraries "
        + "it includes and their licences are listed in the third-party notices."

    static let allCredits: [Credit] = [
        Credit(name: "Webamp", by: "Jordan Eldredge and contributors",
               role: "skin sprite tables, font lookup, parsers, marquee and snapping rules",
               licence: "MIT", url: "https://github.com/captbaritone/webamp"),
        Credit(name: "Bitamp", by: "Ryan Romanosky and contributors",
               role: "ZIP reader, layout tables, docking, the routines behind sudamp Dark",
               licence: "MIT", url: "https://github.com/ryanromanov/Bitamp"),
        Credit(name: "wamp", by: "Valerii Bakalenko", role: "skin text-file parsers",
               licence: "MIT", url: "https://github.com/wishval/wamp"),
        Credit(name: "macamp", by: "André Hickmann Kuschnereit", role: "region parsing and snapshot approach (reference)",
               licence: "MIT", url: "https://github.com/andrehickmann/macamp"),
        Credit(name: "MacAmp", by: "Hank Yeomans", role: "EQ presets and .eqf files, visualiser DSP, screen clamping",
               licence: "MIT", url: "https://github.com/hfyeomans/MacAmp"),
        Credit(name: "AndAmp Dark, Light and Spot", by: "Mattix (https://mattix.nl)", role: "bundled skins",
               licence: "CC BY 4.0", url: "https://github.com/mattijsf/andamp"),
        Credit(name: "Winamp Skin Museum", by: "the skins' authors; museum by Jordan Eldredge",
               role: "100 bundled classic skins (Skins > Skin Museum), each its author's work",
               licence: "no licence statement", url: "https://skins.webamp.org"),
        Credit(name: "mpv and FFmpeg", by: "the mpv and FFmpeg developers, via MPVKit",
               role: "decoding and playback", licence: "LGPL", url: "https://mpv.io"),
        Credit(name: "QuickJS-NG", by: "Fabrice Bellard, Charlie Gordon and the QuickJS-NG contributors",
               role: "JavaScript runtime for yt-dlp (bundled as qjs)", licence: "MIT",
               url: "https://github.com/quickjs-ng/quickjs"),
        Credit(name: "yt-dlp", by: "the yt-dlp contributors",
               role: "stream resolution; downloaded from its official releases on first launch, never bundled or "
                   + "redistributed", licence: "Unlicense", url: "https://github.com/yt-dlp/yt-dlp"),
    ]

    /// The About content for this app: version and build from the bundle (BuildInfo when run outside one) and the
    /// current skin's credit.
    static func current(bundle: Bundle = .main, skin: SkinEntry? = nil) -> AboutContent {
        let info = bundle.infoDictionary ?? [:]
        var content = AboutContent(version: info["CFBundleShortVersionString"] as? String ?? BuildInfo.version,
                                   build: info["CFBundleVersion"] as? String)
        if let skin, let credit = skin.credit { content.currentSkin = "\(skin.name) – \(credit)" }
        return content
    }

    /// The credits as one paragraph per project, for the scrolling credits view (and its accessibility text).
    var creditsText: String {
        credits.map { "\($0.name), \($0.by): \($0.role). \($0.licence). \($0.url)" }.joined(separator: "\n")
    }
}

/// The files the About window can show.
enum AboutDocument: String, CaseIterable {
    case notices = "THIRD_PARTY_NOTICES.md"
    case licence = "LICENSE"
    case credits = "CREDITS.md"

    var title: String {
        switch self {
        case .notices: return "Third-Party Notices"
        case .licence: return "Licence (GPL-3.0-or-later)"
        case .credits: return "Credits"
        }
    }

    /// Where the file is: the app bundle's Resources first (the app bundle copies them there), then, for
    /// `swift run` and agent bundles inside a checkout, the repository found by walking up from `searchFrom`
    /// (default: the bundle, the executable and the working directory).
    func url(bundle: Bundle = .main, searchFrom: [URL]? = nil) -> URL? {
        let fileManager = FileManager.default
        if let resource = bundle.resourceURL?.appending(path: rawValue), fileManager.fileExists(atPath: resource.path) {
            return resource
        }
        let starts = searchFrom ?? [bundle.bundleURL, bundle.executableURL, URL(fileURLWithPath: fileManager.currentDirectoryPath)]
            .compactMap { $0 }
        for start in starts {
            var dir = start.hasDirectoryPath ? start : start.deletingLastPathComponent()
            for _ in 0..<8 {
                let candidate = dir.appending(path: rawValue)
                if fileManager.fileExists(atPath: candidate.path),
                   fileManager.fileExists(atPath: dir.appending(path: "Package.swift").path) {
                    return candidate
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }

    /// The file's text, or a short explanation when this build doesn't carry it.
    func text(bundle: Bundle = .main, searchFrom: [URL]? = nil) -> String {
        if let url = url(bundle: bundle, searchFrom: searchFrom), let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return "\(rawValue) is not included in this build. It is part of sudamp's source release."
    }
}

/// `AboutWindow.show()` opens (or brings forward) the About window; `showDocument` opens a notices, licence or
/// credits viewer.
enum AboutWindow {
    private static var controller: AboutWindowController?
    private static var documents: [AboutDocument: AboutDocumentWindowController] = [:]

    static func show(skin: SkinEntry? = nil) {
        let content = AboutContent.current(skin: skin)
        if controller?.content != content { controller = AboutWindowController(content: content) }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func showDocument(_ document: AboutDocument) {
        let window = documents[document] ?? AboutDocumentWindowController(document: document)
        documents[document] = window
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

final class AboutWindowController: NSWindowController {
    let content: AboutContent
    static let width: CGFloat = 480

    init(content: AboutContent) {
        self.content = content
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "About sudamp"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = makeContent()
        window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: Self.width, height: 600))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("AboutWindowController is built in code") }

    /// Every label's text, top to bottom, plus the credits; tests read the window through this.
    var displayedText: [String] {
        guard let stack = window?.contentView?.subviews.first as? NSStackView else { return [] }
        var texts: [String] = []
        func collect(_ view: NSView) {
            if let field = view as? NSTextField { texts.append(field.stringValue) }
            if let button = view as? NSButton { texts.append(button.title) }
            if let scroll = view as? NSScrollView, let text = scroll.documentView as? NSTextView { texts.append(text.string) }
            for sub in (view as? NSStackView)?.arrangedSubviews ?? [] { collect(sub) }
        }
        for view in stack.arrangedSubviews { collect(view) }
        return texts
    }

    private func makeContent() -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])

        let icon = NSImageView(image: NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        icon.setAccessibilityLabel("sudamp icon")
        stack.addArrangedSubview(icon)

        stack.addArrangedSubview(label(content.appName, font: .boldSystemFont(ofSize: 22)))
        stack.addArrangedSubview(label(content.subtitle, font: .systemFont(ofSize: 13), color: .secondaryLabelColor))
        let version = label(content.versionLine, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, selectable: true)
        stack.addArrangedSubview(version)
        stack.setCustomSpacing(14, after: version)
        stack.addArrangedSubview(paragraph(content.summary))
        stack.addArrangedSubview(paragraph(content.stance))
        stack.addArrangedSubview(paragraph(content.licence))
        if let skin = content.currentSkin { stack.addArrangedSubview(paragraph("Current skin: \(skin)")) }

        let buttons = NSStackView(views: [
            button("Licence…", action: #selector(showLicence(_:))),
            button("Credits…", action: #selector(showCredits(_:))),
            button("Third-Party Notices…", action: #selector(showNotices(_:))),
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)
        stack.setCustomSpacing(14, after: buttons)

        stack.addArrangedSubview(label("Credits", font: .boldSystemFont(ofSize: 13)))
        let credits = creditsView()
        stack.addArrangedSubview(credits)
        credits.widthAnchor.constraint(equalToConstant: Self.width - 48).isActive = true
        credits.heightAnchor.constraint(equalToConstant: 210).isActive = true
        return container
    }

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor, selectable: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = .center
        field.isSelectable = selectable
        return field
    }

    private func paragraph(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.alignment = .center
        field.preferredMaxLayoutWidth = Self.width - 48
        field.isSelectable = true
        return field
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// The credits as linked rich text in a small scroller.
    private func creditsView() -> NSScrollView {
        let text = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        for (index, credit) in content.credits.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n\n", attributes: body)) }
            var name = body
            name[.font] = NSFont.boldSystemFont(ofSize: 11)
            if let url = URL(string: credit.url) { name[.link] = url }
            text.append(NSAttributedString(string: credit.name, attributes: name))
            text.append(NSAttributedString(string: " by \(credit.by) (\(credit.licence)): \(credit.role).", attributes: body))
        }
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 6, height: 6)
            view.textStorage?.setAttributedString(text)
            view.setAccessibilityLabel("Credits")
        }
        return scroll
    }

    @objc private func showLicence(_ sender: Any?) { AboutWindow.showDocument(.licence) }
    @objc private func showCredits(_ sender: Any?) { AboutWindow.showDocument(.credits) }
    @objc private func showNotices(_ sender: Any?) { AboutWindow.showDocument(.notices) }
}

/// A plain read-only viewer for a notices, licence or credits file.
final class AboutDocumentWindowController: NSWindowController {
    let aboutDocument: AboutDocument

    init(document: AboutDocument, bundle: Bundle = .main, searchFrom: [URL]? = nil) {
        aboutDocument = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = document.title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        super.init(window: window)
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.textContainerInset = NSSize(width: 10, height: 10)
            view.string = document.text(bundle: bundle, searchFrom: searchFrom)
            view.setAccessibilityLabel(document.title)
        }
        window.contentView = scroll
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("AboutDocumentWindowController is built in code") }

    var displayedText: String { ((window?.contentView as? NSScrollView)?.documentView as? NSTextView)?.string ?? "" }
}
