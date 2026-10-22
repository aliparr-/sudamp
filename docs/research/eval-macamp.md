# EVAL macamp: hfyeomans/MacAmp as a fork base for sudamp (vs build fresh and borrow pieces)

## Summary
I cloned MacAmp at cb0c77f (2026-10-02). It has 20,369 lines of Swift in 121 files, 137 Swift Testing tests, no CI, one maintainer, 9 stars and 4 open issues. It is a real, working, Swift-6-strict codebase.

**Audio engine.** It is one AVAudioEngine graph: playerNode (local files) or an AVAudioSourceNode stream bridge, then AVAudioUnitEQ (10 bands), then the main mixer, then output. A 2048-frame installTap feeds Goertzel bars and a vDSP FFT. The stream bridge already does exactly what sudamp needs for PCM from libmpv: it reads interleaved Float32 stereo from a lock-free SPSC ring buffer.

**Skins and windows.** Each sprite is its own SwiftUI Image view with .interpolation(.none), placed with .offset inside AppKit borderless windows. There is no region.txt support. Issue #84 lists real skin-fidelity defects: magenta not treated as transparent, an antialiased green EQ curve, viscolor ignored, wrong space glyph. Non-ASCII characters render as spaces.

**Build on this CLT-only machine.** The upstream Package.swift is stale: mixed ObjC/Swift in one target, and the asset catalog needs actool. After that, the macOS 27 SDK hits a CLT-specific problem: SwiftUI's @State is now a macro, and its plugin ships only with Xcode, so even a minimal @State view fails at any deployment target. I made mechanical fixes:
- moved the ObjC shim into its own C target;
- excluded the asset catalog and made an .icns with iconutil instead;
- copied resources;
- replaced @State (38 declarations) with a custom DynamicProperty shim;
- removed the 9 #Preview blocks;
- added a plugin-path workaround for the test macros.

After those fixes, debug and release builds succeed. The tests compile and an ad-hoc-signed .app assembles. I did not launch the app or run the tests: MacAmp is not one of the upstreams I was cleared to execute.

**macOS 27 minimum.** Only about 7 call sites need macOS 26/27 (typed NotificationCenter messages, and the video tap). After patching those, it compiles at macOS 15.

**Licence.** MacAmp's code is MIT, but none of the 7 bundled skins can be reused, including the Nullsoft "Winamp.wsz" that the code uses as its fallback. Code derived from Webamp and the Butterchurn files ship without their MIT notices.

**Fit with sudamp.** About 40% of the code is video, Milkdrop and a custom HTTP-radio decoder that mpv would replace. The rendering approach is the one the skins research rejected for sudamp.

**Recommendation: don't fork. Borrow about 3.9k lines of specific MIT modules, plus about 1k lines of tests, and use the rest as reference.**

## Verdict
BORROW SPECIFIC PIECES, DO NOT FORK. Use the rest of MacAmp as reference only.

Why not fork:
1. **Architecture mismatch.** MacAmp draws each sprite as its own SwiftUI view. The skins research picked a 1x bitmap compositor in a CALayer, which is pixel-exact and can be checked against golden images. Issue #84 shows MacAmp's fidelity bugs live in that layer: antialiased EQ curve, gradient visualiser, magenta handling, no region.txt, non-ASCII titles shown as blanks.
2. **About 40% of the code is dead weight for sudamp.**
   - Video: 1,963 lines plus 47 tests (40 video-tap, 7 biquad).
   - Milkdrop/Butterchurn: 1,528 lines.
   - Custom MP3/AAC radio decoder: 2,323 lines, replaced by mpv.
   - The AudioPlayer facade (1,097 lines) is tangled up with the video taps, so stripping video is real work.
3. **SwiftUI fights this CLT-only machine.** @State and #Preview macros don't exist without Xcode, so every SwiftUI view needs a shim, and the shim's runtime behaviour is unverified.
4. **Everything visual has to go.** All 7 bundled skins must be stripped, including the Nullsoft fallback the code depends on. The Webamp and Butterchurn MIT notices are missing and need fixing.
5. **No upstream to lean on.** There is one maintainer and no CI, and a fork would diverge immediately.

Two things are not blockers:
- The macOS 27 minimum. After patching about 7 call sites, the code compiles at macOS 15.
- The build. A CLT build works after about an hour of mechanical changes.

