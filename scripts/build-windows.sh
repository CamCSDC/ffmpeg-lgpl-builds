#!/usr/bin/env bash
#
# build-windows.sh — Compile an LGPL-only FFmpeg for Windows.
#
# EvoIMS fork (CamCSDC/ffmpeg-lgpl-builds): adds zlib, FreeType and HarfBuzz,
# built here from SHA256-pinned release tarballs, so the binary has the drawtext
# filter (FFmpeg 8.1 needs both FreeType and HarfBuzz for it) and the PNG encoder
# (zlib) that EvoIMS's case-story videos and waveform pictures need. All three
# are permissively licensed (zlib licence; FreeType under the FTL; HarfBuzz under
# the "Old MIT" licence), so the build stays LGPL-2.1-only. Each is built with
# its optional dependencies off — FreeType without HarfBuzz, Brotli, bzip2 and
# libpng; HarfBuzz without GLib, ICU, cairo and graphite2 — because MSYS2's own
# packages would drag in GLib/graphite2/libintl, which are LGPL and would widen
# what ships.
#
# Run inside an MSYS2 MINGW64 shell with the toolchain + encoder header
# packages installed (see .github/workflows/build.yml for the package list).
#
# Usage:
#   scripts/build-windows.sh --target x86_64-pc-windows-msvc
#
# Produces self-contained ffmpeg.exe + ffprobe.exe binaries plus the runtime
# DLLs they (transitively) import, bundled in a tarball at:
#
#   dist/x86_64-pc-windows-msvc/
#     ffmpeg.exe
#     ffprobe.exe
#     libvpl-2.dll                          (Intel QSV dispatcher)
#     libwinpthread-1.dll                   (mingw-w64 pthread runtime)
#     libgcc_s_seh-1.dll                    (GCC unwinder — libvpl dep)
#     libstdc++-6.dll                       (GCC C++ runtime — libvpl dep)
#     libopenh264-7.dll                     (Cisco OpenH264 — software H.264 encoder)
#     COPYING.LGPLv2.1
#     LIBVPL-LICENSE.txt
#     LIBWINPTHREAD-LICENSE.txt
#     LIBOPENH264-LICENSE.txt
#     FREETYPE-LICENSE.txt                  (FreeType Project License)
#     HARFBUZZ-LICENSE.txt                  ("Old MIT")
#     ZLIB-LICENSE.txt
#     GCC-RUNTIME-LIBRARY-EXCEPTION.txt
#     GCC-LICENSE.txt
#     SOURCE.txt
#     ffmpeg-<version>-<triple>.tar.gz
#     ffmpeg-<version>-<triple>.tar.gz.sha256
#
# Builds with mingw-w64 gcc even though the triple says "msvc" — the triple
# is a consumer convention (Rust, vendor.toml) for "Windows x64"; the
# resulting PE executable is ABI-identical from a subprocess caller's view.
# SOURCE.txt records the actual toolchain used so there's no ambiguity.
#
# Idempotent: caches the source tarball and the unpacked tree under build/.
# Remove build/ for a clean rebuild.
#
set -euo pipefail

# ---- args -------------------------------------------------------------------
TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            TARGET="$2"
            shift 2
            ;;
        *)
            echo "unknown arg: $1" >&2
            echo "usage: $0 --target x86_64-pc-windows-msvc" >&2
            exit 2
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "missing required --target flag" >&2
    echo "usage: $0 --target x86_64-pc-windows-msvc" >&2
    exit 2
fi

case "$TARGET" in
    x86_64-pc-windows-msvc) ;;
    *)
        echo "unsupported target: $TARGET" >&2
        echo "currently only x86_64-pc-windows-msvc is supported" >&2
        exit 2
        ;;
esac

# ---- environment check ------------------------------------------------------
# Must run inside MSYS2's MINGW64 shell so PATH points at mingw gcc, not the
# msys-gcc (which would emit binaries linked against the MSYS2 POSIX runtime).
if [ "${MSYSTEM:-}" != "MINGW64" ]; then
    echo "✗ this script must run inside an MSYS2 MINGW64 shell (got MSYSTEM=${MSYSTEM:-unset})" >&2
    exit 1
fi

# ---- config -----------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -f "$REPO_ROOT/VERSION" ]; then
    echo "missing $REPO_ROOT/VERSION" >&2
    exit 1
fi
FFMPEG_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"

# Defence-in-depth: pinned tarball SHA256, mirrored from scripts/build-macos.sh.
# Bumping VERSION without adding a branch here aborts the build.
case "$FFMPEG_VERSION" in
    8.1.2) SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c" ;;
    8.1.1) SHA256="b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3" ;;
    *)
        echo "✗ no pinned SHA256 for FFmpeg $FFMPEG_VERSION in scripts/build-windows.sh" >&2
        echo "  add a case branch after verifying against ffmpeg.org" >&2
        exit 1
        ;;
esac

BUILD_ROOT="${REPO_ROOT}/build/${TARGET}"
TARBALL="${REPO_ROOT}/build/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SOURCE_DIR="${BUILD_ROOT}/ffmpeg-${FFMPEG_VERSION}"
PREFIX="${BUILD_ROOT}/install"
TARBALL_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
OUT_DIR="${REPO_ROOT}/dist/${TARGET}"

