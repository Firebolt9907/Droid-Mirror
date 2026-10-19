#ifndef SC_CAMERA_CUTOUT_H
#define SC_CAMERA_CUTOUT_H

#include <SDL3/SDL.h>
#include <stdint.h>
#include "coords.h"
#include "options.h"

struct sc_cutout_rect { int32_t left, top, right, bottom; };
struct sc_camera_cutout {
    uint16_t width, height;
    uint8_t count;
    struct sc_cutout_rect rects[4];
};

// All access is on the SDL main thread. NULL clears geometry between sessions.
void sc_camera_cutout_set(const struct sc_camera_cutout *cutout);
bool sc_camera_cutout_matches_frame(struct sc_size frame);
void sc_camera_cutout_render(SDL_Renderer *renderer, const SDL_FRect *content,
                            struct sc_size frame, enum sc_orientation orientation);
void sc_camera_cutout_update_window(SDL_Renderer *renderer, const SDL_FRect *content,
                                   struct sc_size frame, enum sc_orientation orientation);
// Additional angle rotates both the cutout and native hit area with the live video.
void sc_camera_cutout_render_rotated(SDL_Renderer *renderer, const SDL_FRect *content,
    struct sc_size frame, enum sc_orientation orientation, double angle);
void sc_camera_cutout_update_window_rotated(SDL_Renderer *renderer, const SDL_FRect *content,
    struct sc_size frame, enum sc_orientation orientation, double angle);
// Exposed for geometry tests. Returns an inscribed circle in renderer pixels.
bool sc_camera_cutout_circle(const struct sc_cutout_rect *rect,
                            const struct sc_camera_cutout *cutout, const SDL_FRect *content,
                            enum sc_orientation orientation, SDL_FPoint *center, float *radius);
#endif
