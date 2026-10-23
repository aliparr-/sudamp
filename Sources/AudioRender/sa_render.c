// SPDX-License-Identifier: GPL-3.0-or-later
//
// Real-time render body for the AVAudioSourceNode (DESIGN §5.2): host pause with 5 ms ramps, fades, balance
// gains, TTFA stamp, counters, probe log and the visualiser's mono SPSC ring. Runs on the CoreAudio IO thread:
// no allocation, no locks (the pull AO's own trylock aside), no ObjC or Swift, only C11 atomics.

#include "sa_render.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "sudamp_ao.h"

#define RING_MASK (SA_RENDER_RING_FRAMES - 1)
#define RING_GUARD_FRAMES SA_RENDER_RING_GUARD_FRAMES

_Static_assert((SA_RENDER_RING_FRAMES & RING_MASK) == 0, "ring size must be a power of two");

struct SARender {
    // Written by any thread, read by the render thread.
    _Atomic(SARenderReadFn) read;
    _Atomic(void *) read_context;
    atomic_bool host_paused;
    atomic_bool pause_settled; // render thread: the pause ramp has finished and output is silent
    atomic_bool muted;
    _Atomic int64_t latency_ns;
    _Atomic float gain_left_target;
    _Atomic float gain_right_target;
    _Atomic uint32_t fade_request_frames;
    _Atomic uint64_t ttfa_armed_ns;
    _Atomic uint64_t ttfa_ns;

    // Written by the render thread, read by any thread.
    _Atomic uint64_t callbacks;
    _Atomic uint64_t frames;
    _Atomic uint64_t short_reads;
    _Atomic uint64_t silent_callbacks;
    _Atomic uint64_t ao_unavailable;
    _Atomic uint64_t host_paused_callbacks;
    _Atomic uint64_t last_callback_ns;
    _Atomic uint32_t last_frame_count;

    // Render-thread-only state.
    float pause_gain; // 1 = playing, 0 = host-paused
    float gain_left;
    float gain_right;
    float fade_gain;  // >= 1 when no fade is running
    float fade_step;

    // Visualiser ring (single producer: render thread; single consumer). `ring_claimed` is raised (followed by a
    // release fence) before a callback overwrites slots and `ring_written` is published after, seqlock-style, so a
    // reader that validates against `ring_claimed` can never return a slot the writer was reusing.
    _Atomic uint64_t ring_claimed;
    _Atomic uint64_t ring_written;
    _Atomic float ring[SA_RENDER_RING_FRAMES];

    // Optional probe log (allocated before rendering starts).
    SAProbeRecord *probe;
    uint32_t probe_capacity;
    _Atomic uint32_t probe_count;
};

static int ao_reader(void *context, float *left, float *right, int frames, int64_t delay_ns, bool *streaming)
{
    (void)context;
    *streaming = sudamp_ao_is_streaming() != 0;
    return sudamp_ao_read(left, right, frames, delay_ns);
}

uint64_t sa_render_now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

SARender *sa_render_create(void)
{
    SARender *r = calloc(1, sizeof(*r));
    if (!r)
        return NULL;
    atomic_init(&r->read, ao_reader);
    atomic_init(&r->read_context, NULL);
    atomic_init(&r->gain_left_target, 1.0f);
    atomic_init(&r->gain_right_target, 1.0f);
    r->pause_gain = 1.0f;
    r->gain_left = 1.0f;
    r->gain_right = 1.0f;
    r->fade_gain = 1.0f;
    return r;
}

void sa_render_destroy(SARender *r)
{
    if (!r)
        return;
    free(r->probe);
    free(r);
}

void sa_render_set_reader(SARender *r, SARenderReadFn read, void *context)
{
    atomic_store_explicit(&r->read_context, context, memory_order_relaxed);
    atomic_store_explicit(&r->read, read ? read : ao_reader, memory_order_release);
}

void sa_render_set_host_paused(SARender *r, bool paused)
{
    if (paused && !atomic_load_explicit(&r->host_paused, memory_order_relaxed))
        atomic_store_explicit(&r->pause_settled, false, memory_order_relaxed);
    atomic_store_explicit(&r->host_paused, paused, memory_order_release);
}

bool sa_render_host_pause_settled(const SARender *r)
{
    return atomic_load_explicit(&r->pause_settled, memory_order_acquire);
}

bool sa_render_host_paused(const SARender *r) { return atomic_load_explicit(&r->host_paused, memory_order_acquire); }

void sa_render_set_latency_ns(SARender *r, int64_t latency_ns)
{
    atomic_store_explicit(&r->latency_ns, latency_ns < 0 ? 0 : latency_ns, memory_order_relaxed);
}

int64_t sa_render_latency_ns(const SARender *r) { return atomic_load_explicit(&r->latency_ns, memory_order_relaxed); }