mkdir -p "$BUILD_ROOT" "$OUT_DIR" "$(dirname "$TARBALL")"

# ---- prereq verification ----------------------------------------------------
# Anchor pkg-config to the MINGW64 install so neither this script's checks
# nor FFmpeg's configure can pick up the msys2-native pkg-config (which
# wouldn't see /mingw64/lib/pkgconfig/) if PATH order ever shifted.
export PKG_CONFIG=/mingw64/bin/pkg-config
export PKG_CONFIG_PATH=/mingw64/lib/pkgconfig:/mingw64/share/pkgconfig

for tool in gcc make nasm git "$PKG_CONFIG" curl tar sha256sum strings objdump; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "✗ $tool not found in PATH" >&2
        echo "  install MSYS2 MINGW64 toolchain + dependencies; see .github/workflows/build.yml" >&2
        exit 1
    fi
done

# Pin nv-codec-headers (the NVENC/NVDEC API stubs) from source rather than using
# MSYS2's latest. The header version sets the MINIMUM NVIDIA driver NVENC accepts
# at runtime. FFmpeg 8.1.x's configure accepts a cascade of header versions, each
# mapping to a driver floor (Windows):
#     >= 12.1.14.0              → 531.61   ~Mar 2023
#     >= 12.0.16.1  && < 12.1   → 522.25   ~Oct 2022
#     >= 11.1.5.3   && < 12.0   → 471.41   ~Jul 2021   ← we pick this
#     >= 11.0.10.3  && < 11.1   → 456.71   ~Sep 2020
# MSYS2's default (n13.0) demands driver 570+ (Feb 2025), which locks out most
# streamers. We pick the oldest tier that still carries every NVENC feature
# Polycast's H.264 argv uses — p-presets, -tune, spatial/temporal AQ, B-frame
# refs, rc-lookahead, all present since SDK 10 / API 11.x — giving a ~5-year-old
# driver floor that covers essentially any NVIDIA GPU updated since 2021.
# NOTE: the cascade boundaries are exact — e.g. n12.0.16.0 is REJECTED because
# the 12.0 tier requires >= .16.1. Bump only if a future FFmpeg drops a tier.
NVCODEC_TAG="n11.1.5.3"
NVCODEC_DIR="${BUILD_ROOT}/nv-codec-headers"
if [ ! -d "$NVCODEC_DIR/.git" ]; then
    rm -rf "$NVCODEC_DIR"
    git clone --depth 1 --branch "$NVCODEC_TAG" \
        https://github.com/FFmpeg/nv-codec-headers.git "$NVCODEC_DIR"
fi
echo "▶ installing pinned nv-codec-headers ${NVCODEC_TAG} (min NVIDIA driver 471.41 Win / 470.57.02 Linux)"
make -C "$NVCODEC_DIR" PREFIX=/mingw64 install

# Encoder packages. NVENC (just installed above) + libvpl + openh264 ship
# pkg-config files; AMF is header-only and detected by a path probe. openh264
# is the BSD-2-Clause software H.264 encoder used as the CPU fallback.
for pcfile in ffnvcodec vpl openh264; do
    if ! "$PKG_CONFIG" --exists "$pcfile" 2>/dev/null; then
        echo "✗ pkg-config can't find $pcfile" >&2
        case "$pcfile" in
            ffnvcodec) echo "  the pinned nv-codec-headers ${NVCODEC_TAG} build/install above failed — check git clone + make" >&2 ;;
            vpl)       echo "  install: pacman -S mingw-w64-x86_64-libvpl" >&2 ;;
            openh264)  echo "  install: pacman -S mingw-w64-x86_64-openh264" >&2 ;;
        esac
        exit 1
    fi
done
if [ ! -f /mingw64/include/AMF/core/Factory.h ]; then
    echo "✗ AMF headers not found at /mingw64/include/AMF/" >&2
    echo "  install: pacman -S mingw-w64-x86_64-amf-headers" >&2
    exit 1
fi

# ---- zlib + FreeType (EvoIMS fork) -------------------------------------------
# Built from upstream release tarballs, each pinned by SHA256 (and verified by
# their maintainers' signatures when the pins were taken: zlib by Mark Adler,
# 5ED4 6A67 21D3 6558 7791 E2AA 783F CD8E 58BC AFBA; FreeType by Werner Lemberg,
# E306 7470 7856 409F F194 8010 BE6C 3AAC 63AD 8E3F). Static, into a private
# prefix, so FFmpeg links exactly these and nothing MSYS2 happens to carry.
# The tarballs are kept under build/sources/ and attached to each release as
# the corresponding source.
ZLIB_VERSION="1.3.2"
ZLIB_SHA256="bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"
ZLIB_URLS=("https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
           "https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz")
FREETYPE_VERSION="2.14.3"
FREETYPE_SHA256="36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f"
FREETYPE_URLS=("https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"
               "https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE_VERSION}/freetype-${FREETYPE_VERSION}.tar.xz")
# HarfBuzz publishes no signatures; the pin matches the SHA256 digest GitHub
# records for the release asset.
HARFBUZZ_VERSION="14.4.0"
HARFBUZZ_SHA256="2357ed966c6ced7bfa720b0640c0231065af01158fbea215093ffa15aed44371"
HARFBUZZ_URLS=("https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz")

