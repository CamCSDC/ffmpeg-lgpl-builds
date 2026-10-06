> **EvoIMS fork.** This fork builds **Windows x64 only**, on GitHub-hosted runners, and adds **zlib** and
> **FreeType** (both permissively licensed, built from pinned upstream tarballs) so the binary has the
> `drawtext` filter and the PNG encoder that EvoIMS needs for its
> case-story videos and waveform pictures. It stays LGPL-2.1-only. Each release attaches the exact FFmpeg,
> zlib and FreeType source tarballs it was built from. Upstream: [serversideup/ffmpeg-lgpl-builds](https://github.com/serversideup/ffmpeg-lgpl-builds).

# ffmpeg-lgpl-builds

Reproducible, LGPL-only FFmpeg binaries for closed-source applications.

Built and published by [@serversideup](https://github.com/serversideup) so that downstream projects can consume FFmpeg without inheriting GPL or non-free obligations. 

## Sponsored by Depot

<a href="https://depot.dev/"><img src="https://serversideup.net/sponsors/depot.png" alt="Depot" width="250px"></a>

These builds run on [Depot](https://depot.dev/)'s Apple Silicon macOS runners. Depot sponsors our CI so we can publish reproducible, multi-arch FFmpeg releases on real Apple hardware without paying the macOS-runner tax ourselves. If you need fast, cache-aware GitHub Actions runners (Linux, Windows, or macOS), give them a look. Huge thanks to the Depot team. 🙏

## What "LGPL-only" means here

Each release ships a pair of binaries — `ffmpeg` and `ffprobe` — produced from the same configure pass and therefore inheriting the same flag profile:

- `--disable-gpl` — no GPL-licensed code linked in (no `libx264`, no `libx265`, no `libxvid`, no `libpostproc`)
- `--disable-nonfree` — no non-free code (no `libfdk_aac`)
- `--disable-version3` — stays on LGPLv2.1 (avoids dependencies that would relicense the bundle to v3)
- `--disable-autodetect` — no Homebrew or system optional libs sneak in; only what we explicitly enable
- `--disable-programs --enable-ffmpeg --enable-ffprobe` — ship the two CLI tools downstream consumers need; skip `ffplay` (drags in SDL)

Hardware-accelerated encoders are enabled per-platform from LGPL-clean SDK headers (the encoders themselves are GPU-vendor implementations; the SDK headers we link against are BSD/MIT and don't impose copyleft):

- **macOS:** VideoToolbox (`h264_videotoolbox`, `hevc_videotoolbox`)
- **Windows:** NVIDIA NVENC (`h264_nvenc`, `hevc_nvenc`), Intel Quick Sync via oneVPL (`h264_qsv`, `hevc_qsv`), AMD AMF (`h264_amf`, `hevc_amf`)

Windows also enables **libopenh264** (`--enable-libopenh264`), a software (CPU) H.264 encoder used as a last-resort fallback on hosts with no usable GPU encoder. OpenH264 is BSD-2-Clause, so it stays LGPL-clean and doesn't trip the forbidden-flag check (it is *not* `--enable-gpl`/`--enable-nonfree`/`--enable-version3`). It is provided by the MSYS2 `mingw-w64-x86_64-openh264` package and ships as `libopenh264-7.dll` bundled alongside `ffmpeg.exe` (with its BSD-2-Clause license in `LIBOPENH264-LICENSE.txt`), the same way `libvpl-2.dll` is; the C++ runtime it needs, `libstdc++-6.dll`, is already in the bundle closure via libvpl.

The build is verified post-link to confirm none of the banned flags ended up enabled and that the linkage matches the platform's expectations:

- **macOS:** both binaries link only to system frameworks under `/System/` and `/usr/lib/`
- **Windows:** each DLL in the import table must either be present in `C:\Windows\System32\` (= Windows itself provides it; no redistribution obligation) or be one of the two DLLs we explicitly bundle alongside `ffmpeg.exe` — `libvpl-2.dll` (Intel's oneVPL dispatcher; MIT) and `libwinpthread-1.dll` (mingw-w64 pthread runtime; BSD-style permissive). Both bundled DLLs are required because libvpl is dispatcher-only (no static archive) and libwinpthread is injected late in FFmpeg's link command in a way that can't be redirected to the static archive without breaking libvpl. Both carry LGPL-compatible permissive licenses, so bundling them adds no copyleft beyond what the FFmpeg LGPL already imposes

A consumer that bundles one of these binaries into a closed-source product still owes its end users the corresponding FFmpeg source under LGPL § 6. Since this repo's `VERSION` file pins an upstream FFmpeg release whose source is publicly available at `https://ffmpeg.org/releases/`, the source-availability obligation is satisfied by pointing users at that URL plus the SHA256 recorded in each release's `RELEASE-NOTES.md`. Consumers should reproduce this notice in their own distribution.

## How releases work

A release is cut whenever `VERSION` or the build script changes on `main` (or via manual `workflow_dispatch` for a one-off rebuild). The GitHub Actions workflow at `.github/workflows/build.yml` runs the platform-specific build script for every supported target, uploads the resulting binaries as a tagged release, and writes a `RELEASE-NOTES.md` recording the SHA256 of each artifact.

Tag format: `v<ffmpeg-version>-<run-number>`, e.g. `v8.1.2-42`, where `<run-number>` is the GitHub Actions workflow run number (monotonic, so every push or dispatch produces a fresh distinct tag — no counter file to keep in sync).

Per release, per target, the published artifacts are:

- `ffmpeg-<version>-<triple>.tar.gz` — contains the `ffmpeg` (or `ffmpeg.exe`) and `ffprobe` binaries, `COPYING.LGPLv2.1`, and `SOURCE.txt` (provenance record). macOS builds additionally include `OPENSSL-LICENSE` (OpenSSL 3 is statically linked in as the TLS backend, Apache-2.0-licensed). Windows builds additionally include `libvpl-2.dll` (Intel oneVPL dispatcher, MIT-licensed) + `LIBVPL-LICENSE.txt`, `libwinpthread-1.dll` (mingw-w64 pthread runtime, BSD-style permissive) + `LIBWINPTHREAD-LICENSE.txt`, and `libopenh264-7.dll` (Cisco OpenH264 software encoder, BSD-2-Clause) + `LIBOPENH264-LICENSE.txt`.
- `ffmpeg-<version>-<triple>.tar.gz.sha256`

TLS backend per platform (for `rtmps`/`https`): **macOS = OpenSSL 3** (Apache-2.0, statically linked), **Windows = Schannel** (system SSPI), **Linux = GnuTLS** (dynamic, distro-provided). macOS deliberately does not use SecureTransport or LibreSSL/libtls: FFmpeg's RTMP layer probes its transport with nonblocking reads, and both of those backends turn the probe into a blocking read that waits on the server's next ack — RTMPS throughput collapses to ~2.5% of real time (measured identically on both; OpenSSL and GnuTLS handle the probe correctly). The macOS and Linux builds gate every ship on an RTMPS throughput smoke test: 10s of 1080p60 at ~8 Mbps pushed to a local MediaMTX over TLS must sustain ≥ 0.9x real time — a handshake-only check passes on a backend that is unusable for streaming.

Currently supported targets:

- `aarch64-apple-darwin` (macOS, Apple Silicon)
- `x86_64-apple-darwin` (macOS, Intel — cross-compiled from Apple Silicon)
- `x86_64-pc-windows-msvc` (Windows x64, built with mingw-w64 gcc via MSYS2 — the "msvc" in the triple is a consumer convention for "Windows x64"; the resulting PE executable is ABI-compatible regardless of caller toolchain)
- `x86_64-unknown-linux-gnu` (Linux x64, for Docker). Unlike the desktop targets, this binary is **not** self-contained: it links gnutls / libva / libopenh264 dynamically against the libraries provided by the consuming container's distribution packages. Encoders: `h264_nvenc` (NVIDIA, runtime lib injected by the NVIDIA Container Toolkit), `h264_vaapi` (Intel iGPU + AMD), `libopenh264` (CPU fallback), `aac`. QSV/oneVPL is omitted for now — VAAPI covers Intel iGPUs.
- `aarch64-unknown-linux-gnu` (Linux ARM, for Docker — e.g. Ampere/Graviton VPSes). **Software-only:** `libopenh264` (CPU) + native `aac`, gnutls TLS, plus stream passthrough. arm64 servers have no NVENC or Intel VAAPI, so there are no GPU encoders; same dynamic-link model as the x64 Linux build.

## How to bump the FFmpeg version

1. Look up the new upstream version at <https://ffmpeg.org/releases/>.
2. Verify the tarball's SHA256 against the upstream signed checksum file.
3. Edit `VERSION` to the new value, e.g. `8.2.0`.
4. Add a case branch for the new version to **all three** of `scripts/build-macos.sh`, `scripts/build-windows.sh`, and `scripts/build-linux.sh` with the pinned tarball SHA256 (defence-in-depth check on each platform).
5. Open a PR. CI runs the full matrix on the PR for verification.
6. Merge to `main`. The push triggers the release workflow, producing `v<new-version>-<run-number>`.

## How to bump only the build flags

Edit `scripts/build-macos.sh` or `scripts/build-windows.sh` and merge to `main`. The push triggers a new release with the same `VERSION` and the next run number, e.g. `v8.1.2-43`. Release notes call out the flag delta.

## How to trigger an ad-hoc rebuild

Run the workflow manually from the Actions tab (`workflow_dispatch`). Produces a fresh tag at the next run number without any commit.

## How to verify a release independently

Given a macOS artifact `ffmpeg-8.1.2-aarch64-apple-darwin.tar.gz`:

```bash
# Confirm the SHA256 matches the published .sha256
shasum -a 256 -c ffmpeg-8.1.2-aarch64-apple-darwin.tar.gz.sha256

# Confirm LGPL flags in the binary itself (ffprobe came from the same configure
# pass, so checking ffmpeg covers both)
tar -xzf ffmpeg-8.1.2-aarch64-apple-darwin.tar.gz
./ffmpeg -version | grep configuration | tr ' ' '\n' | grep -E '^--' | sort

# Should NOT contain: --enable-gpl, --enable-nonfree, --enable-version3
# Should contain: --disable-gpl, --disable-nonfree, --disable-version3
```

Given a Windows artifact `ffmpeg-8.1.2-x86_64-pc-windows-msvc.tar.gz` (verify from PowerShell, cmd, or an MSYS2 shell):

```powershell
# Confirm the SHA256 matches the published .sha256
Get-FileHash -Algorithm SHA256 ffmpeg-8.1.2-x86_64-pc-windows-msvc.tar.gz

# Confirm LGPL flags + expected hardware encoders
tar -xzf ffmpeg-8.1.2-x86_64-pc-windows-msvc.tar.gz
.\ffmpeg.exe -version
.\ffmpeg.exe -hide_banner -encoders | Select-String 'nvenc|qsv|amf|aac'

# Should list h264_nvenc, hevc_nvenc, h264_qsv, hevc_qsv, h264_amf, hevc_amf, aac
# (which encoders can actually encode at runtime depends on the host's GPU
# drivers — the binary always *contains* all of them)
```

To reproduce from source, check out this repo at the tag and run the platform's build script:

- **macOS:** `scripts/build-macos.sh --target aarch64-apple-darwin` on an Apple Silicon Mac with Xcode CLT installed.
- **Windows:** `scripts/build-windows.sh --target x86_64-pc-windows-msvc` from inside an MSYS2 MINGW64 shell with the toolchain + encoder header packages installed (see `.github/workflows/build.yml` for the exact `pacman -S` list).

The resulting `dist/<triple>/{ffmpeg,ffprobe}` (or `.exe`) binaries should be bit-identical to the published artifact (modulo embedded timestamps).

## License

This repository — both the build scripts and the FFmpeg binaries they produce — is distributed under **LGPL-2.1**. See `LICENSE` for the full text. The build script also bakes a copy of `COPYING.LGPLv2.1` (taken verbatim from the FFmpeg source tree) into every released tarball, so downstream consumers receive the license alongside the binary as LGPL § 6 requires.
