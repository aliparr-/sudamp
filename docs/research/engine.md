# Playback engine (IINA / libmpv / alternatives)

## SUMMARY
Use libmpv (mpv 0.41.x, LGPL build with -Dgpl=false) as sudamp's engine. Ship it as our own fork of MPVKit's xcframework build, published as SwiftPM binaryTargets. Write a thin Swift 6 wrapper of our own. Study IINA but don't copy it: IINA is a GPLv3 app with no library or framework product. Its yt-dlp support is just the yt-dlp_macos binary, renamed `youtube-dl` and put on PATH, with mpv's built-in ytdl_hook doing the work. In 1.4+ the optional Online Media plugin (io.iina.ytdl) re-implements ytdl_hook in JavaScript.

Stock MPVKit (1.1.0-n9.0.2, 2026-10-07) is good for a prototype. Its macOS libmpv includes LuaJIT, so ytdl_hook is embedded, and both CoreAudio and AVFoundation audio outputs. Three problems make it unsuitable to ship as-is:
- Its own README now says it is "only suitable for learning libmpv".
- Its FFmpeg is built with `--disable-filters` plus a whitelist. I checked with nm: only aformat, amix, anull, aresample, areverse, asetrate, atempo, atrim, equalizer, firequalizer, pan, superequalizer and volume are present. That is enough for the Winamp EQ but rules out the lavfi filters a visualiser needs (asplit, bandpass, astats, ametadata, amerge).
- mpv 0.41.0, still the latest tagged release, crashes in ao_coreaudio when the audio device changes on macOS 26/27 (issue #18274). The fix is only on master and in Homebrew's backport; MPVKit doesn't carry it.

The fork fixes all three: add the filters, apply the one-commit patch, and drop the video-only dependencies.

How the pieces fit:
- **Stream resolution:** sudamp runs the bundled yt-dlp (`-J`) itself, with a JS runtime (yt-dlp needs one for YouTube), and hands mpv the direct audio URL plus `http-header-fields`, `user-agent` and `stream-lavf-o` (request_size, reconnect). mpv runs with `ytdl=no`. This gives sudamp control over errors, prefetching, retries and URL expiry. ytdl_hook (with `script-opts=ytdl_hook-ytdl_path=…`) stays as a fallback.
- **EQ:** one labelled lavfi chain of 10 `equalizer@bN` filters plus a `volume@pre` preamp, installed once at startup. Gains change live with `af-command eq g <dB> bN`, which never rebuilds the filter chain.
- **Visualiser:** libmpv has no PCM callback, and `ao=pcm` is an untimed file writer. The robust option that needs no permission prompt is a lavfi tap at the end of the af chain: asplit → mono → bandpass bank → amerge → astats → `ametadata=mode=print:file=…`, read by a background thread and matched to `audio-pts`. A Linux mpv player (vivi) shipped exactly this design in October 2026. An optional high-fidelity mode can use a Core Audio process tap on our own PID (macOS 14.2+). Apple documents that taps need NSAudioCaptureUsageDescription and a System Audio Recording prompt, and documents no exemption for tapping your own process.
- **Media keys:** sudamp owns MPNowPlayingInfoCenter (setting `playbackState` explicitly, which macOS requires) and MPRemoteCommandCenter. libmpv's built-in profile already sets `input-media-keys=no` and `media-controls=no`, so mpv won't compete for the keys.

Alternatives are clearly worse:
- **AVPlayer:** on this Mac (macOS 27.0.1), `isPlayableExtendedMIMEType` says it can't play WebM/Opus (YouTube itag 251). Apple DTS says MTAudioProcessingTap isn't available for HLS, so there would be no EQ or visualiser for SoundCloud, Mixcloud or YouTube live.
- **VLCKit:** LGPL-2.1+, stable 3.7.4; 4.0 is still alpha a25.
- **Own FFmpeg + AVAudioEngine engine (or the new AetherEngine):** gives the most control but is far more work. It's the plan B.

One Swift 6 pitfall I confirmed by experiment with Swift 6.4: a C-callback closure literal written inside a @MainActor method, which is IINA's mpv_set_wakeup_callback pattern, crashes in `_dispatch_assert_queue_fail` as soon as mpv calls it from its own thread. The compiler gives no warning.

## RECOMMENDATION
1) Engine: libmpv.
- Prototype on stock MPVKit 1.1.0-n9.0.2 (product "MPVKit", LGPL). Until we have a patched build, test `audio-format=float` as the workaround for the macOS 26/27 hotplug crash.
- Before the visualiser work and before release, switch to `sudamp-mpv-build`: a fork of MPVKit's BuildScripts that is macOS arm64 (+ x86_64 if wanted) only, mpv 0.41.0 + commit c5d391ad (or a pinned master), `-Dgpl=false -Dlua=luajit -Dcoreaudio=enabled -Dcplayer=false -Djavascript=disabled`.
- FFmpeg in that build: the existing whitelist plus `--enable-filter=asplit,amerge,bandpass,astats,ametadata,anullsink,asetnsamples,adelay,aselect,alimiter,aspectralstats`.
- Publish the result as SwiftPM binaryTargets. Decide the licence now: if sudamp is GPLv3 you may copy IINA code; otherwise only study it.

