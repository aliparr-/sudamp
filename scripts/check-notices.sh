#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# THIRD_PARTY_NOTICES.md for sudamp (DESIGN §9, §10; PLAN M7 credits, M8 licence compliance).
#
# The link set is computed, not hand-kept: the binary targets of MPVKit's `MPVKit` product (the LGPL build sudamp
# depends on), read with `swift package dump-package` from the checkout matching Package.resolved, cross-checked
# against the linker map (`.build/sudamp-link.map`, written by every `sudamp` link) when one exists. Every library
# in that set, every system library MPVKit links, the bundled helpers and skins, and every MIT holder in
# PROVENANCE.md must have an entry in THIRD_PARTY_NOTICES.md; otherwise this script exits non-zero.
#
# Usage:
#   scripts/check-notices.sh                 check THIRD_PARTY_NOTICES.md (default; offline)
#   scripts/check-notices.sh --generate      rewrite THIRD_PARTY_NOTICES.md from the table below (fetches the
#                                            Apache-2.0 text once into ~/Library/Caches/sudamp-dev/notices, pinned)
#   scripts/check-notices.sh --link-set      print the computed link set (and linker-map object counts) and exit
#   scripts/check-notices.sh --list-sources  print key, version and source archive URL per entry (mirror-sources.sh)
# Options:
#   --notices FILE          check FILE instead (tests check a copy with an entry removed)
#   --link-map FILE|none    linker map to cross-check (default .build/sudamp-link.map when present)
#   --checkout DIR          MPVKit checkout (default: the .build*/checkouts/MPVKit matching Package.resolved)
#   --require-sources DIR   (M8) also require DIR to hold every source archive scripts/mirror-sources.sh lists
#
# Exit codes: 0 complete, 1 an entry is missing or out of date, 2 usage or environment error.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JQ=/usr/bin/jq
[ -x "$JQ" ] || JQ=jq
NOTICES="$ROOT/THIRD_PARTY_NOTICES.md"
MODE=check
LINK_MAP=""
CHECKOUT="${MPVKIT_CHECKOUT:-}"
SOURCES_DIR=""
CACHE="${SUDAMP_DEV_CACHE:-$HOME/Library/Caches/sudamp-dev}/notices"
APACHE_URL="https://www.apache.org/licenses/LICENSE-2.0.txt"
APACHE_SHA256="cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"

