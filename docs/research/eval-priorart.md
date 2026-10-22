# EVAL priorart: Native Swift Winamp-skin prior art (wishval/wamp, andrehickmann/macamp, ryanromanov/Bitamp, pzzzy/macwamp) plus the Webamp js reference: which pieces to reuse in sudamp

## Summary
I cloned all four Swift projects and Webamp (HEAD 7734cd3, 2026-10-19) into /tmp/sudamp-priorart, then compiled them and ran parser, sprite and zip experiments in /tmp/sudamp-priorart/experiments.

**What each project is**
- **Bitamp** (MIT, SwiftPM) is the strongest skin and engine codebase. It builds with plain `swift build` on this CLT-only Mac (21 s). Each window is drawn into a 1x canvas and scaled with nearest-neighbour at 1x, 1.5x or 2x. Missing sprites fall back one by one to an original, code-generated default skin, which it can export as a real .wsz. It has typed sprite and layout tables, docking and about 176 Swift Testing tests.
  - Gaps: no region.txt support, no streaming (AVAudioFile only) and a zip reader with no size limits.
- **andrehickmann/macamp** (MIT, SwiftPM, Swift 6 mode, zero dependencies) builds in 22.5 s and its tests compile. In about 7.8k lines it covers:
  - all four region.txt sections, shade mode, double size and docking;
  - Shoutcast/Icecast HTTP radio decoded into AVAudioEngine with an EQ, a spectrum analyser and ICY metadata;
  - a `-snapshot` render mode.
  - Weaknesses: it is 2 days old, one controller file is 1,447 lines, and it unzips skins to disk with `ditto` and no limits.
- **wishval/wamp** (MIT, 124★, the most mature project) is Xcode-only, so it cannot be built here. It draws a single 275px stacked window, has no docking or snapping, and has no tests for its skin code. It has the best text-file parsers and the only zip loader with size limits. Its sprite table has real bugs.
- **MacWamp** (pzzzy/macwamp, GPL-3.0-or-later, 1.7k lines) does not load .wsz files at all; it reads loose BMPs from its bundle and draws a checkerboard when they are missing. Its tests use XCTest, so they don't compile on CLT. Its README says the 2024 Winamp source release was used as a reference, so it should not be used.
- **Webamp** remains the canonical reference: 212 sprites can be extracted mechanically, and it has parser fixtures and snapping tests.

None of the four uses yt-dlp, mpv, YouTube, SoundCloud or Mixcloud; only macamp streams anything (HTTP radio). hfyeomans/MacAmp fails `swift build` in 2 s ("mixed language source files", from an Objective-C shim plus a bridging header).

**Recommendation:** don't fork any of them. Build a fresh SkinKit and port from:
- Bitamp: rendering, tables, docking, EQ sliders and default-skin generation;
- Webamp: the sprite table and the region and marquee logic, with its fixtures;
- wamp: the ini, viscolor and pledit parsers and its zip limit policy;
- macamp: the tolerant region.txt parser.

## Verdict
Don't fork any of these. Build sudamp's own SkinKit and AppKit shell, and port specific MIT pieces. For a terminal-driven, CLT-only workflow, Bitamp would be a better fork base than hfyeomans/MacAmp: it builds and its tests compile with SwiftPM, its rendering is the recommended design, and it has an original default skin and a .wsz writer. But its audio layer (AVAudioFile, ML chiptune, Paks, Apple Music) would all be thrown away, so take its parts rather than the repo. andrehickmann/macamp is the closest end-to-end match: HTTP stream decoded into an AVAudioEngine EQ and analyser, which is option B's output side. Use it as a reference; it is too young and monolithic to fork.

