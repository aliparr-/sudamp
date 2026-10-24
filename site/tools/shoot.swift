// Screenshots of the site in WebKit (Safari's engine), offscreen, for checking the design without a visible screen.
//
//   swiftc -O site/tools/shoot.swift -o /tmp/shoot
//   /tmp/shoot <url> <out.png> [--width 1440] [--height 900] [--scale 2] [--wait 2.5] [--js '<script>'] [--full]
//              [--scroll <y>] [--then <js> --wait <s> --shot <out2.png> …]
//
// `--js` runs after the page loads (before waiting); `--full` captures the whole page height. Prints console errors
// the page reported and the result of the last script.

import AppKit
import WebKit

final class Shooter: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    struct Step { var js: String?; var wait: Double; var out: String? ; var full: Bool }
    let web: WKWebView
    let window: NSWindow
    var steps: [Step]
    let width: CGFloat, height: CGFloat, scale: CGFloat

    init(url: URL, width: CGFloat, height: CGFloat, scale: CGFloat, steps: [Step]) {
        self.width = width; self.height = height; self.scale = scale; self.steps = steps
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        // A fresh, private store each run, so edits are never hidden by a cached script.
        config.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        let hook = """
        window.__errors = [];
        addEventListener('error', e => { window.webkit.messageHandlers.log.postMessage('error: ' + e.message + ' @ ' + (e.filename||'') + ':' + e.lineno); });
        addEventListener('unhandledrejection', e => { window.webkit.messageHandlers.log.postMessage('rejection: ' + (e.reason && (e.reason.stack || e.reason))); });
        const ce = console.error.bind(console); console.error = (...a) => { window.webkit.messageHandlers.log.postMessage('console.error: ' + a.join(' ')); ce(...a); };
        const cw = console.warn.bind(console); console.warn = (...a) => { window.webkit.messageHandlers.log.postMessage('console.warn: ' + a.join(' ')); cw(...a); };
        const cl = console.log.bind(console); console.log = (...a) => { window.webkit.messageHandlers.log.postMessage('log: ' + a.join(' ')); cl(...a); };
        """
        controller.addUserScript(WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = controller
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: config)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        controller.add(self, name: "log")
        // Keep the page "visible" even though no one can see the window (the screen may be locked).
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if web.responds(to: sel) {
            typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(web.method(for: sel), to: F.self)(web, sel, false)
        }
        window.contentView = web
        window.setFrameOrigin(CGPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        web.navigationDelegate = self
        web.load(URLRequest(url: url))
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        print("[page] \(message.body)")
    }

    // Module scripts can still be running when `load` fires: give the page a moment before the first script.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.run() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { print("fail: \(error)"); exit(1) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { print("fail: \(error)"); exit(1) }

    func run() {
        guard !steps.isEmpty else { exit(0) }
        let step = steps.removeFirst()
        let go = {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.wait) {
                guard let out = step.out else { return self.run() }
                self.capture(out: out, full: step.full) { self.run() }
            }
        }
        if let js = step.js {
            // callAsyncJavaScript awaits a returned promise; the script is a function body, so `return` works.
            web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): if !(value is NSNull) { print("js: \(value)") }
                case .failure(let error): print("js error: \(error)")
                }
                go()
            }
        } else { go() }
    }

    func capture(out: String, full: Bool, done: @escaping () -> Void) {
        let finish: (CGFloat) -> Void = { h in
            if full {
                self.window.setContentSize(CGSize(width: self.width, height: h))
                self.web.frame = CGRect(x: 0, y: 0, width: self.width, height: h)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (full ? 1.2 : 0.05)) {
                let cfg = WKSnapshotConfiguration()
                cfg.snapshotWidth = NSNumber(value: Double(self.width * self.scale) / Double(NSScreen.main?.backingScaleFactor ?? 1))
                cfg.afterScreenUpdates = true
                self.web.takeSnapshot(with: cfg) { image, error in
                    guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { print("snapshot failed: \(String(describing: error))"); exit(1) }
                    try? png.write(to: URL(filePath: out))
                    print("wrote \(out) \(rep.pixelsWide)x\(rep.pixelsHigh)")
                    if full {
                        self.window.setContentSize(CGSize(width: self.width, height: self.height))
                        self.web.frame = CGRect(x: 0, y: 0, width: self.width, height: self.height)
                    }
                    done()
                }
            }
        }
        if full {
            web.evaluateJavaScript("document.documentElement.scrollHeight") { r, _ in finish(CGFloat((r as? NSNumber)?.doubleValue ?? Double(self.height))) }
        } else { finish(height) }
    }
}

let args = CommandLine.arguments
guard args.count >= 3, let url = URL(string: args[1]) else {
    print("usage: shoot <url> <out.png> [--width w] [--height h] [--scale s] [--wait s] [--js script] [--full] [--then js --wait s --shot out]")
    exit(2)
}
var width: CGFloat = 1440, height: CGFloat = 900, scale: CGFloat = 1
var steps: [Shooter.Step] = []
var current = Shooter.Step(js: nil, wait: 2.5, out: args[2], full: false)
var i = 3
while i < args.count {
    let a = args[i]
    func next() -> String { i += 1; return i < args.count ? args[i] : "" }
    switch a {
    case "--width": width = CGFloat(Double(next()) ?? 1440)
    case "--height": height = CGFloat(Double(next()) ?? 900)
    case "--scale": scale = CGFloat(Double(next()) ?? 1)
    case "--wait": current.wait = Double(next()) ?? 2.5
    case "--js", "--then":
        if a == "--then" { steps.append(current); current = Shooter.Step(js: nil, wait: 1, out: nil, full: false) }
        current.js = next()
    case "--shot": current.out = next()
    case "--full": current.full = true
    default: print("unknown \(a)"); exit(2)
    }
    i += 1
}
steps.append(current)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let shooter = Shooter(url: url, width: width, height: height, scale: scale, steps: steps)
DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("timeout"); exit(3) }
app.run()