Rough effort, from my estimates for an AI agent working from the terminal (not measured):
- **Fork:** about 1 day for the build plus macOS 15, 2–3 days to strip and rebrand, and 4–8 days to fix skin fidelity inside SwiftUI. That gives a sudamp-shaped demo in about 2–3 weeks, on an architecture the research rejected, with permanent CLT friction.
- **Fresh and borrow:** 2–4 weeks for the AppKit renderer, windows, docking, shade and double size. This is offset by about 1 week saved by reusing MacAmp's engine, EQ, visualiser and docking modules.

So forking gets a demo about 1–2 weeks sooner, but building fresh ends in the planned architecture with a free choice of minimum macOS and a clean licence trail. Both paths need the same mpv producer, yt-dlp manager, catalog, genre NSMenu and original "sudamp Dark" skin.

Optional: if the user approves running MacAmp's code, the scratch build at /tmp/sudamp-priorart/macamp-spm could host a one-day spike. It would wire an mpv PCM producer into activateStreamBridge to test pacing, latency and seek before writing sudamp's own engine.

## Reusable
- Licence for every item below: MIT © 2025-2026 Hank Yeomans; copy its LICENSE text into sudamp's THIRD_PARTY_NOTICES. Items derived from Webamp also need Webamp's MIT notice. Paths are relative to /tmp/sudamp-priorart/macamp.
- MacAmpApp/Audio/LockFreeRingBuffer.swift (218 lines) and Tests/MacAmpTests/LockFreeRingBufferTests.swift (444 lines): SPSC interleaved Float32 ring buffer on swift-atomics, with a seqlock flush and a CAS read. Add a write variant that never overwrites, for paced mpv producers.
- MacAmpApp/Audio/AudioEngineController.swift, the stream-bridge subset: makeStreamRenderBlock, activateStreamBridge, deactivateStreamBridge and handleEngineDidReconfigure (about 250 lines). Pattern: interleaved source format, non-interleaved graph format, stop and reset before rewiring to avoid error -10868, and an atomic silence gate. This is the template for the libmpv PCM → AVAudioSourceNode bridge.
- MacAmpApp/Audio/AudioEngineConfigurationObserver.swift (93 lines) and Tests/MacAmpTests/EngineConfigObserverTests.swift: debounces output-route changes with a 150 ms quiet window.
- MacAmpApp/Audio/EqualizerController.swift configureEQ(), plus BiquadCoefficientSet.frequencies [70,180,320,600,1000,3000,6000,12000,14000,16000] (shelves at the ends, 1-octave bandwidth). Also Models/EQPreset.swift (17 presets), Models/EQF.swift (Winamp .eqf codec) and Tests/MacAmpTests/EQCodecTests.swift. Drop the video-tap fanout.
- MacAmpApp/Audio/VisualizerPipeline.swift, VisualizerScratchBuffers.swift and VisualizerFeed.swift (about 720 lines): zero-allocation installTap processing with Goertzel bars and a vDSP 2048-point FFT. Reuse the data side only; draw the bars yourself with viscolor colours stepped per row.
- MacAmpApp/Models/SnapUtils.swift, DockGraph.swift and ScreenClamp.swift (about 420 lines), with DockGraphTests (12) and ScreenClampTests (14). Derived from Webamp's snapUtils, so keep both notices (Hank Yeomans and Jordan Eldredge).
- MacAmpApp/Utilities/WindowSnapManager.swift and Views/Shared/TitlebarDragCaptureView.swift: AppKit cluster drag with snapping. Good reference or adaptable code for sudamp's WindowManager.
- MacAmpApp/Windows/WindowScreenGuard.swift, WindowFramePersistence.swift and WindowFrameStore.swift (plus WindowFrameStoreTests): window recovery after sleep/wake and display changes, and frame persistence. Swap the typed NotificationCenter messages for addObserver(forName:) if the minimum is below macOS 26/27.
- MacAmpApp/Models/PLEditParser.swift, VisColorParser.swift, M3UParser.swift and M3UEntry.swift: small parsers. Cross-check them against Webamp's parsers and fixtures.
- MacAmpApp/Audio/ObjCBridge/AUAudioUnitWorkgroupShim.{h,m}: joins a producer thread to the output os_workgroup. Use only if sudamp runs its own real-time producer thread; it must live in a separate C target under SwiftPM.
- MacAmpApp/Audio/Streaming/ICYFramer.swift: only if sudamp keeps a native internet-radio path that bypasses mpv.
- Reference only (read, don't copy): SpriteResolver.swift (digit fallback logic) and the docs/MULTI_WINDOW_ARCHITECTURE.md and docs/CUSTOM_DRAG_FIX.md design notes. Port sprite coordinates from Webamp's skinSprites.ts directly, with draw-rect corrections, rather than from MacAmp's partial SkinSprites.swift.
- Do NOT reuse: MacAmpApp/Skins/*.wsz (all 7 are Nullsoft or third-party), Assets.xcassets icons (MacAmp branding), or the Butterchurn/ folder unless Jordan Berg's MIT notices are added.

## Experiments
- Clone and history
  METHOD: git clone --depth 1 into /tmp/sudamp-priorart/macamp; git clone --filter=blob:none --bare into /tmp/sudamp-priorart/macamp-history; git log stats
  RESULT: HEAD cb0c77f (2026-10-02); 768 commits since 2025-09-04; tags up to v2.0; single author
- Upstream Package.swift as-is
  METHOD: rsync to /tmp/sudamp-priorart/macamp-spm; swift build
  RESULT: FAIL: 'target … contains mixed language source files' (the ObjC os_workgroup shim)
- Shim split into a C target
  METHOD: moved AUAudioUnitWorkgroupShim.{h,m} to Shim/ (with include/); added import AudioWorkgroupShim to 2 files
  RESULT: FAIL: Assets.xcassets processing needs actool ('requires Xcode')
- Exclude xcassets, copy resources
  METHOD: exclude Assets.xcassets; .copy("Skins"), .copy("Butterchurn")
  RESULT: FAIL: 44 '@State' errors (SwiftUIMacros.StateMacro plugin not found) and 9 #Preview errors (PreviewsMacros)
- Isolate the @State macro problem
  METHOD: probe package /tmp/sudamp-priorart/swiftui-state-probe, macOS 14 target, minimal @State view; tried typealias State, @SwiftUICore.State, and a custom DynamicProperty wrapper
  RESULT: @State fails at every target; typealias and module-qualified forms fail; a wrapper around SwiftUI.State compiles (runtime behaviour not checked); @Binding and @Environment are fine
- Full scratch conversion
  METHOD: CLTState shim (sed at 38 sites), Python script removing 9 #Preview blocks, CLTState(wrappedValue:) in MacAmpApp.init, '= nil' for optionals; swift build and swift build -c release
  RESULT: Build complete (debug about 32 s clean, release 40 s); 16 warnings, all macOS-27 deprecations; 0 concurrency diagnostics
- Compile the test target
  METHOD: swift build --build-tests (also with a library+exec split, and with --build-system native)
  RESULT: swiftbuild: TestingMacros plugin not found when the test target depends on an executable target (also reproduced in the probe). native: 'no such module Testing'. Fixed with -Xswiftc -plugin-path -Xswiftc …/host/plugins/testing; tests compile. Not run, by policy.
- Find what pins the macOS minimum
  METHOD: rebuilt with .macOS 26.0, 15.0 and 14.0; patched typed-notification observers and #available-gated VideoTap in /tmp/sudamp-priorart/macamp-spm15
  RESULT: 26: 4 errors; 15: those plus 2 VideoTap errors, then builds after patching 3 files (about 7 sites); 14: VideoTap Synchronization atomics need 15
- Assemble an .app without Xcode
  METHOD: iconutil -c icns on the appiconset PNGs; sed/plutil on Info.plist $(VARS); copied the resource bundle and Butterchurn into Contents/Resources; codesign --sign - --options runtime --entitlements
  RESULT: /tmp/sudamp-priorart/appbundle/MacAmp.app (9.0 MB, adhoc,runtime). Not launched, by policy. The SwiftPM Bundle.module accessor checks Bundle.main.resourceURL first, so the layout is correct.
- Skin provenance
  METHOD: unzip -l and readme extraction for all 7 bundled .wsz into /tmp/sudamp-priorart/macamp-skins-inspect
  RESULT: All third-party or Nullsoft; two say 'All rights reserved'; none carries a licence that allows redistribution
- Butterchurn licence
  METHOD: curl the npm registry for butterchurn-presets 2.4.7 and the raw LICENSE files on GitHub; grep the vendored files
  RESULT: Both MIT © 2013-2018 Jordan Berg; MacAmp ships no notice
- Repo metadata and issues
  METHOD: WebFetch of the GitHub repo and issues pages (API rate-limited); WebFetch of issue #84
  RESULT: 9 stars, 1 fork, 4 open issues; #84 lists 7 skin rendering defects

## Risks
- I did not run the app or its tests, because MacAmp is outside the list of upstreams I was cleared to execute. Pixel exactness at 1x/2x, whether the CLTState shim behaves correctly at runtime, the audio behaviour, and the claimed '137 tests, TSan clean' are all unverified on this machine.
- This affects sudamp too: on the macOS 27 SDK without Xcode, any SwiftUI @State (and #Preview, @Entry, @Animatable) fails to compile. If sudamp uses SwiftUI for preferences, plan on AppKit, @Observable models owned by AppKit, or a DynamicProperty shim.
- This affects sudamp too: under the default swiftbuild system, a test target that depends on an executable target loses the TestingMacros plugin. Keep tests depending on library targets, or pass -Xswiftc -plugin-path …/plugins/testing.
- On macOS 27, AVAudioEngine connect, play, installTap and auAudioUnit are deprecated, and their replacements exist only on macOS 27. If sudamp's minimum is below 27, it either tolerates the warnings or adds #available branches.
- MacAmp's ring buffer overwrites the oldest audio when full and its stream pipeline has no backpressure. Feeding it on-demand YouTube, SoundCloud or Mixcloud audio from mpv needs explicit pacing (ao=pcm is untimed, per the engine research), plus new handling for seek, duration and pause flush.
- If you fork: video is tangled into AudioPlayer, EqualizerController fanout, VisualizerPipeline and WindowCoordinator, so stripping it is more than deleting files. The fallback skin is hard-wired to the Nullsoft Winamp.wsz and must be replaced by an original skin before anything else works.
- Licence hygiene: code derived from Webamp (SkinSprites, SnapUtils) and the Butterchurn JS ship without MIT notices. The underlying Milkdrop presets come from many community authors, and their individual licensing is unverified.
- Security: ZIP skin loading has no size or entry caps (it trusts uncompressedSize), so it is exposed to zip bombs. ButterchurnWebView uses the private drawsBackground KVC call.
- Maintenance and bus factor: one maintainer, 9 stars, no CI, and about 150k lines of AI-generated planning docs alongside 20k lines of Swift. A fork would get little upstream benefit and would carry a large amount of context.
- My effort estimates are rough, for an AI agent working from the terminal, and were not measured.

## Facts
- Snapshot under review is commit cb0c77f2 (2026-10-02). There are 768 commits on main, made from 2025-09-04 to 2026-10-02, with peaks in 2025-10 (266) and 2026-03 (180). One human author (Hank Yeomans); most commit messages carry Claude Co-Authored-By trailers. Tags run v0.7.5 to v2.0. (git log in /tmp/sudamp-priorart/macamp-history/repo.git (blobless clone); git tag)
- 9 stars, 1 fork, 0 watchers. 4 open issues: #88 multichannel video, #84 Nucleo NLog v2G rendering defects, #79 can't drag or double-click to open files, #47 Cmd+Shift+1-3 shortcut conflict. (WebFetch of https://github.com/hfyeomans/MacAmp and /issues, 2026-10-22)
- There is no CI. The tracked dotfiles are only .githooks (git-lfs hooks plus a pre-commit hook for secrets and SwiftLint) and .swiftlint.yml. .gitignore ignores all dotfiles, which would include .github. (git ls-files | grep '^\.' in /tmp/sudamp-priorart/macamp; .gitignore line 2)
- Size: 20,369 lines of Swift in 121 files under MacAmpApp (14,201 code lines), plus 3,185 test lines. The repo also holds about 150k lines of markdown in docs/ and tasks/, and a 284 KB BUILDING_RETRO_MACOS_APPS_SKILL.md. (python3 /tmp/sudamp-priorart/tools/loc.py; find docs tasks -name '*.md' | xargs wc -l)
- Lines (code lines) by area: windows/docking/shade 2,727 (2,088); audio engine core 2,792 (1,794; AudioPlayer.swift alone is 1,097); HTTP-radio streaming 2,323 (1,517); playlist 2,176 (1,592); skin parsing/model 2,131 (1,580); video 1,963 (1,212); main-window UI and widgets 1,833 (1,424); Milkdrop 1,528 (966) plus 1.7 MB of Butterchurn JS; EQ 1,250 (926); visualisers 1,005 (650); app shell 642 (452). (/tmp/sudamp-priorart/tools/loc.py output (per-file mapping printed))
- There is a single module. The XcodeGen target and the SwiftPM executable target both use path MacAmpApp. Dependencies are ZIPFoundation 0.9.20 and swift-atomics 1.3.0. Swift 6.2 with SWIFT_STRICT_CONCURRENCY complete; the deployment target is macOS 27.0. (/tmp/sudamp-priorart/macamp/Package.swift, Package.resolved, project.yml)
- Strict concurrency is clean. It compiles in Swift 6 language mode with Swift 6.4 and produces 0 concurrency diagnostics. The only warnings are 16 macOS-27 deprecations: AVAudioEngine connect/play/installTap/auAudioUnit and AVPlayerItemDidPlayToEndTime. Escape hatches used: 15 @unchecked Sendable, 2 nonisolated(unsafe), 5 @preconcurrency. (/tmp/sudamp-priorart/build-clean.log; grep counts over MacAmpApp)
- There are 137 @Test functions in 20 Swift Testing suites; all are unit or logic tests, with no UI or golden-image tests. 40 of them are video-tap tests, plus 7 biquad tests that check the video EQ against AVAudioUnitEQ. Others: LockFreeRingBuffer 16, AudioPlayer state 17, ScreenClamp 14, DockGraph 12, StreamPauseTail 9, and only 6 skin tests (SkinManager 4, SpriteResolver 2). (grep -c '@Test' /tmp/sudamp-priorart/macamp/Tests/MacAmpTests/*.swift)
- Local files: AVAudioFile(forReading:) is played by AVAudioPlayerNode.scheduleSegment. The graph is playerNode → AVAudioUnitEQ → mainMixer → output, connected with an explicit Float32 non-interleaved format at the output sample rate. (MacAmpApp/Audio/AudioEngineController.swift lines 128-214, 494-497)
- HTTP radio pipeline: URLSession → ICYFramer → AudioFileStreamParser (AudioFileStream) → AudioConverterDecoder (AudioConverterFillComplexBuffer, Float32 stereo) → LockFreeRingBuffer (32,768 frames) → AVAudioSourceNode render block → the same EQ → mixer. Supported formats are MP3 and AAC-ADTS only, chosen by a hint from the URL/path; HLS and Ogg are open tasks. AVPlayer is used only for video. (MacAmpApp/Audio/Streaming/StreamDecodePipeline.swift lines 1-20, 470-480; StreamPlayer.swift line 130; tasks/hls-streaming-support, tasks/ogg-vorbis-s)
- ICY metadata: the client sends Icy-MetaData: 1 and reads the icy-metaint header case-insensitively. The framer is configured on the delegate queue before data arrives. StreamTitle is decoded as ISO-Latin-1. M3U and PLS playlist URLs are resolved first. (StreamDecodePipeline.swift lines 192-232, 316-327; ICYFramer.swift line 152)
- Reconnect: up to 10 attempts with exponential backoff (1, 2, 4… seconds, capped at 16 s). The counter resets after 5 s of stable playback. There is no reconnect while paused. 4xx errors, decode errors and DNS/bad-URL failures are terminal; 5xx, 429 and server-closed are retried. (MacAmpApp/Audio/StreamPlayer.swift lines 65-66, 382-482, 596-609)
- EQ is AVAudioUnitEQ(numberOfBands: 10) at Winamp's internal frequencies [70, 180, 320, 600, 1000, 3000, 6000, 12000, 14000, 16000] Hz. Band 0 is a low shelf, band 9 a high shelf, the rest parametric with bandwidth 1.0 octave. Preamp uses globalGain and on/off uses bypass. There are 17 presets and an EQF codec. (MacAmpApp/Audio/EqualizerController.swift lines 18-43, 255-285; Audio/VideoDSP/BiquadCoefficientSet.swift line 40)
- Visualiser data: installTap(onBus:0, bufferSize:2048) on mainMixerNode. Zero-allocation scratch buffers compute Goertzel bars (19-20) and a 2048-point vDSP FFT for Butterchurn. Results are polled at 30 Hz on the main run loop in .common mode. (MacAmpApp/Audio/VisualizerPipeline.swift lines 110-123, 186-210, 320-410)
- Visualiser rendering is not pixel-exact. Each of the 19 bars is a SwiftUI GeometryReader drawn with a smooth LinearGradient across viscolor 2-17, rather than stepped colours per row. Heights are animated fractionally with withAnimation(.linear), driven by a 30 FPS Timer.publish. (MacAmpApp/Views/VisualizerView.swift lines 21-125, 128-215)
- Clean PCM integration point: AudioEngineController.activateStreamBridge(ringBuffer:sampleRate:) creates an AVAudioSourceNode with an interleaved Float32 stereo format, wires it into EQ → mixer, re-wires on route changes, and has a silence gate. A libmpv 48 kHz stereo producer only has to call LockFreeRingBuffer.write. Caveat: write() overwrites the oldest data when the ring is full and has no blocking or backpressure, and the ring holds about 0.68 s at 48 kHz. A producer that feeds on-demand content faster than real time must therefore pace itself on availableFrames. A new PlaybackSource case is also needed, because streams currently have duration 0 and cannot seek. (AudioEngineController.swift lines 336-489; LockFreeRingBuffer.swift lines 55-102, 191-199; PlaybackCoordinator.swift lines 68-93)
- Route-change handling: AudioEngineConfigurationObserver collapses bursts of AVAudioEngineConfigurationChange into one will/did pair with a 150 ms quiet window. The controller then refreshes the bridge format, re-checks the mixer→output connection and restarts the engine. (MacAmpApp/Audio/AudioEngineConfigurationObserver.swift; AudioEngineController.swift lines 517-563)
- Skin rendering: each sprite is a SwiftUI Image(nsImage:) with .interpolation(.none), .antialiased(false) and .resizable() inside a frame, positioned with .offset. The views are hosted in AppKit BorderlessWindow controllers. Sprites are cut out of BMPs loaded with NSImage(data:) and redrawn into RGBA8 contexts. (MacAmpApp/Views/Components/SimpleSpriteImage.swift lines 48-66; Models/ImageSlicing.swift; Windows/BorderlessWindow.swift)
- Missing skin features: region.txt (non-rectangular windows) and skin cursors (Skin.cursors is always [:]). Title marquee characters outside ASCII become spaces, and it scrolls 5 px every 150 ms. The EQ curve is an antialiased SwiftUI Path in Color.green, not the EQMAIN palette. Issue #84 lists 7 fidelity defects, including magenta not treated as transparent and the wrong space glyph. ZIP extraction trusts the declared sizes and has no caps. (grep 'region' finds nothing in skin code; ViewModels/SkinManager.swift line 102 (cursors: [:]); Views/MainWindow/MainWindowTrackInfoLayer.swift lines )
- Docking: custom AppKit drag via TitlebarDragCaptureNSView into WindowSnapManager. Dragging Main moves its whole cluster (DockGraph). SnapUtils copies Webamp's snapUtils API (snap, snapToMany, snapWithin, applySnap, boundingBox) with SNAP_DISTANCE 10. ScreenClamp and WindowScreenGuard recover windows after sleep/wake and display changes. Shade strips exist for Main, EQ and Playlist. Double size is .scaleEffect(2) on Main and EQ only. (Views/Shared/TitlebarDragCaptureView.swift; Utilities/WindowSnapManager.swift lines 200-330; Models/SnapUtils.swift; Models/DockGraph.swift; Views/Mai)
- The upstream Package.swift does not build on any machine as-is. Its first error is 'target … contains mixed language source files', caused by the ObjC os_workgroup shim added 2026-03-22. Only the XcodeGen path is maintained. (/tmp/sudamp-priorart/build1.log; git log -- MacAmpApp/Audio/ObjCBridge)
- On the macOS 27 SDK with CLT only, SwiftUI's @State is an attached macro (SwiftUIMacros.StateMacro) and #Preview needs PreviewsMacros. Neither plugin ships with the CLT; only libObservationMacros, libSwiftMacros and testing/libTestingMacros are present. A minimal @State view fails even at a macOS 14 target. A module typealias or the SwiftUICore.State qualifier does not avoid it. A custom @propertyWrapper DynamicProperty that wraps SwiftUI.State compiles. @Observable, @Environment and @Binding work. (/tmp/sudamp-priorart/swiftui-state-probe; SwiftUICore.swiftinterface line 20038; ls /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins)
- With the scratch SwiftPM conversion, swift build succeeds: about 32 s clean debug, 40 s release. Changes made: ObjC shim moved to a C target with 2 imports; Assets.xcassets excluded; Skins and Butterchurn copied as resources; @State replaced by a CLTState shim at 38 sites in 14 files; 9 #Preview blocks removed; executable split into a library plus thin main (optional). The .app was assembled with iconutil (.icns from the appiconset PNGs), a plutil-substituted Info.plist and an ad-hoc hardened-runtime codesign with MacAmp.entitlements, giving 9.0 MB. It was not launched. (/tmp/sudamp-priorart/macamp-spm (Package.swift, Shim/, AppMain/main.swift, MacAmpApp/Utilities/CLTState.swift); /tmp/sudamp-priorart/appbundle/MacAmp.)
- Building the tests under swiftbuild fails when the test target depends on an executable target: TestingMacros.TagMacro 'plugin not found'. Explicit-module builds pass only ObservationMacros and SwiftMacros. Adding -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing fixes it. I reproduced this in a 3-target probe, where swift test then passes. MacAmp's tests compile with the flag but were not run. (/tmp/sudamp-priorart/build10.log vs build11.log; /tmp/sudamp-priorart/swiftui-state-probe)
- The macOS 27 minimum is mostly a choice. At a 26.0 target, 4 errors appear, all typed NotificationCenter messages in WindowScreenGuard.swift and WindowVisibilityController.swift. At 15.0 there are those plus MTAudioProcessingTapCreateWithPreferredFormat and AVAudioFormat(formatDescription:) in VideoTap.swift. After patching 3 files (about 7 call sites), the full app builds at macOS 15.0. At 14.0, VideoTap's Synchronization atomics fail. (/tmp/sudamp-priorart/macamp-spm15; commit 8c444dc 'raise minimum macOS to 27')
- The macOS 27 SDK deprecates AVAudioEngine connect(_:to:format:) in favour of a throwing connectNode(_:to:format:), which is available only on macOS 27. Code targeting below 27 keeps the old API and lives with warnings or uses #available. (MacOSX27.0.sdk AVFAudio.framework/Headers/AVAudioEngine.h lines 281, 295)
- Bundled skins: Winamp.wsz is Nullsoft's classic base skin with REGION.TXT and .CUR files, and the code hard-wires it as the 'bundled:Winamp' fallback. The other 6:
- Internet-Archive and Tron-Vaporwave (LuigiHann; no licence stated);
- KenWood_KDC_7000_Elite (Ely Ocbina, 'All rights reserved');
- Mac_OS-X_skin ('parts ripped from OS elements');
- Sony_MP3_Player_ (James Ness);
- Winamp3_Classified_v5.5 ('© 2004-2007 … All rights reserved').
No AndAmp skins are present. (unzip -l and readme extraction in /tmp/sudamp-priorart/macamp-skins-inspect; ViewModels/SkinManager.swift line 35)
- Licence notices are missing. Butterchurn and butterchurn-presets 2.4.7 are MIT (© 2013-2018 Jordan Berg), but the vendored minified files have no licence header and the repo has no NOTICE file. SkinSprites.swift says it is 'Ported (subset) from Webamp's skinSprites.ts', and SnapUtils mirrors Webamp snapUtils, yet Webamp's MIT notice does not appear. LICENSE is MIT © 2025-2026 Hank Yeomans. (git ls-files | grep -i notice/licen → only LICENSE; Models/SkinSprites.swift line 19; registry.npmjs.org/butterchurn-presets/2.4.7; raw LICENSE of jbe)
- ButterchurnWebView uses the private WKWebView KVC call setValue(false, forKey: "drawsBackground"). The entitlements enable allow-jit and allow-unsigned-executable-memory. The app is not sandboxed. (MacAmpApp/Views/Windows/ButterchurnWebView.swift line ~103; MacAmpApp/MacAmp.entitlements)
- There is no genre or catalog concept. RadioStation has an optional genre string, and RadioStationLibrary is a JSON array in UserDefaults with no picker UI. (MacAmpApp/Models/RadioStation.swift; Models/RadioStationLibrary.swift)