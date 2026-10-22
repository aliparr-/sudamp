#pragma once
#include <stdint.h>
/// Pull up to `frames` planar float frames from mpv's AO queue (render-thread safe; same call ao_coreaudio makes).
/// delay_ns = time until the first sample written here reaches the speaker. Returns frames copied (rest is
/// zero-padded), or -1 if no AO is active (buffers untouched).
int sudamp_ao_read(float *left, float *right, int frames, int64_t delay_ns);
/// bit0 = AO initialised, bit1 = mpv asked AO to start (streaming)
int sudamp_ao_state(void);
int sudamp_ao_samplerate(void);
long long sudamp_ao_init_count(void);
