#ifndef SC_SECURE_BLACK_FRAME_H
#define SC_SECURE_BLACK_FRAME_H

#include <stdbool.h>
#include <stddef.h>
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>

enum sc_frame_content { SC_FRAME_UNKNOWN, SC_FRAME_BLACK, SC_FRAME_CONTENT };

// Detect a candidate black page (not proof of secure content), allowing only a narrow, centered bottom navigation pill.
// Accept planar YUV420 or the NV12 planes used by VideoToolbox.
static inline enum sc_frame_content
sc_frame_content(const AVFrame *frame) {
    if (!frame || frame->width <= 0 || frame->height <= 0
            || (frame->format != AV_PIX_FMT_YUV420P
                && frame->format != AV_PIX_FMT_YUVJ420P
                && frame->format != AV_PIX_FMT_NV12)) {
        return SC_FRAME_UNKNOWN;
    }
    bool full_range = frame->color_range == AVCOL_RANGE_JPEG
                      || frame->format == AV_PIX_FMT_YUVJ420P;
    int max_y = full_range ? 2 : 18;
    size_t navigation_pixels = 0;
    // System gesture navigation can remain visible over a secure Android view.
    // Never ignore the entire navigation strip: bound both location and area.
    bool portrait = frame->height > frame->width;
    int navigation_top = frame->height - frame->height * 3 / 100;
    size_t navigation_limit = (size_t)frame->width * frame->height / 200;
    bool nv12 = frame->format == AV_PIX_FMT_NV12;
    for (int plane = 0; plane < (nv12 ? 2 : 3); ++plane)
        if (!frame->data[plane] || !frame->linesize[plane]) return SC_FRAME_UNKNOWN;
    for (int plane = 0; plane < (nv12 ? 2 : 3); ++plane) {
        int width = plane ? (frame->width + 1) / 2 : frame->width;
        if (nv12 && plane) width *= 2; // Interleaved U/V bytes.
        int height = plane ? (frame->height + 1) / 2 : frame->height;
        for (int y = 0; y < height; ++y) {
            const unsigned char *row = frame->data[plane]
                + (ptrdiff_t)y * frame->linesize[plane];
            for (int x = 0; x < width; ++x) {
                int value = row[x];
                if (plane ? (value < 126 || value > 130) : value > max_y) {
                    if (!plane && portrait && y >= navigation_top
                            && x >= frame->width / 5 && x < frame->width * 4 / 5
                            && ++navigation_pixels <= navigation_limit) {
                        continue;
                    }
                    return SC_FRAME_CONTENT;
                }
            }
        }
    }
    return SC_FRAME_BLACK;
}

// Entrance readiness is deliberately stricter than secure-window detection.
// Ignore system bars and require visible area, rather than a single bright or
// chroma-noise pixel on an otherwise black startup surface. Dark/unknown pages
// still become interactive through the nonanimated startup fallback.
static inline enum sc_frame_content
sc_frame_reveal_content(const AVFrame *frame) {
    if (!frame || frame->width <= 0 || frame->height <= 0
            || (frame->format != AV_PIX_FMT_YUV420P
                && frame->format != AV_PIX_FMT_YUVJ420P
                && frame->format != AV_PIX_FMT_NV12)
            || !frame->data[0] || !frame->linesize[0]) {
        return SC_FRAME_UNKNOWN;
    }
    bool full_range = frame->color_range == AVCOL_RANGE_JPEG
                      || frame->format == AV_PIX_FMT_YUVJ420P;
    int threshold = full_range ? 8 : 23;
    int left = frame->width / 20, top = frame->height / 20;
    int right = frame->width - left, bottom = frame->height - top;
    size_t required = ((size_t)(right - left) * (bottom - top) + 99) / 100;
    size_t visible = 0;
    for (int y = top; y < bottom; ++y) {
        const unsigned char *row = frame->data[0]
            + (ptrdiff_t)y * frame->linesize[0];
        for (int x = left; x < right; ++x) {
            if (row[x] > threshold && ++visible >= required) return SC_FRAME_CONTENT;
        }
    }
    return SC_FRAME_BLACK;
}

static inline bool
sc_frame_is_fully_black(const AVFrame *frame) {
    return sc_frame_content(frame) == SC_FRAME_BLACK;
}

#endif