while [ $# -gt 0 ]; do
    case "$1" in
        --generate) MODE=generate; shift ;;
        --check) MODE=check; shift ;;
        --link-set) MODE=linkset; shift ;;
        --list-sources) MODE=sources; shift ;;
        --notices) NOTICES="$2"; shift 2 ;;
        --link-map) LINK_MAP="$2"; shift 2 ;;
        --checkout) CHECKOUT="$2"; shift 2 ;;
        --require-sources) SOURCES_DIR="$2"; shift 2 ;;
        -h|--help) sed -n '3,26p' "$0"; exit 0 ;;
        *) echo "check-notices: unknown argument $1" >&2; exit 2 ;;
    esac
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/check-notices.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------------------------------------------
# The component table. One line per notice entry, fields separated by '|':
#   key | binary targets (comma-separated; '-' for none) | name | version | built by (MPVKit release asset repo and
#   tag) | licence as used by sudamp (SPDX) | upstream | source archive | copyright | licence text | note
# Licence text: LGPL-2.1, LGPL-3.0 and Apache-2.0 are printed once at the end; GPL-3.0 is sudamp's own LICENSE;
# "embedded:<key>" is the component's own notice, copied verbatim from upstream at the pinned version (below).
# ---------------------------------------------------------------------------------------------------------------
IFS= read -r -d '' COMPONENTS <<'TABLE' || true
mpv|Libmpv|mpv|v0.41.0 with MPVKit patches 0001-0003, built with -Dgpl=false|MPVKit 1.0.0|LGPL-2.1-or-later|https://mpv.io|https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz|Copyright (C) the mpv developers; mpv is a fork of mplayer2 and MPlayer|LGPL-2.1|Built without GPL-only files (-Dgpl=false), with Lua (LuaJIT) and without JavaScript. Some source files carry BSD, MIT or ISC notices; see the Copyright file in the source archive. MPVKit's patches are in its tag 1.0.0 (Sources/BuildScripts/patch/libmpv).
ffmpeg|Libavcodec,Libavdevice,Libavfilter,Libavformat,Libavutil,Libswresample,Libswscale|FFmpeg (libavcodec, libavdevice, libavfilter, libavformat, libavutil, libswresample, libswscale)|n8.1.2, configured with --enable-version3 and without --enable-gpl or --enable-nonfree|MPVKit 1.0.0|LGPL-3.0-or-later|https://ffmpeg.org|https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz|Copyright (c) 2000-2026 the FFmpeg developers|LGPL-3.0|--enable-version3 turns FFmpeg's LGPL-2.1-or-later into LGPL-3.0-or-later. Some files carry MIT/X11/BSD-style notices; see LICENSE.md in the source archive. The configure line is embedded in libavutil (av_configuration).
openssl|Libcrypto,Libssl|OpenSSL (libcrypto, libssl)|3.3.5|openssl-build 3.3.5|Apache-2.0|https://openssl-library.org|https://github.com/openssl/openssl/releases/download/openssl-3.3.5/openssl-3.3.5.tar.gz|Copyright (c) 1998-2025 The OpenSSL Project Authors; Copyright (c) 1995-1998 Eric A. Young, Tim J. Hudson|Apache-2.0|In MPVKit's dependency graph; the sudamp link takes a few objects from libcrypto and none from libssl (FFmpeg's TLS is GnuTLS).
gnutls|gnutls|GnuTLS|3.8.11|gnutls-build 3.8.11|LGPL-2.1-or-later|https://gnutls.org|https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.11.tar.xz|Copyright (C) 2000-2025 Free Software Foundation, Inc. and others|LGPL-2.1|The library is LGPL-2.1-or-later; GnuTLS's command-line tools (GPL-3.0-or-later) are not included.
nettle|nettle,hogweed|Nettle (libnettle, libhogweed)|3.10|gnutls-build 3.8.11|LGPL-3.0-or-later|https://www.lysator.liu.se/~nisse/nettle/|https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz|Copyright (C) 2001-2024 Niels Möller and the Nettle contributors|LGPL-3.0|Dual-licensed LGPL-3.0-or-later or GPL-2.0-or-later; sudamp uses it under LGPL-3.0-or-later.
gmp|gmp|GNU Multiple Precision Arithmetic Library (GMP)|6.2.1|gnutls-build 3.8.11|LGPL-3.0-or-later|https://gmplib.org|https://gmplib.org/download/gmp/gmp-6.2.1.tar.xz|Copyright 1991-2020 Free Software Foundation, Inc.|LGPL-3.0|Dual-licensed LGPL-3.0-or-later or GPL-2.0-or-later; sudamp uses it under LGPL-3.0-or-later.
libass|Libass|libass|0.17.5|libass-build 0.17.5|ISC|https://github.com/libass/libass|https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz|Copyright (C) 2006-2016 libass contributors|embedded:libass|
freetype|Libfreetype|FreeType|2.14.3|libass-build 0.17.5|GPL-2.0-or-later (used under GPL-3.0-or-later)|https://freetype.org|https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz|Portions of this software are copyright (C) 2026 The FreeType Project (https://freetype.org). All rights reserved.|GPL-3.0|FreeType is dual-licensed under the FreeType License (FTL) or GPL-2.0 "or any later version"; sudamp takes the GPL option, compatible with its own GPL-3.0-or-later, and keeps the FreeType credit line above.
fribidi|Libfribidi|GNU FriBidi|1.0.16|libass-build 0.17.5|LGPL-2.1-or-later|https://github.com/fribidi/fribidi|https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz|Copyright (C) 2001-2024 the GNU FriBidi authors (Behdad Esfahbod, Dov Grobgeld, Roozbeh Pournader and others)|LGPL-2.1|
harfbuzz|Libharfbuzz|HarfBuzz|14.2.0|libass-build 0.17.5|MIT-Modern-Variant|https://harfbuzz.github.io|https://github.com/harfbuzz/harfbuzz/releases/download/14.2.0/harfbuzz-14.2.0.tar.xz|See the notice below|embedded:harfbuzz|HarfBuzz's "Old MIT" licence.
libunibreak|Libunibreak|libunibreak|6.1|libass-build 0.17.5|Zlib|https://github.com/adah1972/libunibreak|https://github.com/adah1972/libunibreak/archive/refs/tags/libunibreak_6_1.tar.gz|Copyright (C) Wu Yongwei, Tom Hacohen, Petr Filipsky, Andreas Röver|embedded:libunibreak|
libbluray|Libbluray|libbluray|1.4.0|libbluray-build 1.4.0|LGPL-2.1-or-later|https://www.videolan.org/developers/libbluray.html|https://download.videolan.org/pub/videolan/libbluray/1.4.0/libbluray-1.4.0.tar.xz|Copyright (C) 2009-2025 the libbluray authors|LGPL-2.1|
uchardet|Libuchardet|uchardet|0.0.8|libuchardet-build 0.0.8|LGPL-2.1-or-later|https://www.freedesktop.org/wiki/Software/uchardet/|https://www.freedesktop.org/software/uchardet/releases/uchardet-0.0.8.tar.xz|Copyright (C) 1998 Netscape Communications Corporation and the uchardet contributors|LGPL-2.1|Tri-licensed MPL-1.1, GPL-2.0-or-later or LGPL-2.1-or-later; sudamp uses it under LGPL-2.1-or-later.
luajit|Libluajit|LuaJIT|2.1.1784580905 (v2.1 branch at commit 2460b3ff93a1c955de3d62cfc825de7d68dc272e)|libluajit-build 2.1.0-fix|MIT|https://luajit.org|https://github.com/LuaJIT/LuaJIT/archive/2460b3ff93a1c955de3d62cfc825de7d68dc272e.tar.gz|Copyright (C) 2005-2026 Mike Pall; Lua 5.1/5.2 parts Copyright (C) 1994-2012 Lua.org, PUC-Rio|embedded:luajit|Linked because MPVKit builds mpv with Lua; sudamp runs no Lua (mpv load-scripts=no). The commit is the one whose committer time is the version's last number.
dav1d|Libdav1d|dav1d|1.5.3|libdav1d-build 1.5.3|BSD-2-Clause|https://code.videolan.org/videolan/dav1d|https://downloads.videolan.org/pub/videolan/dav1d/1.5.3/dav1d-1.5.3.tar.xz|Copyright (C) 2018-2025, VideoLAN and dav1d authors|embedded:dav1d|
uavs3d|Libuavs3d|uavs3d|1.2.1 (as reported by the library; libuavs3d-build pins the upstream source)|libuavs3d-build 1.2.1-fix|BSD-3-Clause|https://github.com/uavs3/uavs3d|https://github.com/uavs3/uavs3d/archive/refs/heads/master.tar.gz|Copyright (c) 2018-2022 Peking University Shenzhen Graduate School, Peng Cheng Laboratory and Guangdong Bohua UHD Innovation Corporation|embedded:uavs3d|M8: pin the exact upstream commit mpvkit/libuavs3d-build 1.2.1-fix built.
libplacebo|Libplacebo|libplacebo|7.360.1|libplacebo-build 7.360.1|LGPL-2.1-or-later|https://code.videolan.org/videolan/libplacebo|https://code.videolan.org/videolan/libplacebo/-/archive/v7.360.1/libplacebo-v7.360.1.tar.gz|Copyright (C) 2017-2026 Niklas Haas and the libplacebo contributors|LGPL-2.1|Also contains glad-generated OpenGL loaders and fast_float (Apache-2.0, MIT or BSL-1.0); M8 adds their texts.
lcms2|lcms2|Little CMS|2.17|lcms2-build 2.17.0|MIT|https://www.littlecms.com|https://github.com/mm2/Little-CMS/releases/download/lcms2.17/lcms2-2.17.tar.gz|Copyright (c) 2023 Marti Maria Saguer|embedded:lcms2|
libdovi|Libdovi|libdovi (dovi_tool)|3.3.2|libdovi-build 3.3.2|MIT|https://github.com/quietvoid/dovi_tool|https://github.com/quietvoid/dovi_tool/archive/refs/tags/libdovi-3.3.2.tar.gz|Copyright (c) 2025 quietvoid|embedded:dovi|A Rust static library: it also carries the Rust standard library (std, core, alloc, compiler_builtins, panic_abort; MIT or Apache-2.0), std's backtrace crates (addr2line, gimli, object, rustc-demangle; MIT or Apache-2.0), anyhow (MIT or Apache-2.0) and bitvec_helpers (MIT), per the linker map. sudamp uses them under Apache-2.0 (text below).
moltenvk|MoltenVK|MoltenVK|1.4.2|moltenvk-build 1.4.2|Apache-2.0|https://github.com/KhronosGroup/MoltenVK|https://github.com/KhronosGroup/MoltenVK/archive/refs/tags/v1.4.2.tar.gz|Copyright (c) 2015-2025 The Brenwill Workshop Ltd.|Apache-2.0|Includes SPIRV-Cross (Apache-2.0) and the Vulkan headers (Apache-2.0 or MIT). Linked because MPVKit's mpv and libplacebo enable Vulkan; sudamp renders no video.
shaderc|Libshaderc_combined|shaderc, combined with glslang, SPIRV-Tools and SPIRV-Headers|v2025.5 (glslang 7a47e2531cb3, SPIRV-Tools 262bdab48146, SPIRV-Headers b824a462d425)|libshaderc-build 2025.5.0|Apache-2.0 AND BSD-3-Clause AND MIT|https://github.com/google/shaderc|https://github.com/google/shaderc/archive/refs/tags/v2025.5.tar.gz|Copyright 2015-2025 The Shaderc Authors; glslang: Copyright (C) 2002-2005 3Dlabs Inc. Ltd., 2012-2016 LunarG, Inc., The Khronos Group Inc. and others|Apache-2.0|shaderc and SPIRV-Tools are Apache-2.0; glslang's licence file lists BSD-3-Clause, MIT and Apache-2.0 parts; SPIRV-Headers uses a Khronos MIT-style licence. M8 adds the glslang and SPIRV-Headers texts (sources at the revisions in shaderc's DEPS file).
TABLE