2) Swift wrapper: `MPVCore` (`final class`, `@unchecked Sendable`) owns the handle and `DispatchQueue(label:"sudamp.mpv")`. Call `setlocale(LC_NUMERIC,"C")` before mpv_create.
- Options set before mpv_initialize: `vid=no`, `audio-display=no`, `vo=null`, `ytdl=no`, `ao=coreaudio`, `audio-client-name=sudamp`, `cache=yes`, `demuxer-max-bytes=64MiB`, `demuxer-readahead-secs=30`, `cache-pause-wait=2`, `network-timeout=15`, `gapless-audio=weak`, `msg-level=all=warn`, `af=<EQ chain + viz tap>` (set as a NODE array).
- Wakeup callback must be a top-level `nonisolated func mpvWakeup(_ ctx: UnsafeMutableRawPointer?) { let c = Unmanaged<MPVCore>.fromOpaque(ctx!).takeUnretainedValue(); c.queue.async { c.drain() } }`. Never use a closure literal inside a @MainActor method; I reproduced that crash with Swift 6.4.
- `drain()` loops `mpv_wait_event(h,0)` until MPV_EVENT_NONE, converts events to Sendable enums, and yields them to an AsyncStream consumed on the MainActor.
- Observed properties: pause, volume, time-pos, duration, media-title, metadata (for icy-title), idle-active, paused-for-cache, cache-buffering-state, demuxer-cache-state, audio-params. Also handle START_FILE, FILE_LOADED and END_FILE(reason/error), and log messages at warn level.
- Use mpv_command_async/mpv_command_node_async for loadfile.

3) URL resolution (option F):
- Bundle yt-dlp (the onedir yt-dlp_macos.zip build for faster start; sign every nested Mach-O with hardened runtime) plus a JS runtime: Deno ≥2.3, or QuickJS-NG ≥0.12 for size, but benchmark its challenge-solve time.
- Keep an updatable copy in ~/Library/Application Support/sudamp/bin.
- Run `yt-dlp -J --no-playlist --no-warnings --js-runtimes <rt>:<path> -f 'bestaudio/best' URL`. For YouTube 24/7 live, verify with `yt-dlp -F` which HLS variant to pick, since audio-only may not exist for live.
- Pass `loadfile <url> replace -1 {"http-header-fields": <from http_headers>, "user-agent": …, "stream-lavf-o": "request_size=<http_chunk_size>,reconnect=1,reconnect_streamed=1,reconnect_delay_max=10", "force-media-title": title}`.
- Prefetch the next random item's resolution. Parse `expire=` and re-resolve before it. On END_FILE with an error or HTTP 403, re-resolve once and seek to the last time-pos, then skip to the next catalogue entry.
- Keep ytdl_hook mode behind a debug flag (`ytdl=yes`, `script-opts=ytdl_hook-ytdl_path=<abs path>,ytdl_hook-try_ytdl_first=yes`).

4) EQ: install once at start-up:
`@eq:lavfi=[volume@pre=volume=0dB:precision=float,equalizer@b0=f=60:t=q:w=1:g=0,equalizer@b1=f=170:t=q:w=1:g=0,equalizer@b2=f=310:t=q:w=1:g=0,equalizer@b3=f=600:t=q:w=1:g=0,equalizer@b4=f=1000:t=q:w=1:g=0,equalizer@b5=f=3000:t=q:w=1:g=0,equalizer@b6=f=6000:t=q:w=1:g=0,equalizer@b7=f=12000:t=q:w=1.4:g=0,equalizer@b8=f=14000:t=q:w=1.8:g=0,equalizer@b9=f=16000:t=q:w=1.8:g=0]`
- Sliders send `af-command eq g <dB> b<i>`; the preamp sends `af-command eq volume <dB>dB pre`. Range ±12 dB like Winamp.
- EQ off means all gains at 0, never removing the filter. Q values need tuning by ear. Add `alimiter` after it once the custom build has it.