SOURCES_DIR="${REPO_ROOT}/build/sources"
DEPS_PREFIX="${BUILD_ROOT}/deps"
mkdir -p "$SOURCES_DIR" "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib/pkgconfig"

# fetch_verified <file> <sha256> <url>... — the first mirror that answers, then
# the pinned hash, or stop.
fetch_verified() {
    local file="$1" sha="$2"
    shift 2
    if [ ! -f "$SOURCES_DIR/$file" ]; then
        local url
        for url in "$@"; do
            echo "▶ downloading $file from $url"
            if curl -fL --retry 3 "$url" -o "$SOURCES_DIR/$file.partial"; then
                mv "$SOURCES_DIR/$file.partial" "$SOURCES_DIR/$file"
                break
            fi
        done
    fi
    if [ ! -f "$SOURCES_DIR/$file" ]; then
        echo "✗ could not download $file from any mirror" >&2
        exit 1
    fi
    local actual
    actual="$(sha256sum "$SOURCES_DIR/$file" | awk '{print $1}')"
    if [ "$actual" != "$sha" ]; then
        echo "✗ checksum mismatch for $file" >&2
        echo "   expected: $sha" >&2
        echo "   actual:   $actual" >&2
        exit 1
    fi
    echo "  ✓ $file sha256 ok"
}

ZLIB_SRC="${BUILD_ROOT}/zlib-${ZLIB_VERSION}"
FREETYPE_SRC="${BUILD_ROOT}/freetype-${FREETYPE_VERSION}"
HARFBUZZ_SRC="${BUILD_ROOT}/harfbuzz-${HARFBUZZ_VERSION}"

if [ ! -f "$DEPS_PREFIX/lib/libz.a" ]; then
    fetch_verified "zlib-${ZLIB_VERSION}.tar.gz" "$ZLIB_SHA256" "${ZLIB_URLS[@]}"
    rm -rf "$ZLIB_SRC"
    tar -xf "$SOURCES_DIR/zlib-${ZLIB_VERSION}.tar.gz" -C "$BUILD_ROOT"
    echo "▶ building zlib ${ZLIB_VERSION} (static)"
    make -C "$ZLIB_SRC" -f win32/Makefile.gcc libz.a CFLAGS="-O3 -Wall"
    cp "$ZLIB_SRC/libz.a" "$DEPS_PREFIX/lib/"
    cp "$ZLIB_SRC/zlib.h" "$ZLIB_SRC/zconf.h" "$DEPS_PREFIX/include/"
    cat > "$DEPS_PREFIX/lib/pkgconfig/zlib.pc" <<EOF
prefix=${DEPS_PREFIX}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: zlib
Description: zlib compression library
Version: ${ZLIB_VERSION}
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
EOF
else
    echo "✓ zlib ${ZLIB_VERSION} already built"
fi

# Ours first, so FreeType's configure and FFmpeg's both find this zlib and FreeType.
export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"

if [ ! -f "$DEPS_PREFIX/lib/libfreetype.a" ]; then
    fetch_verified "freetype-${FREETYPE_VERSION}.tar.xz" "$FREETYPE_SHA256" "${FREETYPE_URLS[@]}"
    rm -rf "$FREETYPE_SRC"
    tar -xf "$SOURCES_DIR/freetype-${FREETYPE_VERSION}.tar.xz" -C "$BUILD_ROOT"
    echo "▶ building FreeType ${FREETYPE_VERSION} (static; zlib only — no HarfBuzz, Brotli, bzip2 or libpng)"
    (
        cd "$FREETYPE_SRC"
        ./configure \
            --prefix="$DEPS_PREFIX" \
            --enable-static --disable-shared \
            --with-zlib=yes \
            --with-bzip2=no --with-png=no --with-harfbuzz=no --with-brotli=no \
            CFLAGS="-O3" \
            CPPFLAGS="-I${DEPS_PREFIX}/include" \
            LDFLAGS="-L${DEPS_PREFIX}/lib"
        make -j"$(nproc)"
        make install
    )
else
    echo "✓ FreeType ${FREETYPE_VERSION} already built"
fi

if [ ! -f "$DEPS_PREFIX/lib/libharfbuzz.a" ]; then
    for tool in meson ninja g++; do
        command -v "$tool" >/dev/null 2>&1 || { echo "✗ $tool not found (needed for HarfBuzz)" >&2; exit 1; }
    done
    fetch_verified "harfbuzz-${HARFBUZZ_VERSION}.tar.xz" "$HARFBUZZ_SHA256" "${HARFBUZZ_URLS[@]}"
    rm -rf "$HARFBUZZ_SRC"
    tar -xf "$SOURCES_DIR/harfbuzz-${HARFBUZZ_VERSION}.tar.xz" -C "$BUILD_ROOT"
    echo "▶ building HarfBuzz ${HARFBUZZ_VERSION} (static; FreeType only — no GLib, ICU, cairo or graphite2)"
    # Everything optional off except FreeType, which drawtext uses through hb-ft;
    # no subprojects fetched, so nothing arrives that is not in the pinned tarball.
    meson setup "$HARFBUZZ_SRC/_build" "$HARFBUZZ_SRC" \
        --prefix="$DEPS_PREFIX" --libdir=lib \
        --buildtype=release --default-library=static --wrap-mode=nofallback \
        -Dfreetype=enabled \
        -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled \
        -Dpng=disabled -Dzlib=disabled -Dicu=disabled \
        -Dgraphite=disabled -Dgraphite2=disabled \
        -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Dutilities=disabled \
        -Dsubset=disabled -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dgpu_demo=disabled
    meson compile -C "$HARFBUZZ_SRC/_build"
    meson install -C "$HARFBUZZ_SRC/_build"
