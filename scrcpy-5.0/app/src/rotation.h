#ifndef SC_ROTATION_H
#define SC_ROTATION_H

#include <math.h>
#include <SDL3/SDL.h>

#define SC_ROTATION_DURATION_MS 350
#define SC_ROTATION_PRESENTATION_PROP "droidmirror.rotation.active"

// Match high-refresh displays without adding a full delay after rendering.
static inline Uint64
sc_rotation_frame_interval(float refresh_rate) {
    if (!isfinite(refresh_rate) || refresh_rate < 1) return 16;
    long interval = lround(1000.0 / refresh_rate);
    return interval < 4 ? 4 : interval > 16 ? 16 : interval;
}

static inline int
sc_rotation_wait_ms(Uint64 now, Uint64 deadline) {
    return deadline > now ? (int) (deadline - now) : 0;
}

// Allow encoder alignment rounding, without mistaking quality changes for turns.
static inline bool
sc_rotation_same_aspect(float w, float h, float other_w, float other_h) {
    return w > 0 && h > 0 && other_w > 0 && other_h > 0
        && fabs((w/h) / (other_w/other_h) - 1) < .05;
}

static inline bool
sc_rotation_is_orientation_change(float w, float h, float new_w, float new_h) {
    return ((w < h && new_w > new_h) || (w > h && new_w < new_h))
        && sc_rotation_same_aspect(w, h, new_h, new_w);
}

static inline double
sc_rotation_progress(Uint64 now, Uint64 start) {
    double t = (double) (now - start) / SC_ROTATION_DURATION_MS;
    if (t >= 1) return 1;
    // Ease in and out with zero velocity and acceleration at both ends.
    return t * t * t * (10 + t * (-15 + 6 * t));
}

// Fit the complete moving frame in the window, without clipping its corners.
static inline SDL_FRect
sc_rotation_rect(float width, float height, float frame_w, float frame_h,
                 double angle) {
    double radians = angle * (3.141592653589793 / 180.0);
    double c = fabs(cos(radians)), s = fabs(sin(radians));
    double scale = fmin(width / (frame_w*c + frame_h*s),
                        height / (frame_w*s + frame_h*c));
    float w = frame_w * scale, h = frame_h * scale;
    return (SDL_FRect){(width-w)/2, (height-h)/2, w, h};
}

static inline SDL_FPoint
sc_rotation_point(SDL_FPoint point, SDL_FPoint center, double angle) {
    double radians = angle * (3.141592653589793 / 180.0);
    double c = cos(radians), s = sin(radians);
    float x = point.x - center.x, y = point.y - center.y;
    return (SDL_FPoint){center.x + x*c - y*s, center.y + x*s + y*c};
}
#endif
