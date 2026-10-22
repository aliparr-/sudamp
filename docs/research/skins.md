# Winamp classic skins and skinned UI rendering

## SUMMARY
A .wsz file is a plain ZIP of fixed-layout BMP sprite sheets plus three small text files. Every file is optional; when one is missing, Winamp falls back to its built-in look. The layout is fully documented. Webamp's MIT-licensed `skinSprites.ts` gives exact coordinates for every sprite, and its CSS files give where each element sits in the window. Both 1998-era community specs confirm the same coordinates, and a 2026 MIT Swift project (wishval/wamp) has already ported the sprite table to Swift. I tested this on the dev machine: ImageIO on macOS 27 decoded all 1,199 BMPs from 75 real museum skins, including 4/8/16/24/32-bit and RLE8 files. Real skins are messy. Across 600 museum skins, 18.8% keep their files in nested folders, filename case is mixed, and sheet sizes are often non-standard. Coverage is very uneven: gen.bmp is in only 7.3% of skins, pledit.bmp in 93.8%, and region.txt in 28.8%. These numbers drive the design decisions.

Webamp itself (MIT, v2.3.1, June 2026, still active) is excellent reference code but a poor shell for the product. All its windows live inside one DOM page. Swapping in our own audio engine goes through `__customMediaClass`, which its own docs call "a bit of a hack… not considered stable". The visualiser and Milkdrop need a Web Audio AnalyserNode, so mpv's audio would have to be piped into JavaScript. An existing 2026 WKWebView wrapper of Webamp needed a full-screen transparent window, a private `drawsBackground` setting, a 60 Hz timer toggling click-through, and it recreates the web view on every skin switch because switching in place crashes it. A native AppKit renderer is a few thousand lines and gives real per-window macOS behaviour. The approach: draw each Winamp window into a 1x software bitmap and display it in a CALayer with nearest-neighbour scaling. This matches how Winamp drew, is pixel-perfect at 1x/2x/3x, and can be checked automatically against the Skin Museum's 275x348 Webamp-rendered screenshots.

For the default skin, ship a real original .wsz ("sudamp Dark"), generated from code (a Swift/CoreGraphics script), so it goes through the same pipeline as third-party skins. It must contain no Nullsoft pixels. The same skin also serves as the fallback for sheets a third-party skin lacks, and on Retina it should open at 2x window scale. For the genre picker, use a native macOS menu opened from the song-title area, plus the eject button, title-bar menu, right-click menu and the menu bar. These all work with any skin. In a second step, the playlist window can list the current genre's streams, since nearly every skin draws it. A gen.bmp "Stations" window would fall back to our own skin's look in about 93% of skins, so defer it.

## RECOMMENDATION
Build a native AppKit skin engine and stay compatible with the classic .wsz format. Use Webamp only as reference code.