else
    echo "✓ HarfBuzz ${HARFBUZZ_VERSION} already built"
fi

for pcfile in zlib freetype2 harfbuzz; do
    if ! "$PKG_CONFIG" --exists "$pcfile"; then
        echo "✗ pkg-config can't find $pcfile after building it" >&2
        exit 1
    fi
done
# MSYS2's pkgconf answers with a Windows path (D:/a/...) where the script holds an
# MSYS one (/d/a/...), so both are put in the same form before comparing.
FT_PREFIX="$(cygpath -m "$("$PKG_CONFIG" --variable=prefix freetype2)")"
WANT_PREFIX="$(cygpath -m "$DEPS_PREFIX")"
if [ "${FT_PREFIX,,}" = "${WANT_PREFIX,,}" ]; then
    echo "  ✓ FFmpeg will link this FreeType, not MSYS2's"
else
    echo "✗ pkg-config resolves freetype2 to $FT_PREFIX, not $WANT_PREFIX" >&2
    exit 1
fi

# ---- fetch ------------------------------------------------------------------
if [ ! -f "$TARBALL" ]; then
    echo "▶ downloading ffmpeg ${FFMPEG_VERSION} source"
    curl -fL "$TARBALL_URL" -o "$TARBALL.partial"
    mv "$TARBALL.partial" "$TARBALL"
else
    echo "✓ tarball cached at $TARBALL"
fi

# ---- verify -----------------------------------------------------------------
echo "▶ verifying checksum"
ACTUAL_SHA256="$(sha256sum "$TARBALL" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$SHA256" ]; then
    echo "✗ checksum mismatch for $TARBALL" >&2
    echo "   expected: $SHA256" >&2
    echo "   actual:   $ACTUAL_SHA256" >&2
    exit 1
fi
echo "  ✓ sha256 ok"

# ---- extract ----------------------------------------------------------------
if [ ! -d "$SOURCE_DIR" ]; then
    echo "▶ extracting"
    tar -xf "$TARBALL" -C "$BUILD_ROOT"
else
    echo "✓ source tree present at $SOURCE_DIR"
fi

# ---- configure --------------------------------------------------------------
cd "$SOURCE_DIR"

STAMP="${SOURCE_DIR}/.configured-for-${TARGET}"
if [ ! -f "$STAMP" ]; then
    echo "▶ configuring (LGPL only, NVENC + QSV + AMF + libopenh264 CPU fallback, Schannel TLS) for ${TARGET}"
    # Flag rationale (deltas from build-macos.sh in parens):
    #   --disable-gpl / --nonfree / --version3 / --autodetect
    #                              same — license discipline + no surprise deps
    #   --enable-static / --disable-shared
    #                              same — one self-contained binary
    #   --disable-programs --enable-ffmpeg --enable-ffprobe
    #                              same — ship the two CLI tools
    #   --enable-ffnvcodec         the NVIDIA codec headers library. Must be
    #                              named explicitly because --disable-autodetect
    #                              blocks the implicit auto-enable that nvenc
    #                              would otherwise pull in.
    #   --enable-nvenc             (mac h264_videotoolbox → Windows NVIDIA NVENC)
    #   --enable-amf               (… AMD AMF on Polaris+/Ryzen APUs)
    #   --enable-libvpl            (… Intel QSV via oneVPL dispatcher)
    #   --enable-libopenh264       software (CPU) H.264 fallback for hosts with no
    #                              usable GPU encoder. BSD-2-Clause → LGPL-clean, so
    #                              it doesn't trip the forbidden-flag guardrail below.
    #   --enable-schannel          (mac --enable-securetransport → Windows Schannel)
    #   --target-os=mingw32        FFmpeg's identifier for the mingw-w64 target
    #                              regardless of bitness (legacy naming)
    #   --pkg-config=$PKG_CONFIG   pin the MINGW64 pkg-config explicitly so the
    #                              cross-compile heuristic in FFmpeg's configure
    #                              can't pick up the msys2-native one
    #   --pkg-config-flags=--static
    #                              ask pkg-config for the static dep chain so
    #                              transitive libs (e.g. libvpl's deps) link
    #                              correctly
    #   --extra-ldflags="-static-libgcc"
    #                              static libgcc keeps libgcc_s_seh-1.dll out of
    #                              *ffmpeg.exe's own* import table. It comes back
    #                              transitively anyway: libvpl-2.dll (a prebuilt
    #                              mingw DLL we can't relink) imports both
    #                              libgcc_s_seh-1.dll and libstdc++-6.dll, so we
    #                              bundle those at stage time. We don't try to
    #                              also static-link libwinpthread because FFmpeg's
    #                              EXTRALIBS injects -lpthread late in the link
    #                              command, after any -Bstatic switch in our
    #                              extra-ldflags has been reset by FFmpeg's own
    #                              flags — so libwinpthread-1.dll inevitably
    #                              shows up in the import table too. The
    #                              transitive audit below is the backstop that
    #                              guarantees we've bundled the full closure.
    ./configure \
        --prefix="$PREFIX" \
        --disable-gpl --disable-nonfree --disable-version3 \
        --disable-autodetect \
        --enable-static --disable-shared \
        --disable-programs --enable-ffmpeg --enable-ffprobe \
        --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
        --disable-debug \
        --enable-ffnvcodec \
        --enable-nvenc \
        --enable-amf \
        --enable-libvpl \
        --enable-libopenh264 \
        --enable-schannel \
        --enable-zlib \
        --enable-libfreetype \
        --enable-libharfbuzz \
        --enable-encoder=h264_nvenc,hevc_nvenc,h264_amf,hevc_amf,h264_qsv,hevc_qsv,libopenh264,aac \
        --enable-decoder=h264,hevc,aac,mp3,pcm_s16le,pcm_s24le,pcm_f32le \
        --enable-muxer=flv,mp4,mov \
        --enable-demuxer=flv,mpegts,mov,mp4 \
        --enable-parser=h264,hevc,aac \
        --enable-protocol=rtmp,rtmps,tls,tcp,udp,file,pipe \
        --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb \
        --enable-filter=scale,fps,format,aresample,asetnsamples,anull,null,copy \
        --arch=x86_64 --target-os=mingw32 \
        --cc=gcc \
        --pkg-config="$PKG_CONFIG" \
        --pkg-config-flags=--static \
        --extra-cflags="-O3 -I${DEPS_PREFIX}/include" \
        --extra-ldflags="-static-libgcc -L${DEPS_PREFIX}/lib"
    touch "$STAMP"
