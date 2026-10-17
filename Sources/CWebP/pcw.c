#include "pcw.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <webp/demux.h>

struct pcw_decoder {
    /* The whole file, held for as long as the decoder lives. `WebPAnimDecoderNew` does not
     * copy the bytes it is given — it keeps a borrowed view of them — so letting this go
     * produces use-after-free reads inside libwebp rather than a clean failure. */
    uint8_t *data;
    size_t size;
    WebPAnimDecoder *dec;
    WebPAnimInfo info;
    int exhausted;
};

static uint8_t *read_whole_file(const char *path, size_t *out_size) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) return NULL;

    /* fseeko/ftello rather than fseek/ftell: the 32-bit variants break past 2 GB on some
     * platforms, and the cost of using the wide ones is nothing. */
    if (fseeko(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    off_t end = ftello(f);
    if (end <= 0) { fclose(f); return NULL; }
    if (fseeko(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }

    uint8_t *buf = (uint8_t *)malloc((size_t)end);
    if (buf == NULL) { fclose(f); return NULL; }

    size_t got = fread(buf, 1, (size_t)end, f);
    fclose(f);
    if (got != (size_t)end) { free(buf); return NULL; }

    *out_size = (size_t)end;
    return buf;
}

pcw_decoder *pcw_open(const char *path) {
    if (path == NULL) return NULL;

    size_t size = 0;
    uint8_t *bytes = read_whole_file(path, &size);
    if (bytes == NULL) return NULL;

    WebPData data;
    data.bytes = bytes;
    data.size = size;

    WebPAnimDecoderOptions opt;
    if (!WebPAnimDecoderOptionsInit(&opt)) { free(bytes); return NULL; }
    opt.color_mode = MODE_RGBA;
    /* libwebp's own frame threading. Worth having: the frames of a real animation are large
     * enough that the dsp kernels dominate, and this is a per-decoder setting. */
    opt.use_threads = 1;

    WebPAnimDecoder *dec = WebPAnimDecoderNew(&data, &opt);
    if (dec == NULL) { free(bytes); return NULL; }

    pcw_decoder *d = (pcw_decoder *)calloc(1, sizeof(pcw_decoder));
    if (d == NULL) { WebPAnimDecoderDelete(dec); free(bytes); return NULL; }

    if (!WebPAnimDecoderGetInfo(dec, &d->info)) {
        WebPAnimDecoderDelete(dec);
        free(bytes);
        free(d);
        return NULL;
    }

    d->data = bytes;
    d->size = size;
    d->dec = dec;
    d->exhausted = 0;
    return d;
}

void pcw_close(pcw_decoder *d) {
    if (d == NULL) return;
    if (d->dec != NULL) WebPAnimDecoderDelete(d->dec);
    free(d->data);
    free(d);
}

int pcw_width(const pcw_decoder *d) { return d == NULL ? 0 : (int)d->info.canvas_width; }
int pcw_height(const pcw_decoder *d) { return d == NULL ? 0 : (int)d->info.canvas_height; }
int pcw_frame_count(const pcw_decoder *d) { return d == NULL ? 0 : (int)d->info.frame_count; }
int pcw_loop_count(const pcw_decoder *d) { return d == NULL ? 0 : (int)d->info.loop_count; }

size_t pcw_frame_bytes(const pcw_decoder *d) {
    if (d == NULL) return 0;
    return (size_t)d->info.canvas_width * (size_t)d->info.canvas_height * 4u;
}

int pcw_next(pcw_decoder *d, uint8_t *dst, size_t dst_size, int *timestamp_ms) {
    if (d == NULL || d->dec == NULL || dst == NULL) return -1;
    if (d->exhausted) return 1;

    size_t need = pcw_frame_bytes(d);
    if (dst_size < need) return -1;

    if (!WebPAnimDecoderHasMoreFrames(d->dec)) {
        d->exhausted = 1;
        return 1;
    }

    uint8_t *frame = NULL;
    int ts = 0;
    if (!WebPAnimDecoderGetNext(d->dec, &frame, &ts) || frame == NULL) {
        d->exhausted = 1;
        return -1;
    }

    /* A copy, not a borrow: the pointer libwebp just handed over is invalidated by the very
     * next call, and the caller wants to keep this frame on screen until then. */
    memcpy(dst, frame, need);
    if (timestamp_ms != NULL) *timestamp_ms = ts;
    return 0;
}

void pcw_reset(pcw_decoder *d) {
    if (d == NULL || d->dec == NULL) return;
    WebPAnimDecoderReset(d->dec);
    d->exhausted = 0;
}
