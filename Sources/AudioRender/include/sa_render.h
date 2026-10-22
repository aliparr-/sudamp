// SPDX-License-Identifier: GPL-3.0-or-later
//
// sa_render — the real-time half of the AVAudioEngine bridge (DESIGN §5.2). Plain C11 so that nothing on the
// CoreAudio IO thread allocates, takes a lock (other than the pull AO's trylock) or enters Swift/ObjC.
// Every setter is a relaxed/release atomic store and may be called from any thread; the render function must be
// called from a single thread at a time (the IO thread, or a test thread that drives it directly).
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The graph's fixed format: 48 kHz, stereo, deinterleaved float32 (same as the pull AO's output).
#define SA_RENDER_SAMPLE_RATE 48000
/// Host-pause ramp: 5 ms at 48 kHz.
#define SA_RENDER_PAUSE_RAMP_FRAMES 240
/// Visualiser ring size in mono frames (power of two).
#define SA_RENDER_RING_FRAMES 8192

typedef struct SARender SARender;

/// A source of planar float frames with sudamp_ao_read's contract: returns frames copied (the rest of
/// `frames` is zero-filled by the source) or -1 when no data source is available (buffers untouched).
/// `*streaming` is set to whether the source was streaming before the read (so a short read is an underrun).
typedef int (*SARenderReadFn)(void *context, float *left, float *right, int frames, int64_t delay_ns,
                              bool *streaming);

/// Cumulative counters, readable from any thread (each field is individually consistent).
typedef struct {
    uint64_t callbacks;           ///< render calls
    uint64_t frames;              ///< frames rendered
    uint64_t shortReads;          ///< reads that returned 0 <= n < requested while the source was streaming
    uint64_t silentCallbacks;     ///< callbacks whose whole output was zero
    uint64_t aoUnavailable;       ///< reads that returned -1 (no AO yet, or the AO lock was contended)
    uint64_t hostPausedCallbacks; ///< callbacks fully silenced by the host-pause flag (no read)
    uint64_t lastCallbackNanos;   ///< CLOCK_UPTIME_RAW time of the latest callback
    uint32_t lastFrameCount;      ///< frame count of the latest callback
} SARenderCounters;

/// One render callback, for benchmarks (sudamp-dev bench-transport / devswitch). Raw values are pre-gain.
typedef struct {
    uint64_t t_ns;   ///< CLOCK_UPTIME_RAW at callback start
    int32_t frames;  ///< frames requested
    int32_t got;     ///< reader result; -1 unavailable, -2 host-paused (no read)
    float first_r;   ///< raw right-channel sample 0
    float last_r;    ///< raw right-channel sample at got-1 (or 0)
    float peak;      ///< max |output| over both channels, post-gain
    float rms_l;     ///< RMS of the raw left channel over the read frames
} SAProbeRecord;

/// Creates render state reading from the sudamp pull AO. Never fails short of memory exhaustion (then NULL).
SARender *sa_render_create(void);
void sa_render_destroy(SARender *render);

/// Replaces the data source (NULL restores the pull AO). Call before rendering starts; tests use this.
void sa_render_set_reader(SARender *render, SARenderReadFn read, void *context);

/// The render body: fills `frames` samples of each channel. `*is_silence` is set when the whole output is zero.
void sa_render_process(SARender *render, float *left, float *right, uint32_t frames, bool *is_silence);

/// Host pause (DESIGN §5.2): true ramps the output to silence within SA_RENDER_PAUSE_RAMP_FRAMES and then stops
/// reading; false resumes reading with a ramp up over the first delivered frames. Instant for the caller.
void sa_render_set_host_paused(SARender *render, bool paused);
bool sa_render_host_paused(const SARender *render);
/// True once a callback has finished the pause ramp (output silent, AO no longer read). Pause mpv only after
/// this, or mpv's own pause empties the read and cuts the ramp short (measured in E1).
bool sa_render_host_pause_settled(const SARender *render);

