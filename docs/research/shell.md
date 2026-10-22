# macOS app shell, distribution, and catalog backend

## SUMMARY
Main correction to the brief: this Mac has only the Command Line Tools installed. There is no Xcode.app, so `xcodebuild`, `actool`, `ibtool` and XCTest are all missing. `swift build`, `swift test` (Swift 6.4, swiftbuild backend), `codesign`, `notarytool`, `stapler` and `iconutil` are all present. I built a throwaway AppKit app with SwiftPM, put it in a hand-made .app bundle, ad-hoc signed it, and it ran on macOS 27.0.1. Swift Testing works; `import XCTest` fails. SwiftPM still can't produce .app bundles on its own (a July 2026 forum pitch on the topic is still at the pitch stage). XcodeGen and Tuist only generate projects that need `xcodebuild`, so they are no use here until Xcode is installed. Recommendation: one Swift package with several modules, a thin executable target, and a Makefile/shell script that assembles, signs and notarizes the bundle. Use AppKit for every Winamp window: borderless, non-opaque NSWindow subclasses with custom drawing and custom dragging. Use SwiftUI only for secondary UI such as Preferences.

Distribution has to be Developer ID plus notarization. The Mac App Store is ruled out by guidelines 2.5.2, 2.4.5 and 5.2.3. Homebrew has disabled casks that fail Gatekeeper since 2026-09-01. Two things were checked directly on this machine. First, an ad-hoc signed binary with the hardened runtime cannot load an ad-hoc dylib ("different Team IDs"), so dev builds should be ad-hoc signed without the hardened runtime. Second, the official Deno 2.9.8 binary is already Developer ID signed with the hardened runtime and its own JIT entitlements. Apple's notary service accepts nested code signed by a different Developer ID team, so Deno can be embedded unchanged. yt-dlp_macos is an ad-hoc signed PyInstaller onefile binary. The yt-dlp zipapp is 3 MB of pure Python and includes yt-dlp-ejs. For runtime updates the cleanest route is a bundled, signed Python plus the zipapp, which is data rather than Mach-O code. Its hash would come from our own signed manifest. Apps that aren't sandboxed don't quarantine files they write unless `LSFileQuarantineEnabled` is set, so Gatekeeper never checks those files.

Licensing: make sudamp GPL-3.0-or-later. That is compatible with mpv (GPLv2+), a GPL build of FFmpeg (Homebrew's is GPLv3+) and IINA's GPLv3 code. An LGPL build gives a GPLv3 app no legal benefit; it only means fewer dependencies. The catalog should be versioned JSON, hosted as static files with an Ed25519 signature from CryptoKit; GitHub Pages ETags and 304 responses were verified. The bigger protection is a strict URL allowlist with canonicalization. Catalog URLs reach yt-dlp, which had several command-injection advisories in 2025–2026, and mpv, which accepts protocols such as file://, edl://, env://, archive:// and av://. Random picks should use a weighted shuffle-bag per genre that persists across launches, skips failing streams with backoff, and pre-resolves the next pick. Housekeeping: an untracked `sc.json` (a SoundCloud API response, created 08:45) appeared in the repo root. This agent didn't create it; it is probably from a sibling agent. I left it alone.

## RECOMMENDATION
1) APP SHELL (AppKit windows, SwiftUI for secondary UI)
- `final class SkinWindow: NSWindow`: styleMask [.borderless], isOpaque=false, backgroundColor=.clear, hasShadow=false, override canBecomeKey/canBecomeMain → true. Drag with your own mouseDown/mouseDragged, not isMovableByWindowBackground. One window each for Main (275×116), EQ (275×116) and Playlist (275×116, resizable in 25×29 steps). Shade mode is 275×14. Double-size multiplies the frame by 2 with an integer-scaled layer (magnificationFilter = .nearest).
- `WindowManager` (@MainActor) ports Webamp's snapUtils (MIT): SNAP_DISTANCE 15 pt, snapping to screen visibleFrame and to other windows.
  - Dragging Main: compute the connected set with traceConnection(abuts), attach those windows via addChildWindow(_, ordered: .above) for the drag, move Main, then removeChildWindow on mouseUp.
  - Other windows move alone and snap.