COMPONENTS=${COMPONENTS%$'\n'}

# Libraries MPVKit asks the linker for (`linkedLibrary`): part of macOS, linked dynamically, never redistributed.
IFS= read -r -d '' SYSTEM_LIBRARIES <<'TABLE' || true
libbz2|bzip2 compression|BSD-like (bzip2 licence), shipped with macOS
libc++|LLVM C++ standard library|Apache-2.0 WITH LLVM-exception, shipped with macOS
libexpat|Expat XML parser|MIT, shipped with macOS
libiconv|GNU libiconv (Apple's build)|LGPL, shipped with macOS
libresolv|DNS resolver|BSD, shipped with macOS
libxml2|libxml2|MIT, shipped with macOS
libz|zlib|Zlib, shipped with macOS
TABLE

SYSTEM_LIBRARIES=${SYSTEM_LIBRARIES%$'\n'}

# Who the PROVENANCE.md MIT holders are, for readable headings (unknown holders still get their notice).
IFS= read -r -d '' MIT_PROJECTS <<'TABLE' || true
Jordan Eldredge|Webamp|https://github.com/captbaritone/webamp
Ryan Romanosky and Bitamp contributors|Bitamp|https://github.com/ryanromanov/Bitamp
Valerii Bakalenko|wamp|https://github.com/wishval/wamp
Hank Yeomans|MacAmp|https://github.com/hfyeomans/MacAmp
OpenJS Foundation and other contributors|lodash (deburr letter table)|https://github.com/lodash/lodash
André Hickmann Kuschnereit|macamp|https://github.com/andrehickmann/macamp
TABLE
MIT_PROJECTS=${MIT_PROJECTS%$'\n'}

# ---------------------------------------------------------------------------------------------------------------
# Component notices, copied verbatim from upstream at the pinned versions (the source file is named per case).
# ---------------------------------------------------------------------------------------------------------------
embedded_text() {
    case "$1" in
        libass)  # libass 0.17.5 COPYING
            cat <<'TEXT'
ISC License

Copyright (C) 2006-2016 libass contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
TEXT
            ;;
        harfbuzz)  # harfbuzz 14.2.0 COPYING
            cat <<'TEXT'
HarfBuzz is licensed under the so-called "Old MIT" license.  Details follow.
For parts of HarfBuzz that are licensed under different licenses see individual
files names COPYING in subdirectories where applicable.

Copyright © 2010-2022  Google, Inc.
Copyright © 2015-2020  Ebrahim Byagowi
Copyright © 2019,2020  Facebook, Inc.
Copyright © 2012,2015  Mozilla Foundation
Copyright © 2011  Codethink Limited
Copyright © 2008,2010  Nokia Corporation and/or its subsidiary(-ies)
Copyright © 2009  Keith Stribley
Copyright © 2011  Martin Hosken and SIL International
Copyright © 2007  Chris Wilson
Copyright © 2005,2006,2020,2021,2022,2023  Behdad Esfahbod
Copyright © 2004,2007,2008,2009,2010,2013,2021,2022,2023  Red Hat, Inc.
Copyright © 1998-2005  David Turner and Werner Lemberg
Copyright © 2016  Igalia S.L.
Copyright © 2022  Matthias Clasen
Copyright © 2018,2021  Khaled Hosny
Copyright © 2018,2019,2020  Adobe, Inc
Copyright © 2013-2015  Alexei Podtelezhnikov