else
    echo "✓ already configured (rm $STAMP to reconfigure)"
fi

# ---- build ------------------------------------------------------------------
echo "▶ building (this takes a few minutes)"
make -j"$(nproc)"
make install

BIN="${PREFIX}/bin/ffmpeg.exe"
FFPROBE_BIN="${PREFIX}/bin/ffprobe.exe"
if [ ! -x "$BIN" ]; then
    echo "✗ build did not produce $BIN" >&2
    exit 1
fi
if [ ! -x "$FFPROBE_BIN" ]; then
    echo "✗ build did not produce $FFPROBE_BIN" >&2
    exit 1
fi

# ---- verify the binary ------------------------------------------------------
echo "▶ verifying binary"

# Read the configuration string out of the binary directly. Defence-in-depth
# even though we set the flags ourselves — catches an autodetect leak.
CONFIG_LINE="$(strings "$BIN" | grep -E 'configuration:.*--disable-gpl' | head -n1 || true)"
if [ -z "$CONFIG_LINE" ]; then
    echo "✗ couldn't find embedded configuration string in $BIN" >&2
    exit 1
fi
for forbidden in '--enable-gpl' '--enable-nonfree' '--enable-version3'; do
    if echo "$CONFIG_LINE" | grep -q -- "$forbidden"; then
        echo "✗ binary has $forbidden — refusing to ship" >&2
        echo "   $CONFIG_LINE" >&2
        exit 1
    fi
done
echo "  ✓ no GPL / non-free / v3 flags"

# Confirm each expected encoder ended up baked in. Same string-scan pattern
# as build-macos.sh; captures `strings` output once to avoid pipefail / EPIPE
# when grep -q would close the pipe early.
SYMS="$(strings "$BIN")"
for needed in 'h264_nvenc' 'hevc_nvenc' 'h264_amf' 'hevc_amf' 'h264_qsv' 'hevc_qsv' 'libopenh264' 'aac '; do
    case "$SYMS" in
        *"$needed"*) ;;
        *)
            echo "✗ binary missing expected symbol: $needed" >&2
            exit 1
            ;;
    esac
done
echo "  ✓ nvenc + amf + qsv + libopenh264 + aac encoders present"

# ---- stage ------------------------------------------------------------------
echo "▶ staging to $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp "$BIN" "$OUT_DIR/ffmpeg.exe"
cp "$FFPROBE_BIN" "$OUT_DIR/ffprobe.exe"