1. **SkinKit module (Swift 6).**
   - Load the .wsz into memory with ZIPFoundation 0.9.20 (or about 150 lines of our own central-directory reader plus Compression's COMPRESSION_ZLIB).
   - Build a dictionary of lower-cased basename → Data. The last duplicate wins, directories are ignored, and only whitelisted names are kept: the sheet names (.bmp/.png), the three .txt files and the cursor names. Cap entries at 32 MB each and 96 MB total.
   - Decode with CGImageSourceCreateWithData, then normalise each sheet by drawing it into an sRGB RGBA8 context with alpha ignored.
   - Fallbacks: per sheet to our own skin; nums_ex over numbers; balance→volume; EQ maximise-button fallback as in Webamp.
   - Port Webamp's skinSprites.ts to a Swift enum plus rectangle table, and the CSS positions to a layout table, with the MIT notice for Jordan Eldredge. Crop sprites clipped to each sheet's real bounds.
   - Parsers: port Webamp's regionParser and parseIni/parseViscolors together with their test fixtures; normalise pledit.txt colours to #RRGGBB; scan gen.bmp letter widths.

2. **Renderer.**
   - One borderless NSWindow per Winamp window (main, playlist, optional EQ): isOpaque=false, backgroundColor=.clear, hasShadow=true.
   - Each window composes into a 1x CGContext (275x116, playlist at 275+25n by 116+29m, shade height 14). Set the result as layer.contents with magnificationFilter=.nearest.
   - Window scale ∈ {1, 1.5, 2, 3} such that scale × backingScaleFactor is a whole number. Default to 2x on Retina; double-size via ⌘D.
   - The visualiser redraws only its 76x16 rectangle at about 30 fps, using viscolor indices.
   - The marquee uses text.bmp: 5x6 glyphs, 220ms/5px stepping, separator '  ***  ', diacritics stripped. If a title has characters outside FONT_LOOKUP (CJK, emoji), switch automatically to a small system-font renderer in the skin's text colours.
   - Playlist rows use Core Text at backing resolution with pledit.txt colours.
   - region.txt: clear alpha outside the polygons, override hitTest, call invalidateShadow(). Docking uses 15px snapping and child windows.
   - Add NSAccessibility elements for every hotspot.

3. **Testing.** Golden-image tests against museum screenshots (275x348 PNGs) for about 100 skins: compare the main and EQ regions in Webamp's fixed state.

4. **Default skin.** An original 'sudamp Dark' .wsz produced by a Swift/CoreGraphics generator script in the repo: palette, 1px bevels, hand-made 5x6 font, nums_ex digits, flat transport icons, pledit/gen sheets. No Nullsoft pixels and no tracing of base-2.91. It also serves as the fallback base. Consider @2x sheets later.

5. **Genre picker.**
   - Primary: a native NSMenu dropdown anchored under the marquee. It opens on a click without drag on the marquee, and is also reachable from eject, the title-bar options button, the right-click 'Genre ▸' submenu, and a menu-bar Genre menu with ⌘1…⌘9 and 'Surprise me' (random genre).
   - The marquee shows 'GENRE ▸ title' and on first run reads 'CLICK HERE TO PICK A GENRE'. The kbps/kHz fields show the stream's real bitrate and sample rate from mpv.
   - Secondary: the playlist window lists the current genre's streams; double-click plays one.
   - Defer a gen.bmp Stations window.

6. **Skins distribution.** Bundle only our own skins, and optionally the CC BY 4.0 AndAmp skins with credits. Support drag-and-drop .wsz and ~/Library/Application Support/sudamp/Skins. Add a 'Get more skins…' entry that opens skins.webamp.org; an in-app browser via api.webamp.org GraphQL (nsfw:false, screenshot previews, r2 download URLs) should come only after contacting the maintainer.

7. **Webamp-in-WKWebView.** If wanted, do a one-day UX spike only; do not ship it.

## RISKS
- [high] Stream titles with CJK, Cyrillic, emoji or other non-Latin characters cannot be drawn with text.bmp, which only has A-Z, 0-9, some punctuation and ÅÖÄ. -> Strip diacritics first (as Webamp does). If anything is still unmappable, fall back automatically to a system-font marquee in the skin's text colours. Add a setting 'Always use skin font'. Playlist rows already use system fonts.
- [high] Copyright: bundling third-party museum skins, or reusing Nullsoft base-skin pixels (which Webamp bundles), without permission. -> Ship only our original generated skin, plus explicitly licensed ones (CC BY 4.0 AndAmp skins) with a CREDITS file. Third-party skins come only through user action (drop, folder, user-initiated museum download). Record provenance: the generator uses only coordinate tables.
- [medium] There is no PCM path from mpv for the spectrum and oscilloscope, which affects both UI options. -> Settle this in the audio-engine research. Candidates: a Core Audio process tap on our own process (macOS 14.2+, may trigger a permission prompt), or mpv outputting PCM into an AVAudioEngine we own with an installTap. v1 can ship with the visualiser off or simulated.
- [medium] Scope creep: EQ window (needs mpv af equalizer mapping), Milkdrop (projectM is LGPL-2.1), cursors (.ani), shade modes for every window, docking. -> v1 = main window plus playlist, shade mode, double size, region.txt. EQ, cursors and Milkdrop come in v1.x. The layout and sprite tables already include them, so adding them later is cheap.
- [medium] Real-world skin quirks: nested folders, mixed case, undersized sheets, malformed region.txt or pledit.txt, odd BMPs, and hostile archives (zip bombs, .exe inside). -> In-memory basename map with size caps; whitelist names; clip sprites to sheet bounds; per-sheet fallback; port Webamp's parser fixtures. Fuzz with the 600-skin sample and keep golden tests against museum screenshots.
- [low] Shaped transparent windows: whether clicks on fully transparent pixels pass through is OS behaviour I have not verified, and the shadow can mismatch the shape. -> Override hitTest using the region polygons. Call invalidateShadow() after skin or shade changes. Only 28.8% of skins use region.txt, so it can be disabled if it causes trouble.
- [low] Non-integer effective scaling (macOS 'scaled' display modes, odd window scales) blurs nearest-neighbour art. -> Allow only window scales where scale × backingScaleFactor is a whole number. Accept the WindowServer's downsampling in scaled modes; it affects every app.
- [low] Dependence on the undocumented api.webamp.org GraphQL API and r2 hosting for an in-app skin browser. -> Make it optional, cache responses, rate-limit, attribute the museum, and contact the maintainer. Fall back to opening skins.webamp.org in the browser.
- [high] If the Webamp route were chosen: the unstable __customMediaClass API, the private drawsBackground key, crashes on skin switching, and polling for click-through. -> Don't ship it. Limit it to a prototype spike.

## OPEN QUESTIONS
- What licence is sudamp under (MIT/Apache vs GPL)? This decides whether Audacious/qmmp skin code (GPL) or IINA (GPLv3) can be reused, and how MIT notices from Webamp, wamp and MacAmp are handled.
- v1 window set: main only, main plus playlist, or also EQ (which needs an mpv equaliser mapping) and Milkdrop (projectM LGPL vs none)?
- Visualiser data source from mpv (process tap vs PCM pipe into AVAudioEngine)? Needs a decision from the audio-engine research.
- Should the default window scale be 2x (double-size) on Retina, with 1x optional? Should 1.5x be offered?
- Is an in-app Skin Museum browser in scope for v1, and will the Webamp maintainer endorse use of api.webamp.org?
- Do we want an @2x PNG extension for our own skin later, or is chunky 1x pixel art the intended aesthetic?
- Do we commission a pixel artist for 'sudamp Dark', or is the code-generated flat look acceptable for v1?
- Should the eject button be repurposed as 'Pick genre', or kept for 'open URL/file' with the genre menu only on the marquee?

## OPTIONS
- UI engine A: native AppKit renderer (1x software bitmap per window → CALayer with nearest-neighbour scaling): Recommended. This is the product path.
- UI engine B: Webamp in a transparent WKWebView, mpv as audio via __customMediaClass: Rejected for the product; acceptable only as a throwaway prototype.
- UI engine C: SwiftUI views with .interpolation(.none) (MacAmp-style): Viable fallback. Use SwiftUI for preferences and non-skinned windows only.
- Default skin 1: original 'sudamp Dark' as a real .wsz, generated by a Swift/CoreGraphics script: Recommended. Default to 2x window scale on Retina.
- Default skin 2: separate resolution-independent native/vector skin with Winamp layout: Rejected for v1.
- Default skin 3: hybrid, adding @2x PNG sheets to our .wsz: Optional v1.x improvement after option 1 ships.
- Genre picker A: native NSMenu 'genre dropdown' opened from skin-agnostic hotspots: Recommended as the primary picker.
- Genre picker B: playlist window as station browser: Recommended as the secondary view (v1 or v1.1), together with A.
- Genre picker C: dedicated 'Stations' window drawn with gen.bmp/genex.bmp (Media Library style): Defer until the catalogue grows (server-side); when it is built, theme it from pledit.bmp/pledit.txt rather than gen.bmp.

## VERIFICATION CHECKS (non-confirmed)
- [partially-true] File coverage across museum skins: gen.bmp 7.3%, pledit.bmp 93.8%, region.txt 28.8%, nums_ex 19.8%, pledit.txt 92.2%, nested folders 18.8%.
    CORRECTION: An independent random sample of 400 skins (8 offsets × 50) gave gen.bmp 11.8%, genex 11.5%, pledit.bmp 97.8%, pledit.txt 97.0%, region.txt 31.0%, nums_ex 23.2%, numbers 79.2%, eqmain 98.0%, nested 18.8%. The exact numbers depend on the sample, but the conclusions hold: gen.bmp is rare (about 8–12%) and pledit is almost always present.
    SRC: Live query against https://api.webamp.org/graphql: skins(first:50, offset:N){ nodes { archive_files { filename } } }
- [partially-true] Webamp matches files with ^(.*[/\\])?NAME\.(png|bmp)$ (case-insensitive), takes the LAST match, accepts .png, prefers nums_ex when DIGIT_0_EX exists, and falls back from balance to volume.
    CORRECTION: The real regex is `^(.*[/\\])?${base}.(${ext})$`, and the '.' is NOT escaped, so it matches any character. Last-match-wins applies only through getFileFromZip (images and viscolor). getPlaylistStyle reads PLEDIT.txt with files[0], the FIRST match. The FALLBACKS, numExIsUsed and EQ_MAXIMIZE_BUTTON_ACTIVE_FALLBACK parts are correct.
    SRC: packages/webamp/js/skinParserUtils.ts lines 13-49 and 154-186; components/Skin.tsx lines 36-42
- [partially-true] Main-window layout from Webamp CSS (e.g. marquee 111,24 154x6; play state 26,28 9x9) matches the 1998 specs ('Both 1998-era community specs confirm the same coordinates').
    CORRECTION: The Webamp CSS numbers are copied correctly, but some of them are hit boxes, not draw rects. #marquee has padding: 3px 0, so the text is drawn at y=27 (Strider: song title 112,27 152x6). The play state also has a 3x9 #work-indicator at 24,28 (Strider: 24,28 11x9). The minus sign is 38,32 in Webamp but 40,32 in Strider. The specs and Webamp differ by 1–3 px in places, so the Swift layout table must hold draw rects, not CSS boxes.
    SRC: https://raw.githubusercontent.com/captbaritone/webamp/master/packages/webamp/css/main-window.css (lines 82-98, 169-177); Strider spec pages 7-8
- [partially-true] Core Audio process taps (AudioHardwareCreateProcessTap, macOS 14.2+) can capture our own output for the visualiser, possibly with a permission prompt. libmpv probably has no PCM callback (memory).
    CORRECTION: The API and macOS 14.2 are correct. But Apple's guide says the app needs NSAudioCaptureUsageDescription, and on first use the system asks the user to grant 'system audio recording' permission. That is a heavy prompt to show just for a spectrum display. libmpv's public headers (client.h, render.h) have no PCM callback, so the 'memory' claim holds. The only built-in route is ao=pcm (--ao-pcm-file) or lavfi filters.
    SRC: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps ; https://github.com/mpv-player/mpv/blob/master/include/mpv/client.h and render.h (grep: no PCM/audio-data API) ; DOCS/man/ao.rst lines 284-296
- [unverifiable] There is no @2x convention for classic skins; WACUP's double/triple size is limited.
    CORRECTION: WACUP's 2020 blog and 2017 forum confirm only that classic-skin scaling was partial back then. I found no current (2025-26) source on WACUP's classic-skin scaling. 'No @2x convention' fits everything I found, but I can't prove it.
    SRC: https://getwacup.com/changelog/beta_0_9_9_1364.html (PNG support only) ; https://getwacup.com/blog/index.php/2020/01/09/wacup-and-winamp-and-4k-just-how-bad-is-it/

## CONFIRMED CLAIMS
- The 1998 Strider spec says every skin file is optional and missing ones fall back to the original look. It also says any BMP type is accepted, an oversized sheet uses its top-left part, an undersized sheet is see-through where pixels are missing, and an undersized main.bmp shows garbage.
- ImageIO on macOS 27 decodes every real skin BMP as com.microsoft.bmp, including RLE8, 16-bit and 32-bit files, with no spurious transparency. All headers are 40-byte BITMAPINFOHEADER, and zip entries are only stored or deflate.
- Webamp's skinSprites.ts is 841 lines under MIT ('Copyright (c) [2015] [Jordan Eldredge]'). GENEX is commented out, VIDEO/MB/AVS are absent, and gen.bmp's A–Z title font sits at y=88 (active) and y=96 (inactive).
- Window geometry constants: resize steps of 25×29, base 275×116, snap distance 15. Playlist can resize but not double; main and EQ can double. Marquee is 31 characters, separator '  ***  ', steps every 220 ms, resumes 1 s after a drag. Text is deburred and lower-cased.
- Webamp npm latest is 2.3.1 (2026-06-16), the repo has commits as recent as 2026-10-21, and `__customMediaClass` is documented as 'a bit of a hack… not considered stable'. IMedia exposes getAnalyser(): AnalyserNode.
- etedgy/macos-native-winamp-with-skins uses a full-screen transparent NSWindow, private drawsBackground KVC, a 60 Hz click-through timer, and recreates the instance on skin switch because in-place switching crashes. WebKit bug 221663 is still NEW.
- wishval/wamp is MIT, 124★, AppKit, depends only on ZIPFoundation, ports Webamp's sprite table, uses 32 MB/96 MB zip caps, and maps lower-cased basenames.
- Audacious core is BSD-2 but its skins-qt plugin is GPLv3 (from XMMS/BMP). It unzips with 'unzip -o -j', tries .bmp/.png/.xpm, maps balance→volume and nums_ex→numbers, and rejects the whole skin if a core sheet is missing.
- The 2024 Winamp source release was under WCL 1.0 (no forks, later no distribution of modified versions), contained third-party proprietary code, and was deleted from GitHub in October 2024.
- ZIPFoundation 0.9.20 (24 Sep) reads in memory via Archive(data:accessMode:). Compression's COMPRESSION_ZLIB is raw DEFLATE (RFC 1951). AppleArchive does not handle ZIP.
- Skin Museum: POST api.webamp.org/graphql, no auth, about 104k classic skins, r2 download URLs, 275×348 Webamp-rendered screenshots. The skin-database README says GraphQL 'is not currently used by anything'.
- Webamp's bundled base skin is Nullsoft artwork, not covered by MIT. AndAmp Dark/Light/Spot are CC BY 4.0, and macamp bundles them with attribution.
- Per Jordan Eldredge's investigation, Winamp prefers nums_ex.bmp when both it and numbers.bmp are present.
- Apple APIs: CALayer.magnificationFilter = .nearest; NSGraphicsContext.imageInterpolation 'is not part of the graphics state'; NSWindow.invalidateShadow() recomputes the shadow from the window shape.
- qmmp is GPL and v2.4.2 shipped in Sept 2026.

## MISSED CONSIDERATIONS
- Golden-image tests are weaker than the report suggests. Museum screenshots show live visualiser bars and a marquee mid-scroll, so those areas must be masked. For any skin missing a sheet, Webamp drew Nullsoft's base-2.91 while sudamp would draw 'sudamp Dark', so only compare skins that have every sheet. Screenshots were also made by different Webamp versions over the years. The minus sign and remaining-time mode never appear in them (the clock shows 00:03 elapsed).
- Double-size is not the same as window scale. Winamp/Webamp double-size applies only to main and EQ (playlist canDouble=false). A 2x Retina default must scale every window the same way and keep docking, snapping and the 25×29 resize maths in skin pixels.
- Layout rects must be draw rects, not Webamp CSS hit boxes. Examples: marquee padding 3px puts text at y=27; the 3px work indicator sits at x=24; the minus sign is 38 vs 40 between Webamp and Strider. The pause-state time blink, the clutter-bar 'D' toggle and the easter-egg title bars (TITLEBAR y=57/72) also need handling.
- region.txt has to be rasterised without anti-aliasing, following GDI polygon rules (even-odd, right/bottom edges exclusive). Otherwise edge pixels come out semi-transparent. Webamp uses SVG clip-path, so it is not an exact reference for which pixels are covered.
- Click-through on transparent pixels: as far as I remember (not verified), the WindowServer already passes clicks through alpha-0 pixels of non-opaque windows (Apple's old RoundTransparentWindow sample relies on it). Explicitly setting ignoresMouseEvents=false may disable that. Test early; a hitTest override alone does not control pass-through to other apps.
- Docking with NSWindow.addChildWindow: children move with the parent and keep a fixed z-order relative to it. Winamp docking is a dynamic graph (windows dock transitively; dragging a docked child undocks it; focus brings a window to the front). It needs custom logic, plus checks of minimise, Spaces and full-screen behaviour.
- Visualiser data: a process tap needs NSAudioCaptureUsageDescription and a 'system audio recording' prompt, which is bad UX for a music player. libmpv has no PCM callback. The audio-engine design should plan an in-process PCM path, or a simulated or level-only visualiser.
- Licence chain: wamp's SpriteCatalog is derived from Webamp, so keep both MIT notices. hfyeomans/MacAmp bundles 'Classic Winamp' (Nullsoft) and other third-party skins; never copy its resources. AndAmp's generator is GPL (only its .wsz output is CC BY 4.0). Two unrelated projects are both named MacAmp/macamp; cite carefully.
- Trademark and trade dress: Webamp's README says the 'Winamp name, interface' are Nullsoft property. Keep 'Winamp', the llama, the lightning bolt and 'WINAMP' title-bar text out of the app name, icon, default skin and marketing. Make sudamp Dark visually distinct and use nominative references only. This matters for App Store review too.
- When text.bmp cannot render a title and the marquee falls back to a system font, take the colours from text.bmp itself (Audacious does this in skin_get_textcolors), not from pledit.txt, which belongs to the playlist.
- Zip details: filename encodings (CP437 or Shift-JIS when the UTF-8 flag is clear; ZIPFoundation has a pathEncoding parameter). .ani cursors need a parser (ImageIO handles only .cur); Webamp's MIT ani-cursor package is a reference. Webamp reads PLEDIT.txt with first-match semantics, so decide on purpose which rule to follow.
- r2.webampskins.org blocks some default User-Agents (403 for Python urllib). An in-app museum downloader needs a proper UA and should cache. Some skin readmes forbid modification or redistribution, so treat downloaded skins as user-local and never re-host them.
- Webamp's recent activity is museum/website work; the player package hasn't released since 2.3.1 (June 2026). That doesn't matter for a reference-only port, but pin the commit the tables are ported from.

## RECOMMENDATION ASSESSMENT
The recommendation holds up. Build a native AppKit renderer that composes each window at 1x into a CGImage shown in a CALayer with nearest-neighbour scaling, port Webamp's MIT sprite tables, ship an original generated default skin, and use a native NSMenu genre picker. The facts it rests on checked out: Webamp is MIT and the GENEX block is commented out; `__customMediaClass` is officially 'a hack'; the drawsBackground KVC is still private (WebKit bug 221663 is NEW); ImageIO decodes real skin BMPs (I re-tested 2,029 of them on macOS 27 with 0 failures); ZIPFoundation 0.9.20 and its in-memory init exist; the Audacious skin code is GPLv3; and the 2024 Winamp source is off-limits. Rejecting the WKWebView route is right, though it should rest on the verified structural problems rather than a 2-star hobby repo's crash report. The coverage numbers are approximate: in my sample gen.bmp was 11.8% and pledit 97.8%. The conclusions still stand: defer a gen.bmp Stations window, and use the playlist as the secondary browser.

Changes I'd make:
1. Build the layout table from draw rects cross-checked against Strider, not from raw Webamp CSS boxes.
2. Narrow golden tests to complete skins only, with the visualiser and marquee masked.
3. Treat the default 2x Retina scale as a uniform scale for all windows, separate from Winamp's double-size (main and EQ only).
4. Specify non-anti-aliased, GDI-style region rasterisation, and test macOS's built-in alpha click-through before overriding hitTest.
5. Drop the process tap as a visualiser source because of its 'system audio recording' prompt. Push the audio-engine work towards an in-process PCM path, or ship a simulated visualiser in v1.
6. Add a trademark/trade-dress rule (no Winamp name or logos; sudamp Dark must look clearly different), and record the licence chain (Webamp → wamp MIT notices; AndAmp generator is GPL; never copy MacAmp's bundled skins).
7. Take the fallback marquee font colours from text.bmp.

On eject: keep it as 'open URL/stream' and put the genre menu on the marquee, the options button, the right-click menu and the menu bar. That avoids changing a control's meaning in every skin.