For full copyright notices consult the individual files in the package.


Permission is hereby granted, without written agreement and without
license or royalty fees, to use, copy, modify, and distribute this
software and its documentation for any purpose, provided that the
above copyright notice and the following two paragraphs appear in
all copies of this software.

IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE TO ANY PARTY FOR
DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES
ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN
IF THE COPYRIGHT HOLDER HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH
DAMAGE.

THE COPYRIGHT HOLDER SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING,
BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS FOR A PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS
ON AN "AS IS" BASIS, AND THE COPYRIGHT HOLDER HAS NO OBLIGATION TO
PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
TEXT
            ;;
        libunibreak)  # libunibreak_6_1 LICENCE
            cat <<'TEXT'
Copyright (C) Wu Yongwei <wuyongwei at gmail dot com>
Copyright (C) Tom Hacohen <tom at stosb dot com>
Copyright (C) Petr Filipsky <philodej at gmail dot com>
Copyright (C) Andreas Röver <roever at users dot sf dot net>

This software is provided 'as-is', without any express or implied
warranty.  In no event will the author be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software.  If you use this software
   in a product, an acknowledgement in the product documentation would
   be appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not
   be misrepresented as being the original software.
3. This notice may not be removed or altered from any source
   distribution.
TEXT
            ;;
        dav1d)  # dav1d 1.5.3 COPYING
            cat <<'TEXT'
Copyright © 2018-2025, VideoLAN and dav1d authors
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
TEXT
            ;;
        uavs3d)  # uavs3d master COPYING
            cat <<'TEXT'
Copyright (c) 2018-2022 ["Peking University Shenzhen Graduate School", "Peng Cheng Laboratory", and "Guangdong Bohua UHD Innovation Corporation"]

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
3. Neither the name of the organizations (Peking University Shenzhen Graduate School, Peng Cheng Laboratory and Guangdong Bohua UHD Innovation Corporation)
   nor the names of its contributors may be used to endorse or promote products
   derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
TEXT
            ;;
        lcms2)  # Little-CMS lcms2.17 LICENSE
            cat <<'TEXT'
MIT License

Copyright (c) 2023 Marti Maria Saguer

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the 
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to 
permit persons to whom the Software is furnished to do so, subject
to the following conditions:

The above copyright notice and this permission notice shall be 
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF 
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE 
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
TEXT
            ;;
        dovi)  # dovi_tool libdovi-3.3.2 LICENSE
            cat <<'TEXT'
MIT License

Copyright (c) 2025 quietvoid

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
TEXT
            ;;
        luajit)  # LuaJIT 2460b3ff COPYRIGHT
            cat <<'TEXT'
===============================================================================
LuaJIT -- a Just-In-Time Compiler for Lua. https://luajit.org/

Copyright (C) 2005-2026 Mike Pall. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

[ MIT license: https://www.opensource.org/licenses/mit-license.php ]

===============================================================================
[ LuaJIT includes code from Lua 5.1/5.2, which has this license statement: ]

Copyright (C) 1994-2012 Lua.org, PUC-Rio.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

===============================================================================
[ LuaJIT includes code from dlmalloc, which has this license statement: ]

This is a version (aka dlmalloc) of malloc/free/realloc written by
Doug Lea and released to the public domain, as explained at
https://creativecommons.org/licenses/publicdomain

===============================================================================
TEXT
            ;;
        quickjs-ng)  # quickjs-ng v0.17.0 LICENSE
            cat <<'TEXT'
The MIT License (MIT)
 
Copyright (c) 2017-2026 Fabrice Bellard
Copyright (c) 2017-2024 Charlie Gordon
Copyright (c) 2023-2026 Ben Noordhuis
Copyright (c) 2023-2026 Saúl Ibarra Corretgé

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
TEXT
            ;;
        *) echo "check-notices: no embedded text $1" >&2; exit 2 ;;
    esac
}

# ---------------------------------------------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------------------------------------------
FAILURES=0
fail() { echo "check-notices: $*" >&2; FAILURES=$((FAILURES + 1)); }
field() { echo "$1" | cut -d'|' -f"$2"; }

RESOLVED_REV=$("$JQ" -r '.pins[] | select(.identity == "mpvkit") | .state.revision' "$ROOT/Package.resolved")
RESOLVED_VERSION=$("$JQ" -r '.pins[] | select(.identity == "mpvkit") | .state.version' "$ROOT/Package.resolved")
if [ -z "$RESOLVED_REV" ] || [ "$RESOLVED_REV" = null ]; then
    echo "check-notices: MPVKit is not pinned in Package.resolved" >&2; exit 2
fi
QJS_VERSION=$(sed -nE 's/^QJS_VERSION="([^"]+)".*/\1/p' "$ROOT/scripts/fetch-qjs.sh")
QJS_SHA256=$(sed -nE 's/^QJS_SHA256="([^"]+)".*/\1/p' "$ROOT/scripts/fetch-qjs.sh")
MPV_HEADERS_VERSION=$(sed -nE 's/^Copied by .* from mpv (v[0-9.]+).*/\1/p' "$ROOT/Sources/SudampAO/vendor/README.md")
SKINS=$(cd "$ROOT/Fixtures/skins" && ls AndAmp-*.wsz 2>/dev/null | sort)
# Winamp Skin Museum skins bundle.sh copies into Contents/Resources/Skins/Museum (scripts/fetch-museum-skins.sh).
MUSEUM_COUNT=0
[ -f "$ROOT/Fixtures/skins/museum.json" ] && MUSEUM_COUNT=$("$JQ" '.skins | length' "$ROOT/Fixtures/skins/museum.json")
SPARKLE=0
grep -q -i 'sparkle' "$ROOT/Package.swift" && grep -q -E '\.package\(.*[Ss]parkle' "$ROOT/Package.swift" && SPARKLE=1
# "MIT © <holder>" entries of PROVENANCE.md, e.g. "2015 Jordan Eldredge".
MIT_HOLDERS=$({ grep -o 'MIT © [^;|(]*' "$ROOT/PROVENANCE.md" || true; } | sed -E 's/^MIT © //; s/[[:space:]]+$//' | LC_ALL=C sort -u)