5) Visualiser:
- Append once at start-up (custom build only): `@viz:lavfi=[asetnsamples=n=1024:p=0,asplit[o][m];[m]aformat=sample_fmts=flt:channel_layouts=mono,asplit=N[b0]…;[bi]bandpass=f=<log-spaced 40 Hz–16 kHz>:t=q:w=4[ci];…;[c0]…amerge=inputs=N,astats=metadata=1:reset=1:measure_perchannel=RMS_level+Peak_level:measure_overall=none,ametadata=mode=print:direct=1:file=<loopback tcp or pipe URL>,anullsink;[o]anull]`.
- A reader thread parses `frame:/pts_time:` and `lavfi.astats.K.*` lines into a ring buffer. The render loop (CVDisplayLink, 60 Hz) shows the frame with pts ≤ `audio-pts`.
- Expected error ≤ one 1024-sample frame (~21 ms at 48 kHz) and CPU <2% of one core (estimate; measure it).
- Oscilloscope: re-synthesise from bands (vivi's approach) for v1.
- Later, an opt-in 'true scope' mode via a Core Audio process tap on our own PID (macOS 14.2+, NSAudioCaptureUsageDescription), after testing whether it prompts.

6) Now Playing: sudamp-owned MPNowPlayingInfoCenter + MPRemoteCommandCenter, modelled on IINA's NowPlayingInfoManager/RemoteCommandController.
- Set `playbackState` on every play or pause, and set MPNowPlayingInfoPropertyIsLiveStream for streams without a duration.
- Map title to icy-title or media-title, and artist to the uploader or genre.
- nextTrack means 'next random stream in this genre'. Remove the targets when idle.