Port these, and from where:
- **(a) Sprite table:** generate a Swift table mechanically from Webamp skinSprites.ts, pinned to commit 7734cd3 (my extractor already yields all 212 rects). Use Bitamp's typed SkinElement enum and its WszSkin.source(for:) as the API shape and a cross-check. Don't copy wamp's SpriteCatalog; it has 14 wrong rects.
- **(b) Main, EQ and playlist layout:** start from Bitamp Layout.swift, which already holds draw rects. Diff it against Webamp's CSS effective boxes and the Strider spec. Fix the shade transport x positions (168 vs 169) and decide the shuffle width (46 vs 47).
- **(c) .wsz loader:** start from Bitamp ZipArchive.swift (no dependencies). Before allocating, reject any entry whose declared or compressed size is over 32 MB; cap the total at 96 MB (wamp's policy) and the number of entries. Whitelist the sheet, .txt and .cur names, let the last duplicate win, and decode with ImageIO. Bitamp's RLEBitmap decoder isn't needed on macOS 27.
- **(d) region.txt:** port Webamp's regionParser semantics with its 7 fixtures and snapshot. macamp's parseRegions is the most tolerant Swift starting point: it handles commas-only and multi-line lists. Keep Webamp's partial-polygon behaviour. Write our own non-anti-aliased rasteriser into the 1x canvas alpha; none of the projects has one.
- **(e) Font and marquee:** port Webamp FONT_LOOKUP (including <>{}) and the marqueeUtils stepOffset/loopText functions with their tests: 5 px every 220 ms, 31 characters, the '  ***  ' separator, 1 s resume after a drag. wamp's TextSpriteRenderer is a usable verbatim port once the <>{} mappings are added. Take Bitamp's Marquee message/flash overlay. Add a system-font fallback for CJK and emoji ourselves.
- **(f) viscolor and pledit parsers:** port wamp's IniParser, ViscolorsParser and PlaylistStyleParser with Webamp's VISCOLOR and PLEDIT fixtures. Strip text after a second '=' (Webamp behaviour). Take the eqmain graph-colour sampler from Bitamp or wamp.
- **(g) Docking and snapping:** port Bitamp Docking.swift and WindowGroup with its tests. Change the snap distance to Webamp's 15 and add test cases from Webamp's snapUtils.test.ts.
- **(h) EQ slider sprites:** port Bitamp's VerticalSliderGeometry and drawSlider with their tests. Use 51 px of thumb travel to match Webamp pixel-for-pixel in golden tests.
- **(i) Default skin:** port Bitamp's DefaultSkin, SkinTheme, Canvas, PixelFont and WszWriter. Write a new 'sudamp Dark' theme with no Bitamp branding, export it as a .wsz at build time, and use it as the per-sheet fallback. AndAmp Dark (CC BY 4.0, credit Mattix) is an optional bundled alternative.
- **Also worth taking:** Bitamp's SkinnedView 1.5x edge handling, the bundle.sh/notarize.sh flow (codesign, notarytool, plutil, all without Xcode), and the test.sh `-plugin-path` workaround. Optionally, macamp's IcyDemuxer for Icecast titles.

Licence obligations, assuming sudamp is GPL-3.0-or-later:
- All four MIT sources are compatible. Keep each copyright line and the MIT permission text in the headers of ported files, and in a THIRD_PARTY_NOTICES file in the repo and inside the .app.
- The four notices: Webamp (© 2015 Jordan Eldredge); wamp (© 2026 Valerii Bakalenko), plus Webamp's notice for its Webamp-derived files; Bitamp (© 2026 Ryan Romanosky and Bitamp contributors); macamp (© 2026 André Hickmann Kuschnereit).
- Add Webamp's notice to any table derived from its sprite names.
- MacWamp's GPL code would be licence-compatible, but don't use it: by its own README it was researched against the WCL-licensed Winamp source.
- Never copy wamp's or hfyeomans/MacAmp's bundled skins (base-2.91 is Nullsoft artwork), or Bitamp's CoreML models (Basic Pitch is Apache-2.0 and irrelevant to sudamp).

## Reusable
- Webamp packages/webamp/js/skinSprites.ts @7734cd3: canonical sprite table and FONT_LOOKUP. MIT © 2015 Jordan Eldredge. Generate Swift from it with /tmp/sudamp-priorart/experiments/extract_sprites.py (212 sprites).
- Webamp js/regionParser.ts with regionParser.test.js, __snapshots__/regionParser.test.js.snap and __tests__/fixtures/region*.txt (7 files): region semantics and test data. MIT.
- Webamp js/utils.ts parseIni/parseViscolors and utils.test.ts, plus fixtures VISCOLOR.TXT, CENTRA_VISCOLOR.TXT, viscolor_*.txt and PLEDIT*.TXT. MIT.
- Webamp js/snapUtils.ts (183 lines) and snapUtils.test.ts (477 lines); resizeUtils.ts and its test (25x29 playlist resize steps). MIT.
- Webamp marqueeUtils/Marquee.tsx (stepOffset, loopText, 220 ms stepping, drag behaviour) and components/EqualizerWindow/Band.tsx (spriteNumber, spriteOffsets); components/Skin.tsx FALLBACKS (balance→volume, EQ maximise). MIT.
- Bitamp Sources/BitampKit/Skin/ZipArchive.swift (94 lines, Compression-based ZIP reader; must add size limits). MIT © 2026 Ryan Romanosky and Bitamp contributors.
- Bitamp Skin/Skin.swift (SkinElement enum), Skin/WszSkin.swift (sheet loading, per-sprite fallback, nums_ex handling, viscolor parser, EQ graph colours), Skin/Layout.swift (main/EQ/playlist/shade draw-rect tables). MIT.
- Bitamp Skin/DefaultSkin.swift, SkinTheme.swift, Canvas.swift, PixelFont.swift (original 4x5 font) and WszWriter.swift: code-generated original skin exported to .wsz. MIT.
- Bitamp UI/SkinnedView.swift (1x canvas drawn with nearest-neighbour at 1, 1.5 or 2x, shadow invalidation), UI/Docking.swift (snapping and docking WindowGroup), UI/Marquee.swift (overlay/flash), UI/EqualizerView.swift VerticalSliderGeometry, Skin/GenArt.swift (gen.bmp letters). MIT.
- Bitamp scripts/bundle.sh, notarize.sh and test.sh (SwiftPM .app bundle, Developer ID notarization and the TestingMacros -plugin-path workaround on CLT). MIT.
- Bitamp Tests/BitampTests/BitampTests.swift: Swift Testing cases for sprite bounds, layout, docking, marquee, export round-trip, EQ slider. MIT. Adapt as needed.
- wamp Wamp/Skinning/IniParser.swift, ViscolorsParser.swift (CRLF-safe; the Webamp regex), PlaylistStyleParser.swift, EqGraphColorsParser.swift, and the extractZip limit policy in SkinParserUtils.swift (32 MB per entry, 96 MB total, streamed). MIT © 2026 Valerii Bakalenko. Its TextSpriteRenderer is derived from Webamp, so keep both notices.
- macamp Sources/MacAmpCore/Skin.swift parseRegions (tolerant multi-section region parser) and parseGenFont; MacAmpCore/IcyDemuxer.swift (ICY metadata, tested); MacAmp/StreamDecoder.swift (HTTP → AudioFileStream → AVAudioConverter, reference for an AVAudioEngine output path); the AppController `-snapshot` mode as a golden-test pattern. MIT © 2026 André Hickmann Kuschnereit.
- macamp Resources/Skins/AndAmp {Dark,Light,Spot}.wsz: CC BY 4.0 by Mattix (mattijsf/andamp). Can be bundled with attribution.
- Experiment scripts I wrote (not third-party code), in /tmp/sudamp-priorart/experiments: extract_sprites.py, compare_sprites.py, webamp_ref.py, parsers/harness.swift, pledit/pledit.swift, zipbomb/bitamp_zip.swift.

## Experiments
- Does each project build with plain `swift build` on this CLT-only machine?
  METHOD: `swift build` from clean in each clone (andrehickmann_macamp, ryanromanov_Bitamp, pzzzy_macwamp), plus a copy of hfyeomans/MacAmp at /tmp/sudamp-priorart/hfyeomans_MacAmp/copy. Only compiled; no product or test binary was run.
  RESULT: - macamp: OK in 22.5 s, 0 warnings.
- Bitamp: OK in 21.4 s, 0 warnings.
- MacWamp: OK in 18 s.
- wamp: no Package.swift; it needs xcodebuild, which is not installed.
- hfyeomans/MacAmp: fails in 2 s ('contains mixed language source files').
- Do the test targets compile without Xcode?
  METHOD: `swift build --build-tests` (compile only)
  RESULT: - macamp: OK.
- Bitamp: fails on an incremental build with 'plugin for module TestingMacros not found'; OK when `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` is added.
- MacWamp: fails (no XCTest on CLT).
- How accurate are the Swift sprite tables compared with Webamp?
  METHOD: extract_sprites.py regex-parses skinSprites.ts into JSON (212 active sprites; GENEX is commented out). compare_sprites.py diffs the rects I hand-expanded from wamp's SpriteCatalog and Bitamp's WszSkin.source(for:).
  RESULT: - Bitamp: 118/124 identical; the 6 differences are minor or intentional.
- wamp: 83/97 identical; 14 differ, including wrong pledit SELECT_ALL and MISC_OPTIONS sprites, a wrong pressed shade button, and 22 px transport buttons.
- How well do the region.txt and viscolor.txt parsers handle Webamp's fixtures?
  METHOD: parsers/harness.swift contains verbatim copies of wamp's IniParser and RegionParser, macamp's parseRegions and parseVisColors, and Bitamp's parseVisColors. Its output is compared with webamp_ref.py, a Python port of Webamp's regionParser, parseIni and parseViscolors. Inputs: 7 Webamp region fixtures, 2 synthetic ones (commas-only PointList; PointList continued over CRLF lines) and 4 viscolor fixtures.
  RESULT: **region.txt [Normal] vs Webamp:**
- wamp matches 8 of 11. It returns nothing for the commas-only PointList, the form the fixture's own comment says is the only one Winamp accepts. It also returns nothing for NumPoints larger than the number of points, and for continuation lines.
- macamp matches 10 of 11 and parses all four sections. It drops partial polygons that Webamp keeps, and joins continuation lines, which Webamp does not.

**viscolor:**
- wamp and Bitamp match on all 4 fixtures (Bitamp only when there are at least 24 lines).
- macamp fails viscolor_valgaav (space-separated values) and falls back to all defaults.
- How well do the pledit.txt parsers handle Webamp's fixtures?
  METHOD: pledit/pledit.swift with verbatim parser logic, run on PLEDIT, PLEDIT_TOPAZ, PLEDIT_WITH_EQUALS and PLEDIT_WITH_QUOTES
  RESULT: - wamp gets all colours right in all 4. It keeps a trailing '= comment' in Font, which Webamp strips.
- Bitamp and macamp fail the quoted file (all four colours fall back to defaults).
- Bitamp ignores Font; it uses its own playlist pixel font.
- How do the loaders cope with a zip bomb?
  METHOD: bomb.wsz is 1,043,870 bytes and contains Skin/MAIN.BMP (1 GiB of zeros, deflate) plus viscolor.txt.
- Bitamp: its ZipArchive struct copied verbatim into zipbomb/bitamp_zip.swift, run with the same entry loop as WszSkin.init, under /usr/bin/time -l.
- macamp: the same file extracted with /usr/bin/ditto -x -k, macamp's own method.
  RESULT: - Bitamp reader: inflated all 1,073,741,824 bytes; peak RSS 2,156,036,096 bytes (about 2,000x the file size).
- ditto: wrote 1.0 GiB to disk, and macamp then reads the file into memory.
- wamp's limits were reviewed in the code, not run (running it needs ZIPFoundation): at most about 32 MB per entry and 96 MB in total.
- How does each project draw and lay out windows?
  METHOD: Read SkinnedView/Canvas (Bitamp), SkinView (macamp), MainWindow/MainPlayerView (wamp) and WinampSkin (MacWamp); viewed docs/images/bitamp.png and macamp docs/screenshot.png
  RESULT: - Bitamp: a 1x RGBA Canvas with no anti-aliasing per window, drawn scaled with interpolation .none at 30 fps. This is the architecture the research recommends.
- macamp: view bounds scaling with interpolationQuality .none.
- wamp: AppKit subviews in one stacked window.
- MacWamp: NSImage blits from bundled BMPs.
- Bitamp's default skin is dark and polished but carries the BITAMP brand.

## Risks
- All of this prior art is under 7 months old with one maintainer each, and much of it looks AI-assisted (wamp ships CLAUDE.md and .claude/; macamp's 15 commits span 2 days; macamp and Bitamp have near-identical snapping code). Treat ported code as unreviewed and check it against Webamp and golden-image tests.
- Ported tables carry bugs:
- wamp: wrong pledit button sprites, pressed shade glyph, 22 px transport buttons.
- macamp: shade seek thumb x+3.
- Bitamp: EQ close pressed sprite (0,116) vs Webamp (0,125); unverified which one Winamp uses.
Generate tables from Webamp mechanically rather than hand-copying.
- Zip-bomb exposure if Bitamp's reader or macamp's ditto path is copied unchanged: a 1 MB .wsz reached 2.16 GB RSS, or wrote 1 GiB to disk. Limits must be enforced before allocating.
- No prior art rasterises region.txt GDI-style (fill rule, right/bottom-exclusive edges); Winamp's exact fill rule is unverified. Whether clicks pass through transparent pixels is also unverified (macamp relies on WindowServer behaviour without a hitTest override).
- The Swift Testing 'TestingMacros plugin not found' bug reproduces on this CLT install with incremental test builds. Use the -plugin-path flag in the Makefile, or clean and retry.
- Bitamp targets macOS 13 with swift-tools 5.9 (Swift 5 language mode). Porting into Swift 6 / ApproachableConcurrency targets will need Sendable and MainActor fixes; Canvas and the skin classes are non-Sendable reference types.
- Bitamp shows '?' and Webamp, wamp and macamp show blanks for characters missing from the skin font. YouTube, SoundCloud and Mixcloud titles are often CJK or contain emoji, so sudamp must add its own system-font fallback (no prior art exists).
- The snap distance differs: Bitamp and macamp use 10, Webamp uses 15. Pick one deliberately; Webamp's 15 is the documented reference.
- Provenance: MacWamp says it used the WCL-licensed 2024 Winamp source as a reference, so don't read it for implementation or derive from it. wamp's and hfyeomans/MacAmp's repos contain Nullsoft and third-party skins that must not be copied.
- Not verified: FSF's listing of CC BY 4.0 as GPLv3-compatible (from memory) for bundling AndAmp skins. Also not verified: whether 1.5x window scale looks clean on non-Retina displays (Bitamp works around half-point edges, but 1.5 device pixels per skin pixel blurs or duplicates rows).

## Facts
- Licences: wamp is MIT © 2026 Valerii Bakalenko; andrehickmann/macamp is MIT © 2026 André Hickmann Kuschnereit; Bitamp is MIT © 2026 Ryan Romanosky and Bitamp contributors; MacWamp (pzzzy/macwamp) is GPL-3.0-or-later; Webamp is MIT © 2015 Jordan Eldredge (packages/webamp 2.3.1). (head of LICENSE in each /tmp/sudamp-priorart/*/repo; MacWamp README 'licensed under GPL-3.0-or-later'; webamp/repo/LICENSE.txt and packages/webamp/pac)
- MacWamp's URL is https://github.com/pzzzy/macwamp. Its README says the original Winamp source release and Linamp 'were used as local references for behavior, architecture, and coordinate research'. Its scripts/setup-assets.sh clones https://github.com/alexfreud/winamp.git to import Winamp bitmaps. (/tmp/sudamp-priorart/pzzzy_macwamp/repo/README.md 'Legal / asset notice'; scripts/setup-assets.sh REPO_URL)
- Lines of Swift: wamp 11,174 (tests 2,327; Skinning/ 1,030); macamp 7,809 (tests 365); Bitamp 20,949 (tests 3,836); MacWamp 1,687 (tests 13); hfyeomans/MacAmp 25,103 (tests 3,185). (find … -name '*.swift' | xargs wc -l on each clone)
- Activity: every project has a single maintainer and is from 2026.
- wamp: 287 commits, 2026-04-04 to 2026-10-09; 124★, 9 forks; tags v1.1.0–v1.2.0.
- macamp: 15 commits, 2026-10-12 to 2026-10-13; 0★; tags v0.1.0–v0.3.0.
- Bitamp: 75 commits, 2026-10-03 to 2026-10-16; 1★; 10 tags up to v0.7.1.
- MacWamp: 10 commits, 2026-06-01 to 2026-09-27; 0★; no tags. (git clone --bare --filter=tree:0 histories (rev-list --count, log dates); git ls-remote --tags; GitHub repo pages via WebFetch (REST API was rate-limi)
- Build results with plain SwiftPM on this machine (CLT only, Swift 6.4):
- macamp: `swift build` OK in 22.5 s from clean, 0 warnings; `--build-tests` OK.
- Bitamp: `swift build` OK in 21.4 s, 0 warnings; `--build-tests` failed with "plugin for module 'TestingMacros' not found" and succeeded once `-Xswiftc -plugin-path -Xswiftc <CLT>/usr/lib/swift/host/plugins/testing` was added (the workaround in its scripts/test.sh).
- MacWamp: `swift build` OK in 18 s; tests fail ('unable to resolve module dependency: XCTest').
- wamp: no Package.swift, Xcode project only; xcodebuild needs Xcode.
- hfyeomans/MacAmp: `swift build` fails in 2 s ('target … contains mixed language source files'; it contains AUAudioUnitWorkgroupShim.m plus a bridging header). (swift build logs in this session; /tmp/sudamp-priorart/ryanromanov_Bitamp/repo/scripts/test.sh; /tmp/sudamp-priorart/hfyeomans_MacAmp/copy)
- None of the four Swift projects uses yt-dlp, mpv, YouTube, SoundCloud or Mixcloud (grep finds nothing).
- macamp plays Shoutcast/Icecast over HTTP: URLSession.bytes, then AudioFileStream and AVAudioConverter, then AVAudioPlayerNode, AVAudioUnitEQ and the mixer. A tested IcyDemuxer reads stream titles. It also has Spotify (Web Playback SDK in a WKWebView) and a Core Audio process tap for the visualiser.
- Bitamp plays local files through AVAudioFile. Its Expansion Paks are external programs talking JSON lines; a Pak returns a file or a URL that Bitamp downloads in full before playing ('not for endless radio streams').
- wamp is local-only by declared non-goal. (grep -rli 'yt-dlp|mpv|youtube|soundcloud|mixcloud' (no hits); macamp Sources/MacAmp/StreamDecoder.swift, MacAmpCore/IcyDemuxer.swift; Bitamp docs/PAK-)
- Sprite table accuracy against Webamp's skinSprites.ts (212 active sprites extracted mechanically):
- Bitamp: 118 of 124 mapped rects identical. The differences are next button 22 vs 23 wide, shuffle 46 vs 47 wide (both equal Webamp's effective CSS draw widths), and pressed EQ close at (0,116) vs (0,125).
- wamp: 83 of 97 identical. Real bugs: PLAYLIST_SELECT_ALL uses (0,111), which is ADD_URL; MISC_OPTIONS uses (0,130), which is ADD_DIR; the pressed shade button uses (0,27), the unshade glyph, instead of (9,18); all transport buttons are 22 wide instead of 23. (/tmp/sudamp-priorart/experiments/extract_sprites.py, compare_sprites.py, webamp_sprites.json; wamp Wamp/Skinning/SpriteCatalog.swift; Bitamp Sources/B)
- Layout tables:
- Bitamp's Layout.swift holds draw rects that match Webamp's effective CSS boxes: marquee 111,27,154x6 (the padding is already applied); time digits at 48/60/78/90,26; minus drawn at 38,32; stereo at 239,41; plus EQ, playlist and shade layouts, with tests (controlsFitTheWindow, controlsDoNotOverlap, hitTesting).
- macamp hard-codes coordinates inside its drawing code. Its shade-mode seek thumb uses x=20/23/26 instead of Webamp's 17/20/23.
- wamp, when skinned, hides the kbps, kHz and mono/stereo fields (frame = .zero) and stacks main, EQ and playlist in one window. (Bitamp Sources/BitampKit/Skin/Layout.swift; Webamp css/main-window.css (extracted); macamp Sources/MacAmp/MainWindowView.swift line 111; wamp Wamp/UI/)
- ZIP loaders:
- wamp is the only one with limits: ZIPFoundation in memory, 32 MB per entry enforced inside the streaming closure, 96 MB total, a map of lower-cased basenames, last duplicate wins. It has no filename whitelist.
- Bitamp's ZipArchive (94 lines, no dependencies, Compression COMPRESSION_ZLIB) pre-allocates `[UInt8](repeating: 0, count: entry.uncompressedSize)` and inflates every entry, including ones that aren't skin files. The first duplicate wins.
- macamp extracts to a temp folder with /usr/bin/ditto and no limits. (wamp Wamp/Skinning/SkinParserUtils.swift; Bitamp Sources/BitampKit/Skin/ZipArchive.swift and WszSkin.swift init(url:); macamp Sources/MacAmpCore/Skin.)
- region.txt support:
- wamp: [Normal] section only, applied as a CAShapeLayer mask on the main view.
- macamp: all four sections, used as a CGContext clip; no hitTest override.
- Bitamp: none (it only shapes its own Orb skin).
- None rasterises the polygons GDI-style without anti-aliasing. (wamp UI/MainWindow.swift:179-188; macamp SkinView.swift draw() and the regionName overrides in MainWindowView/EqualizerView; grep 'region' in Bitamp S)
- Text and marquee:
- Webamp FONT_LOOKUP maps < > { } to the [ ] glyphs. Its marquee holds 31 characters, uses the separator '  ***  ', steps 5 px every 220 ms, resumes 1 s after a drag, and its pure functions stepOffset and loopText have tests.
- wamp TextSpriteRenderer is a verbatim FONT_LOOKUP port plus diacritic folding, but it lacks the <>{} mappings.
- macamp maps <>{} to [] and draws unknown characters blank; its marquee steps one glyph every 6 ticks.
- Bitamp upper-cases text and turns unknown characters into '?'. Its marquee scrolls 1 px per 30 fps tick and has a message/flash overlay.
- None falls back to a system font in the marquee for CJK or emoji. Only Bitamp's playlist ListFont falls back (to Arial, then Hiragino). (webamp js/skinSprites.ts:14-85, components/MainWindow/Marquee.tsx; wamp Skinning/TextSpriteRenderer.swift; macamp MacAmpCore/Skin.swift SkinText, Skin)
- EQ slider sprite logic:
- Webamp Band.tsx: frame = round(v/100*27); x offset (n%14)*15 and y offset (n/14)*65 from (13,164); the background is 14x63; the thumb is 11x11 and travels 51 px (62-11).
- wamp and Bitamp select the same frames but use 52 px of travel (63-11).
- Bitamp adds a 0 dB snap (±0.6 dB) and tests (sliderEnds, middleSnapsToFlat, verticalSliderRunsBottomToTop). (webamp js/components/EqualizerWindow/Band.tsx; Bitamp UI/EqualizerView.swift VerticalSliderGeometry; wamp UI/Components/WinampSlider.swift:108-117)
- Docking and snapping:
- Webamp snapUtils.ts (183 lines plus a 477-line test file) uses SNAP_DISTANCE 15 with traceConnection.
- Bitamp Docking.swift (423 lines): a pure snap/touching/docked geometry layer plus a @MainActor WindowGroup. It handles group drag from the main window, other windows moving alone, snapping to screen edges, hiding the main window, regroup, per-window shade, uniform scale, saved layout and keep-on-screen. It has 5 geometry tests and a mainWindowCanHide test. Snap distance is 10.
- macamp WindowSnapping.swift (53 lines) uses an almost identical algorithm, also with a 10 px distance. (webamp js/snapUtils.ts; Bitamp Sources/BitampKit/UI/Docking.swift; macamp Sources/MacAmpCore/WindowSnapping.swift and AppController.beginWindowDrag/up)
- Default skin: only Bitamp generates an original skin in code. It is made of DefaultSkin.swift (764 lines), SkinTheme (139), Canvas (165), PixelFont (an original 4x5 font, 111) and WszWriter (278), which writes any skin out as a classic .wsz with standard sheet sizes. It has three themes and the test exportedSkinLoadsBackIdentically, and offers window scales of 1x, 1.5x and 2x (default 2x), with handling for half-point edges.
- macamp bundles AndAmp Dark/Light/Spot skins (CC BY 4.0, by Mattix).
- wamp bundles Nullsoft's base-2.91.wsz and other third-party skins; its built-in look is plain AppKit drawing, not a .wsz. (Bitamp Sources/BitampKit/Skin/*.swift, UI/SkinnedView.swift (scales [1,1.5,2]), docs/images/bitamp.png; macamp Resources/Skins/CREDITS.md; wamp skins/)
- Other loader semantics:
- nums_ex vs numbers: Bitamp and wamp prefer nums_ex, like Winamp; macamp prefers numbers.bmp.
- None of the three implements Webamp's balance→volume fallback.
- Bitamp falls back per sprite to its DefaultSkin, and a sprite that runs past the edge of its sheet is drawn fully transparent.
- wamp treats a partial sprite as missing and uses its programmatic drawing instead. (Bitamp WszSkin.sprite(for:); macamp Skin.swift `sheets["numbers"] ?? sheets["nums_ex"]`; wamp SkinParserUtils.loadAllSheets, WinampClassicSkin.sprite;)