if [ -n "$CHECKOUT" ]; then
    :
else
    for d in "$ROOT/.build/checkouts/MPVKit" "$ROOT"/.build*/checkouts/MPVKit; do
        [ -f "$d/Package.swift" ] || continue
        if [ "$(git -C "$d" rev-parse HEAD 2>/dev/null)" = "$RESOLVED_REV" ]; then CHECKOUT="$d"; break; fi
    done
fi
if [ -z "$CHECKOUT" ] || [ ! -f "$CHECKOUT/Package.swift" ]; then
    echo "check-notices: no MPVKit checkout at ${RESOLVED_REV:0:12} (run swift build, or pass --checkout DIR)" >&2; exit 2
fi
# dump-package on a copy, so nothing is written into the checkout.
mkdir -p "$TMP/manifest"
cp "$CHECKOUT/Package.swift" "$TMP/manifest/Package.swift"
if ! (cd "$TMP" && swift package --package-path "$TMP/manifest" dump-package >"$TMP/dump.json" 2>"$TMP/dump.err"); then
    cat "$TMP/dump.err" >&2; exit 2
fi

# Binary targets reachable from the MPVKit product (the LGPL build in Package.swift): "name<TAB>url".
LINK_SET=$("$JQ" -r '
    def deps($p; $t): [$p.targets[] | select(.name == $t) | .dependencies[]? | (.byName // .target // .product) | .[0]];
    . as $p
    | [$p.products[] | select(.name == "MPVKit") | .targets[]]
    | reduce range(0; 8) as $i (.; (. + [.[] as $t | deps($p; $t)[]]) | unique)
    | . as $closure
    | [$p.targets[] | select(.type == "binary" and (.name as $n | $closure | index($n))) | "\(.name)\t\(.url)"]
    | sort | .[]' "$TMP/dump.json")
SYSTEM_LINKED=$("$JQ" -r '
    def deps($p; $t): [$p.targets[] | select(.name == $t) | .dependencies[]? | (.byName // .target // .product) | .[0]];
    . as $p
    | [$p.products[] | select(.name == "MPVKit") | .targets[]]
    | reduce range(0; 8) as $i (.; (. + [.[] as $t | deps($p; $t)[]]) | unique)
    | . as $closure
    | [$p.targets[] | select(.name as $n | $closure | index($n)) | .settings[]? | select(.tool == "linker")
       | .kind.linkedLibrary._0? // empty] | unique | .[]' "$TMP/dump.json")
[ -n "$LINK_SET" ] || { echo "check-notices: MPVKit's manifest yielded no binary targets" >&2; exit 2; }

# "<repo> <tag>" of a release-asset URL: https://github.com/mpvkit/<repo>/releases/download/<tag>/<file>
built_by() { echo "$1" | sed -nE 's#^https://github.com/mpvkit/([^/]+)/releases/download/([^/]+)/.*#\1 \2#p'; }

# Object files the linker took from each MPVKit library (framework or archive), from the linker map.
if [ -z "$LINK_MAP" ] && [ -f "$ROOT/.build/sudamp-link.map" ]; then LINK_MAP="$ROOT/.build/sudamp-link.map"; fi
[ "$LINK_MAP" = none ] && LINK_MAP=""
LINKED_OBJECTS=""
if [ -n "$LINK_MAP" ]; then
    [ -f "$LINK_MAP" ] || { echo "check-notices: no linker map at $LINK_MAP" >&2; exit 2; }
    LINKED_OBJECTS=$(LC_ALL=C awk '/^# Object files:/ { on = 1; next } /^# Sections:/ { exit } on' "$LINK_MAP" \
        | { LC_ALL=C grep '/Products/' || true; } \
        | LC_ALL=C sed -nE 's#.*/([A-Za-z0-9_+-]+)\.framework/[^/(]+\(.*#\1#p; s#.*/lib([A-Za-z0-9_+-]+)\.a\(.*#\1#p' \
        | LC_ALL=C sort | uniq -c | awk '{ print $2 "\t" $1 }')
fi

# Fingerprint of everything the generated file is made from; a mismatch means the file is stale.
INPUTS_SHA=$( { cat "$0"; echo "$RESOLVED_REV"; echo "$LINK_SET"; echo "$SYSTEM_LINKED"; echo "$MIT_HOLDERS";
                echo "$QJS_VERSION $QJS_SHA256"; echo "$MPV_HEADERS_VERSION"; echo "$SKINS"; echo "$MUSEUM_COUNT"; echo "$SPARKLE"; } \
              | shasum -a 256 | cut -d' ' -f1)

component_for_target() {
    local target="$1"
    while IFS= read -r line; do
        case ",$(field "$line" 2)," in *",$target,"*) echo "$line"; return 0 ;; esac
    done <<<"$COMPONENTS"
    return 1
}

if [ "$MODE" = linkset ]; then
    echo "MPVKit $RESOLVED_VERSION ($RESOLVED_REV) from $CHECKOUT"
    printf '%-22s %-28s %s\n' "binary target" "built by" "objects linked"
    while IFS=$'\t' read -r name url; do
        objects=$(echo "$LINKED_OBJECTS" | awk -F'\t' -v n="$name" '$1 == n { print $2 }')
        printf '%-22s %-28s %s\n' "$name" "$(built_by "$url")" "${objects:-${LINK_MAP:+0}}"
    done <<<"$LINK_SET"
    echo "system libraries: $(echo $SYSTEM_LINKED)"
    exit 0
fi

if [ "$MODE" = sources ]; then
    # key<TAB>version<TAB>source URL, for scripts/mirror-sources.sh.
    while IFS= read -r line; do
        printf '%s\t%s\t%s\n' "$(field "$line" 1)" "$(field "$line" 4)" "$(field "$line" 8)"
    done <<<"$COMPONENTS"
    exit 0
fi

# ---------------------------------------------------------------------------------------------------------------
# Generate
# ---------------------------------------------------------------------------------------------------------------
licence_link() {
    case "$1" in
        LGPL-2.1) echo "[GNU LGPL v2.1](#gnu-lesser-general-public-license-version-21)" ;;
        LGPL-3.0) echo "[GNU LGPL v3.0](#gnu-lesser-general-public-license-version-3)" ;;
        Apache-2.0) echo "[Apache License 2.0](#apache-license-version-20)" ;;
        GPL-3.0) echo "[GNU GPL v3.0](#gnu-general-public-license-version-3)" ;;
        embedded:*) echo "reproduced below" ;;
    esac
}

mit_text() {
    cat <<TEXT
MIT License

Copyright (c) $1

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
TEXT
}

apache_text() {
    local cached="$CACHE/Apache-2.0.txt"
    if [ ! -f "$cached" ] || [ "$(shasum -a 256 "$cached" | cut -d' ' -f1)" != "$APACHE_SHA256" ]; then
        mkdir -p "$CACHE"
        curl -fsSL -A "sudamp-dev check-notices" -o "$cached.partial" "$APACHE_URL"
        [ "$(shasum -a 256 "$cached.partial" | cut -d' ' -f1)" = "$APACHE_SHA256" ] || {
            rm -f "$cached.partial"; echo "check-notices: $APACHE_URL changed (sha256 mismatch)" >&2; exit 2; }
        mv "$cached.partial" "$cached"
    fi
    cat "$cached"
}

generate() {
    local lgpl3="$CHECKOUT/LICENSE"
    head -2 "$lgpl3" | grep -q 'GNU LESSER GENERAL PUBLIC LICENSE' && head -2 "$lgpl3" | grep -q 'Version 3' \
        || { echo "check-notices: $lgpl3 is not the LGPL-3.0 text" >&2; exit 2; }
    cat <<HEADER
# Third-party notices

<!-- Generated by scripts/check-notices.sh --generate; do not edit by hand. inputs-sha256: $INPUTS_SHA -->

sudamp (The Sudden Amp) is free software under the GNU General Public License, version 3 or later (\`LICENSE\`); its
pull audio output (\`Sources/SudampAO\`) is LGPL-2.1-or-later. This file lists the third-party software in the
sudamp app, its licences and notices. It is generated from MPVKit $RESOLVED_VERSION's binary targets (revision
\`$RESOLVED_REV\`), \`scripts/fetch-qjs.sh\`, the bundled skins and \`PROVENANCE.md\`; \`scripts/check-notices.sh\`
fails if a linked library or bundled component has no entry. Human-readable credits are in \`CREDITS.md\` and the
app's About window.

**Corresponding source.** sudamp links libmpv, FFmpeg and the libraries below statically. Each sudamp release
attaches the complete corresponding source: the sudamp tag, MPVKit's build scripts and patches at tag
$RESOLVED_VERSION, and the source archive of every library listed here (\`scripts/mirror-sources.sh\`, DESIGN §10).
The LGPL lets you relink sudamp with modified versions of these libraries: build sudamp from that source with
your changed library in place of MPVKit's binary target.

## Linked libraries (MPVKit $RESOLVED_VERSION, static)

| Binary target | Component | Version | Licence | Built by | Notice |
|---|---|---|---|---|---|
HEADER
    while IFS=$'\t' read -r target url; do
        local line
        line=$(component_for_target "$target") || { echo "check-notices: no table entry for $target" >&2; exit 1; }
        [ "$(field "$line" 5)" = "$(built_by "$url")" ] || {
            echo "check-notices: MPVKit builds $target from $(built_by "$url"); update its table entry (version, source)" >&2; exit 1; }
        # Short cells: the name and version up to the first " (" or ", "; the notice has the details.
        printf '| `%s` | %s | %s | %s | %s | [%s](#%s) |\n' "$target" "$(field "$line" 3 | sed -E 's/ \(.*//; s/, .*//')" \
            "$(field "$line" 4 | sed -E 's/ \(.*//; s/, .*//')" \
            "$(field "$line" 6)" "$(built_by "$url")" "$(field "$line" 1)" "$(field "$line" 1)"
    done <<<"$LINK_SET"

    cat <<'SECTION'

## System libraries (part of macOS, not redistributed)

MPVKit's targets ask the linker for these; they are dynamic libraries that ship with macOS.

| Library | What | Licence |
|---|---|---|
SECTION
    for lib in $SYSTEM_LINKED; do
        local line
        line=$(echo "$SYSTEM_LIBRARIES" | awk -F'|' -v l="lib$lib" '$1 == l') || true
        [ -n "$line" ] || { echo "check-notices: no system-library entry for lib$lib" >&2; exit 1; }
        printf '| `%s` | %s | %s |\n' "$(field "$line" 1)" "$(field "$line" 2)" "$(field "$line" 3)"
    done

    cat <<SECTION

## Bundled components

| Component | What | Version | Licence | Where |
|---|---|---|---|---|
| \`qjs\` | [QuickJS-NG](#quickjs-ng) JavaScript runtime, yt-dlp's fallback JS engine (DESIGN §6.2) | $QJS_VERSION (\`qjs-darwin-arm64\`, sha256 \`${QJS_SHA256:0:16}…\`) | MIT | \`Contents/Helpers/qjs\` |
| \`mpv-headers\` | [mpv internal headers](#mpv-headers) compiled into SudampAO | $MPV_HEADERS_VERSION | LGPL-2.1-or-later | \`Sources/SudampAO/vendor/mpv\` |
SECTION
    for skin in $SKINS; do
        printf '| `%s` | [AndAmp](#andamp) %s skin by Mattix | mattijsf/andamp @ `1458304a` | CC-BY-4.0 | `Contents/Resources/Skins` |\n' \
            "$skin" "$(echo "$skin" | sed -E 's/AndAmp-(.*)\.wsz/\1/')"
    done
    if [ "$MUSEUM_COUNT" -gt 0 ]; then
        printf '| `Museum` | %s classic skins from the [Winamp Skin Museum](#winamp-skin-museum), each its author'"'"'s work | listed in `Fixtures/skins/museum.json` | none stated | `Contents/Resources/Skins/Museum` |\n' \
            "$MUSEUM_COUNT"
    fi
    if [ "$SPARKLE" = 1 ]; then
        echo '| `Sparkle` | Sparkle update framework | see Package.resolved | MIT | `Contents/Frameworks/Sparkle.framework` |'
    fi

    cat <<'SECTION'

## Not bundled

- **yt-dlp** (https://github.com/yt-dlp/yt-dlp, Unlicense) resolves streams. sudamp downloads it from yt-dlp's
  official releases on first launch, checks it against the release's SHA2-256SUMS, and never bundles,
  redistributes or hosts it. Its own build carries its third-party licences.
- **Other skins** the user adds (Open Skin…, drag-and-drop, Get More Skins…) are the user's own; sudamp only
  ships the skins above.

## Notices
SECTION
    while IFS= read -r line; do
        local key text
        key=$(field "$line" 1)
        text=$(field "$line" 10)
        printf '\n### %s\n\n' "$key"
        printf -- '- **%s**, %s\n' "$(field "$line" 3)" "$(field "$line" 4)"
        printf -- '- Binary targets: %s\n' "$(field "$line" 2 | sed -E 's/([^,]+)/`\1`/g; s/,/, /g')"
        printf -- '- Licence: %s (%s)\n' "$(field "$line" 6)" "$(licence_link "$text")"
        printf -- '- Upstream: %s\n' "$(field "$line" 7)"
        printf -- '- Source archive: %s\n' "$(field "$line" 8)"
        printf -- '- %s\n' "$(field "$line" 9)"
        local note
        note=$(field "$line" 11)
        [ -n "$note" ] && printf -- '- %s\n' "$note"
        case "$text" in
            embedded:*) printf '\n```text\n'; embedded_text "${text#embedded:}"; printf '```\n' ;;
        esac
    done <<<"$COMPONENTS"

    printf '\n### quickjs-ng\n\n'
    printf -- '- **QuickJS-NG** %s, `qjs-darwin-arm64` from https://github.com/quickjs-ng/quickjs/releases/tag/%s\n' "$QJS_VERSION" "$QJS_VERSION"
    printf -- '- Licence: MIT; source archive https://github.com/quickjs-ng/quickjs/archive/refs/tags/%s.tar.gz\n' "$QJS_VERSION"
    printf '\n```text\n'; embedded_text quickjs-ng; printf '```\n'

    cat <<SECTION

### mpv-headers

- **mpv internal headers**, $MPV_HEADERS_VERSION, copied unmodified into \`Sources/SudampAO/vendor/mpv\` by
  \`scripts/vendor-mpv-headers.sh\` so the pull AO can implement mpv's internal AO API.
- Licence: LGPL-2.1-or-later ($(licence_link LGPL-2.1)); \`Sources/SudampAO\` as a whole is LGPL-2.1-or-later.
- Copyright (C) the mpv developers

### andamp

- **AndAmp Dark**, **AndAmp Light** and **AndAmp Spot** skins by **Mattix** (https://mattix.nl), made for AndAmp
  (https://github.com/mattijsf/andamp), unmodified copies of \`skin/dist/\` at commit \`1458304a\`.
- Licence: Creative Commons Attribution 4.0 International (CC BY 4.0), https://creativecommons.org/licenses/by/4.0/
  ("The bundled skins are artwork. AndAmp Dark, Light and Spot … are licensed under CC BY 4.0"). The AndAmp name
  and icon are not licensed; sudamp names the skins only to credit them. See \`Fixtures/skins/CREDITS.md\`.
SECTION
    if [ "$MUSEUM_COUNT" -gt 0 ]; then
        cat <<SECTION

### winamp-skin-museum

- **$MUSEUM_COUNT classic skins** from the Winamp Skin Museum (https://skins.webamp.org, by Jordan Eldredge), listed
  by MD5, museum file name and menu name in \`Fixtures/skins/museum.json\` and bundled unmodified.
- Licence: none stated. Each skin is the work of its author and is credited by its museum file name in the Skins
  menu and the About window; neither the museum nor the Internet Archive records a licence or rights statement.
  They are bundled by the owner's decision (DESIGN §8.3) and are not covered by sudamp's GPL. Some show third-party
  trademarks, characters or photographs, which belong to their owners.
SECTION
    fi
    cat <<SECTION

## Code adapted from MIT-licensed projects

Files ported or adapted from these projects keep their notices in their headers; \`PROVENANCE.md\` maps each file to
its upstream commit.
SECTION
    while IFS= read -r holder; do
        [ -n "$holder" ] || continue
        local name project url
        name=$(echo "$holder" | sed -E 's/^[0-9][0-9-]*[[:space:]]+//')
        project=$(echo "$MIT_PROJECTS" | awk -F'|' -v n="$name" '$1 == n { print $2 }')
        url=$(echo "$MIT_PROJECTS" | awk -F'|' -v n="$name" '$1 == n { print $3 }')
        printf '\n### MIT © %s\n\n' "$holder"
        [ -n "$project" ] && printf '%s, %s\n' "$project" "$url"
        printf '\n```text\n'; mit_text "$holder"; printf '```\n'
    done <<<"$MIT_HOLDERS"

    cat <<'SECTION'

## Licence texts

### GNU General Public License, version 3

sudamp's own licence; its full text is `LICENSE` (in the app: `Contents/Resources/LICENSE`). The LGPL v3 below
refers to it.

### GNU Lesser General Public License, version 2.1

```text
SECTION
    cat "$ROOT/Sources/SudampAO/vendor/LICENSE.LGPL"
    printf '```\n\n### GNU Lesser General Public License, version 3\n\n```text\n'
    cat "$lgpl3"
    printf '```\n\n### Apache License, Version 2.0\n\n```text\n'
    apache_text
    printf '```\n'
}

if [ "$MODE" = generate ]; then
    generate > "$TMP/out.md"
    mv "$TMP/out.md" "$NOTICES"
    echo "check-notices: wrote $NOTICES ($(wc -l < "$NOTICES" | tr -d ' ') lines)"
fi

# ---------------------------------------------------------------------------------------------------------------
# Check
# ---------------------------------------------------------------------------------------------------------------
[ -f "$NOTICES" ] || { echo "check-notices: $NOTICES does not exist (run --generate)" >&2; exit 1; }
# The cells of the table row whose first cell is `id`, '|'-separated, trimmed.
row() { { LC_ALL=C grep -F "| \`$1\` |" "$NOTICES" || true; } | head -1 | sed -E 's/^\| *//; s/ *\|$//; s/ *\| */|/g'; }

grep -q "inputs-sha256: $INPUTS_SHA" "$NOTICES" \
    || fail "THIRD_PARTY_NOTICES.md is stale (its inputs changed): run scripts/check-notices.sh --generate"

TARGET_COUNT=0
while IFS=$'\t' read -r target url; do
    TARGET_COUNT=$((TARGET_COUNT + 1))
    r=$(row "$target")
    if [ -z "$r" ]; then
        fail "linked library \`$target\` ($(built_by "$url")) has no entry"
        continue
    fi
    [ "$(field "$r" 5)" = "$(built_by "$url")" ] \
        || fail "\`$target\`: the entry says built by '$(field "$r" 5)', MPVKit's manifest says '$(built_by "$url")'"
    if line=$(component_for_target "$target"); then
        [ "$(field "$line" 5)" = "$(built_by "$url")" ] \
            || fail "\`$target\`: MPVKit now builds it from $(built_by "$url"); update check-notices.sh's table and regenerate"
    else
        fail "\`$target\` is not in check-notices.sh's component table"
    fi
done <<<"$LINK_SET"

if [ -n "$LINKED_OBJECTS" ]; then
    while IFS=$'\t' read -r name count; do
        echo "$LINK_SET" | cut -f1 | grep -qx "$name" \
            || fail "the linker map shows $count objects from \`$name\`, which is not one of MPVKit's binary targets"
    done <<<"$LINKED_OBJECTS"
fi

for lib in $SYSTEM_LINKED; do
    [ -n "$(row "lib$lib")" ] || fail "system library \`lib$lib\` (linked by MPVKit) has no entry"
done

r=$(row qjs)
if [ -z "$r" ]; then fail "bundled \`qjs\` (QuickJS-NG) has no entry"
else case "$(field "$r" 3)" in "$QJS_VERSION "*) ;; *) fail "\`qjs\`: entry is not for $QJS_VERSION (scripts/fetch-qjs.sh)" ;; esac
fi
r=$(row mpv-headers)
[ -n "$r" ] && [ "$(field "$r" 3)" = "$MPV_HEADERS_VERSION" ] || fail "vendored mpv headers ($MPV_HEADERS_VERSION) have no entry"
for skin in $SKINS; do [ -n "$(row "$skin")" ] || fail "bundled skin \`$skin\` has no entry"; done
[ "$MUSEUM_COUNT" = 0 ] || [ -n "$(row Museum)" ] || fail "the $MUSEUM_COUNT bundled museum skins (\`Museum\`) have no entry"
[ "$SPARKLE" = 0 ] || [ -n "$(row Sparkle)" ] || fail "Sparkle is a dependency but has no entry"
while IFS= read -r holder; do
    [ -z "$holder" ] || LC_ALL=C grep -qF "### MIT © $holder" "$NOTICES" || fail "PROVENANCE.md's MIT © $holder has no notice"
