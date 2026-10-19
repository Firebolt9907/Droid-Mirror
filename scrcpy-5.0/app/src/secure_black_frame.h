#ifndef SC_SECURE_BLACK_FRAME_H
#define SC_SECURE_BLACK_FRAME_H

#include <stdbool.h>
#include <stddef.h>
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>

// Detect a candidate black page (not proof of secure content), allowing only a narrow, centered bottom navigation pill.
// Accept planar YUV420 or the NV12 planes used by VideoToolbox.
static inline bool
sc_frame_is_fully_black(const AVFrame *frame) {
    if (!frame || frame->width <= 0 || frame->height <= 0
            || (frame->format != AV_PIX_FMT_YUV420P
                && frame->format != AV_PIX_FMT_YUVJ420P
                && frame->format != AV_PIX_FMT_NV12)) {
        return false;
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
    for (int plane = 0; plane < (nv12 ? 2 : 3); ++plane) {
        if (!frame->data[plane] || !frame->linesize[plane]) return false;
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
                    return false;
                }
            }
        }
    }
    return true;
}

#endif
