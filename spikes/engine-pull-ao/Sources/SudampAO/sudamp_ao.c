// Spike: replaces mpv's `audio_out_pcm` driver at link time with a *pull* AO whose data is
// read by the host's AVAudioSourceNode render block. Built against mpv v0.41.0 internal headers
// (MPVKit 1.0.0 = v0.41.0 + 3 unrelated patches). Internal ABI: must be rebuilt per libmpv version.
#include <pthread.h>
#include <stdatomic.h>
#include "audio/out/internal.h"
#include "audio/format.h"
#include "osdep/timer.h"
#include "sudamp_ao.h"

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static struct ao *g_ao;
static atomic_int g_started;
static atomic_llong g_inits;

static int init(struct ao *ao)
{
    ao->format = AF_FORMAT_FLOATP;              // matches AVAudioFormat standard (deinterleaved float32)
    mp_chmap_from_channels(&ao->channels, 2);
    ao->device_buffer = 1024;                   // ~2 render quanta; mpv soft buffer = max(this, audio-buffer)
    pthread_mutex_lock(&g_lock);
    g_ao = ao;
    pthread_mutex_unlock(&g_lock);
    atomic_fetch_add(&g_inits, 1);
    return 0;
}

static void uninit(struct ao *ao)
{
    pthread_mutex_lock(&g_lock);                // waits for an in-flight render read to finish
    g_ao = NULL;
    pthread_mutex_unlock(&g_lock);
    atomic_store(&g_started, 0);
}

static void reset(struct ao *ao) { atomic_store(&g_started, 0); }
static void start(struct ao *ao) { atomic_store(&g_started, 1); }

const struct ao_driver audio_out_pcm = {
    .description = "sudamp pull AO (link-time replacement of ao_pcm)",
    .name        = "pcm",
    .init        = init,
    .uninit      = uninit,
    .reset       = reset,
    .start       = start,
};

int sudamp_ao_read(float *left, float *right, int frames, int64_t delay_ns)
{
    if (pthread_mutex_trylock(&g_lock) != 0)
        return -1;
    int r = -1;
    struct ao *ao = g_ao;
    if (ao && ao->format == AF_FORMAT_FLOATP && ao->channels.num == 2) {
        void *planes[2] = { left, right };
        r = ao_read_data(ao, planes, frames, mp_time_ns() + delay_ns, NULL, true, true);
    }
    pthread_mutex_unlock(&g_lock);
    return r;
}

int sudamp_ao_state(void)
{
    int s = 0;
    pthread_mutex_lock(&g_lock);
    if (g_ao) s |= 1;
    pthread_mutex_unlock(&g_lock);
    if (atomic_load(&g_started)) s |= 2;
    return s;
}
int sudamp_ao_samplerate(void)
{
    pthread_mutex_lock(&g_lock);
    int r = g_ao ? g_ao->samplerate : 0;
    pthread_mutex_unlock(&g_lock);
    return r;
}
long long sudamp_ao_init_count(void) { return atomic_load(&g_inits); }
