# EVAL enginespike: sudamp engine pipeline spike: libmpv (MPVKit 1.0.0) + ao_pcm/FIFO vs in-process pull AO vs Option A lavfi EQ (macOS 27.0.1, CLT-only, M5 Pro)

## Summary
I tested this hands-on, not by reading code alone. SwiftPM with MPVKit 1.0.0 (product "MPVKit") resolves, builds and runs on this CLT-only machine. That gives a static libmpv: mpv v0.41.0, client API 2.5.

The literal Option B, ao=pcm writing into a FIFO or pipe, does pace itself in real time through backpressure. In 20 s of steady play it delivered 384,020 B/s with 0 underruns. It is still unsuitable, and the mpv source explains why: ao_pcm is "untimed", reports a fixed 65,536-sample device buffer with delay 0, and does a blocking fwrite while the AO thread holds buffer_state->lock. The mpv core takes that same lock in ao_get_delay, so the core thread is blocked about 1.3 s at a time.
- Measured costs: get_property p50 1286 ms; time-pos only updates in 1.393 s steps; `set pause` took 1.93 s; seek or skip gave 1.7–2.7 s of stale audio, or 0.9–1.1 s of silence with the best discard strategy.
- Hard deadlocks: any synchronous libmpv call, and mpv_terminate_destroy, hang for as long as the reader stops reading.

I found and validated a better Option B. libmpv is a static archive in which audio_out_ao_pcm.c.o exports only `_audio_out_pcm`, while ao_read_data and mp_time_ns are global. A ~90-line C target in sudamp can therefore define its own `audio_out_pcm` as a pull AO, the same pattern ao_coreaudio uses. The linker then takes sudamp's driver instead of mpv's file writer. An AVAudioSourceNode render block calls sudamp_ao_read(), which calls ao_read_data(). I verified this in debug and release builds.
- **Steady playback:** 0 short reads, 10.67 ms callbacks, get_property p50 7–11 µs, and time-pos within about one IO buffer of the audio actually rendered.
- **Transport:** pause reaches the render callback in ≤9.6 ms and resumes sample-continuous. A seek gives new audio in 9.6–10.8 ms with 0–1 stale quantum; loadfile takes 21.5–23.9 ms.
- **CPU and output DSP:** 1.1% of one core (release build). AVAudioUnitEQ measured exactly +12.00 dB per band and +6.00 dB for the preamp.
- **Network:** an HTTPS internet-radio stream played in 0.9 s with its ICY title.

Option A's EQ claims are all confirmed by measured output level:
- The target must be `equalizer@bN` (plain `bN` returns -12).
- Gains are lost on seek and on loadfile.
- An af-command sent right after a seek fails.
- Re-applying on PLAYBACK_RESTART works, and so does keeping the `af` string in sync (no glitch).

Upstream still has no PCM API: PR #16769, a libmpv callback AO, was closed unmerged on 2026-04-26.

Recommendation: build on libmpv for demux, decode and resample, deliver audio through the in-process pull AO into sudamp's own AVAudioEngine, and keep the render callback in C/ObjC. The FIFO variant and Option C should not be built; Option A stays as the fallback.

## Verdict
Build Option B, using a pull AO rather than a pipe: libmpv handles networking, demux, decode and resample, and sudamp's AVAudioEngine handles output, EQ, volume, balance, visualiser data and device changes. Do not build ao_pcm+FIFO, and do not build Option C. Keep Option A only as a fallback.

