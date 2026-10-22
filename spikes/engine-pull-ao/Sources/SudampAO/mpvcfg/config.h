/* Minimal config.h so mpv 0.41.0 internal AO headers compile outside mpv's meson build (spike only). */
#pragma once
#define HAVE_POSIX 1
#define HAVE_DARWIN 1
#define HAVE_WIN32_DESKTOP 0
#define HAVE_ANDROID 0