/// Time from the start of a callback until its first sample is audible (output latency + IO buffer).
/// The read passes `latency + frames/48000` to ao_read_data, which wants the time the *last* sample plays.
void sa_render_set_latency_ns(SARender *render, int64_t latency_ns);
int64_t sa_render_latency_ns(const SARender *render);

/// Per-channel gains (balance), 0...1. Changes are interpolated across one callback to avoid zipper noise.
void sa_render_set_channel_gains(SARender *render, float left, float right);

/// Starts a linear fade-in from silence over `seconds` of rendered audio (1.5 s launch fade, 50 ms after a
/// device change). The fade advances only over frames the source actually delivered.
void sa_render_fade_in(SARender *render, double seconds);

/// Debug/tool safety: when true the output buffers are zeroed after measurement (ring, probe, TTFA and counters
/// still see the real signal), so nothing reaches the EQ, mixer or device.
void sa_render_set_output_muted(SARender *render, bool muted);

/// Time to first audio: arm() records "now" and clears the stamp; the first callback that starts after arm()
/// and outputs a non-zero sample records its start time. 0 = not armed / not yet.
void sa_render_arm_ttfa(SARender *render);
uint64_t sa_render_ttfa_armed_ns(const SARender *render);
uint64_t sa_render_ttfa_ns(const SARender *render);

SARenderCounters sa_render_counters(const SARender *render);

/// Copies the newest `count` mono samples, ending `lag_frames` before the write position, into `dst`.
/// Returns `count`, or 0 if not enough history exists, the request exceeds the ring, or the writer lapped the
/// copy twice. Single consumer.
int sa_render_ring_copy_newest(const SARender *render, float *dst, int count, int lag_frames);
/// Total mono frames ever written to the ring.
uint64_t sa_render_ring_written(const SARender *render);

/// Enables the per-callback probe log with room for `capacity` records (allocates; call before rendering).
bool sa_render_probe_enable(SARender *render, uint32_t capacity);
uint32_t sa_render_probe_count(const SARender *render);
/// Records [0, sa_render_probe_count()) are complete and immutable.
const SAProbeRecord *sa_render_probe_records(const SARender *render);

/// Monotonic nanoseconds (CLOCK_UPTIME_RAW), the clock every timestamp above uses (Core.monotonicNanos too).
uint64_t sa_render_now_ns(void);

/// Synthetic source for tests: constant samples, an optional cap on frames per read (short reads) and a
/// failure switch (-1). Pass `sa_test_source_read` and a pointer to this struct to sa_render_set_reader.
typedef struct {
    float left;
    float right;
    int max_frames;  ///< 0 = no cap
    bool unavailable;
    bool streaming;
    uint64_t reads;
    int last_requested;
    int64_t last_delay_ns;
} SATestSource;
int sa_test_source_read(void *context, float *left, float *right, int frames, int64_t delay_ns, bool *streaming);

/// Deterministic test signals for measurements (eq-selftest, analyser and ring tests). Always "streaming".
typedef enum {
    SA_TONE_SINE = 0,    ///< amplitude * sin(2π · frequency · n / 48000) + amplitude2 * sin(2π · frequency2 · n / 48000)
    SA_TONE_NOISE = 1,   ///< uniform white noise in [-amplitude, amplitude] from a 64-bit xorshift (seeded)
    SA_TONE_COUNTER = 2, ///< sample n = (float)n (exact below 2^24), for ring integrity tests; amplitudes ignored
} SAToneKind;

typedef struct {
    int kind;                ///< SAToneKind
    double frequency;        ///< Hz (sine)
    float amplitude_left;
    float amplitude_right;
    double frequency2;       ///< Hz of an optional second partial (sine; both channels)
    float amplitude2;        ///< its amplitude (0 = none)
    uint64_t start_frame;    ///< frames before this index are zero (onset/latency measurements)
    uint64_t frame;          ///< next frame index (state; set to 0 to restart)
    uint64_t seed;           ///< noise state (non-zero)
} SAToneSource;
int sa_tone_source_read(void *context, float *left, float *right, int frames, int64_t delay_ns, bool *streaming);

#ifdef __cplusplus
}
#endif