# Runtime DLLs we ship next to ffmpeg.exe. ffmpeg.exe imports libvpl-2.dll and
# libwinpthread-1.dll directly; libvpl-2.dll in turn imports the mingw-w64 GCC
# runtime (libgcc_s_seh-1.dll, libstdc++-6.dll). Because ffmpeg.exe imports
# libvpl-2.dll unconditionally (not delay-loaded), the GCC runtime must ship
# too or ffmpeg.exe fails to start (STATUS_DLL_NOT_FOUND, 0xC0000135) on any
# machine without the MSYS2 toolchain on PATH. The transitive audit below
# enforces that this list is the complete closure.
#
#   libvpl-2.dll        — Intel oneVPL dispatcher (MIT). Can't static-link; the
#                         dispatcher's whole job is loading the vendor runtime
#                         at runtime.
#   libwinpthread-1.dll — mingw-w64 pthread runtime (BSD-style permissive).
#   libgcc_s_seh-1.dll  — GCC unwinder runtime. GPLv3 WITH the GCC Runtime
#   libstdc++-6.dll       Library Exception, which explicitly permits shipping
#                         these alongside a GCC-compiled program without
#                         imposing copyleft on that program.
#   libopenh264-7.dll   — Cisco OpenH264 software H.264 encoder (BSD-2-Clause).
#                         MSYS2 links it as a DLL (its import lib wins over the
#                         static archive), so it ships next to ffmpeg.exe. The
#                         glob tolerates openh264 soname bumps across rebuilds.
for src in \
    /mingw64/bin/libvpl-2.dll \
    /mingw64/bin/libwinpthread-1.dll \
    /mingw64/bin/libgcc_s_seh-1.dll \
    /mingw64/bin/libstdc++-6.dll \
    /mingw64/bin/libopenh264-*.dll; do
    name="$(basename "$src")"
    if [ ! -f "$src" ]; then
        echo "✗ $name not found at $src" >&2
        exit 1
    fi
    cp "$src" "$OUT_DIR/$name"
done

cp "$SOURCE_DIR/COPYING.LGPLv2.1" "$OUT_DIR/COPYING.LGPLv2.1"

# Bundle licenses for the DLLs we ship alongside ffmpeg.exe.
for vpl_license in /mingw64/share/licenses/libvpl/LICENSE.txt /mingw64/share/licenses/libvpl/LICENSE; do
    if [ -f "$vpl_license" ]; then
        cp "$vpl_license" "$OUT_DIR/LIBVPL-LICENSE.txt"
        break
    fi
done
for wp_license in /mingw64/share/licenses/winpthreads/COPYING /mingw64/share/licenses/winpthreads/LICENSE; do
    if [ -f "$wp_license" ]; then
        cp "$wp_license" "$OUT_DIR/LIBWINPTHREAD-LICENSE.txt"
        break
    fi
done
# OpenH264 (BSD-2-Clause) — must ship with the bundled libopenh264 DLL. Grab
# whatever license file MSYS2 installs for the package, regardless of its name.
openh264_license="$(ls /mingw64/share/licenses/openh264/* 2>/dev/null | head -n1 || true)"
if [ -n "$openh264_license" ] && [ -f "$openh264_license" ]; then
    cp "$openh264_license" "$OUT_DIR/LIBOPENH264-LICENSE.txt"
else
    echo "✗ openh264 license not found under /mingw64/share/licenses/openh264/ — required to ship the bundled libopenh264 DLL" >&2
    exit 1
fi
# zlib (zlib licence) and FreeType (used under the FreeType Project License,
# which asks for credit in the documentation — SOURCE.txt carries it).
cp "$ZLIB_SRC/LICENSE" "$OUT_DIR/ZLIB-LICENSE.txt"
cp "$FREETYPE_SRC/docs/FTL.TXT" "$OUT_DIR/FREETYPE-LICENSE.txt"
# HarfBuzz's own licence, then the one its compiled-in Microsoft shaping data
# carries (also MIT). Its other licence files cover test fonts, not built.
{
    cat "$HARFBUZZ_SRC/COPYING"
    printf '\n\n---- src/ms-use/COPYING (Universal Shaping Engine data, compiled in) ----\n\n'
    cat "$HARFBUZZ_SRC/src/ms-use/COPYING"
} > "$OUT_DIR/HARFBUZZ-LICENSE.txt"

# GCC runtime: ship the Runtime Library Exception (the term that makes
# redistribution alongside our binary copyleft-free) plus the GPLv3 base text.
for gcc_dir in /mingw64/share/licenses/gcc-libs /mingw64/share/licenses/gcc; do
    if [ -d "$gcc_dir" ]; then
        if [ -f "$gcc_dir/RUNTIME.LIBRARY.EXCEPTION" ]; then
            cp "$gcc_dir/RUNTIME.LIBRARY.EXCEPTION" "$OUT_DIR/GCC-RUNTIME-LIBRARY-EXCEPTION.txt"
        fi
        for gpl in "$gcc_dir/COPYING3" "$gcc_dir/COPYING"; do
            if [ -f "$gpl" ]; then
                cp "$gpl" "$OUT_DIR/GCC-LICENSE.txt"
                break
            fi
        done
        break
    fi
done
# MSYS2 does not install the exception text where the loop above looks, and the
# GCC runtime DLLs ship under it — so the copy kept in this repository is used.
if [ ! -f "$OUT_DIR/GCC-RUNTIME-LIBRARY-EXCEPTION.txt" ]; then
    cp "$REPO_ROOT/licenses/GCC-RUNTIME-LIBRARY-EXCEPTION.txt" "$OUT_DIR/GCC-RUNTIME-LIBRARY-EXCEPTION.txt"
fi

# ---- transitive import audit ------------------------------------------------
# Walk the full DLL import graph reachable from ffmpeg.exe / ffprobe.exe. Every
# DLL must resolve to one of:
#   (a) a file we bundle in $OUT_DIR (license-audited above), or
#   (b) a Windows system DLL — present in System32; Windows itself provides it.
# Anything else is an unexpected runtime dep that needs a decision. Unlike the
# previous direct-imports-only check, this recurses into the bundled DLLs'
# *own* imports — which is what catches libvpl-2.dll dragging in the GCC
# runtime. NTFS is case-insensitive, so an all-caps name from objdump still
# resolves a lower-case file.
SYSTEM32="/c/Windows/System32"
if [ ! -d "$SYSTEM32" ]; then
    echo "✗ $SYSTEM32 not found — can't run the import audit" >&2
    exit 1
