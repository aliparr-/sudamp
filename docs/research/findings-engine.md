- [high] IINA is GPL-3.0, a Swift/AppKit app on libmpv with no library or framework product. IINA 1.5.0 (2026-10-03) moved to mpv 0.41.0 and FFmpeg 9.0.1 and requires macOS 12+ on Apple Silicon. Its libmpv is configured in iina/MPVController.swift (mpvInit: mpv_create, options, mpv_set_wakeup_callback, mpv_observe_property, mpv_initialize, then vo=libmpv).
  => sudamp can't embed IINA. Copying any IINA code makes sudamp GPLv3. If sudamp is to be MIT/Apache, treat IINA as reference only and write the wrapper from scratch.
  (https://github.com/iina/iina (LICENSE = GPLv3 via api.github.com/repos/iina/iina); https://github.com/iina/iina/releases/tag/v1.5.0; https://raw.githubusercontent.com/iina/iina/develop/iina/MPVController.swift)
- [high] IINA's yt-dlp integration: other/download_libs.sh downloads https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos to deps/executable/youtube-dl. PlayerCore.startMPV() puts Utility.exeDirURL (Contents/MacOS) and the user pref ytdlSearchPath in front of PATH, so mpv's built-in ytdl_hook finds it. MPVController sets mpv `ytdl=no` when the Online Media plugin (io.iina.ytdl) is enabled; that plugin re-implements ytdl_hook.lua in JS and self-updates yt-dlp. The plugin system arrived in IINA 1.4.0, and 1.5.0 added a plugin store. IINA's prebuilt dylibs (iina.io/dylibs/arm64/filelist.txt) include libluajit-5.1.2.dylib and libmpv.2.dylib.
  => The proven pattern is to bundle yt-dlp_macos and either let ytdl_hook find it or drive it yourself. sudamp should drive it itself (see recommendation) and add an in-app yt-dlp updater like IINA's plugin.
  (https://raw.githubusercontent.com/iina/iina/develop/other/download_libs.sh; iina/PlayerCore.swift line ~650; iina/MPVController.swift line ~564; https://github.com/iina/plugin-online-media; https://github.com/iina/iina/releases/tag/v1.4.0)
- [high] IINA files worth studying:
- MPVController.swift: init options, event loop (readEvents/handleEvent), property observing, chkErr.
- MPVNode.swift: mpv_node ↔ Swift conversion.
- MPVFilter.swift: filter string build/parse.
- PlayerCore.swift: setAudioEq at ~L1689; startMPV PATH handling.
- NowPlayingInfoManager.swift.
- RemoteCommandController, which lives inside AppDelegate.swift at ~L1362.
- MiniPlayerWindowController.swift: 'music mode', a compact window with album art and playlist; the autoSwitchToMusicMode pref defaults to true for audio files.
- Equalizations.swift: 22 EQ presets.
- MPVOption/MPVProperty/MPVCommand.swift: generated from mpv docs by other/parse_doc.rb.
IINA has no visualiser.
  => Read these to design sudamp's own MPVCore, NowPlaying and mini-window, but reimplement them. The 'no visualiser' point comes from browsing the source, not an explicit statement.
  (https://api.github.com/repos/iina/iina/git/trees/develop?recursive=1 plus the raw files; Preference.swift keys autoSwitchToMusicMode/musicModeShowAlbumArt)
- [high] IINA's EQ is 10 lavfi `equalizer` filters at ISO frequencies (32 Hz to 16 kHz, t=h, width=f/1.2247). On every slider change it rebuilds the whole labelled lavfi filter with addAudioFilter instead of using af-command.
  => Don't copy this approach. Rebuilding the chain reinitialises the filters. sudamp should install the chain once and change gains with af-command.
  (iina/PlayerCore.swift setAudioEq(fromGains:) https://raw.githubusercontent.com/iina/iina/develop/iina/PlayerCore.swift)
- [high] MPVKit (LGPL-3.0 package):
- Two products: `MPVKit` (LGPL, built with -Dgpl=false) and `MPVKit-GPL`.
- Latest release 1.1.0-n9.0.2 (2026-10-07): mpv v0.41.0, FFmpeg n9.0.2, libplacebo 7.360.1, MoltenVK 1.4.2.
- Package.swift requires macOS 12+. Libluajit is linked only on macOS, and its build uses -Dlua=luajit and -Dcoreaudio/-Davfoundation=enabled on macOS.
- The xcframeworks are static archives. I verified that the arm64 libmpv slice contains player_lua.c.o, ao_coreaudio.c.o and ao_avfoundation.m.o, and that the strings '@ytdl_hook.lua' and 'ytdl_path' are embedded.
- arm64 static slice sizes: libmpv 6.3 MB, libavcodec 10.6 MB, libavformat 2.6 MB, libavfilter 1.2 MB, plus MoltenVK, shaderc, libplacebo, dav1d, ass and TLS libraries.
- The README now says 'MPVKit is only suitable for learning libmpv and will not be maintained too frequently' and points to AetherEngine for production.
  => `.package(url: "https://github.com/mpvkit/MPVKit.git")` plus product "MPVKit" gives a working LGPL libmpv with ytdl_hook today. Good for a prototype, but plan to own the build.
  (https://github.com/mpvkit/MPVKit (README, Package.swift); https://github.com/mpvkit/MPVKit/releases/tag/1.1.0-n9.0.2; local nm/ar/strings inspection of Libmpv.xcframework (macos-arm64_x86_64))
- [high] MPVKit's FFmpeg is configured with `--disable-filters` plus a whitelist. The only audio filters in the macOS libavfilter are aformat, amix, anull, aresample, areverse, asetrate, atempo, atrim, equalizer, firequalizer, pan, superequalizer and volume. There is no asplit, amerge, bandpass, astats, aspectralstats, ametadata, asetnsamples, anullsink or alimiter. The demuxers (hls, dash, mov, matroska, ogg, mp3, aac, flac) and protocols (https, tls, icecast, unix, pipe) cover YouTube, SoundCloud and Mixcloud.
  => The Winamp EQ works on stock MPVKit. Any lavfi-based visualiser tap needs a custom FFmpeg build (a fork of this script with extra --enable-filter flags).
  (https://raw.githubusercontent.com/mpvkit/MPVKit/main/Sources/BuildScripts/XCFrameworkBuild/main.swift (filter list ~L742); local `nm` of Libavfilter/Libavformat arm64 slices)
- [high] mpv 0.41.0 (2025-12-21) is still the latest tagged release; master is 0.42-dev and adds a curl stream backend and client API 2.6. ao_coreaudio has a SIGSEGV in hotplug_cb on audio device change (Bluetooth connect/disconnect) on macOS 26/27 (mpv #18274, reproduced 5/5 on 0.41.0 on macOS 27.0). It was fixed on master by PR #18383 / commit c5d391ad ('ao_coreaudio: register hotplug after succesful audiounit init', 2026-08-18). Homebrew's mpv.rb backports that commit. MPVKit main has only three libmpv patches (moltenvk context, static build, tvOS avfoundation), so it has no fix. A reported workaround is `audio-format=float`; `ao=avfoundation` was reported to cause high CPU.
  => Plugging in AirPods would crash sudamp on the dev machine's OS unless our libmpv carries this patch. It's a must-have in the fork.
  (https://api.github.com/repos/mpv-player/mpv/releases; https://github.com/mpv-player/mpv/issues/18274; https://github.com/mpv-player/mpv/commit/c5d391adba7bd024954d0df1e0405f5749f4d4ca; https://raw.githubusercontent.com/Homebrew/homebrew-core/main/Formula/m/mpv.rb; MPVKit Sources/BuildScripts/patch/libmpv)
- [high] Bundling Homebrew mpv with dylibbundler is a poor fit for distribution:
- The formula (revision 11) depends on ffmpeg built with --enable-gpl --enable-version3 (GPLv3), and on vapoursynth, rubberband, libplacebo, molten-vk, vulkan-loader, mujs, luajit, libarchive and yt-dlp.
- Its bottles are built per OS (arm64_golden_gate = macOS 27), so the dylibs' minimum OS is the build machine's.
- mpv's meson build makes libass and libplacebo mandatory and defaults to gpl=true.
  => Fine for local experiments (brew install mpv). Don't ship it: it would be GPLv3, pull in a huge dependency tree and only run on macOS 27+.
  (https://raw.githubusercontent.com/Homebrew/homebrew-core/main/Formula/m/mpv.rb; .../Formula/f/ffmpeg.rb; https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/meson.build and meson.options)
- [high] libmpv API rules:
- mpv_create() uses the built-in [libmpv] profile: config=no, idle=yes, terminal=no, osc=no, input-default-bindings=no, input-media-keys=no, media-controls=no.
- mp_create refuses to start unless LC_NUMERIC is 'C' or 'C.UTF-8', and prints 'Non-C locale detected'.
- The wakeup callback may be called from any thread, may be re-entrant, and must not call any client API function. Respond to it by draining mpv_wait_event(h, 0) until MPV_EVENT_NONE on another thread.
- The API is thread-safe but serialised by one core lock.
- Async calls (mpv_command_async) can be reordered and their replies arrive as events matched by reply_userdata.
- Event pointers are only valid until the next mpv_wait_event.
- mpv may spawn subprocesses (e.g. ytdl), so the host must not reap SIGCHLD globally.
  => Wrapper design: call setlocale(LC_NUMERIC,"C") first. Use one serial DispatchQueue that owns the handle and drains events. Copy event data into Sendable Swift values before hopping to the MainActor.
  (https://raw.githubusercontent.com/mpv-player/mpv/master/include/mpv/client.h; https://raw.githubusercontent.com/mpv-player/mpv/master/etc/builtin.conf; https://raw.githubusercontent.com/mpv-player/mpv/master/player/main.c (check_locale))
- [high] Swift 6 pitfall, reproduced locally with Apple Swift 6.4 on macOS 27.0.1. A `@convention(c)` closure literal written inside a @MainActor method (IINA's `mpv_set_wakeup_callback(self.mpv, { ctx in ... }, ...)` pattern; my test used pthread_create) crashes with EXC_BREAKPOINT in `_dispatch_assert_queue_fail ← _swift_task_checkIsolatedSwift` when called from a background thread. This happens with and without `-default-isolation MainActor`. The compiler also accepted mutating main-actor state inside that closure with no diagnostic. Defining the callback as a top-level `nonisolated func`, or as a `nonisolated static let cb: @convention(c) ...`, runs correctly off the main thread.
  => In sudamp's MPVCore, the wakeup callback must be a nonisolated free function that only does `queue.async { drain() }`. Wrap mpv_handle (OpaquePointer, not Sendable) in a `final class MPVHandle: @unchecked Sendable`, and use passRetained/release so shutdown can't leave a dangling context.
  (local experiment: /tmp/sudamp-research/scripts/iso/main.swift, main2.swift, main3.swift (crash report showed _dispatch_assert_queue_fail / swift_task_isCurrentExecutorWithFlagsImpl))
- [high] Properties sudamp needs, per mpv's input docs and source:
- media-title: title tag, else filename; ytdl_hook sets force-media-title.
- metadata (MPV_FORMAT_NODE_MAP; metadata/by-key/<k>). Radio ICY 'StreamTitle' appears as key `icy-title` (common/network.c mp_parse_icy_metadata), and mpv sends 'Icy-MetaData: 1' by default.
- duration: absent for live.
- time-pos.
- audio-pts: updates more often than time-pos and includes audio driver delay, which suits visualiser sync.
- pause, volume.
- demuxer-cache-state: seekable-ranges, cache-end, cache-duration, fw-bytes, raw-input-rate.
- paused-for-cache, cache-buffering-state, core-idle.
- audio-params: format, samplerate, channels.
- eof-reached: only meaningful with keep-open.
- idle-active.
- af/vf: readable and writable as a NODE array of {name,label,enabled,params}, which avoids string escaping.
  => Observe: pause (FLAG), volume/time-pos/duration (DOUBLE), media-title (STRING), metadata/demuxer-cache-state/audio-params (NODE), idle-active/paused-for-cache (FLAG). Watch END_FILE events for errors. Use icy-title for 24/7 radio 'now playing'.
  (https://raw.githubusercontent.com/mpv-player/mpv/master/DOCS/man/input.rst; https://raw.githubusercontent.com/mpv-player/mpv/master/stream/network.c; .../DOCS/man/options.rst (--http-header-fields example))
- [high] ytdl_hook details (mpv master):
- If `vid=no`/`video=no` is set and ytdl-format is empty, it requests `bestaudio/best`.
- It runs `<ytdl> --no-warnings -J --flat-playlist ... --format <fmt> --no-playlist -- URL`.
- script-opts `ytdl_hook-ytdl_path` takes a ':'-separated list (defaults yt-dlp, yt-dlp_x86, youtube-dl), searched in config dirs then PATH.
- The default `include` list only covers YouTube and Twitch, so SoundCloud/Mixcloud page URLs are first tried by FFmpeg unless `ytdl_hook-try_ytdl_first=yes` is set or the URL is prefixed `ytdl://`.
- It copies yt-dlp's http_headers, user-agent and cookies (as a memory:// cookies-file) and maps downloader_options.http_chunk_size to stream-lavf-o request_size.
- It publishes the raw subprocess result at `user-data/mpv/ytdl/json-subprocess-result`.
- `--prefetch-playlist` 'does not work with URLs resolved by the youtube-dl wrapper'.
  => If you self-resolve, copy what the hook does (headers, cookies, request_size) and set ytdl=no, or mpv will spawn yt-dlp again on a failed googlevideo URL. If you use the hook, read json-subprocess-result to show errors.
  (https://raw.githubusercontent.com/mpv-player/mpv/master/player/lua/ytdl_hook.lua (L895-1004, L840-887); DOCS/man/options.rst --ytdl / --vid / --prefetch-playlist)
- [high] FFmpeg's http protocol supports `request_size` (chunked range requests), `reconnect`, `reconnect_streamed`, `reconnect_on_http_error` and `reconnect_delay_max` (default 120 s). mpv passes these through `stream-lavf-o`.
  => For multi-hour mixes on self-resolved URLs, pass per-file options like `stream-lavf-o=request_size=10485760,reconnect=1,reconnect_streamed=1,reconnect_delay_max=10` through loadfile's options argument.
  (https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/http.c (AVOption table ~L203-226); mpv options.rst --stream-lavf-o)
- [high] yt-dlp state of play:
- Latest release 2026.10.21 (the brew 2026.08.19 is behind). yt-dlp_macos is 37 MB (PyInstaller onefile); yt-dlp_macos.zip is 54 MB (onedir, faster start).
- YouTube JS challenges need an external runtime through EJS. Deno ≥2.3 is the only one enabled by default; Node ≥22, QuickJS / QuickJS-NG and Bun (deprecated) work via `--js-runtimes`. QuickJS before 2025-04-26 and QuickJS-NG before 0.12.0 can take minutes.
- The EJS scripts are bundled inside yt-dlp_macos.
- Without a runtime, users report 'n challenge solving failed' and 'Only images are available for download'.
  => Bundling yt-dlp alone isn't enough for YouTube; sudamp must also ship a JS runtime (Deno, tens of MB, or QuickJS-NG ≥0.12, ~1-2 MB) and pass `--js-runtimes deno:<path>` or `quickjs:<path>`. yt-dlp must be updatable outside the signed bundle.
  (https://api.github.com/repos/yt-dlp/yt-dlp/releases; https://github.com/yt-dlp/yt-dlp/wiki/EJS; https://github.com/yt-dlp/yt-dlp/issues/15556)
- [high] EQ filters:
- FFmpeg `equalizer` (a biquad peaking filter) supports the runtime commands frequency/f, width_type/t, width/w, gain/g and mix/m.
- In a lavfi graph, `name@inst` sets instance name 'inst', and avfilter_graph_send_command matches target against the instance name, the filter name or 'all'.
- mpv's `af-command <label> <command> <argument> [<target>]` calls avfilter_graph_send_command on the labelled lavfi filter.
- `volume` accepts a runtime `volume` command.
- `superequalizer` has 18 fixed bands (65 Hz to 20 kHz) and no process_command, so changes need a chain rebuild.
- `firequalizer` accepts gain/gain_entry commands but is FIR with a default 10 ms delay.
  => Winamp EQ = `@eq:lavfi=[volume@pre=...,equalizer@b0=f=60...,...,equalizer@b9=f=16000...]`, changed live with `af-command eq g 4.5 b3`. Coefficients are recomputed and the biquad state is kept, so there should be no dropout. Zipper noise on fast slider drags is untested.
  (https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/doc/filters.texi (equalizer/superequalizer/firequalizer/volume); libavfilter/graphparser.c L359; libavfilter/avfiltergraph.c L1478-1500; libavfilter/af_superequalizer.c; mpv input.rst vf-command/af-command; mpv filters/f_lavfi.c L833)
- [high] libmpv has no PCM or audio callback API; the 2017 'pcm_cb' feature request (#4228) was never implemented. `ao=pcm` is a WAV/raw file writer that marks itself `ao->untimed = true`, so it runs faster than real time and can't feed the speakers at the same time. `af-metadata/<label>` only returns the metadata of the lavfi filter's first output pad's last frame (f_lavfi.c MP_FILTER_COMMAND_GET_META), so polling it loses frames and gives no timing.
  => Visualiser data has to come from a lavfi side-branch that streams metadata out of the graph, or from outside mpv (a Core Audio tap).
  (https://github.com/mpv-player/mpv/issues/4228; https://raw.githubusercontent.com/mpv-player/mpv/master/audio/out/ao_pcm.c (L164); mpv filters/f_lavfi.c L838-843; DOCS/client-api-changes.rst)
- [high] Prior art from October 2026: vivi, a libmpv player, replaced its second decode with a lavfi tap appended last to the af chain (label @vivi-viz). The graph is: `asetnsamples=n=1024:p=0,asplit[vo][vt]; [vt]aformat=channel_layouts=mono,asplit=49 → 48 log-spaced bandpass=f=..:t=q:w=4 (30 Hz-14 kHz) + full band → amerge=inputs=49,astats=metadata=1:reset=1:measure_perchannel=RMS_level:measure_overall=none,ametadata=mode=print:direct=1:file=tcp\\://127.0.0.1\\:PORT,anullsink; [vo]anull`. A reader thread parses `frame:… pts_time:` and `lavfi.astats.N.RMS_level=` lines (~47 frames/s) and picks the frame matching time-pos ('the filter runs ahead of the speakers by the audio buffer'). Scope and waveform modes are re-synthesised from the band levels.
  => This is a shipped, working template for sudamp's spectrum analyser with no extra permissions. Use 19-75 Winamp bands and sync to `audio-pts`, which accounts for the 200 ms default audio-buffer plus driver delay. It needs the custom FFmpeg filter set.
  (https://github.com/Loafer19/vivi/issues/71; commit https://github.com/Loafer19/vivi/commit/9b03b77aceba854fd6c99ec289589907a6bb078b (src/viz/tap.rs))
- [medium] Core Audio process taps: AudioHardwareCreateProcessTap and AudioHardwareDestroyProcessTap are macOS 14.2+. CATapDescription has initStereoMixdownOfProcesses:, privateTap and muteBehavior, plus bundleIDs and processRestoreEnabled from macOS 26. Apple's sample doc says that capturing with a tap requires NSAudioCaptureUsageDescription, and 'the first time you start recording from an aggregate device that contains a tap, the system prompts you to grant the app system audio recording permission'. No exemption for tapping your own process is documented. Field reports say a missing key or permission gives silence with noErr, that there is no public preflight API (projects dlopen TCC's TCCAccessPreflight), and that a stable signing identity is required.
  => A self-tap gives true post-mix PCM (real oscilloscope and FFT, latency of about one HAL buffer, ~10 ms, from memory) but probably triggers a scary 'record system audio' prompt. Keep it optional, off by default.
  (local SDK headers CoreAudio.framework/Headers/AudioHardwareTapping.h, CATapDescription.h; https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps (JSON); https://github.com/insidegui/AudioCap; https://dev.to/nickdelv/2000-buffers-of-nothing-3i8)
- [high] Other mpv visualisers (e.g. mfcc64/mpv-scripts visualizer.lua) use `lavfi-complex` with showcqt, showspectrum, showwaves or avectorscope, which produce video frames that mpv displays.
  => For sudamp this would need a render API (SW) surface and pixel reading, a poor fit for drawing a Winamp-style vis in our own skin. Treat it as a fallback idea only.
  (https://raw.githubusercontent.com/mfcc64/mpv-scripts/master/visualizer.lua)
- [high] Measured on this Mac (macOS 27.0.1, build 26A434) with AVURLAsset.isPlayableExtendedMIMEType:
- Not playable: audio/webm;codecs=opus, audio/webm, video/webm, audio/mp4;codecs=opus.
- Playable: audio/mp4;codecs=mp4a.40.2, audio/ogg;codecs=opus, audio/ogg;codecs=vorbis, application/vnd.apple.mpegurl (HLS), audio/mpeg, audio/aac, audio/x-caf;codecs=opus, audio/flac.
  => With AVPlayer, YouTube itag 140 (m4a AAC) and HLS work but itag 251 (webm/opus, usually the best YouTube audio) doesn't, so format selection is constrained.
  (local script /tmp/sudamp-research/scripts/avcheck.swift)
- [medium] Apple DTS (developer forums): 'The MTAudioProcessingTap is not available with HTTP live streaming', and there is no supported workaround.
  => An AVPlayer engine would have no EQ or visualiser on HLS sources: YouTube live, SoundCloud hls_aac/hls_opus/hls_mp3, Mixcloud HLS. That rules AVPlayer out as the main engine.
  (https://developer.apple.com/forums/thread/45966)
- [high] SoundCloud formats in yt-dlp: _DEFAULT_FORMATS = http_aac, hls_aac, http_opus, hls_opus, http_mp3, hls_mp3, including encrypted-hls (AES-128) handled as 'hls-aes'.
  => mpv/FFmpeg plays all of these. AVPlayer can play the AAC and MP3 variants but gives no processing tap on HLS.
  (https://raw.githubusercontent.com/yt-dlp/yt-dlp/master/yt_dlp/extractor/soundcloud.py L109, L308-372)
- [medium] VLCKit is LGPL-2.1+. Latest stable tag is 3.7.4 (2026-09-30); 4.0 is still alpha (4.0.0-a25, 2026-09-30). It's distributed via CocoaPods/Carthage, and VLCKit's own README says it's for media not supported by AVFoundation. From memory: libVLC has a built-in 10-band EQ whose default band set matches Winamp's (60…16k), and libvlc_audio_set_callbacks gives PCM only if the host does the audio output itself.
  => VLCKit is viable but heavier, has an ObjC API and an alpha 4.x line, and VLC's YouTube Lua scraper is weaker than yt-dlp. No clear win over libmpv.
  (https://code.videolan.org/api/v4/projects/videolan%2FVLCKit/repository/tags; https://code.videolan.org/videolan/VLCKit/-/raw/master/README.md; libVLC EQ/callback details from memory)
- [medium] AetherEngine (the project MPVKit now recommends) is an FFmpeg-demux / VideoToolbox / AVPlayer engine. It's licensed LGPL-3.0 with an App Store exception, needs Swift 6.0+ and macOS 15+, and is distributed via SwiftPM. Features relevant to sudamp: a `LoadOptions.audioOnly` lean pipeline, WebM/Opus via FFmpeg, and an opt-in `installAudioTap()` that delivers mono Float32 48 kHz PCM with source PTS. The README doesn't mention an EQ, and says its bundled FFmpeg has no network support (remote HLS goes to AVPlayer).
  => A credible plan-B base if sudamp later wants an AVFoundation-native engine with a PCM tap. It's young, from one maintainer, with no yt-dlp or EQ story, and its AVPlayer HLS path would hit the same no-tap limit.
  (https://raw.githubusercontent.com/superuser404notfound/AetherEngine/main/README.md; .../Package.swift)
- [high] Now Playing on macOS: MPNowPlayingInfoCenter.playbackState is macOS-only, and Apple says 'You must set this property every time the app begins or halts playback, otherwise remote control functionality may not work'. IINA (libmpv, no AVPlayer) uses MPNowPlayingInfoCenter.default() with MPNowPlayingInfoPropertyMediaType = .audio, title/artist/album, elapsed time, rate and artwork, plus MPRemoteCommandCenter play, pause, togglePlayPause, stop, next and previous targets. It removes those targets when idle (IINA issue #4331) and has a play-then-pause workaround so Now Playing doesn't fall back to Music.app. libmpv defaults to input-media-keys=no, so mpv won't grab the keys.
  => sudamp owns media keys with no Accessibility permission. Set MPNowPlayingInfoPropertyIsLiveStream for 24/7 streams, update elapsed time only on state changes or seeks, map nextTrack to 'next random stream', and disable commands when idle.
  (https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter/playbackstate (JSON); iina/NowPlayingInfoManager.swift; iina/AppDelegate.swift RemoteCommandController; mpv options.rst --input-media-keys)