- Always on top: level = .floating on all windows. Optional 'show on all Spaces': collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary].
- NSStatusItem menu: genre submenu, Play/Pause/Next, Copy link.
- Dock: .regular by default; a 'Hide Dock icon' pref switches to setActivationPolicy(.accessory), only while the status item is enabled. Add applicationDockMenu with genres.
- Hotkeys: KeyboardShortcuts 3.1.0, defaults using ⌃⌥ (not Option-only).
- Media keys: MPRemoteCommandCenter (toggle, play, pause, next, previous). Set MPNowPlayingInfoCenter.playbackState on every transition, plus IsLiveStream and ExcludeFromSuggestions = true.
- Swift 6: App, UI and SkinKit targets use `.defaultIsolation(MainActor.self)`; every target enables ApproachableConcurrency.
  - Catalog, Picker and Core: nonisolated Sendable structs.
  - Engine: an actor, or a final class with a private serial queue marked @unchecked Sendable, around mpv_handle. The mpv wakeup C callback receives an Unmanaged context and hops to the main queue or an AsyncStream.
  - Mark yt-dlp Process and JSON work @concurrent.

2) PROJECT AND BUILD (SwiftPM + Makefile; no Xcode needed)
- Package.swift: swift-tools-version 6.2+, platforms [.macOS(.v14)], arm64.
- Targets:
  - `SudampApp` (executable: AppDelegate, WindowManager, menus, status item, hotkeys, NowPlaying)
  - `SudampUI` (AppKit skin views)
  - `SkinKit` (.wsz ZIP reading, BMP decoding via ImageIO, sprite tables ported from Webamp skinSprites.ts, viscolor.txt / pledit.txt / region.txt parsers)
  - `Catalog` (Codable models, validation, URL canonicalizer/allowlist, loader, CryptoKit verification)
  - `Picker` (shuffle-bag, persistence)
  - `Engine` (libmpv wrapper, yt-dlp resolver, helper paths)
  - `CMPV` (.systemLibrary(pkgConfig: "mpv") for dev; a local .binaryTarget xcframework or vendored dylibs for release)
  - `SudampCore` (settings, os.Logger, shared types)
- Tests: Swift Testing only, via `swift test --parallel` (XCTest isn't available without Xcode). Add golden-image skin rendering tests using an offscreen CGContext.
- Make targets: `make build | test | app | run | release`.
- `make app` copies the executable to Contents/MacOS, the *.bundle resource bundles to Contents/Resources, dylibs and Sparkle.framework (with ditto) to Contents/Frameworks, and deno/python to Contents/Helpers. It fills in the Info.plist template and runs `codesign --force --sign -` with no --options runtime.
- Add an XcodeGen project.yml only once Xcode.app is installed, for Instruments and Icon Composer.

3) DISTRIBUTION
- Enroll in the Apple Developer Program.
- Release: sign inside-out with `codesign --force --options runtime --timestamp --sign "Developer ID Application: … (TEAMID)"`, in this order: Frameworks dylibs, Sparkle (Autoupdate, Updater.app, framework), python helper and its .so/.dylib files, main executable, then the app.
  - Main app entitlements: none.
  - Avoid LuaJIT inside the app process (prefer resolving in the app, or mpv built with non-JIT Lua); otherwise add com.apple.security.cs.allow-jit.
  - Leave deno exactly as Deno Land signed it (allowed by the notary service; it carries its own JIT entitlements). Never use --deep.
- Notarize: `ditto -c -k --keepParent Sudamp.app` → `xcrun notarytool submit … --keychain-profile sudamp --wait` → `xcrun stapler staple` → build the DMG (hdiutil) → notarize and staple the DMG.
- Runtime yt-dlp updates:
  - Pin {version, url, sha256} in the signed catalog manifest.
  - Download the zipapp to ~/Library/Application Support/Sudamp/yt-dlp/<ver>/ and verify the SHA-256.
  - Switch over atomically, and fall back to the bundled copy on failure.
  - Run `python3 -I -B` with PYTHONDONTWRITEBYTECODE=1.
  - Don't set LSFileQuarantineEnabled, and never write into the .app.
- App updates: Sparkle 2.10 (SUPublicEDKey, SUFeedURL pointing at an appcast on the catalog host).
- Homebrew: own tap first, then homebrew/cask once notarized and notable enough (auto_updates true).
- Dev: ad-hoc signing without the hardened runtime works on macOS 27.0.1 (verified). Unnotarized builds sent to others require Privacy & Security › Open Anyway.

