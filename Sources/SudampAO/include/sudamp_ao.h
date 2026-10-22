// SPDX-License-Identifier: LGPL-2.1-or-later
// sudamp pull AO — public C API used by the AudioRender bridge (DESIGN §5.2).
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Fixed output format of the pull AO: 48 kHz, stereo, planar float32 (matches AVAudioFormat's standard format).
#define SUDAMP_AO_SAMPLERATE 48000
#define SUDAMP_AO_CHANNELS 2

/// Pull up to `frames` planar float frames from mpv's AO queue. Safe on the real-time render thread
/// (trylock + the same ao_read_data call ao_coreaudio makes). `delay_ns` is the time until the first sample
/// written here reaches the speaker. Returns the number of frames copied (the rest is zero-filled), or -1 if no AO
/// is active or the lock is contended (buffers untouched; the caller outputs silence).
int sudamp_ao_read(float *left, float *right, int frames, int64_t delay_ns);

/// bit0 = AO initialised, bit1 = mpv has started the AO (it is streaming). Takes the AO lock: not for the IO thread.
int sudamp_ao_state(void);
/// 1 while mpv has started the AO (between its start and reset/uninit callbacks), else 0. Lock-free, so the
/// render callback can tell an underrun (streaming, short read) from a pause or idle (not streaming).
int sudamp_ao_is_streaming(void);
/// Sample rate of the active AO, or 0.
int sudamp_ao_samplerate(void);
/// Number of times mpv initialised this AO (guard: must be > 0 after the first file).
long long sudamp_ao_init_count(void);
/// Number of reads refused because the AO format/rate/channels were not floatp/48000/stereo (guard: must stay 0).
long long sudamp_ao_error_count(void);
/// The driver description compiled into this binary ("sudamp pull AO").
const char *sudamp_ao_description(void);

#ifdef __cplusplus
}
#endif