fi

audit_import_closure() {
    declare -A seen=()
    local queue=("$OUT_DIR/ffmpeg.exe" "$OUT_DIR/ffprobe.exe")
    while [ "${#queue[@]}" -gt 0 ]; do
        local file="${queue[0]}"
        queue=("${queue[@]:1}")
        local dll
        while read -r dll; do
            dll="$(echo "$dll" | tr -d '[:space:]')"
            [ -z "$dll" ] && continue
            local lc="${dll,,}"
            [ -n "${seen[$lc]:-}" ] && continue
            seen[$lc]=1
            if [ -f "$OUT_DIR/$dll" ]; then
                queue+=("$OUT_DIR/$dll")    # bundled — recurse into its imports
            elif [ -f "$SYSTEM32/$dll" ]; then
                :                           # Windows system DLL — Windows provides it
            else
                echo "✗ unresolved runtime dependency: $dll" >&2
                echo "  reached from the ffmpeg.exe/ffprobe.exe import graph;" >&2
                echo "  not bundled in $OUT_DIR and not present in $SYSTEM32." >&2
                echo "  fix: add it to the staged DLL list above, or static-link it." >&2
                return 1
            fi
        done < <(objdump -p "$file" | grep -i 'DLL Name:' | awk '{print $3}')
    done
    return 0
}
echo "▶ auditing import closure"
audit_import_closure
echo "  ✓ every imported DLL resolves to System32 + bundled DLLs"

# Self-contained run check: execute the *staged* binaries with /mingw64/bin off
# PATH so they can only load DLLs from their own directory (cwd) plus System32
# — exactly what an end user's machine looks like. The old check ran the
# install-tree binary with the full MSYS2 PATH, which hid missing-bundle bugs
# because the toolchain DLLs were resolvable.
echo "▶ verifying staged binaries run self-contained"
for exe in ffmpeg.exe ffprobe.exe; do
    if ! ( cd "$OUT_DIR" && PATH="/c/Windows/System32:/c/Windows" "./$exe" -hide_banner -version >/dev/null ); then
        echo "✗ staged $exe failed to run with a clean PATH (missing bundled DLL?)" >&2
        exit 1
    fi
done
echo "  ✓ binaries run self-contained"

# EvoIMS fork: what the two added libraries are for, exercised rather than
# assumed — drawtext with a font file and a clock that changes every frame (the
# case-story video), and a PNG from showwavespic (a recording's waveform).
echo "▶ verifying drawtext and PNG work"
FONT="C:/Windows/Fonts/arial.ttf"
if ! ( cd "$OUT_DIR" && PATH="/c/Windows/System32:/c/Windows" ./ffmpeg.exe -hide_banner -loglevel error \
        -f lavfi -i color=c=black:s=320x180:d=1 \
        -vf "drawtext=fontfile='C\:/Windows/Fonts/arial.ttf':text='%{pts\:hms}':fontcolor=white:fontsize=24" \
        -frames:v 5 -f null - ); then
    echo "✗ drawtext failed (font: $FONT)" >&2
    exit 1
fi
if ! ( cd "$OUT_DIR" && PATH="/c/Windows/System32:/c/Windows" ./ffmpeg.exe -hide_banner -loglevel error -y \
        -f lavfi -i sine=duration=1 \
        -filter_complex "aformat=channel_layouts=mono,showwavespic=s=640x120" \
        -frames:v 1 "$BUILD_ROOT/waveform-check.png" ); then
    echo "✗ PNG encoding failed" >&2
    exit 1
fi
echo "  ✓ drawtext and PNG work"

CONFIG_CLEAN="$(echo "$CONFIG_LINE" | sed -E 's/^.*configuration:[[:space:]]*//')"

cat > "$OUT_DIR/SOURCE.txt" <<EOF
FFmpeg ${FFMPEG_VERSION}
Source tarball: ${TARBALL_URL}
SHA256:         ${SHA256}
zlib ${ZLIB_VERSION}:     ${ZLIB_URLS[0]}
SHA256:         ${ZLIB_SHA256}
FreeType ${FREETYPE_VERSION}: ${FREETYPE_URLS[0]}
SHA256:         ${FREETYPE_SHA256}
HarfBuzz ${HARFBUZZ_VERSION}: ${HARFBUZZ_URLS[0]}
SHA256:         ${HARFBUZZ_SHA256}
Built on:       $(date -u +%Y-%m-%dT%H:%M:%SZ)
Built for:      ${TARGET}
Toolchain:      mingw-w64 gcc (via MSYS2)
NVENC API:      nv-codec-headers ${NVCODEC_TAG} — minimum NVIDIA driver 471.41 (Windows) / 470.57.02 (Linux)
Configuration:  ${CONFIG_CLEAN}