static float clamp01(float v) { return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v); }

void sa_render_set_channel_gains(SARender *r, float left, float right)
{
    atomic_store_explicit(&r->gain_left_target, clamp01(left), memory_order_relaxed);
    atomic_store_explicit(&r->gain_right_target, clamp01(right), memory_order_relaxed);
}

void sa_render_fade_in(SARender *r, double seconds)
{
    double frames = seconds * SA_RENDER_SAMPLE_RATE;
    uint32_t f = frames < 1.0 ? 1u : (frames > 4.0e9 ? 4000000000u : (uint32_t)frames);
    atomic_store_explicit(&r->fade_request_frames, f, memory_order_release);
}

void sa_render_set_output_muted(SARender *r, bool muted)
{
    atomic_store_explicit(&r->muted, muted, memory_order_relaxed);
}

void sa_render_arm_ttfa(SARender *r)
{
    atomic_store_explicit(&r->ttfa_ns, 0, memory_order_relaxed);
    atomic_store_explicit(&r->ttfa_armed_ns, sa_render_now_ns(), memory_order_release);
}

uint64_t sa_render_ttfa_armed_ns(const SARender *r) { return atomic_load_explicit(&r->ttfa_armed_ns, memory_order_acquire); }
uint64_t sa_render_ttfa_ns(const SARender *r) { return atomic_load_explicit(&r->ttfa_ns, memory_order_acquire); }

SARenderCounters sa_render_counters(const SARender *r)
{
    SARenderCounters c;
    c.callbacks = atomic_load_explicit(&r->callbacks, memory_order_relaxed);
    c.frames = atomic_load_explicit(&r->frames, memory_order_relaxed);
    c.shortReads = atomic_load_explicit(&r->short_reads, memory_order_relaxed);
    c.silentCallbacks = atomic_load_explicit(&r->silent_callbacks, memory_order_relaxed);
    c.aoUnavailable = atomic_load_explicit(&r->ao_unavailable, memory_order_relaxed);
    c.hostPausedCallbacks = atomic_load_explicit(&r->host_paused_callbacks, memory_order_relaxed);
    c.lastCallbackNanos = atomic_load_explicit(&r->last_callback_ns, memory_order_relaxed);
    c.lastFrameCount = atomic_load_explicit(&r->last_frame_count, memory_order_relaxed);
    return c;
}

bool sa_render_probe_enable(SARender *r, uint32_t capacity)
{
    if (r->probe || capacity == 0)
        return r->probe != NULL;
    r->probe = calloc(capacity, sizeof(SAProbeRecord));
    if (!r->probe)
        return false;
    r->probe_capacity = capacity;
    return true;
}

uint32_t sa_render_probe_count(const SARender *r) { return atomic_load_explicit(&r->probe_count, memory_order_acquire); }
const SAProbeRecord *sa_render_probe_records(const SARender *r) { return r->probe; }

uint64_t sa_render_ring_written(const SARender *r) { return atomic_load_explicit(&r->ring_written, memory_order_acquire); }

int sa_render_ring_copy_newest(const SARender *r, float *dst, int count, int lag_frames)
{
    if (count <= 0 || lag_frames < 0 || count + lag_frames > SA_RENDER_RING_FRAMES - RING_GUARD_FRAMES)
        return 0;
    for (int attempt = 0; attempt < 2; attempt++) {
        uint64_t written = atomic_load_explicit(&r->ring_written, memory_order_acquire);
        if (written < (uint64_t)(count + lag_frames))
            return 0;
        uint64_t start = written - (uint64_t)lag_frames - (uint64_t)count;
        for (int i = 0; i < count; i++)
            dst[i] = atomic_load_explicit(&r->ring[(start + (uint64_t)i) & RING_MASK], memory_order_relaxed);
        // Seqlock-style validation: if any copied load saw a slot the writer reused, the acquire fence pairs with the
        // writer's release fence after its claim, so this load sees that claim. Slot s is reused only once the claim
        // passes s + RING_FRAMES.
        atomic_thread_fence(memory_order_acquire);
        uint64_t claimed = atomic_load_explicit(&r->ring_claimed, memory_order_relaxed);
        if (claimed - start <= SA_RENDER_RING_FRAMES)
            return count;
    }
    return 0;
}

