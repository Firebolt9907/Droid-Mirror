#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../scrcpy-5.0/app/src/secure_black_frame.h"

int main(void) {
    // Padded strides: padding must not count as screen content.
    unsigned char y[8 * 4], u[4 * 2], v[4 * 2];
    memset(y, 255, sizeof(y));
    memset(u, 255, sizeof(u));
    memset(v, 255, sizeof(v));
    for (int row = 0; row < 4; row++) memset(y + row * 8, 16, 6);
    for (int row = 0; row < 2; row++) {
        memset(u + row * 4, 128, 3);
        memset(v + row * 4, 128, 3);
    }
    AVFrame frame = {0};
    frame.width = 6;
    frame.height = 4;
    frame.format = AV_PIX_FMT_YUV420P;
    frame.color_range = AVCOL_RANGE_MPEG;
    frame.data[0] = y; frame.data[1] = u; frame.data[2] = v;
    frame.linesize[0] = 8; frame.linesize[1] = 4; frame.linesize[2] = 4;
    assert(sc_frame_is_fully_black(&frame));
    y[3 * 8 + 5] = 40; // Even one visible pixel must prevent the overlay.
    assert(!sc_frame_is_fully_black(&frame));
    y[3 * 8 + 5] = 16;
    u[0] = 180; // Dark colored content is not neutral black.
    assert(!sc_frame_is_fully_black(&frame));
    u[0] = 128;
    frame.color_range = AVCOL_RANGE_JPEG;
    assert(!sc_frame_is_fully_black(&frame));
    for (int row = 0; row < 4; row++) memset(y + row * 8, 0, 6);
    assert(sc_frame_is_fully_black(&frame));
    frame.format = AV_PIX_FMT_RGB24;
    assert(!sc_frame_is_fully_black(&frame));
    frame.format = AV_PIX_FMT_YUV420P;
    frame.data[2] = NULL;
    assert(!sc_frame_is_fully_black(&frame));
    assert(!sc_frame_is_fully_black(NULL));
    unsigned char uv[8 * 2];
    memset(uv, 255, sizeof(uv));
    for (int row = 0; row < 2; ++row) memset(uv + row * 8, 128, 6);
    frame.format = AV_PIX_FMT_NV12;
    frame.data[1] = uv; frame.data[2] = NULL; frame.linesize[1] = 8;
    assert(sc_frame_is_fully_black(&frame));
    uv[1] = 190;
    assert(!sc_frame_is_fully_black(&frame));
    uv[1] = 128;
    frame.format = AV_PIX_FMT_YUV420P;
    unsigned char portrait_y[100 * 200], portrait_u[50 * 100], portrait_v[50 * 100];
    memset(portrait_y, 16, sizeof(portrait_y));
    memset(portrait_u, 128, sizeof(portrait_u));
    memset(portrait_v, 128, sizeof(portrait_v));
    frame.width = 100; frame.height = 200;
    frame.color_range = AVCOL_RANGE_MPEG;
    frame.data[0] = portrait_y; frame.data[1] = portrait_u; frame.data[2] = portrait_v;
    frame.linesize[0] = 100; frame.linesize[1] = 50; frame.linesize[2] = 50;
    memset(portrait_y + 198 * 100 + 35, 235, 30); // Visible Android gesture pill.
    assert(sc_frame_is_fully_black(&frame));
    portrait_y[100 * 100 + 50] = 235; // Visible content in the actual page.
    assert(!sc_frame_is_fully_black(&frame));
    portrait_y[100 * 100 + 50] = 16;
    portrait_y[198 * 100 + 5] = 235; // Bottom content outside the pill area.
    assert(!sc_frame_is_fully_black(&frame));
    portrait_y[198 * 100 + 5] = 16;
    for (int row = 194; row < 200; row++) memset(portrait_y + row * 100 + 20, 235, 60);
    assert(!sc_frame_is_fully_black(&frame)); // A navigation strip is too large.
    puts("Secure black-frame tests passed");
}