This binary is LGPL-2.1-only. Per LGPL § 6, downstream end users are entitled
to the complete corresponding source code for this FFmpeg build. The FFmpeg,
zlib and FreeType source tarballs above (matching the SHA256s) are attached,
verbatim, to the GitHub release this binary came from (with HarfBuzz's),
beside the build
scripts that produced it:

  https://github.com/CamCSDC/ffmpeg-lgpl-builds

a fork of https://github.com/serversideup/ffmpeg-lgpl-builds that adds zlib,
FreeType and HarfBuzz for EvoIMS. Check out the tag matching this binary's release to
reproduce the build.

zlib is statically linked under the zlib licence (ZLIB-LICENSE.txt). FreeType is
statically linked under the FreeType Project License (FREETYPE-LICENSE.txt):
Portions of this software are copyright © 2026 The FreeType Project
(https://freetype.org). All rights reserved.
HarfBuzz is statically linked under its "Old MIT" licence (HARFBUZZ-LICENSE.txt).

This artifact also bundles the runtime DLLs that ffmpeg.exe imports, directly
or transitively:

  libvpl-2.dll        — Intel oneVPL dispatcher (MIT). Loaded at runtime when
                        the Intel Quick Sync encoders (h264_qsv / hevc_qsv)
                        are selected. See LIBVPL-LICENSE.txt.
  libwinpthread-1.dll — mingw-w64 pthread runtime (BSD-style permissive).
                        Imported unconditionally by FFmpeg's static libs.
                        See LIBWINPTHREAD-LICENSE.txt.
  libgcc_s_seh-1.dll  — GCC unwinder runtime, imported by libvpl-2.dll.
  libstdc++-6.dll     — GCC C++ runtime, imported by libvpl-2.dll.
                        Both are GPLv3 WITH the GCC Runtime Library Exception,
                        which explicitly permits redistributing them alongside
                        a GCC-compiled program without imposing copyleft on
                        that program. See GCC-RUNTIME-LIBRARY-EXCEPTION.txt and
                        GCC-LICENSE.txt.

All bundled DLLs are LGPL-compatible; shipping them imposes no copyleft
obligation on downstream consumers beyond what the FFmpeg LGPL already does.

The "msvc" in the target triple is a consumer convention (Rust, vendor.toml)
for "Windows x64." The actual build toolchain is mingw-w64 gcc; the resulting
.exe is a standard Windows PE executable and behaves identically regardless
of the consumer's chosen toolchain.
EOF

# ---- package ----------------------------------------------------------------
ARCHIVE="ffmpeg-${FFMPEG_VERSION}-${TARGET}.tar.gz"
echo "▶ packaging $ARCHIVE"
ARCHIVE_FILES=(
    ffmpeg.exe
    ffprobe.exe
    libvpl-2.dll
    libwinpthread-1.dll
    libgcc_s_seh-1.dll
    libstdc++-6.dll
    COPYING.LGPLv2.1
    SOURCE.txt
    ZLIB-LICENSE.txt
    FREETYPE-LICENSE.txt
    HARFBUZZ-LICENSE.txt
    GCC-RUNTIME-LIBRARY-EXCEPTION.txt
)
# libopenh264 ships under a soname-versioned name (libopenh264-N.dll) that the
# staging step copied into $OUT_DIR. ffmpeg.exe imports it directly, so it MUST
# go in the archive — pick up whatever name it landed as.
for openh264_dll in "$OUT_DIR"/libopenh264-*.dll; do
    [ -f "$openh264_dll" ] && ARCHIVE_FILES+=("$(basename "$openh264_dll")")
done
for optional in LIBVPL-LICENSE.txt LIBWINPTHREAD-LICENSE.txt LIBOPENH264-LICENSE.txt GCC-LICENSE.txt; do
    if [ -f "$OUT_DIR/$optional" ]; then
        ARCHIVE_FILES+=("$optional")
    fi
done
( cd "$OUT_DIR" && tar -czf "$ARCHIVE" "${ARCHIVE_FILES[@]}" )
( cd "$OUT_DIR" && sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256" )

BIN_SIZE="$(stat -c%s "$OUT_DIR/ffmpeg.exe")"
BIN_MB="$(awk "BEGIN{printf \"%.1f\", $BIN_SIZE/1024/1024}")"
PROBE_SIZE="$(stat -c%s "$OUT_DIR/ffprobe.exe")"
PROBE_MB="$(awk "BEGIN{printf \"%.1f\", $PROBE_SIZE/1024/1024}")"
VPL_SIZE="$(stat -c%s "$OUT_DIR/libvpl-2.dll")"
VPL_KB="$(awk "BEGIN{printf \"%.0f\", $VPL_SIZE/1024}")"

echo
echo "✅ LGPL ffmpeg ${FFMPEG_VERSION} built for ${TARGET}"
echo "   ffmpeg:    $OUT_DIR/ffmpeg.exe    (${BIN_MB} MB)"
echo "   ffprobe:   $OUT_DIR/ffprobe.exe   (${PROBE_MB} MB)"
echo "   libvpl-2:  $OUT_DIR/libvpl-2.dll  (${VPL_KB} KB — Intel QSV dispatcher)"
echo "   + bundled GCC runtime: libgcc_s_seh-1.dll, libstdc++-6.dll, libwinpthread-1.dll"
echo "   archive:   $OUT_DIR/$ARCHIVE"
echo "   sha256:    $OUT_DIR/${ARCHIVE}.sha256"