void sa_render_process(SARender *r, float *left, float *right, uint32_t frame_count, bool *is_silence)
{
    const uint64_t now = sa_render_now_ns();
    const int n = (int)frame_count;
    const float ramp_step = 1.0f / (float)SA_RENDER_PAUSE_RAMP_FRAMES;

    if (atomic_load_explicit(&r->fade_request_frames, memory_order_relaxed) != 0) {
        uint32_t req = atomic_exchange_explicit(&r->fade_request_frames, 0, memory_order_acquire);
        if (req) {
            r->fade_gain = 0.0f;
            r->fade_step = 1.0f / (float)req;
        }
    }

    // How much to read: everything while playing; only what the ramp-down needs when pausing (so the rest stays
    // queued in mpv and resume is sample-continuous); nothing once paused.
    const bool want_pause = atomic_load_explicit(&r->host_paused, memory_order_acquire);
    int to_read = n;
    if (want_pause) {
        if (r->pause_gain <= 0.0f) {
            to_read = 0;
        } else {
            to_read = (int)ceilf(r->pause_gain / ramp_step);
            if (to_read > n)
                to_read = n;
            if (to_read < 1)
                to_read = 1;
        }
    }

    int got = -2;
    bool streaming = false;
    if (to_read > 0) {
        SARenderReadFn read = atomic_load_explicit(&r->read, memory_order_acquire);
        void *context = atomic_load_explicit(&r->read_context, memory_order_relaxed);
        int64_t delay = atomic_load_explicit(&r->latency_ns, memory_order_relaxed) +
                        (int64_t)to_read * 1000000000LL / SA_RENDER_SAMPLE_RATE;
        got = read(context, left, right, to_read, delay, &streaming);
    }
    const int valid = got > 0 ? got : 0;
    if (valid < n) {
        memset(left + valid, 0, (size_t)(n - valid) * sizeof(float));
        memset(right + valid, 0, (size_t)(n - valid) * sizeof(float));
    }

    // Probe values are taken from the raw source, before any gain.
    float first_r = valid > 0 ? right[0] : 0.0f;
    float last_r = valid > 0 ? right[valid - 1] : 0.0f;
    float sum_l = 0.0f;
    for (int i = 0; i < valid; i++)
        sum_l += left[i] * left[i];

    // Gains: pause ramp × fade × per-channel balance (interpolated across this callback).
    const float gl_target = atomic_load_explicit(&r->gain_left_target, memory_order_relaxed);
    const float gr_target = atomic_load_explicit(&r->gain_right_target, memory_order_relaxed);
    const float gl0 = r->gain_left, gr0 = r->gain_right;
    const float dgl = n > 0 ? (gl_target - gl0) / (float)n : 0.0f;
    const float dgr = n > 0 ? (gr_target - gr0) / (float)n : 0.0f;
    float pause_gain = r->pause_gain;
    const float pause_delta = want_pause ? -ramp_step : ramp_step;
    float fade = r->fade_gain;
    const float fade_step = r->fade_step;
    float peak = 0.0f;
    uint64_t w = atomic_load_explicit(&r->ring_written, memory_order_relaxed);
    atomic_store_explicit(&r->ring_claimed, w + (uint64_t)n, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);

    for (int i = 0; i < n; i++) {
        // The ramp down runs on time; the ramp up only over delivered audio, so a resume that reaches us before
        // mpv streams again still fades in instead of starting with a step.
        if (want_pause ? pause_gain > 0.0f : (pause_gain < 1.0f && i < valid))
            pause_gain = clamp01(pause_gain + pause_delta);
        float g = pause_gain;
        if (i < valid && fade < 1.0f) {
            g *= fade;
            fade += fade_step;
            if (fade > 1.0f)
                fade = 1.0f;
        }
        float l = left[i] * g * (gl0 + dgl * (float)(i + 1));
        float rr = right[i] * g * (gr0 + dgr * (float)(i + 1));
        left[i] = l;
        right[i] = rr;
        float al = fabsf(l), ar = fabsf(rr);
        if (al > peak)
            peak = al;
        if (ar > peak)
            peak = ar;
        atomic_store_explicit(&r->ring[(w + (uint64_t)i) & RING_MASK], 0.5f * (l + rr), memory_order_relaxed);
    }
    atomic_store_explicit(&r->ring_written, w + (uint64_t)n, memory_order_release);
    // Snap float residue so a finished ramp doesn't trigger a 1-frame read next time.
    if (want_pause && pause_gain < 0.5f * ramp_step)
        pause_gain = 0.0f;
    else if (!want_pause && pause_gain > 1.0f - 0.5f * ramp_step)
        pause_gain = 1.0f;
    r->pause_gain = pause_gain;
    atomic_store_explicit(&r->pause_settled, want_pause && pause_gain <= 0.0f, memory_order_release);
    r->gain_left = gl_target;
    r->gain_right = gr_target;
    r->fade_gain = fade;

    const bool silent = !(peak > 0.0f);

    // Time to first audio: the first callback that started after arm() and produced a non-zero sample.
    if (!silent) {
        uint64_t armed = atomic_load_explicit(&r->ttfa_armed_ns, memory_order_acquire);
        if (armed != 0 && now >= armed && atomic_load_explicit(&r->ttfa_ns, memory_order_relaxed) == 0) {
            uint64_t expected = 0;
            if (atomic_compare_exchange_strong_explicit(&r->ttfa_ns, &expected, now, memory_order_acq_rel,
                                                        memory_order_relaxed)) {
                // Re-armed while we stamped: drop the stale stamp.
                if (atomic_load_explicit(&r->ttfa_armed_ns, memory_order_acquire) > now) {
                    expected = now;
                    atomic_compare_exchange_strong_explicit(&r->ttfa_ns, &expected, 0, memory_order_acq_rel,
                                                            memory_order_relaxed);
                }
            }
        }
    }

    atomic_fetch_add_explicit(&r->callbacks, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&r->frames, (uint64_t)n, memory_order_relaxed);
    if (silent)
        atomic_fetch_add_explicit(&r->silent_callbacks, 1, memory_order_relaxed);
    if (got == -1)
        atomic_fetch_add_explicit(&r->ao_unavailable, 1, memory_order_relaxed);
    else if (got == -2)
        atomic_fetch_add_explicit(&r->host_paused_callbacks, 1, memory_order_relaxed);
    else if (got < to_read && streaming)
        atomic_fetch_add_explicit(&r->short_reads, 1, memory_order_relaxed);
    atomic_store_explicit(&r->last_callback_ns, now, memory_order_relaxed);
    atomic_store_explicit(&r->last_frame_count, (uint32_t)n, memory_order_relaxed);

    if (r->probe) {
        uint32_t idx = atomic_load_explicit(&r->probe_count, memory_order_relaxed);
        if (idx < r->probe_capacity) {
            SAProbeRecord *rec = &r->probe[idx];
            rec->t_ns = now;
            rec->frames = n;
            rec->got = got;
            rec->first_r = first_r;
            rec->last_r = last_r;
            rec->peak = peak;
            rec->rms_l = valid > 0 ? sqrtf(sum_l / (float)valid) : 0.0f;
            atomic_store_explicit(&r->probe_count, idx + 1, memory_order_release);
        }
    }

    if (atomic_load_explicit(&r->muted, memory_order_relaxed)) {
        memset(left, 0, (size_t)n * sizeof(float));
        memset(right, 0, (size_t)n * sizeof(float));
        *is_silence = true;
    } else {
        *is_silence = silent;
    }
}