4) LICENSING
- License sudamp GPL-3.0-or-later.
- Build a slim, audio-focused libmpv and FFmpeg with a script checked into the repo. GPL or LGPL configuration is legally irrelevant for a GPLv3 app, so choose for size and fewer dependencies.
- Publish corresponding source and build scripts with each release.
- Ship THIRD_PARTY_NOTICES: mpv, FFmpeg, yt-dlp (Unlicense), yt-dlp-ejs (ISC/MIT), Deno (MIT, V8 BSD), CPython (PSF), Sparkle (MIT), KeyboardShortcuts (MIT), TLS library, Webamp-derived tables (MIT).
- Don't bundle the Winamp base skin or use Winamp marks; describing it as 'plays classic .wsz skins' is fine.

5) CATALOG
- Schema v1, example:
  {"schema":1,"revision":42,"generatedAt":"2026-10-22T10:00:00Z","minAppVersion":"0.1.0","ytdlp":{"version":"2026.10.21","url":"…","sha256":"…"},"genres":[{"id":"deep-house","name":"Deep House","order":10,"aliases":[]}],"streams":[{"id":"yt:jfKfPfyJRdk","source":"youtube","sourceId":"jfKfPfyJRdk","url":"https://www.youtube.com/watch?v=jfKfPfyJRdk","title":"…","artist":"…","genres":["lofi"],"kind":"live","isLive":true,"durationSec":null,"startAtSec":0,"tags":["chill"],"addedAt":"2026-10-01","weight":1.0,"status":"active","lastCheckedAt":"…"}]}
  - source is youtube | soundcloud | mixcloud | radio; kind is live | mix | track; status is active | flaky | dead | hidden.
- Decoding is lenient per item: an unknown source or kind, or a failed validation, drops that item only. An unknown major schema version means ignore the remote catalog.
- Load order: verified remote catalog (Ed25519 detached .sig, revision ≥ cached) → cache in Application Support/Sudamp/catalog/ (json, sig, meta {etag, fetchedAt, revision}) → bundled catalog.json.
- Fetch after playback has started and every 12 h, with If-None-Match; a 304 just updates fetchedAt. Send no identifiers; the User-Agent is just "sudamp/<ver>".
- URL policy (also applied to the bundled catalog):
  - Rebuild every URL from (source, sourceId): YouTube id must match ^[A-Za-z0-9_-]{11}$; SoundCloud https://soundcloud.com/<user>/<slug>; Mixcloud https://www.mixcloud.com/<user>/<slug>/.
  - Radio: http(s) only, no userinfo or IP literals, no localhost/.local, no non-default ports; played directly by mpv with ytdl=no.
  - Pass to yt-dlp as argv with --ignore-config --no-playlist --js-runtimes deno:<path> -- <url>.
  - Call mpv with array-form loadfile, config=no, load-scripts=no, and keep load-unsafe-playlists=no.

6) SERVER LATER
- `sudamp-catalog` repo: YAML per genre → CI (schema check, allowlist, dedupe, stable ids, sign) → GitHub Pages or Cloudflare Pages at catalog.<domain>/v1/catalog.json.
- Weekly scheduled job: liveness via YouTube/SoundCloud oEmbed and the Mixcloud API. yt-dlp metadata refresh only for new or changed items, run from a residential self-hosted runner. Status goes active → flaky → dead after 3 failures over at least 7 days, always via a PR.
- Add Workers + D1 only when you want opt-in anonymous dead-stream reports (POST {streamId, reason, appVersion}, IPs not stored, aggregate counts), submissions turned into PRs by a bot, or aggregate popularity.

7) PICKER
- Each genre has a weighted shuffle-bag: an Efraimidis–Spirakis permutation (key = u^(1/weight)) over active streams.
- On refill, keep the last min(3, n/3) played streams out of the head of the new bag.
- Persist {genreId, revision, order, cursor} as JSON. When the catalog changes, drop removed ids and insert new ids at random positions after the cursor.
- Failure handling:
  - Resolve timeout 15 s, first-audio timeout 20 s, then auto-advance.
  - Per-stream backoff: skip for 1 h, then 24 h; reset on success.
  - After 5 consecutive failures in a genre, stop and show a 'can't reach streams' state with Retry.
