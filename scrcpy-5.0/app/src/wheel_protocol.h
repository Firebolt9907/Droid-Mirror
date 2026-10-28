#ifndef SC_WHEEL_PROTOCOL_H
#define SC_WHEEL_PROTOCOL_H
#include <stdint.h>
#include <math.h>
// Tagged locally by the macOS mouse-wheel monitor; never used for trackpads.
#define SC_DROIDMIRROR_WHEEL_MOUSE_ID UINT32_C(0x444d5748)
#define SC_DROIDMIRROR_TRACKPAD_MOUSE_ID UINT32_C(0x444d5450)
#define SC_DROIDMIRROR_TRACKPAD_RESET_ID UINT32_C(0x444d5452)

// Keep subpixel momentum across samples instead of rounding every sample away.
static inline int32_t
sc_wheel_take_pixels(double *remainder, double delta) {
    double total = *remainder + delta;
    int32_t pixels = (int32_t) lround(total);
    *remainder = total - pixels;
    return pixels;
}
#endif
