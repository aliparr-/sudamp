// SPDX-License-Identifier: LGPL-2.1-or-later
//
// sudamp pull AO. Replaces mpv's `audio_out_pcm` driver at link time with a *pull* AO whose samples are read by
// the host's AVAudioSourceNode render callback (DESIGN §5.1–5.2). MPVKit 1.0.0's static libmpv exports only
// `_audio_out_pcm` from its ao_pcm object, so defining it here keeps the linker from loading mpv's file writer.
//
// Built against the vendored mpv v0.41.0 internal headers (Sources/SudampAO/vendor, LGPL-2.1+). This depends on
// mpv's internal ABI: re-vendor and re-verify (`make verify-binary`) whenever the MPVKit pin changes.
// Ported from spikes/engine-pull-ao/Sources/SudampAO/sudamp_ao.c.

#include <pthread.h>
#include <stdatomic.h>

// Third-party mpv headers: compiled with their own conventions, so their warnings are not ours to fix.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include "audio/out/internal.h"
#include "audio/format.h"
#include "osdep/timer.h"
#pragma clang diagnostic pop

#include "sudamp_ao.h"

static const char kDescription[] = "sudamp pull AO";

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static struct ao *g_ao;
static atomic_int g_started;
static atomic_llong g_inits;
static atomic_llong g_errors;

static int init(struct ao *ao)
{
    // Force the format ourselves so mpv inserts the resampler/converter before us; the render side is fixed
    // at 48 kHz stereo planar float. The audio-samplerate/audio-channels options are belt and braces only.
    ao->format = AF_FORMAT_FLOATP;
    ao->samplerate = SUDAMP_AO_SAMPLERATE;
    mp_chmap_from_channels(&ao->channels, SUDAMP_AO_CHANNELS);
    ao->device_buffer = 1024; // ~2 render quanta; mpv's soft buffer is max(this, audio-buffer)

    pthread_mutex_lock(&g_lock);
    g_ao = ao;
    pthread_mutex_unlock(&g_lock);
    atomic_fetch_add(&g_inits, 1);
    return 0;
}

static void uninit(struct ao *ao)
{
    (void)ao;
    pthread_mutex_lock(&g_lock); // waits for an in-flight render read to finish
    g_ao = NULL;
    pthread_mutex_unlock(&g_lock);
    atomic_store(&g_started, 0);
}

static void reset(struct ao *ao) { (void)ao; atomic_store(&g_started, 0); }
static void start(struct ao *ao) { (void)ao; atomic_store(&g_started, 1); }

const struct ao_driver audio_out_pcm = {
    .description = kDescription,
    .name = "pcm",
    .init = init,
    .uninit = uninit,
    .reset = reset,
    .start = start,
};

int sudamp_ao_read(float *left, float *right, int frames, int64_t delay_ns)
{
    if (pthread_mutex_trylock(&g_lock) != 0)
        return -1;
    int r = -1;
    struct ao *ao = g_ao;
    if (ao) {
        if (ao->format == AF_FORMAT_FLOATP && ao->samplerate == SUDAMP_AO_SAMPLERATE &&
            ao->channels.num == SUDAMP_AO_CHANNELS) {
            void *planes[2] = {left, right};
            r = ao_read_data(ao, planes, frames, mp_time_ns() + delay_ns, NULL, true, true);
        } else {
            atomic_fetch_add(&g_errors, 1);
        }
    }
    pthread_mutex_unlock(&g_lock);
    return r;
}

int sudamp_ao_state(void)
{
    int s = 0;
    pthread_mutex_lock(&g_lock);
    if (g_ao)
        s |= 1;
    pthread_mutex_unlock(&g_lock);
    if (atomic_load(&g_started))
        s |= 2;
    return s;
}

int sudamp_ao_samplerate(void)
{
    pthread_mutex_lock(&g_lock);
    int r = g_ao ? g_ao->samplerate : 0;
    pthread_mutex_unlock(&g_lock);
    return r;
}

int sudamp_ao_is_streaming(void) { return atomic_load_explicit(&g_started, memory_order_relaxed); }

long long sudamp_ao_init_count(void) { return atomic_load(&g_inits); }
long long sudamp_ao_error_count(void) { return atomic_load(&g_errors); }
const char *sudamp_ao_description(void) { return kDescription; }
