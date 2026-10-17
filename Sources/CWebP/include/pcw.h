/*
 * pcw — "Picnido's little WebP decoder", a deliberately tiny C face over libwebpdemux.
 *
 * Why a shim at all, when Swift imports C directly: libwebpdemux hands back an opaque decoder
 * plus a `WebPAnimInfo` struct and a raw `uint8_t*` that is only valid until the next call.
 * Expressing that in Swift means mapping struct layouts by hand and keeping an imported pointer
 * alive across an ownership boundary the compiler cannot check. Twenty lines of C turn it into
 * four `Int`s and a byte copy.
 *
 * The one piece of libwebp semantics that leaks through, because it is the whole reason this
 * exists: **the decoder is forward-only**. `pcw_next` walks the animation one frame at a time,
 * and there is no "give me frame 12" — libwebp's decoder recomputes the frame from the start of
 * the file every time, which is why seeking costs O(n) and why the caller must play in order and
 * `pcw_reset` to loop. Measured on an 18 MB / 180-frame file: 5.3 ms per frame in sequence,
 * versus 88 seconds to walk the same frames through ImageIO.
 */

#ifndef PCW_H
#define PCW_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pcw_decoder pcw_decoder;

/* Opens `path` and prepares an animation decoder.
 *
 * Returns NULL for anything unusable — missing file, unreadable, not a WebP, no animation
 * chunks — because the caller's only sensible response to each of those is the same: fall back
 * to the still-image path. A still WebP yields a decoder with a frame count of 1, which the
 * caller can treat either way.
 */
pcw_decoder *pcw_open(const char *path);

/* Frees the decoder and the file bytes it owns. Safe on NULL. */
void pcw_close(pcw_decoder *d);

int pcw_width(const pcw_decoder *d);
int pcw_height(const pcw_decoder *d);
int pcw_frame_count(const pcw_decoder *d);

/* Loop count as the file declares it: 0 means loop forever. */
int pcw_loop_count(const pcw_decoder *d);

/* Bytes one RGBA frame occupies — width * height * 4. */
size_t pcw_frame_bytes(const pcw_decoder *d);

/* Decodes the next frame into `dst` and writes its *cumulative* timestamp in milliseconds.
 *
 * 0  — a frame was written; `*timestamp_ms` is its start time measured from the beginning of
 *      the animation, so a caller can pace itself without accumulating the per-frame delays.
 * 1  — the animation ended. Nothing was written; call `pcw_reset` to start over.
 * -1 — the frame could not be decoded; the decoder is not usable afterwards.
 *
 * `dst` must be at least `pcw_frame_bytes` long.
 */
int pcw_next(pcw_decoder *d, uint8_t *dst, size_t dst_size, int *timestamp_ms);

/* Rewinds to the first frame. Cheap — it drops accumulated decode state rather than re-reading
 * anything — but the next `pcw_next` still pays the first frame's decode cost. */
void pcw_reset(pcw_decoder *d);

#ifdef __cplusplus
}
#endif

#endif /* PCW_H */
