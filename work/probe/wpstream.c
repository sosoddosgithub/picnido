// Does libwebp's streaming animator beat ImageIO's re-decoding?
//
// ImageIO's WebP path costs O(frame index) per request — 88 s to walk a 180-frame file, and
// identical whether the bytes come from disk or memory, so it is re-decoding rather than
// re-reading. `WebPAnimDecoder` (libwebpdemux) is the API browsers use: it holds the canvas and
// advances frame by frame. If this is O(1) per frame, real-time playback is possible.
//
// Build: clang -O2 -I/opt/homebrew/include wpstream.c \
//            /opt/homebrew/lib/libwebpdemux.a /opt/homebrew/lib/libwebp.a -o wpstream
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <webp/demux.h>

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: wpstream <file.webp>\n"); return 2; }
    FILE* f = fopen(argv[1], "rb");
    if (!f) { perror("open"); return 1; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t* bytes = malloc(size);
    if (fread(bytes, 1, size, f) != (size_t)size) { fprintf(stderr, "read failed\n"); return 1; }
    fclose(f);

    double t0 = now();
    WebPData data = { bytes, (size_t)size };
    WebPAnimDecoderOptions opt;
    WebPAnimDecoderOptionsInit(&opt);
    opt.color_mode = MODE_RGBA;
    WebPAnimDecoder* dec = WebPAnimDecoderNew(&data, &opt);
    if (!dec) { fprintf(stderr, "not an animation\n"); return 1; }
    WebPAnimInfo info;
    WebPAnimDecoderGetInfo(dec, &info);
    printf("file      : %s  (%.1f MB)\n", argv[1], size / 1048576.0);
    printf("canvas    : %ux%u   frames=%u   loop=%u\n",
           info.canvas_width, info.canvas_height, info.frame_count, info.loop_count);
    printf("open      : %.1f ms\n", (now() - t0) * 1000);

    // First pass: walk every frame, timing each one.
    int idx = 0, ts = 0;
    double per[8] = {0};
    double t_start = now();
    while (WebPAnimDecoderHasMoreFrames(dec)) {
        uint8_t* buf = NULL;
        double t = now();
        if (!WebPAnimDecoderGetNext(dec, &buf, &ts)) { fprintf(stderr, "  frame %d failed\n", idx); break; }
        double ms = (now() - t) * 1000;
        if (idx < 8) per[idx] = ms;
        if (idx == 0 || idx == 10 || idx == 30 || idx == 60 || idx == 100 ||
            idx == (int)info.frame_count - 1) {
            printf("  frame %3d : %6.2f ms   (t=%d ms)\n", idx, ms, ts);
        }
        idx++;
    }
    double total = now() - t_start;
    printf("walk      : %d frames in %.3f s  (%.2f ms/frame)  -> %.0f fps\n",
           idx, total, total / idx * 1000, idx / total);
    printf("first 8   :");
    for (int i = 0; i < 8 && i < idx; i++) printf(" %.1f", per[i]);
    printf(" ms  (flat means O(1), rising means the same quadratic cost)\n");

    WebPAnimDecoderDelete(dec);
    free(bytes);
    return 0;
}