**Why this route**
- **ao=pcm into a FIFO or pipe** paces correctly, but by design it blocks the mpv core about 1.3 s at a time. Pause/seek/skip then take 1–2.7 s, and synchronous calls deadlock whenever the reader stalls; all of this was measured.
- **The pull AO** gives about 10 ms pause/seek, 24 ms local skip, accurate time-pos, no core stalls and 1.1% CPU. It needs no mpv source patch with stock MPVKit 1.0.0.
- **The coreaudio hotplug crash** (#18274) doesn't apply, because ao_coreaudio is never used; AVAudioEngine owns the device.
- **The visualiser no longer needs a custom FFmpeg filter set.** Its PCM comes from the render callback.

**Concrete mpv option set** (before mpv_initialize; setlocale(LC_NUMERIC,"C") first)
- `vid=no`, `audio-display=no`
- `ao=pcm` (resolves to sudamp's linked pull AO)
- `audio-samplerate=48000`, `audio-channels=stereo` (the AO forces planar float itself, so audio-format isn't needed)
- `audio-buffer=0.2` (default; this is mpv's queue and replaces any sudamp ring)
- `gapless-audio=weak` (default), `volume=100` (do volume in AVAudioEngine)
- `af=` empty (later possibly loudnorm/alimiter)
- `ytdl=no`, `cache=yes`, `demuxer-max-bytes=64MiB`, `demuxer-readahead-secs=30`, `network-timeout=15`
- Per-file loadfile options from the brief: `http-header-fields`, `user-agent`, `stream-lavf-o=request_size=…,reconnect=1,reconnect_streamed=1,reconnect_delay_max=10`.

**Host-side rules**
- Call `signal(SIGPIPE, SIG_IGN)`.
- Use only the async libmpv API from the UI.
- The event thread exits on SHUTDOWN and is joined before mpv_terminate_destroy.

**Architecture**
- **Pull AO in C.** sudamp_ao.c (about 90 lines, LGPL-2.1+ because it derives from mpv headers) defines `const struct ao_driver audio_out_pcm` as a pull AO: format AF_FORMAT_FLOATP, 2 channels, device_buffer 1024. It exposes `int sudamp_ao_read(float *L, float *R, int frames, int64_t delay_ns)`, which calls `ao_read_data(ao, planes, frames, mp_time_ns()+delay_ns, NULL, true, true)` under a trylock, exactly like ao_coreaudio's render_cb_lpcm. Vendor the needed mpv v0.41.0 headers into the target rather than using unsafeFlags.
- **Render callback outside Swift.** Write the AVAudioSourceNode render block in C/ObjC: Swift 6 isolation traps were reproduced, and Apple marks Swift unsupported for realtime threads. Per callback it:
  - outputs silence when a host-pause flag is set;
  - otherwise calls sudamp_ao_read with delay = presentationLatency + frames/rate;
  - copies the samples into a lock-free single-producer/single-consumer visualiser ring (e.g. 8192 frames).
- **Graph.** sourceNode(48 kHz stereo deinterleaved) → AVAudioUnitEQ(10 parametric bands at 60/170/310/600/1k/3k/6k/12k/14k/16k, bandwidth about 1 octave; preamp = globalGain; measured exact) → mainMixer (outputVolume; sourceNode.pan for balance, not measured) → output.
- **Visualiser.** Read the ring from a 60 Hz display link, with vDSP FFT for the spectrum and raw samples for the oscilloscope. Do not use installTap for it: it delivers 4800-frame/100 ms buffers. For a post-EQ visualiser, either run the EQ in C with vDSP_biquadm inside the render callback, or use mpv's lavfi EQ with the af string kept in sync. The first is untested; the second is verified.
- **Transport.** For pause, set the host flag (instant) and pause mpv asynchronously. For seek and skip, just send the command: mpv's ao_reset clears its queue, so there is no flush logic and at most one stale 10.7 ms quantum.
- **Device changes.** On AVAudioEngineConfigurationChange, pause mpv, re-query the output format, re-connect, engine.start(), then unpause; the pull AO never blocks mpv meanwhile. This is untested here.
- **Startup guard.** Read the `mpv-version` property and require a v0.41.x prefix. After the first file, require sudamp_ao_init_count()>0. In CI, run `strings` on the binary to confirm 'sudamp pull AO' is present and the ao_pcm description absent. If any check fails, fall back to ao=coreaudio (Option A).

**Glass-to-ear estimates** (built-in speakers)
- Pause: ≤1 IO period (measured 3–9.6 ms) plus about 1.3–2.3 ms output latency, so about 5–12 ms.
- Local or cached seek: about 10–12 ms. Local skip: about 25 ms.
- Network skip: open plus first decode, measured at 0.9 s for HTTPS MP3 radio. A yt-dlp resolution adds 1.2–4 s unless the next random item is pre-resolved (orchestrator notes).
- Bluetooth adds its own latency (not measured).

**Long-term**
- When sudamp owns its libmpv build, move the AO into the mpv tree as ao_sudamp (a normal patch).
- Optionally propose an upstream pull API. It sidesteps sfan5's #16769 objections: pause is visible as silence or core-idle, the format is fixed by options, and pull has no startup race.

**Option C (own FFmpeg + AVAudioEngine)** rejected, from reading the mpv source. It would mean re-implementing about 8–9k lines of mpv's demux cache, cache-pause and buffering state, ICY polling, reconnect defaults, HLS quirks, format-change resampling and EDL handling. The decode core would be the same FFmpeg, with no robustness gain for HLS live, long mixes or reconnects.

**Option A** keeps the verified EQ recipe:
- `equalizer@bN` / `volume@pre` targets;
- keep the af string in sync, or re-apply on PLAYBACK_RESTART;
- needs the #18383 hotplug patch and a custom FFmpeg for the visualiser tap.

## Reusable
- /tmp/sudamp-spike/engine/pkg/Sources/SudampAO/sudamp_ao.c + include/sudamp_ao.h + mpvcfg/config.h: the link-time pull-AO override (spike code). It is a derivative of mpv's LGPL-2.1+ internal headers, so license it LGPL-2.1+ (compatible with a GPL-3.0 sudamp). Before production use: vendor the headers, add the version guard, and put the render path in C/ObjC.
- /tmp/sudamp-spike/engine/pkg/Package.swift: working pattern for an MPVKit 1.0.0 dependency (product MPVKit, LGPL-3.0 package) plus a C target and two executables on CLT-only. Spike code, free to reuse.
- /tmp/sudamp-spike/engine/pkg/Sources/spikepull/main.swift: AVAudioEngine graph (source → AVAudioUnitEQ with Winamp bands → mixer), a preallocated render-thread log using Synchronization.Atomic, a CoreAudio default-device latency/buffer query, and a transport latency analysis. Spike code.
- /tmp/sudamp-spike/engine/pkg/Sources/spikepull/EQPull.swift: eqAF() lavfi EQ string generator with the verified af-command targets, plus a measurement harness for the Option A fallback. Spike code.
- /tmp/sudamp-spike/engine/pkg/Sources/spike/Common.swift: minimal libmpv wrapper (options, event thread, timed command/property calls) and the position-encoding ramp test-WAV generator. Spike code. Fix the event-thread/destroy ordering before reuse.
- /tmp/sudamp-spike/engine/pkg/Sources/spike/Consumer.swift + analysis/q1.py, q1b.py: real-time consumer model and analysis for any future pipe-based experiment. Spike code; reference only.
- /tmp/sudamp-spike/engine/iso6: 20-line repro of the Swift 6 @MainActor render-block crash and its nonisolated fix. Useful as a regression test.
- mpv v0.41.0 audio/out/ao_coreaudio.c render_cb_lpcm (LGPL-2.1+): reference for how a pull AO computes out_time for ao_read_data.
- Measurement data: /tmp/sudamp-spike/engine/run-q1-ring20ms, run-q1b-best, run-pull-engine, run-eq-pull, run-net (log.txt, mpv.log, CSV files).

## Experiments
- Do SwiftPM binary xcframework targets work on a CLT-only machine (MPVKit 1.0.0)?
  METHOD: Scratch package /tmp/sudamp-spike/engine/pkg (swift-tools 6.2, macOS 15) with `.package(url: MPVKit, exact: "1.0.0")`, product MPVKit; `swift package resolve && swift build`; run a binary that prints mpv_client_api_version()
  RESULT: Works. Resolve downloaded 271 MB, build took 14 s, linking is static, and the binary prints 131077 (API 2.5).
- Pipe and FIFO capacity on macOS 27
  METHOD: `spike pipecap`: non-blocking writes until EAGAIN
  RESULT: Anonymous pipe 65536 B; FIFO 8192 B; FIFO st_blksize 4096.
- Q1: does ao=pcm into a FIFO pace in real time under backpressure, and how do time-pos, pause, seek, loadfile, a stuck reader, EOF and reader-close behave?
  METHOD: `spike pipe 960 q1-ring20ms`. Options: ao=pcm, ao-pcm-file=<fifo>, ao-pcm-waveheader=no, audio-format=float, audio-samplerate=48000, audio-channels=stereo. The consumer thread pulls exactly 48 kHz with a 20 ms ring. Test file: 60 s 44.1 kHz WAV whose right channel is a ramp encoding the position. Monitor thread polls time-pos every 100 ms. Analysis: analysis/q1.py.
  RESULT: Rate 384,020 B/s with 0 underruns. Core blocked: get_property p50 1286 ms, time-pos steps of 1.393 s. Pause took 1.93 s to apply and leaked 1.97 s of audio; resume was continuous. Seek or skip played 1.7–2.7 s of stale audio under every flush strategy. A stuck reader made every synchronous API call hang (two harness deadlocks). After reader close (SIGPIPE ignored), mpv raced to EOF. At idle the AO closes (FIFO EOF) and reopens on the next loadfile.
- Q1b: best-case strategies for the FIFO path
  METHOD: `spike pipebest q1b-best`: discard everything from command until the SEEK/END_FILE event; keep 100 ms in the ring with up to 3 s of headroom for pause. Analysis: analysis/q1b.py.
  RESULT: Stale audio 20–31 ms, but 0.88–1.10 s of silence before new audio. Pause absorbed 1.86 s and the mpv pause call took 812 ms. API stalls stayed at 1.32 s p50. mpv_terminate_destroy hung after the reader thread stopped.
- /dev/fd/N variant
  METHOD: `spike devfd`: pipe() plus ao-pcm-file=/dev/fd/<writefd>
  RESULT: mpv opened '/dev/fd/6 (RAW PCM)' and played. Once the reader stopped, the next get_property hung, the same blocking behaviour as the FIFO.
- Link-time pull-AO override: sudamp-defined audio_out_pcm calling ao_read_data from an AVAudioSourceNode render block
  METHOD: C target Sources/SudampAO (sudamp_ao.c, built against the mpv v0.41.0 headers) plus executable spikepull: AVAudioSourceNode → AVAudioUnitEQ → mainMixer (outputVolume 0, silent) → output. Scripted actions: EQ change, mpv pause, host pause, seek, loadfile, stop, idle → loadfile. Ran in debug and release (`swift build -c release`).
  RESULT: Release build: 0 short reads, 10.67 ms callbacks, API p50 7 µs, pause 8.6 ms, unpause continuous, seek 9.6 ms with 0 stale frames, loadfile 23.9 ms with 0 stale frames, 1.1% CPU. AO initialised twice (the second after idle). No AVAudioEngineConfigurationChange fired; no device change was attempted.
- Q3: Option A lavfi EQ (af-command target naming and persistence)
  METHOD: `spikepull eq`: af=@eq:lavfi=[volume@pre,...,equalizer@b0..b9]; measure the 1 kHz RMS at the render callback in 1 s windows after each step. Also `spike eq null` and `spike eq coreaudio` (volume=0) to compare return codes.
  RESULT: All research corrections confirmed:
- `b4`/`pre` return -12; `equalizer@b4` gives +12.00 dB and `volume@pre` +6.00 dB.
- Gains are lost after seek and after loadfile.
- An af-command immediately after a seek returns -12.
- Re-applying on PLAYBACK_RESTART works, as does keeping the af string in sync (no glitch, persists).
- Target `equalizer` sets all bands; `all` returns -12 but applies partially.

MPVKit's missing asplit/astats/ametadata (the vis tap) was not tested here.
- Swift 6 isolation crash for render blocks
  METHOD: /tmp/sudamp-spike/engine/iso6: AVAudioSourceNode closure created in a @MainActor function (Swift 6 mode), then in a nonisolated function
  RESULT: @MainActor version: SIGTRAP in _swift_task_checkIsolatedSwift on com.apple.audio.IOThread.client. nonisolated version: runs (141 callbacks in 1.5 s).
- Public internet radio (HTTPS, ICY) through the pull-AO pipeline
  METHOD: `spikepull net https://ice1.somafm.com/groovesalad-128-mp3` (ytdl=no, cache=yes, network-timeout=15)
  RESULT: First audible render at 901 ms, 0 short reads, icy-title present, seekable=no, duration reported (27.6 s, growing).
- Q2: search for any upstream in-process PCM path
  METHOD: Read client.h, render.h and client-api-changes.rst in mpv master (488fec0); diffed audio/out with v0.41.0; GitHub issue search API; WebFetch of PR #16769; cloned mpv_audio_kit
  RESULT: No upstream API. PR #16769 (callback AO) closed unmerged on 2026-04-26; #9283 still open. The only PCM-tap prior art (mpv_audio_kit) relies on its own patched libmpv builds.
- ABI stability of the internals the pull AO uses
  METHOD: diff audio/out/internal.h, ao.h, chmap.h, format.h between v0.41.0 and master
  RESULT: internal.h, ao.h and chmap.h are identical. format.h only appends DSD formats, so the FLOATP value is unchanged.

## Risks
- The link-time override depends on mpv's internal ABI (struct ao layout, the ao_read_data signature, AF_FORMAT enum values). It must be recompiled against the exact libmpv tag in use, and a mismatch would corrupt memory silently. Mitigations: vendored headers pinned to a version, a startup check of mpv-version, a CI smoke test, and a fallback to ao=coreaudio. Upgrading MPVKit to 1.1.0-n9.0.2 (also mpv 0.41.0) should be ABI-identical, but that is unverified.
- The override only works because libmpv is a static archive whose ao_pcm member exports one symbol. A dynamic libmpv, -force_load/-all_load, or a future MPVKit/LTO change could make it silently ineffective (mpv's real ao_pcm would then try to write a file named audiodump.pcm) or cause a duplicate-symbol error. Check in CI that the binary contains 'sudamp pull AO' and not 'RAW PCM/WAVE', and check sudamp_ao_init_count() at runtime.
- ao_read_data(blocking=true) takes a pthread mutex on the realtime render thread, the same as mpv's own ao_coreaudio. Brief priority inversion is possible; no glitches were seen over about 2800 callbacks.
- Realtime code in Swift is fragile: the Swift 6 isolation trap was reproduced, and ARC or allocation in closures is a further hazard. Apple now marks Swift unsupported for realtime threads. Write the render block in C/ObjC.
- Not tested here:
- device hotplug and AVAudioEngineConfigurationChange handling (and the coreaudio #18274 crash);
- Bluetooth latency;
- HLS live, long DASH/progressive YouTube/SoundCloud/Mixcloud mixes, yt-dlp-resolved URLs;
- the x86_64 slice, MPVKit 1.1.0-n9.0.2;
- audible zipper noise on fast EQ drags;
- volume/pan behaviour in AVAudioMixerNode;
- vDSP visualiser CPU.

All latency figures are from the built-in Mac mini speakers.
- If someone builds the FIFO variant after all: blocked-core stalls (about 1.3 s), 1–2.7 s seek/skip, a hard deadlock whenever the reader stalls or exits before mpv_terminate_destroy, time-pos frozen in 1.4 s steps, and SIGPIPE must be ignored. All of these were measured or observed.
- Option A fallback caveats: the EQ gains must be kept in the af string or re-applied after PLAYBACK_RESTART (verified); `all` reports failure even when it partially applies; a visualiser tap needs a custom FFmpeg (filters missing from MPVKit, not re-tested here); and ao_coreaudio needs the #18383 hotplug patch.
- Licensing: sudamp_ao.c derives from LGPL-2.1+ mpv headers, and static linking of LGPL libmpv/FFmpeg carries relinking obligations. This is fine under the GPL-3.0-or-later default, but it remains a user decision.
- MPVKit is a 'learning only', lightly maintained upstream. Pin 1.0.0 (stable; 1.1.0-n9.0.2 is a pre-release) and plan to own the build.
- Live ICY streams report a growing `duration`, so detect live via `seekable=no` or the file format, not via a missing duration.

## Facts
- SwiftPM binary xcframework targets work on this CLT-only machine. `.package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.0.0")` with product "MPVKit" resolved: 100 artifacts, about 271 MB downloaded, 1.7 GB under .build. The first `swift build` took 14 s. The binary links libmpv and FFmpeg statically and runs, reporting mpv_client_api_version()=131077 (API 2.5). The only noise was two harmless ld warnings about missing CLT search paths. (/tmp/sudamp-spike/engine/pkg/Package.swift; /tmp/sudamp-spike/engine/resolve.log; `./.build/debug/spike` printed 'mpv client api version 131077'; otoo)
- MPVKit 1.0.0 builds mpv v0.41.0 plus three patches: moltenvk context, revert static build, and tvOS avfoundation ao. None of them touches audio/out internals. (/tmp/sudamp-spike/engine/dl-mpvkit-src/MPVKit/Sources/BuildScripts/XCFrameworkBuild/main.swift L51 returns "v0.41.0"; Sources/BuildScripts/patch/libmp)
- ao_pcm sets `ao->untimed = true` and a fixed `ao->device_buffer = 1 << 16`. Its get_state always reports free_samples=65536, queued=0, delay=0. audio_write is a plain blocking fwrite() on a stdio FILE*. set_pause returns true without doing anything, and reset() is a no-op. ao_pcm.c in master (488fec0, 2026-10-22) is identical to v0.41.0 apart from one added #include. (/tmp/sudamp-spike/engine/dl-mpv-src/mpv-0.41/audio/out/ao_pcm.c init() ~L150-160, audio_write/get_state ~L189-210; diff against mpv-master)
- The push-AO thread calls driver->write() while holding buffer_state->lock (ao_thread locks p->lock, then ao_play_data, then driver->write). For untimed AOs ao_play_data returns retry=true, so it loops writing as fast as writes complete. ao_get_delay(), ao_reset() and ao_set_paused() all take the same lock, so a blocked fwrite blocks the mpv core thread. Because ao->buffer = max(device_buffer, audio-buffer*rate), the soft queue is at least 65536 samples, about 1.37 s at 48 kHz, whatever --audio-buffer is set to. (mpv-0.41/audio/out/buffer.c ao_thread L706-742, ao_play_data L625-704, ao_get_delay L295-318; audio/out/ao.c L253-264)
- On this macOS 27 machine a FIFO holds only 8192 bytes (about 21 ms of 48 kHz stereo float32), an anonymous pipe holds 65536 bytes, and a FIFO's st_blksize (the stdio buffer basis) is 4096. (`spike pipecap` output: 'anon pipe capacity ... 65536', 'FIFO capacity, 1 MiB writes: 8192 bytes', 'FIFO st_blksize 4096')
- Test setup for the next several measurements: ao=pcm into a FIFO, with a consumer pulling at exactly 48 kHz through a 20 ms ring. mpv was paced by backpressure: the pipe read rate over 5–25 s was 384,020 B/s (real time is 384,000), per-second bytes ranged 382,840–385,632, and there were 0 underrun frames. mpv neither raced ahead nor buffered without bound. (/tmp/sudamp-spike/engine/run-q1-ring20ms/ticks.csv analysed by /tmp/sudamp-spike/engine/analysis/q1.py)
- Under that backpressure the mpv core is blocked almost all the time. get_property(time-pos) latency was p50 1285.8 ms, p90 1294.8 ms, max 1298.7 ms; only 14 samples completed in 20 s against a 100 ms polling target. time-pos changed in steps of exactly 1.393 s. When a sample did return, time-pos led the audio actually consumed by 25–40 ms (FIFO plus ring); between steps it was stale by up to 1.39 s. (/tmp/sudamp-spike/engine/run-q1-ring20ms/monitor.csv; q1.py output)
- Pause on the FIFO path: a synchronous `set pause yes` took 1931–1934 ms to return, and the consumer kept receiving audio for 1.97 s afterwards. Resume was sample-continuous (source position 26.4533 s before and after). With a sudamp-side pause plus a 3 s headroom ring, the ring absorbed 1.858 s while mpv's pause call still took 812 ms. (/tmp/sudamp-spike/engine/run-q1-ring20ms/log.txt (SET pause=yes took 1931.2 ms / 1933.6 ms); /tmp/sudamp-spike/engine/run-q1b-best/log.txt (812.0 ms);)
- If the reader stops reading, libmpv's synchronous API blocks indefinitely. The harness deadlocked twice: `set pause` while the consumer was stopped, and `set volume` while the pipe reader was stopped. Calls issued from side threads took 4939 ms (pause), 3394 ms (get time-pos) and 4394 ms (set volume), returning only after reading resumed. mpv_terminate_destroy also hung when the reader thread exited first, and a `/dev/fd/N` anonymous-pipe run hung the same way. (/tmp/sudamp-spike/engine/run-q1-ring20ms/stdout-deadlock-run1.txt, stdout-deadlock-run2.txt, log.txt (took 4939.6 ms, 3393.9 ms, 4394.0 ms); run-q1b-b)
- Seek and skip on the FIFO path: new audio reached the consumer 1.71–2.67 s after the command, with 1.71–2.67 s of stale audio played first. This held for every flush strategy: none, flush right after the command, flush on PLAYBACK_RESTART, flush on SEEK, and flush on END_FILE for loadfile. Each flush removed only 8–13 KB; the stale audio sat in the in-flight 1.39 s fwrite chunk and mpv's queue. The seek command itself took 0.3–1.27 s to return. (q1.py output; run-q1-ring20ms/log.txt ('flushes: 46.322:12040 B, 54.671:12872 B, 60.234:12752 B, 65.801:8472 B'))
- Best case for the FIFO path: the reader discards everything from the moment of the command until the SEEK or END_FILE event. That cut stale audio to 20–31 ms, but left 0.92–1.07 s of silence before new audio (seek 1.10 s and 0.94 s, loadfile 0.88 s). About 2.4 MB of decoded audio was thrown away while mpv raced to unblock. (/tmp/sudamp-spike/engine/run-q1b-best/ticks.csv, analysis/q1b.py output)
- mpv event ordering (source-derived), which marks the stale/new boundary. For a seek, clear_audio_output_buffers (ao_reset) runs before MPV_EVENT_SEEK is emitted. audio_start_ao (ao_start) runs before MPV_EVENT_PLAYBACK_RESTART, so flushing on playback-restart can cut the head of the new audio. For `loadfile replace`, clear_audio_output_buffers runs before END_FILE. At a natural EOF there is no clear, so gapless playback drains the old audio. (mpv-0.41/player/playloop.c L403-445 (mp_seek) and L1166-1184 (handle_playback_restart); player/loadfile.c L1928 and L2000)
- If the FIFO reader closes while SIGPIPE is ignored, the process survives. ao_pcm ignores the fwrite error, so mpv decodes the rest of the file at full speed: END_FILE arrived 0.84 s later, skipping about 55 s of audio. libmpv no longer blocks SIGPIPE, so the host must set SIG_IGN itself. When playback reaches idle, mpv closes the AO, so the reader sees EOF; the same FIFO fd received data again after the next loadfile. (run-q1-ring20ms/log.txt (reader closed at ~108.04, END_FILE 108.881); mpv DOCS/client-api-changes.rst ('do not override the SIGPIPE signal handler any)
- Upstream libmpv has no in-process PCM path as of master 488fec0 (2026-10-22). client.h and render.h have no audio-data API; the client API 2.6 change for 0.42 only adds a D3D11 render backend; ao_pcm and buffer.c are unchanged. PR #16769 ('audio/out: add libmpv callback driver', opened 2025-09-07) was closed unmerged by its author on 2026-04-26. sfan5's objections were that the client isn't told about pause, that querying the format is async, and that the callback can miss the first samples. Issue #9283 ('libmpv: Get audio frame?') is still open. (/tmp/sudamp-spike/engine/dl-mpv-src/mpv-master/DOCS/client-api-changes.rst; https://github.com/mpv-player/mpv/pull/16769 (WebFetch); GitHub search API)
- mpv_audio_kit (BSD-3, Dart, mpv v0.41.0) obtains PCM from its own patched libmpv builds (`libmpv-r18`, downloaded from its GitHub releases). The patches expose post-filter PCM as NODE properties that the Dart side polls with mpv_get_property_async (`pcm-tap-frame`, `audio-tap-frames`, `analyzer-taps`), plus a `mak-pcm://` input protocol with a `mak_pcm_*` C API. None of this is upstream. This is derived from reading its Dart sources; I didn't read the patch. (/tmp/sudamp-spike/engine/dl-mpv-audio-kit/mpv_audio_kit/hook/build.dart L32-34, lib/src/internals/pcm_native.dart L5-6, event_isolate.dart ~L584)
- A link-time AO override is possible. In the arm64 libmpv.a, audio_out_ao_pcm.c.o exports only `_audio_out_pcm` (S); all its functions are static. `_ao_read_data`, `_ao_stop_streaming`, `_mp_time_ns` and `_mp_chmap_from_channels` are global (T). A SwiftPM C target that defines `const struct ao_driver audio_out_pcm` (compiled against mpv v0.41.0 headers plus a 4-line config.h) links without a duplicate-symbol error, and the archive member is never pulled. Checked with strings: the debug and release spikepull binaries contain only 'sudamp pull AO', and the plain spike binary contains only 'RAW PCM/WAVE file writer'. (lipo/ar/nm on .build/artifacts/mpvkit/Libmpv/Libmpv.xcframework/macos-arm64_x86_64/Libmpv.framework/Versions/A/Libmpv; /tmp/sudamp-spike/engine/pkg/So)
- Pull AO feeding AVAudioEngine on the Mac mini Speakers (48 kHz, 512-frame IO buffer), measured in the release build:
- **Steady play:** 375 callbacks in 4 s, all 512 frames, mean interval 10.67 ms (max 10.75), 0 short reads.
- **Client API:** get_property latency p50 0.007 ms, p99 0.013 ms.
- **Pause:** mpv pause gave a silent render callback 8.6 ms after the command; unpause resumed after 6.7 ms with a 0.2 ms source gap.
- **Seek:** new audio 9.6 ms after the command, with 0 stale frames.
- **loadfile:** new file 23.9 ms after the command, with 0 stale frames.
- **CPU:** decode, resample, engine, EQ and tap together used 1.1% of one core.

The debug build was similar: 3.4% CPU, a seek of 10.8 ms with one stale 10.7 ms quantum, and time-pos 23.4 ms behind the last rendered sample on average (range -10.9 to -43.3 ms). (/tmp/sudamp-spike/engine/run-pull-release.stdout; /tmp/sudamp-spike/engine/run-pull.stdout; /tmp/sudamp-spike/engine/run-pull-engine/render.csv)
- Output latency on this Mac: the default device is 'Mac mini Speakers' at 48 kHz, BufferFrameSize 512, device latency 60 frames, safety offset 48 frames; AVAudioOutputNode.presentationLatency reports 1.25 ms. mpv's own ao_coreaudio reports a device latency of 12,916,666 ns, a device buffer of 1240 samples and a 9600-sample soft buffer. (run-pull.stdout line 1-2; run-eq-coreaudio.stdout (ao/coreaudio verbose log))
- AVAudioUnitEQ with 10 parametric bands at the Winamp frequencies (bandwidth 1 octave) measured exactly as set on a 1 kHz test tone through an installTap: flat 0.00 dB, band 4 at +12 dB gave +12.00 dB, and globalGain +6 gave +6.00 dB. installTap(bufferSize: 1024) actually delivered 4800-frame buffers every 100.0 ms (300 buffers in 30 s), which is too coarse for a 60 fps visualiser. (run-pull.stdout ('tap: 300 buffers, frameLength [4800], mean interval 100.0 ms'; 'tap 1 kHz level: flat +0.00 dB, b4+12 +12.00 dB, preamp+6 +6.00 dB'))
- Swift 6 pitfall, reproduced. AVAudioSourceNodeRenderBlock is declared NS_SWIFT_NONSENDABLE. In Swift 6 mode, a render closure written inside a @MainActor function traps on the first callback: EXC_BREAKPOINT on thread com.apple.audio.IOThread.client in _dispatch_assert_queue_fail, called from _swift_task_checkIsolatedSwift. Building the node in a `nonisolated func` works (141 callbacks in 1.5 s). The macOS 27 SDK also adds AVAudioSourceNodeRenderBlockRealtimeSafe, marked __SWIFT_UNAVAILABLE_MSG("Swift is not supported for use with audio realtime threads"). (/tmp/sudamp-spike/engine/iso6 (exit 133, then exit 0 after the fix); ~/Library/Logs/DiagnosticReports/iso6-2026-10-22-094729.ips; SDK AVFAudio.framewo)
- Option A EQ results, measured on the output level of a 1 kHz tone at the render callback (after mpv's af chain):
- **Target naming:** `af-command eq g 12 b4` returns -12 (error running command); `equalizer@b4` returns 0 and gives +12.00 dB. `pre` fails; `volume@pre` gives +6.00 dB.
- **Lost on seek and loadfile:** after a seek the level is back to +0.00 dB, and after `loadfile replace` it is also +0.00 dB.
- **Seek then immediate command:** an af-command sent immediately after a seek returns -12 and has no effect.
- **Re-applying works:** sending the gain again from the event thread on PLAYBACK_RESTART gives +12.00 dB after both a seek and a loadfile.
- **Type-name target:** `equalizer` sets all 10 bands (g 3 gives +5.27 dB at 1 kHz).
- **`all` target:** `all` returns -12 even though the gains were applied (0.00 dB).
- **Changing the `af` string mid-playback:** 0 silent callbacks and 0 position jumps, and the gains persist across seek and loadfile.
- **Fast slider drags:** 50 af-commands in 1.36 s had 0 failures, a worst call of 0.51 ms, and the expected final level (+0.24 dB). Whether this produces audible zipper noise was not judged.
- **Return codes:** identical under ao=null and ao=coreaudio. (/tmp/sudamp-spike/engine/run-eq-pull.stdout; run-eq-null.stdout; run-eq-coreaudio.stdout; code /tmp/sudamp-spike/engine/pkg/Sources/spikepull/EQPull.s)
- ao=coreaudio from MPVKit 1.0.0 initialises cleanly on macOS 27.0.1 with float output (no init failure). I couldn't test the Bluetooth/aggregate hotplug crash (#18274) headlessly without changing devices. (run-eq-coreaudio.stdout ('selected audio output device: Mac mini Speakers (77)', 'device buffer: 1240 samples'))
- Network path through MPVKit 1.0.0 into the pull AO: https://ice1.somafm.com/groovesalad-128-mp3 was audible at the render callback 901 ms after loadfile, with 0 short reads over 1128 callbacks. metadata/by-key/icy-title and media-title both held the ICY title, and seekable=no. For this live ICY stream mpv nonetheless reported duration=27.6 s, which grows, so 'duration absent for live' doesn't hold here; use seekable or file-format instead. mpv itself sets reconnect=1 and reconnect_delay_max=7 on every lavf stream and parses ICY through the icy_metadata_packet AVOption. (/tmp/sudamp-spike/engine/run-net.stdout; mpv-0.41/stream/stream_lavf.c L404-405 and read_icy L461-480)
- The internal ABI the pull AO relies on is stable from v0.41.0 to master 488fec0. audio/out/internal.h (struct ao, ao_driver, ao_read_data), ao.h and chmap.h are byte-identical. format.h only appends AF_FORMAT_S_DOP and AF_FORMAT_DSD after the IEC61937 formats, so AF_FORMAT_FLOATP keeps its value. (diff mpv-0.41 vs mpv-master under /tmp/sudamp-spike/engine/dl-mpv-src)
- Option C would have to re-implement the mpv layers sitting above FFmpeg (line counts from v0.41.0): demux/demux.c 4702 (packet queue and cache, seek ranges, cache-pause), demux_lavf.c 1458 (including HLS quirks and leaked nested connections), stream_lavf.c 549 (ICY, reconnect defaults, network options, interrupt), filters/f_swresample.c 676 (format-change handling), player/audio.c 991, demux_edl.c 666. (wc -l in /tmp/sudamp-spike/engine/dl-mpv-src/mpv-0.41)
- A shutdown ordering bug in my harness crashed the process (EXC_BAD_ACCESS in mpv_wait_event): the event thread called mpv_wait_event after mpv_terminate_destroy had freed the handle. sudamp's MPVCore must have its event thread exit on MPV_EVENT_SHUTDOWN and be joined before destroy. (~/Library/Logs/DiagnosticReports/spikepull-2026-10-22-095658.ips (faulting frame mpv_wait_event ← MPV.startEvents closure))