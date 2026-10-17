# Vendored libwebp

Pre-built **fat** static libraries (arm64 + x86_64) and matching headers, checked in so that the
app bundle is self-contained, so that building it does not depend on what Homebrew happens to
have installed today, and so that **the same tree can produce both the Apple Silicon build and
the Intel build**.

## Provenance

| | |
|---|---|
| Upstream | https://chromium.googlesource.com/webm/libwebp |
| Version | **1.6.0** — release tarball `libwebp-1.6.0.tar.gz`, sha256 `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564` |
| Licence | BSD 3-Clause + an additional IP-rights grant; full text in `COPYING` |

The fat file holds two slices, and they were **deliberately built by different means**:

| Slice | How it was made | Why that way |
|---|---|---|
| **arm64** | Homebrew's own build — the `webp` formula at `/opt/homebrew/Cellar/webp/1.6.0`, `-O3`, no debug symbols | It is the build 1.3.0 shipped with. Rebuilding it would change the Apple Silicon binary for no gain, and its hash is the one recorded in the 1.3.0 manifest |
| **x86_64** | Built **from the 1.6.0 sources by this project** — see below | Homebrew on this machine has only an arm64 build; there is no x86_64 slice to take. The Intel build has to link a real x86_64 decoder, so one had to be produced |

The two are joined with `lipo -create`. The arm64 slice of the fat file is **byte-identical** to
the arm64-only file that shipped with 1.3.0 (`lipo -thin arm64` + `cmp`, verified), so the Apple
Silicon build links exactly the same bytes it did before. Only the x86_64 slice is new.

## What is here, and why only this

| File | sha256 | Architecture |
|---|---|---|
| `lib/libwebp.a` | `6e34809e3b6a169356698e2045320292214080149c7eefe981104082eea682f7` | `x86_64 arm64` |
| `lib/libwebpdemux.a` | `e836af4e62bdcca9444cff893cc4a35e5025c89f657177103a93959766cc8da1` | `x86_64 arm64` |

`libwebp` is the decoder; `libwebpdemux` is the animation container reader that sits on top of it
and yields one composited frame at a time. Those two are the entire dependency for what this app
does — play animated WebP.

Deliberately **not** vendored: `libwebpmux`, libwebp's encoder, and `libsharpyuv` (a
colour-conversion helper used only by the *encoder*). Leaving them out is not just tidiness: a
static library links only the members it needs, and a missing file is a dependency that can never
be pulled in by accident later.

## How the x86_64 slice was built

From the upstream release tarball — the same one Homebrew's formula unpacks, verified by sha256
against the formula (`e4ab7009…`), so both slices really are libwebp 1.6.0. **No patch, no CMake
file edited, nothing taken from the repository's own source tree.**

```bash
curl -x http://127.0.0.1:21081 -LO \
  https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz
tar -xzf libwebp-1.6.0.tar.gz && cd libwebp-1.6.0

# The tarball ships a pre-generated `configure`, so autotools is all that is needed — no cmake
# (Homebrew's formula uses CMake; this machine has no cmake installed, and the autotools path
# needs only the Command Line Tools).
./configure \
  CC=clang \
  CFLAGS="-arch x86_64 -O3 -mmacosx-version-min=14.0" \
  LDFLAGS="-arch x86_64 -mmacosx-version-min=14.0" \
  --disable-shared --enable-static \
  --disable-libwebpmux \
  --prefix="$PWD/out-x86_64"

make -j8

# The libraries land here, not at the tree root and not in `.build/`:
#   src/.libs/libwebp.a
#   src/demux/.libs/libwebpdemux.a
```

Then the fat file:

```bash
lipo -create <arm64-only libwebp.a>   src/.libs/libwebp.a                  -output libwebp.a
lipo -create <arm64-only libwebpdemux.a> src/demux/.libs/libwebpdemux.a    -output libwebpdemux.a
```

Checks that were run on the result, rather than assumed:

| Check | Result |
|---|---|
| Architecture | `lipo -info` → `x86_64 arm64` |
| arm64 slice unchanged | `lipo -thin arm64` + `cmp` against the 1.3.0 file → identical |
| Member coverage | 113 objects in the x86_64 `libwebp.a`, covering the same source files as the arm64 one (dec / dsp / enc / utils plus every SIMD variant). The arm64 library has 112 — the difference is libtool's object-naming (`libwebpdecode_la-alpha_dec.o` vs `alpha_dec.c.o`), not a missing file |
| Symbols the app uses | `WebPDecodeRGBA`, `WebPDemuxInternal`, `WebPDemuxGetFrame`, `WebPAnimDecoderNewInternal` all present |
| Real decoding | `verify_x86.sh` section 3 opens a folder of animated WebP/GIF under Rosetta and asserts that frames advance |

Two build differences from Homebrew's slice are deliberate and harmless: the x86_64 slice is
compiled at `-mmacosx-version-min=14.0` (matching the app's own `LSMinimumSystemVersion`), and it
leaves out `libwebpmux` because this app never muxes.

## Why these are binaries and not C sources

Vendoring ~80 `.c` files would keep the tree all-text, but libwebp needs a generated `config.h`
and a pile of platform defines to build correctly, and a mis-set define fails quietly — a decoder
that returns subtly wrong pixels rather than an error. With the fat `.a` in the tree the build
links in about a second and cannot be misconfigured. The trade is that the source archive
contains binary blobs; this file and the hashes above exist so that they are accountable.

## The one link-time warning, and why it is left alone

Linking the **arm64** build produces:

    ld: warning: object file (libwebp.a[110](utils.c.o)) was built for newer 'macOS' version
    (15.0) than being linked (14.0)

All 112 arm64 members carry `minos 15.0`, because Homebrew built the formula on macOS 15 and
clang stamps the current deployment target when none is given. The bundle declares
`LSMinimumSystemVersion 14.0`. The **x86_64** slice does not have this problem: it was built here
with `-mmacosx-version-min=14.0`, so its members are stamped 14.0.

Checked rather than assumed: the complete set of undefined symbols across `libwebp.a` and
`libwebpdemux.a` is `memcpy`/`memmove`/`memset`/`bzero`/`malloc`/`calloc`/`free`/`qsort`/`log`/
`pow`/`log10`, `memset_pattern16`, `__chkstk_darwin`, the stack-protector pair, and the
`pthread_mutex_*` / `pthread_cond_*` / `pthread_create` / `pthread_join` family. Every one of
those predates macOS 10.6. Nothing in this library calls an API introduced in macOS 15, so the
warning describes the compiler's default stamp and not a real requirement.

Left as-is rather than patched: rewriting the load commands of a third-party binary to silence a
warning would make the checked-in hash stop matching what Homebrew produced. What would change the
calculation is the app's own minimum rising to 15 — then the warning disappears on its own.

## Updating

Copy both `.a` files from the new build, copy `include/webp/*.h` alongside them, refresh the
version and hashes in this file, and re-run the animation tests — the frame timestamps and the
forward-only semantics in `Sources/CWebP/include/pcw.h` are behaviours of this library, not of
this app, and they are the parts a version bump could change.

If a new libwebp still has to be cross-compiled for Intel, repeat the section above; if Homebrew
ever ships a universal `webp`, the x86_64 slice can simply be taken from it and `lipo`'d with the
arm64 one.