int sa_test_source_read(void *context, float *left, float *right, int frames, int64_t delay_ns, bool *streaming)
{
    SATestSource *s = context;
    s->reads++;
    s->last_requested = frames;
    s->last_delay_ns = delay_ns;
    *streaming = s->streaming;
    if (s->unavailable)
        return -1;
    int n = frames;
    if (s->max_frames > 0 && n > s->max_frames)
        n = s->max_frames;
    for (int i = 0; i < n; i++) {
        left[i] = s->left;
        right[i] = s->right;
    }
    for (int i = n; i < frames; i++) {
        left[i] = 0.0f;
        right[i] = 0.0f;
    }
    return n;
}

int sa_tone_source_read(void *context, float *left, float *right, int frames, int64_t delay_ns, bool *streaming)
{
    (void)delay_ns;
    SAToneSource *s = context;
    *streaming = true;
    for (int i = 0; i < frames; i++) {
        const uint64_t n = s->frame + (uint64_t)i;
        float l = 0.0f, r = 0.0f;
        if (n >= s->start_frame) {
            switch (s->kind) {
            case SA_TONE_NOISE: {
                uint64_t x = s->seed ? s->seed : 0x9E3779B97F4A7C15ull;
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                s->seed = x;
                const float u = (float)((double)(x >> 11) * (1.0 / 9007199254740992.0)) * 2.0f - 1.0f;
                l = u * s->amplitude_left;
                r = u * s->amplitude_right;
                break;
            }
            case SA_TONE_COUNTER:
                l = r = (float)n;
                break;
            default: {
                // Phase reduced to [0, 1) cycles first, so long renders keep full precision.
                const double cycles = fmod(s->frequency * (double)n / (double)SA_RENDER_SAMPLE_RATE, 1.0);
                const double v = sin(2.0 * M_PI * cycles);
                l = (float)v * s->amplitude_left;
                r = (float)v * s->amplitude_right;
                if (s->amplitude2 != 0.0f) {
                    const double c2 = fmod(s->frequency2 * (double)n / (double)SA_RENDER_SAMPLE_RATE, 1.0);
                    const float v2 = (float)sin(2.0 * M_PI * c2) * s->amplitude2;
                    l += v2;
                    r += v2;
                }
                break;
            }
            }
        }
        left[i] = l;
        right[i] = r;
    }
    s->frame += (uint64_t)frames;
    return frames;
}