## RISKS
- [high] YouTube changes (JS challenges, SABR, PO tokens, IP-locked 403s) break yt-dlp extraction, sometimes for days -> Self-updating yt-dlp outside the bundle; JS runtime bundled; catalogue weighted toward multiple sources (SoundCloud, Mixcloud, radio); automatic skip to the next stream on resolve failure; later, server-side resolution or health checks of catalogue entries
- [high] mpv 0.41.0 ao_coreaudio crashes on audio device change on macOS 26/27 (#18274) -> Ship libmpv with commit c5d391ad (as Homebrew does) or a pinned master. In the prototype, test the audio-format=float workaround and regression-test Bluetooth connect/disconnect.
- [high] Swift 6 isolation crash or data races in libmpv C callbacks (reproduced locally) -> Nonisolated top-level callback that only enqueues work; all mpv calls on one serial queue; Sendable event structs; retained Unmanaged context released after mpv_set_wakeup_callback(h,nil,nil) and mpv_terminate_destroy
- [medium] MPVKit maintenance is minimal ('learning only'), and stock builds lack the needed filters and patches -> Own fork of the build scripts in CI, pinned versions, macOS-only slices; treat MPVKit upstream as a reference only
- [medium] Audio filter chain rebuilds (af set/add) cause audible gaps or pops -> Install the EQ and viz chains once before the first loadfile; only use af-command for changes; never toggle filters during playback
- [medium] lavfi visualiser tap: escaping errors, socket/pipe lifecycle across file changes, CPU with many bands -> Set af via the NODE property (no mpv-level escaping); version the reader per connection like vivi; benchmark 19 vs 75 bands; fall back to the process-tap mode
- [medium] Process-tap visualiser triggers a 'System Audio Recording' TCC prompt and fails silently without permission -> Off by default; explain it in the UI; detect silence and fall back to the lavfi tap; requires a stable signing identity
- [medium] Licence contamination (copying GPLv3 IINA code; GPL FFmpeg/mpv builds) or LGPL static-link obligations -> Decide the sudamp licence up front; use -Dgpl=false and an LGPL FFmpeg config; publish build scripts and sources so users can relink; keep IINA as a read-only reference unless sudamp is GPLv3
- [medium] Notarization and Gatekeeper problems with the bundled PyInstaller yt-dlp and the JS runtime (and with runtime-downloaded updates) -> Sign all nested executables with hardened runtime, test notarization early, prefer the onedir build, run updated binaries from Application Support, and verify checksums or signatures of downloads
- [medium] Expiring googlevideo URLs or dropped connections during multi-hour mixes or long pauses -> FFmpeg reconnect options plus request_size; track expire=; on error, re-resolve and seek to the last time-pos
- [low] App size grows (libmpv + FFmpeg + libplacebo + yt-dlp ~54 MB + JS runtime) -> arm64-only or thin builds, strip video dependencies where possible, QuickJS-NG instead of Deno if its speed is acceptable

## OPEN QUESTIONS
- What licence will sudamp use (GPLv3, which allows copying IINA code, or MIT/Apache with LGPL libmpv)?
- Does a Core Audio process tap on sudamp's own PID trigger the System Audio Recording prompt? Test with a Developer-ID-signed build on macOS 14.2+ and 27.
- For YouTube 24/7 live streams, does yt-dlp expose any audio-only format, or must we pick the lowest muxed HLS variant? Check with `yt-dlp -F` on a few genre streams.
- Measured CPU and latency of the bandpass/astats/ametadata tap at 19 vs 75 bands, and whether `ametadata file=pipe:<fd>` works in-process (avoiding a loopback TCP listener).
- Does `af-command eq g` on rapid slider drags cause zipper noise? Do we need gain smoothing (several small steps)?
- Is QuickJS-NG fast enough for yt-dlp's EJS challenges on Apple Silicon, or do we have to ship Deno (tens of MB)?
- Minimum macOS target: MPVKit allows 12, process taps need 14.2, AetherEngine needs 15. What does sudamp support?
- When will mpv 0.42 be tagged (it would include the coreaudio fix and the curl stream backend)? Pin master or patch 0.41.0 until then?
- Is an approximated (band-resynthesised) oscilloscope acceptable for v1, or is a true PCM scope a hard requirement?

## OPTIONS
- A. libmpv via a sudamp fork of the MPVKit build (LGPL): Recommended production path.
- B. Stock MPVKit SwiftPM package (product "MPVKit"): Use for the first prototype (player, EQ, Now Playing, yt-dlp). Replace with option A before the visualiser and before release.
- C. Homebrew mpv/ffmpeg dylibs + dylibbundler: Dev and experimentation only (e.g. test visualiser graphs quickly with the mpv CLI). Not for distribution.
- D. IINA's prebuilt dylibs (iina.io/dylibs/arm64): Only sensible if sudamp chooses GPLv3 and wants a stopgap. Option A is better.
- E. URL resolution inside mpv (ytdl_hook): Keep as a fallback or debug mode only.
- F. URL resolution in sudamp (yt-dlp -J, then direct URL to mpv): Recommended.
- G. Visualiser via lavfi tap in the af chain: Recommended default visualiser.
- H. Visualiser via Core Audio process tap on own PID: Optional 'high-fidelity visualiser' toggle later, after testing whether it prompts.
- I. AVPlayer + yt-dlp: Rejected as the main engine.
- J. VLCKit: Not preferred over libmpv.
- K. FFmpeg (libav*) + AVAudioEngine own engine (or AetherEngine): Plan B if the libmpv visualiser tap proves inadequate.

## VERIFICATION CHECKS (non-confirmed)
- [refuted] Winamp EQ live control: `af-command eq g <dB> b<i>` and `af-command eq volume <dB>dB pre`, where `b3`/`pre` are the `@inst` names inside the lavfi graph (`equalizer@b3=…`, `volume@pre=…`).
    CORRECTION: FFmpeg names a filter given as `equalizer@b3` with the full string "equalizer@b3". graphparser.c L548-551 does `snprintf(name, …, "%s@%s", f->name, p->instance_name)`. avfilter_graph_send_command (avfiltergraph.c L1496) only matches a target that is exactly filter->name, the filter type name, or "all". So target `b3` matches nothing: you get ENOSYS and mpv's af-command fails. Target `equalizer` would change all 10 bands at once. Use `af-command eq g 4.5 equalizer@b3` and `af-command eq volume 3dB volume@pre`. The rest of the claim holds: biquad process_command calls config_filter(outlink, 0), so filter state is kept, and superequalizer has no runtime commands.
    SRC: https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavfilter/graphparser.c (L359-362, L548-551); https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavfilter/avfiltergraph.c (L1478-1503); https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavfilter/af_biquads.c (L1413-1424)
- [refuted] Install the EQ chain once at startup and change gains with af-command, which 'never rebuilds the filter chain', so there are no gaps and the gains persist.
    CORRECTION: af-command doesn't rebuild the graph, but mpv does, on its own: every seek and every file load runs reset_playback_state → mp_filter_reset(filter_root) → lavfi_reset → free_graph. Format changes and EOF draining also free the graph. The graph is then re-parsed from the original graph_string, which still says g=0, so every af-command change is thrown away. On a new random stream the EQ silently goes flat. Also, lavfi_command returns false while the graph isn't initialised (`if (!c->initialized) return false;`), so re-sending gains straight after loadfile or a seek can fail. Fix: keep the `af` option string in sync with the current gains. Setting it between files costs nothing, and mp_output_chain_update_filters reuses unchanged filters via m_obj_settings_equal, so the viz tap isn't touched. Use af-command only during slider drags, and re-apply after PLAYBACK_RESTART or audio reconfig. Or, since we own the build, patch f_lavfi to replay commands when it rebuilds the graph.
    SRC: https://raw.githubusercontent.com/mpv-player/mpv/master/filters/f_lavfi.c (L788-830, L932); https://raw.githubusercontent.com/mpv-player/mpv/master/player/playloop.c (L253-258, L422); https://raw.githubusercontent.com/mpv-player/mpv/master/filters/f_output_chain.c (L602-622)
- [partially-true] mpv 0.41.0 is the latest release. #18274 (ao_coreaudio hotplug SIGSEGV on macOS 26/27) is fixed by 'one-commit patch' c5d391ad (2026-08-18); Homebrew backports it; MPVKit main has only 3 libmpv patches and no fix; audio-format=float is a workaround; ao=avfoundation causes high CPU.
    CORRECTION: Mostly correct. v0.41.0 (21 Dec) is still 'Latest'. c5d391ad was authored 2026-08-18. Homebrew mpv.rb (revision 11) backports exactly that commit with `resolves …/issues/18274`. MPVKit's patch/libmpv has only 0001-0003. The audio-format=float and avfoundation 100%-CPU reports are both in the thread. But the fix landed as PR #18383 (merged 2026-09-01) with two commits. The other one, 'ao_coreaudio: cleanup ao on init failure', releases resources when init fails, and init failure (floatp on macOS 27) is the trigger. The fork should carry both commits. A tester confirmed master 3186d36 ran 10/10 without crashing. Prior art: the Drvolks/MPVKit fork (branch 0.41.0-drvolks) carries 0007-ao-coreaudio-fix-hotplug-cb-use-after-free.patch, and edde746/mpv-build has its own unregister-on-failure commit.
    SRC: https://github.com/mpv-player/mpv/releases; https://github.com/mpv-player/mpv/issues/18274; https://github.com/mpv-player/mpv/pull/18383; https://github.com/mpv-player/mpv/commit/c5d391adba7bd024954d0df1e0405f5749f4d4ca.patch; https://raw.githubusercontent.com/Homebrew/homebrew-core/main/Formula/m/mpv.rb; https://github.com/mpvkit/MPVKit/tree/main/Sources/BuildScripts/patch/libmpv
- [partially-true] MPVKit's latest release is 1.1.0-n9.0.2 (2026-10-07: mpv 0.41.0, FFmpeg n9.0.2, libplacebo 7.360.1, MoltenVK 1.4.2). The README says it's 'only suitable for learning libmpv' and points to AetherEngine. It's LGPL-3.0, macOS 12+, and links LuaJIT on macOS only.
    CORRECTION: The versions, README quote, AetherEngine pointer, LGPL-3.0 licence, `.macOS(.v12)` and the macOS-only Libluajit are all confirmed. The build script passes -Dgpl=false, -Dlua=luajit, -Dcoreaudio/-Davfoundation=enabled, -Dcplayer=false and -Djavascript=disabled. But 1.1.0-n9.0.2 is marked pre-release. The 'Latest' stable is 1.0.0 (25 Jul 2026: mpv 0.41.0 + FFmpeg n8.1.2). Pinning `exact: "1.1.0-n9.0.2"` pins a pre-release. The package also links both OpenSSL 3.3.5 and GnuTLS/gmp/nettle, which matters for the licence and size inventory.
    SRC: https://github.com/mpvkit/MPVKit/releases; https://raw.githubusercontent.com/mpvkit/MPVKit/main/README.md; https://raw.githubusercontent.com/mpvkit/MPVKit/main/Package.swift; https://raw.githubusercontent.com/mpvkit/MPVKit/main/Sources/BuildScripts/XCFrameworkBuild/main.swift (L394-432)
- [outdated] AVPlayer has no EQ or visualiser on HLS because MTAudioProcessingTap isn't available for HLS (Apple DTS). With the WebM/Opus gap, that rules AVPlayer out.
    CORRECTION: MTAudioProcessingTap still isn't supported for HLS. DTS restated this in Jul 2025, so EQ on HLS is still blocked. But macOS 27.0 / iOS 27 add AVPlayerItemSampleBufferOutput, which delivers decoded PCM CMSampleBuffers and is 'Currently supported for HLS AVPlayerItems only, and only for delivering decoded PCM audio' (API_AVAILABLE(macos(27)) in the local SDK header). An Apple engineer pointed to the WWDC 2026 HLS session for this in Jun 2026, and one Aug 2026 forum report says it returned no data on a device. So the visualiser half of the argument is outdated on macOS 27+. The local isPlayableExtendedMIMEType check is confirmed: audio/webm;codecs=opus is false, ogg/opus, HLS and m4a are true. Rejecting AVPlayer still stands on WebM/Opus and EQ.
    SRC: https://developer.apple.com/forums/thread/45966; https://developer.apple.com/documentation/avfoundation/avplayeritemsamplebufferoutput; local SDK AVFoundation.framework/Headers/AVPlayerItemSampleBufferOutput.h (L19-86); local /tmp/fc-sudamp/swifttest/av.swift
- [partially-true] Prior art: vivi, a libmpv player, shipped exactly this lavfi tap design in October 2026: asetnsamples → asplit → mono → 48 bandpass → amerge → astats → ametadata print to tcp, then anullsink. A reader matches frames to time-pos.
    CORRECTION: Confirmed. tap.rs at commit 9b03b77 has the graph string as described and uses the libmpv2 Rust crate. Issue #71 was opened and closed on 2026-10-15, and the feature shipped in v0.9.1 the same day. But vivi is days-old: ten releases between Oct 13 and 20, from one author. 'Proven in a shipping player' is weak evidence of robustness. It syncs to time-pos, not audio-pts. mpv's docs warn that audio-pts 'can lead to negative values… in general you probably want to simply use time-pos'.
    SRC: https://github.com/Loafer19/vivi/issues/71; https://raw.githubusercontent.com/Loafer19/vivi/9b03b77aceba854fd6c99ec289589907a6bb078b/src/viz/tap.rs; https://github.com/Loafer19/vivi/releases; https://raw.githubusercontent.com/mpv-player/mpv/master/DOCS/man/input.rst (audio-pts)
- [partially-true] Per-file `stream-lavf-o=request_size=…,reconnect=1,reconnect_streamed=1,reconnect_delay_max=10` handles long mixes, and ytdl_hook maps http_chunk_size to request_size. The recommendation offers 'mpv 0.41.0 + patch, or a pinned master'.
    CORRECTION: Correct for 0.41.0: these are FFmpeg http.c AVOptions, and reconnect_delay_max defaults to 120. On master (0.42-dev), when mpv is built with libcurl, http(s) URLs go through a new libcurl stream backend instead of FFmpeg (`--curl-enabled`, default yes). There the stream-lavf-o http options don't apply; the equivalents are `curl-max-request-size` and `curl-max-retries`. Master's ytdl_hook sets both curl-max-request-size and request_size. The docs say non-seekable transfers can't be retried. If sudamp pins master, it must switch to the curl-* options or build with -Dlibcurl=disabled.
    SRC: https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/http.c (L203-229); https://raw.githubusercontent.com/mpv-player/mpv/master/DOCS/man/options.rst ('Network backend (libcurl)', --curl-*); https://raw.githubusercontent.com/mpv-player/mpv/master/player/lua/ytdl_hook.lua (L874-886); https://raw.githubusercontent.com/mpv-player/mpv/master/meson.options (libcurl auto)
- [partially-true] AetherEngine: LGPL-3.0 with an App Store exception, Swift 6.0+, macOS 15+, SwiftPM, LoadOptions.audioOnly, opt-in installAudioTap() (mono Float32 48 kHz with PTS), bundled FFmpeg without network support. Implication: its AVPlayer HLS path would hit the same no-tap limit.
    CORRECTION: The licence, macOS 15, audioOnly, installAudioTap and 'the bundled FFmpeg is built without network support' are all confirmed. But Package.swift is swift-tools-version 6.1, not 6.0. And the README says the tap 'delivers on the loopback, remote-HLS (VOD + live), and software paths', which contradicts the report's implication about the HLS path. It also ships FFmpeg as dynamic LGPL-2.1+ frameworks (FFmpegBuild) to keep relinking possible.
    SRC: https://raw.githubusercontent.com/superuser404notfound/AetherEngine/main/README.md (L19, L73, L78, L503, L699); https://raw.githubusercontent.com/superuser404notfound/AetherEngine/main/Package.swift
- [partially-true] VLCKit: LGPL-2.1+, stable 3.7.4 (2026-09-30), 4.0.0-a25 alpha. Distributed via CocoaPods/Carthage, 'No SwiftPM'.
    CORRECTION: The tags and dates are confirmed: 3.7.4 and 4.0.0-a25, both 2026-09-30. The README's LGPLv2.1+ and 'not supported by QuickTime / AVFoundation' wording is confirmed. But VLCKit master (the 4.0 line) now has a Package.swift (swift-tools 5.9, macOS 10.13+) with a binaryTarget pointing at download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260929-1631.zip. The 3.7.4 tag has no Package.swift.
    SRC: https://code.videolan.org/api/v4/projects/videolan%2FVLCKit/repository/tags; https://code.videolan.org/videolan/VLCKit/-/raw/master/Package.swift; https://code.videolan.org/videolan/VLCKit/-/raw/master/README.md
- [unverifiable] Core Audio process taps are macOS 14.2+ and need NSAudioCaptureUsageDescription, and the first recording from a tap aggregate device triggers a system-audio-recording prompt. No self-tap exemption is documented.
    CORRECTION: Apple's doc text is confirmed verbatim, including 'The first time you start recording from an aggregate device that contains a tap, the system prompts you to grant the app system audio recording permission.' Whether tapping only your own PID skips the prompt is not documented either way, and I found no field report. One report says the prompt fires at AudioDeviceStart, not at tap creation. It has to be tested, as the report already lists in its open questions.
    SRC: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps; https://dev.to/nickdelv/2000-buffers-of-nothing-3i8; https://github.com/insidegui/AudioCap

## CONFIRMED CLAIMS
- MPVKit's FFmpeg uses --disable-filters plus a whitelist. The audio filters are only aformat, amix, anull, aresample, areverse, asetrate, atempo, atrim, equalizer, firequalizer, pan, superequalizer and volume, so there's no asplit/amerge/bandpass/astats/ametadata/anullsink/alimiter.
- libmpv's built-in [libmpv] profile sets config=no, idle=yes, terminal=no, osc=no, input-default-bindings=no, input-media-keys=no and media-controls=no, so mpv won't compete for media keys.
- Swift 6.4 pitfall: a @convention(c) closure literal written inside a @MainActor method crashes in _dispatch_assert_queue_fail when mpv calls it from its own thread, and the compiler gives no warning. A nonisolated top-level func works.
- yt-dlp: latest is 2026.10.21. yt-dlp_macos is 37 MB and yt-dlp_macos.zip is 54 MB. YouTube needs an external JS runtime via EJS: Deno ≥2.3 is the only one enabled by default; Node ≥22, QuickJS/QuickJS-NG and Bun (deprecated) work via --js-runtimes. QuickJS before 2025-04-26 and QuickJS-NG before 0.1
- IINA facts: GPLv3. IINA 1.5.0 (2026-10-03) uses mpv 0.41.0 and FFmpeg 9.0.1 and needs macOS 12+ on Apple Silicon. download_libs.sh fetches yt-dlp_macos as youtube-dl. ytdl=no when the Online Media plugin is on. setAudioEq rebuilds 10 ISO-band equalizers via addAudioFilter. The dylibs include libluaj

## MISSED CONSIDERATIONS
- EQ persistence: mpv throws away the lavfi graph on every seek, every loadfile (every new random stream) and every audio format change, then re-parses the original string, so af-command gains are lost. af-command also fails until the new graph is initialised. The design needs one of: (a) write the current gains back into the `af` option (cheap between files; unchanged filters such as the viz tap are reused); (b) re-send gains after PLAYBACK_RESTART or audio-params changes, with a retry; or (c) a small f_lavfi patch in our fork that replays commands after a rebuild.
- The af-command target must be the full instance name (`equalizer@b3`, `volume@pre`). The same applies to any viz-tap commands.
- The viz tap's ametadata output (tcp/pipe) is reopened on every graph rebuild (seek, new file, format change). The reader must handle reconnects and PTS resets per file, not only at startup.
- Hotplug fix: backport both commits of mpv PR #18383 (e8414d9 'cleanup ao on init failure' plus c5d391ad), not only c5d391ad. The Drvolks/MPVKit fork patch is existing prior art. Add an automated Bluetooth/aggregate-device regression test on macOS 27.
- If pinning mpv master, the new default libcurl HTTP backend makes the stream-lavf-o reconnect and request_size advice moot (use curl-max-request-size and curl-max-retries, or -Dlibcurl=disabled). ICY handling also moves into stream_curl.c. Pick one target (0.41.0+patches or master) and write the option set for it.
- macOS 27 added AVPlayerItemSampleBufferOutput (decoded PCM for HLS items). That changes the AVPlayer comparison for visualisers on 27+, although WebM/Opus and EQ still rule AVPlayer out.
- Since sudamp will own the libmpv build anyway, a small mpv patch exposing post-filter PCM (a custom af or an ao-side tap) could give a true oscilloscope/FFT with no TCC prompt. mpv_audio_kit (BSD-3, mpv 0.41.0, custom 'libmpv-rNN' builds) advertises post-DSP PCM/FFT streams on macOS; I didn't verify its mechanism.
- Loudness consistency across random streams from different sources: consider dynaudnorm, loudnorm or ebur128 plus alimiter in the custom FFmpeg whitelist (none are in MPVKit's), especially with a +12 dB EQ preamp.
- YouTube 24/7 live exposes only muxed HLS formats 91-96. With vid=no, mpv still downloads video segments, so pick the lowest variant whose audio bitrate is acceptable (from memory, 91/92 carry lower-bitrate audio than 93+). Watch PO-token/SABR changes; a PO-token provider plugin may become necessary.
- Distribution: Mac App Store is effectively ruled out, because running a downloaded or updated yt-dlp is incompatible with the sandbox and App Review rules. Plan for Developer ID with notarisation. PyInstaller onefile extracts unsigned dylibs at runtime, which works against hardened runtime and library validation; another reason for onedir.
- Size budget: Deno v2.9.8 is about 81.5 MB uncompressed, plus about 54 MB for onedir yt-dlp. QuickJS-NG v0.17.0 is 1.26 MB, so benchmark it first.
- Simpler event-loop alternative: a dedicated thread blocking in mpv_wait_event(h, -1) avoids the wakeup-callback isolation hazard altogether. If a callback is kept, an explicit @Sendable/nonisolated function is required.
- audio-pts can be negative, and mpv itself recommends time-pos. Choose and measure the sync clock rather than assuming audio-pts is better.

## RECOMMENDATION ASSESSMENT
The overall direction is still sound: libmpv from our own LGPL build, a sudamp-owned yt-dlp resolver with ytdl=no, a lavfi visualiser tap, and our own Now Playing and remote commands. The Swift 6 isolation advice also holds; I reproduced the crash with Swift 6.4. AVPlayer remains a poor main engine because it can't play WebM/Opus and has no EQ on HLS.

The EQ section needs a rewrite before anyone builds on it:
1. The af-command targets must be `equalizer@b<i>` and `volume@pre`.
2. "Install once, change only via af-command" doesn't persist. mpv rebuilds the lavfi graph from the original string on every seek, file load and format change, so sudamp must keep the `af` string in sync with the gains, re-apply them after PLAYBACK_RESTART, or patch f_lavfi.

Other changes I'd make:
- **Hotplug crash:** backport both commits of PR #18383, not only c5d391ad, and run a device-change regression test on macOS 27.
- **Prototype pin:** note that MPVKit 1.1.0-n9.0.2 is a pre-release. Either use it knowingly or use 1.0.0.
- **mpv version:** decide between 0.41.0+patches and a pinned master now. Master's libcurl backend changes which network options work (curl-* instead of stream-lavf-o).
- **AVPlayer rationale:** rewrite it for macOS 27. AVPlayerItemSampleBufferOutput now gives PCM for HLS, so drop the "no visualiser on HLS" argument.
- **AetherEngine:** its tap does work on remote HLS. That makes it a slightly stronger plan B than the report suggests, though it has no EQ.
- **Visualiser:** since we own the build, weigh a small libmpv PCM-tap patch against the bandpass/astats/ametadata text pipeline. The tap's only shipping example is a project that is days old.
- **Size and distribution:** budget about 80 MB for Deno, or prove QuickJS-NG ≥0.12 is fast enough. Treat Developer ID (not the App Store) as the only distribution channel.