done <<<"$MIT_HOLDERS"
grep -q '^### GNU Lesser General Public License, version 2.1' "$NOTICES" || fail "the LGPL-2.1 text is missing"
grep -q '^### GNU Lesser General Public License, version 3' "$NOTICES" || fail "the LGPL-3.0 text is missing"
grep -q '^### Apache License, Version 2.0' "$NOTICES" || fail "the Apache-2.0 text is missing"

if [ -n "$SOURCES_DIR" ]; then
    while IFS= read -r line; do
        archive=$(basename "$(field "$line" 8)")
        [ -s "$SOURCES_DIR/$(field "$line" 1)-$archive" ] || [ -s "$SOURCES_DIR/$archive" ] \
            || fail "no mirrored source archive for $(field "$line" 1) ($archive) in $SOURCES_DIR"
    done <<<"$COMPONENTS"
fi

if [ "$FAILURES" -gt 0 ]; then
    echo "check-notices: $FAILURES problem(s) in $NOTICES" >&2
    exit 1
fi
echo "check-notices: OK ($TARGET_COUNT MPVKit binary targets, $(echo $SYSTEM_LINKED | wc -w | tr -d ' ') system libraries, qjs, mpv headers, $(echo $SKINS | wc -w | tr -d ' ') skins, $MUSEUM_COUNT museum skins, $(echo "$MIT_HOLDERS" | grep -c .) MIT notices${LINK_MAP:+; linker map cross-checked})"