- Prefetch: pick and pre-resolve metadata for the next stream when playback starts. Resolve the playable URL about 90 s before a VOD ends (resolved URLs expire); resolve live streams on demand.
- Launch:
  - First run: genre dropdown is focused; choosing a genre starts playback. No surprise audio.
  - Later launches: auto-resume the last genre (pref, default ON). Resume the same VOD at its saved position if the app was quit less than 6 h ago and more than 5 min remain; otherwise play the next bag item. Fade in over 1.5 s.
  - Next = skip within the genre; Previous = history stack.

8) EXTRAS (cheap)
- Scrolling marquee 'Artist – Title'; click the time display to toggle elapsed/remaining.
- Favourites (♥) and History (last 200), exportable as M3U or JSON.
- 'Never play this again' ban.
- Copy link, with timestamp where supported (YouTube &t=Ns, SoundCloud #t=m:ss); Open in browser.
- Drag a .wsz onto any window to apply the skin (validate and unzip into Application Support/Skins); skin menu with recently used skins.
- Sleep timer; sudamp://genre/<id> URL scheme for Raycast and Shortcuts.
- Optional track-change notification; mini 'shade' mode bound to a hotkey.
- Volume and balance scroll on the main window; a VU or fake spectrum driven by mpv audio-level metadata (coordinate with engine research).
- An original startup jingle, not the llama sample.

## RISKS
- [high] YouTube keeps changing (JS challenges, PO tokens, bot checks), breaking playback between yt-dlp releases. Users stuck on an old bundled yt-dlp get silent failures. -> Ship the signed-manifest zipapp updater from v1, with a fallback channel (nightly) and a fallback to the bundled copy. Auto-advance with backoff. Keep a broad SoundCloud/Mixcloud/radio mix in every genre so a YouTube outage doesn't empty one.
- [medium] Notarization problems with nested third-party code: the Python runtime's nested .so layout, deno entitlements, or a re-signed PyInstaller binary failing library validation. -> In the first milestone, build a 'hello' bundle containing Python, the zipapp and deno, and send it through notarytool and spctl -a -vv before writing features. Read the notarytool log JSON. Follow Apple's 'Embedding nonstandard code structures' guide.
- [medium] Legal and terms of service: streaming YouTube audio without the player breaks YouTube's terms, and GPL distribution of FFmpeg/x264 could raise patent questions in some regions. -> Stream only, no download or save features, and use no YouTube branding. Keep the catalog curated and handle takedowns quickly through the catalog repo. Leave encoders out of the FFmpeg build (decoders and network only). Get a lightweight legal review before wide promotion.
- [medium] A malicious or compromised catalog entry (a merged PR, a hosting compromise) drives yt-dlp or mpv to local files, local-network addresses or injected options. -> Canonicalize to (source, sourceId) and reject anything else. Pass arguments as argv with `--` and `--ignore-config`; never use --exec, --netrc-cmd or external downloaders. Use mpv with config=no and load-scripts=no. Add an Ed25519 signature with anti-rollback and require 2 reviewers on the catalog repo.
- [medium] Without a $99/yr Developer ID: no notarization, friction for users (Open Anyway in System Settings), no official Homebrew cask (casks failing Gatekeeper are disabled since 2026-09-01), and a rougher Sparkle experience. -> Decide on enrolment before the first public build. Until then, distribute only to developers who build from source or use a personal tap with clear instructions.
- [low] App size: deno (81.5 MB) + Python (~25 MB) + libmpv/FFmpeg comes to about 150 MB, at odds with Winamp's lightweight spirit. -> Slim, audio-only FFmpeg and mpv build. Benchmark QuickJS (about 1 MB, MIT) against deno for yt-dlp-ejs latency and switch if it's fast enough. Strip Python's unused stdlib modules.
- [low] Multi-window drag jank on macOS 14+ (vsync-synchronized setFrame) and child-window quirks with Spaces or multiple displays. -> Use child windows only while dragging, as one group; detach on mouseUp. Test on multiple displays and Spaces early. If problems persist, fall back to moving one combined window during drags.
- [low] No Xcode.app means no Instruments, no visual debugger and no Liquid Glass icon compilation; SwiftPM's swiftbuild backend is new and may have edge-case bugs (the first swift test run failed spuriously, then passed). -> Install Xcode when convenient for profiling and icons. Keep the build script simple and deterministic. Pin the toolchain version in CI. Rerun with a clean .build if a build fails strangely.
- [low] Ad-hoc dev builds get a new cdhash every build, which resets TCC and Keychain grants. -> The design needs no TCC permissions (Carbon hotkeys, MediaPlayer, network only). If Keychain is needed later, sign dev builds with a stable self-signed or Apple Development identity, still without the hardened runtime.

## OPEN QUESTIONS
- Will the owner join the Apple Developer Program ($99/yr) for Developer ID signing and notarization? It decides the Homebrew and Sparkle story and the first-launch experience for others.
- Install Xcode.app on the dev machine? The brief said it was available, but only the Command Line Tools are installed. It's needed for Instruments, the debugger and Icon Composer/actool.
- Engine coordination: should libmpv's ytdl_hook (needs Lua inside the app process; IINA-style entitlements if LuaJIT) resolve URLs, or should the app run yt-dlp itself and pass direct media URLs and HTTP headers to mpv (no Lua, no JIT entitlements in the app)?
- deno (81.5 MB, yt-dlp's default) or QuickJS (about 1 MB, opt-in via --js-runtimes)? Benchmark resolve latency and reliability for YouTube n/sig challenges on Apple silicon.
- Bundled Python layout: python-build-standalone (astral-sh, 20261021 builds) or BeeWare's Python-Apple-support Python.framework (designed for app embedding)? Which notarizes more cleanly with the hardened runtime?
- If the onefile yt-dlp_macos fallback is chosen: how does IINA's CodeSignOnCopy re-signed onefile load its extracted, ad-hoc-signed Python under the hardened runtime? Verify before relying on it.
- Minimum macOS (14 vs 15) and arm64-only vs universal. Is there demand from Intel Macs on macOS ≤26?
- Domain name for the catalog and appcast hosting (affects ATS, the allowlist and future Workers routes).
- Autoplay policy: should the very first launch play a default genre immediately, or wait for the first genre pick? (Recommended: wait.)
- Housekeeping: an untracked file /Users/aliparr/.t3/projects/sudamp/sc.json (SoundCloud API JSON, created 08:45) appeared in the repo root. This agent didn't create it, probably a sibling research agent did. The orchestrator should decide whether to delete it.

## OPTIONS
- UI-A: AppKit window layer + custom CoreGraphics skin views + SwiftUI only for secondary UI: Recommended.
- UI-B: SwiftUI-first windows (WindowGroup + .windowStyle(.plain) + WindowDragGesture + NSWindow introspection): Rejected for skin windows. Use SwiftUI only for Preferences/About.
- BUILD-A: SwiftPM package + Makefile/scripts that assemble, sign and notarize the .app: Recommended now.
- BUILD-B: XcodeGen project.yml (2.46.0) generating an .xcodeproj that wraps the local package: Optional later, only for debugging and icons once Xcode is installed. Don't make it the primary build.
- BUILD-C: Tuist (4.212) or swift-bundler: Rejected. Too much tool for the job, or too little certainty.
- YTDLP-A: bundle yt-dlp_macos (PyInstaller onefile), as IINA does: Acceptable fallback if Option B proves hard. Verify the hardened-runtime behaviour early.
- YTDLP-B: bundled Python (python-build-standalone 3.13/3.14 install_only_stripped, ~25 MB) + yt-dlp zipapp (3 MB) + deno helper: Recommended. Spike notarizing it in the first milestone.
- CATALOG-HOST-A: static signed JSON on GitHub Pages or Cloudflare Pages (custom domain), built from a separate catalog repo: Recommended for v1.x.
- CATALOG-HOST-B: Cloudflare Workers + D1 API: Defer until reports or submissions are actually needed, then make it opt-in and aggregate-only.
- CATALOG-INTEGRITY: HTTPS + allowlist only vs. adding an Ed25519 detached signature: Do both. The allowlist is mandatory from v1 (even for the bundled catalog); the signature is required once fetching remotely.

## VERIFICATION CHECKS (non-confirmed)
- [partially-true] The official deno 2.9.8 aarch64 binary is Developer ID signed (Deno Land Inc., 2H4KBF436B) with the hardened runtime, a timestamp and JIT entitlements, and the notary service accepts nested code signed by another team, so it can be embedded unchanged.
    CORRECTION: The signature, flags 0x10000(runtime), timestamp and the 5 entitlements all match, and Quinn (DTS) says the notary service does not require the same Developer ID across code items. But `spctl -a -t exec` on the official binary returns 'rejected, source=Unnotarized Developer ID': Deno does not notarize the standalone binary. Embedding it unchanged therefore depends entirely on sudamp's own notarization ticket covering deno's cdhash. Verify with spctl on the stapled app, not just the notarytool log. Deno is 81.5 MB unpacked and 38.8 MB zipped.
    SRC: Local download + codesign -dvv / codesign -d --entitlements / spctl; https://developer.apple.com/forums/thread/683871
- [partially-true] Only deno is enabled by default (minimum 2.0.0); node, quickjs, quickjs-ng and bun need --js-runtimes; each yt-dlp version pins an exact yt-dlp-ejs version; no remote components are allowed by default.
    CORRECTION: The EJS wiki now gives Deno minimum 2.3.0, not 2.0.0. Bun is deprecated. QuickJS before 2025-4-26 (and QuickJS-NG before 0.12.0) can take minutes per solve, and QuickJS writes a temp file per script (theoretical TOCTOU risk). Deno runs the solver with no filesystem or network access, which is a security argument for deno over QuickJS. There is also a `youtube-ejs:jitless=true` extractor-arg. The ejs version 'MUST match' pyproject.toml, and remote components are off by default.
    SRC: https://github.com/yt-dlp/yt-dlp/wiki/EJS ; https://raw.githubusercontent.com/yt-dlp/yt-dlp/master/README.md
- [partially-true] Now Playing: playbackState is macOS-specific; set MPNowPlayingInfoPropertyIsLiveStream and ExcludeFromSuggestions=true (with a minimum target of macOS 14).
    CORRECTION: MPNowPlayingInfoPropertyExcludeFromSuggestions is available only from macOS 15.0. With macOS 14 as the minimum it needs an `if #available(macOS 15, *)` guard. WindowDragGesture is also 15+. playbackState is no longer listed as macOS-only (Apple's docs list iOS 13+ too). IsLiveStream has been available since macOS 10.12.2.
    SRC: https://developer.apple.com/tutorials/data/documentation/mediaplayer/mpnowplayinginfopropertyexcludefromsuggestions.json ; …/mpnowplayinginfocenter/playbackstate.json
- [partially-true] Licensing: mpv is GPLv2+ (LGPLv2.1+ with -Dgpl=false, which doesn't itself grant LGPL); Homebrew FFmpeg is GPL-3.0-or-later (--enable-gpl --enable-version3 plus x264/x265); MPVKit 1.0.0 (2026-07-25) is learning-only; IINA uses the hardened runtime with allow-unsigned-executable-memory and disable-library-validation, and copies yt-dlp_macos as youtube-dl with CodeSignOnCopy.
    CORRECTION: All correct except the MPVKit release: the latest is 1.1.0-n9.0.2 (2026-10-07), not 1.0.0. Homebrew's ffmpeg is now 9.0.2.
    SRC: https://raw.githubusercontent.com/mpv-player/mpv/master/Copyright ; Homebrew ffmpeg.rb ; https://github.com/mpvkit/MPVKit (README + releases.atom); iina/IINA.entitlements, Configs/Shared.xcconfig (ENABLE_HARDENED_RUNTIME = YES), project.pbxproj ('youtube-dl in Copy Executables', CodeSignOnCopy)
- [partially-true] Catalog signing: minisign's 'ED' format is Ed25519 over a BLAKE2b-512 prehash, so use raw Ed25519 and sign in CI with `openssl pkeyutl -sign -rawin`.
    CORRECTION: The minisign facts are correct ('New implementations must use the hashed signature format'). The openssl recipe only works with OpenSSL 3.x: macOS /usr/bin/openssl is LibreSSL 3.3.6, which rejects both '-algorithm ed25519' and '-rawin'. Use a Swift/CryptoKit signing script, or OpenSSL 3 on a Linux runner.
    SRC: https://jedisct1.github.io/minisign/ ; local /usr/bin/openssl probe
- [partially-true] addChildWindow is one-directional, and on macOS 14+ setFrame is vsync-synchronised, so moving two windows is about 2× slower.
    CORRECTION: The one-directional child-window behaviour is in Apple's docs. The vsync / 2× claim rests on one unanswered June 2023 forum post written against Sonoma developer beta 1, with no Apple confirmation. Treat it as a hypothesis to measure, not a fact.
    SRC: https://developer.apple.com/tutorials/data/documentation/appkit/nswindow/addchildwindow(_:ordered:).json ; https://developer.apple.com/forums/thread/731769 (0 replies)
- [refuted] swift-bundler has had no tagged release since 2022 (v2.0.4).
    CORRECTION: Tags v2.0.5 (2023-05-11), v2.0.6 (2025-04-17) and v2.0.7 (2025-04-18) exist, and main has commits as recent as 2026-10-11. The README still recommends `mint install stackotter/swift-bundler@main`. Rejecting it can still be justified, because sudamp needs custom helpers and signing anyway, but this reason is wrong.
    SRC: https://github.com/moreSwift/swift-bundler/releases.atom ; https://github.com/moreSwift/swift-bundler/commits/main.atom

## CONFIRMED CLAIMS
- Only the Command Line Tools are installed. xcodebuild, actool and ibtool are missing; notarytool, stapler, codesign and iconutil are present; Swift is 6.4 with swiftbuild; Swift Testing works but XCTest does not; the first `swift test` run failed spuriously.
- SwiftPM can't produce .app bundles; the 'Product-Builder plugin capability' pitch (Jul 29, revised Aug 27, 2026) is still only a pitch.
- The resource accessor generated under swiftbuild checks Bundle.main.resourceURL, then Bundle(for:).resourceURL, then Bundle.main.bundleURL, so copying <Pkg>_<Target>.bundle into Contents/Resources works.
- An ad-hoc signed executable with the hardened runtime can't load an ad-hoc dylib ('different Team IDs'); without the runtime flag it loads.
- yt-dlp 2026.10.21 is the latest release. The zipapp is 3.07 MB, includes yt_dlp_ejs and needs Python 3.11+. yt-dlp_macos is a 37 MB universal, ad-hoc signed PyInstaller onefile with no TeamIdentifier. PyInstaller says embedded binaries in onefile builds can't be re-signed afterwards.
- Homebrew has disabled homebrew/cask casks that fail Gatekeeper since 2026-09-01, and --no-quarantine is deprecated.
- Sparkle 2.10.0 was released 2026-09-13. Non-Xcode builds need -Wl,-rpath,@loader_path/../Frameworks; symlinks must be preserved; non-sandboxed apps can drop the XPC services; generate_keys stores the key in the Keychain.
- KeyboardShortcuts 3.1.0 (MIT, macOS 10.15+) was released 2026-09-11. macOS 15 blocks Option/Option-Shift-only hotkeys (-9868), and 15.2 reportedly fixed it.
- Mac App Store is ruled out by 2.5.2, 2.4.5(i)/(vii) and 5.2.3 (which names YouTube and SoundCloud and warns about streaming).
- GitHub Pages has a 1 GB site limit and a 100 GB/month soft bandwidth limit, and serves ETag, max-age=600 and 304s. Cloudflare Workers Free gives 100k requests/day and 10 ms CPU, with static assets free and unlimited; D1 and KV limits are as stated.
- Non-sandboxed apps don't quarantine files they write unless LSFileQuarantineEnabled is set; macOS 27 runs only on Apple silicon and is the last release with full Rosetta; Webamp SNAP_DISTANCE=15 with traceConnection; MacWamp is a GPL-3.0 SwiftPM/AppKit Winamp clone.

## MISSED CONSIDERATIONS
- yt-dlp plugins load regardless of --ignore-config. The README says all plugins are imported 'with no checks' from ~/.yt-dlp/plugins, ~/yt-dlp-plugins, $XDG_CONFIG_HOME/yt-dlp/plugins, /etc/yt-dlp/plugins and a `yt-dlp-plugins` directory next to the executable, which would include the Application Support folder holding the updated zipapp. To prevent that, set YTDLP_NO_PLUGINS=1 and pass --no-plugin-dirs. Also set --cache-dir to sudamp's own Caches folder (the default ${XDG_CACHE_HOME}/yt-dlp is shared with the user's yt-dlp), never allow -U self-update, and spawn python/deno with a scrubbed environment (deno is entitled to allow-dyld-environment-variables).
- TLS trust store for a bundled python-build-standalone (unverified): the zipapp doesn't bundle certifi, and a standalone OpenSSL may not find macOS root certificates, causing CERTIFICATE_VERIFY_FAILED. Bundle certifi or set SSL_CERT_FILE (e.g. /etc/ssl/cert.pem), and include this in the notarization spike.
- Deno does not notarize its standalone macOS binary (spctl: 'Unnotarized Developer ID'). Embedding it unchanged only works if sudamp's notarization ticket covers its cdhash. Gate releases on `spctl -a -vv -t exec` against the embedded deno inside the stapled app.
- CI toolchain mismatch: GitHub's macos-26 runners ship Xcode 26.5/26.6, not Swift 6.4, and may use a different SwiftPM build system. Keep swift-tools-version at 6.2 (not the 6.4 that `swift package init` writes) and use `swift build --show-bin-path`. On the plus side, those runners do have Xcode, so CI can compile the Liquid Glass Assets.car with actool and run notarytool with an App Store Connect API key, even without Xcode locally.
- Homebrew 7.x has dropped the quarantine flags entirely, so a personal tap of an unnotarized build gives users no `--no-quarantine` escape hatch. They need Open Anyway or a manual xattr removal. That makes Developer ID enrolment effectively a precondition for any public build.
- The minimum OS should be macOS 15, not 14. ExcludeFromSuggestions and WindowDragGesture are 15+, and on an arm64-only app the 14-only audience is tiny. Otherwise budget for #available branches.
- Swift 6 MainActor-by-default modules: closures and callbacks inferred @MainActor that get invoked off the main thread (the mpv wakeup callback, some C or NotificationCenter callbacks) trap at runtime through dynamic isolation checks. Keep everything that touches mpv in a nonisolated module and mark callbacks nonisolated/@Sendable explicitly.
- Catalog security: alongside anti-rollback, add an expiry/notAfter field to prevent freeze attacks. Re-verify the zipapp's SHA-256 at every launch, not just at download, because Application Support is user-writable.
- Signing tooling: macOS's own openssl (LibreSSL 3.3.6) can't do Ed25519. Write a small Swift/CryptoKit signer and use it for both catalog signing and manifest pinning.
- The bot-check claim may be dated. yt-dlp's README now documents a built-in `youtubepot-webpo` PO-token provider (extractor-args), so 'the PO-token plugin no longer reliably gets around it' should be re-checked before the server-side liveness design depends on it. In any case end users are on residential IPs, so client-side resolution is the main path.
- Sparkle and App Translocation: running from a DMG or quarantined Downloads location breaks in-place updates. Prompt users to move the app to /Applications, and test the first-launch update path.

## RECOMMENDATION ASSESSMENT
Overall the recommendation is sound, and nearly all of its load-bearing facts hold up. I reproduced locally the CLT-only toolchain, the flaky first `swift test` run, the resource accessor order, the ad-hoc library-validation failure, the deno signature, the zipapp contents and the GitHub Pages 304s. Every version claim checked out except MPVKit, and the Homebrew 2026-09-01 disablement is real. The architecture holds: AppKit skin windows, SwiftPM plus a Makefile, Developer ID, a Python zipapp, deno, signed static JSON and GPL-3.0-or-later. Changes I would make: (1) Treat deno as unnotarized third-party code and add a release gate that runs spctl on the embedded binary after stapling; keep deno over QuickJS by default because it is sandboxed and QuickJS has slow-version and temp-file caveats. (2) Harden the yt-dlp invocation beyond --ignore-config: YTDLP_NO_PLUGINS=1, --no-plugin-dirs, a private --cache-dir, a clean environment and no self-update. Put this in the Engine spec now. (3) Add certifi or SSL_CERT_FILE handling to the bundled-Python spike. (4) Raise the minimum to macOS 15, or wrap ExcludeFromSuggestions and WindowDragGesture in availability checks. (5) Use the GitHub macOS runners' Xcode for Assets.car and notarization rather than deferring icons until Xcode is installed locally, but pin swift-tools-version to 6.2 so CI can parse the package. (6) Replace `openssl pkeyutl -rawin` with a Swift signer, and add catalog expiry. (7) Correct the swift-bundler rationale (v2.0.7 shipped April 2025 and the project is active), though rejecting it is still reasonable. (8) Downgrade the vsync/2× window-move claim to 'measure first'. (9) Make Apple Developer Program enrolment a hard prerequisite for any non-developer distribution, since Homebrew 7 removed the quarantine bypass and Gatekeeper requires Open Anyway.
