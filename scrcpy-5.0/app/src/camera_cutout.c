#include "camera_cutout.h"

#include <math.h>
#include <string.h>
#ifdef __APPLE__
#include <dlfcn.h>
#endif

static struct sc_camera_cutout current;

void
sc_camera_cutout_set(const struct sc_camera_cutout *cutout) {
    if (cutout) current = *cutout;
    else memset(&current, 0, sizeof(current));
}

bool
sc_camera_cutout_circle(const struct sc_cutout_rect *rect,
                       const struct sc_camera_cutout *cutout, const SDL_FRect *content,
                       enum sc_orientation orientation, SDL_FPoint *center, float *radius) {
    if (!cutout->width || !cutout->height || content->w <= 0 || content->h <= 0
            || rect->right <= rect->left || rect->bottom <= rect->top) return false;
    float u = ((float) rect->left + rect->right) / (2 * cutout->width);
    float v = ((float) rect->top + rect->bottom) / (2 * cutout->height);
    if (sc_orientation_is_mirror(orientation)) u = 1 - u;
    switch (sc_orientation_get_rotation(orientation)) {
        case 1: { float old = u; u = 1 - v; v = old; break; }
        case 2: u = 1 - u; v = 1 - v; break;
        case 3: { float old = u; u = v; v = 1 - old; break; }
        default: break;
    }
    float sx = (sc_orientation_is_swap(orientation) ? content->h : content->w) / cutout->width;
    float sy = (sc_orientation_is_swap(orientation) ? content->w : content->h) / cutout->height;
    *center = (SDL_FPoint){content->x + u * content->w, content->y + v * content->h};
    *radius = fminf((rect->right - rect->left) * sx, (rect->bottom - rect->top) * sy) / 2;
    return isfinite(*radius) && *radius > 0;
}

// Normalized renderer coordinates keep native hit testing correct on Retina,
// resized/letterboxed video, and every display orientation.
void
sc_camera_cutout_update_window(SDL_Renderer *renderer, const SDL_FRect *content,
                              struct sc_size frame, enum sc_orientation orientation) {
#ifdef __APPLE__
    void (*update)(SDL_Window *, const float *, unsigned) =
        (void (*)(SDL_Window *, const float *, unsigned))
        dlsym(RTLD_DEFAULT, "DroidMirrorSetCameraCutouts");
    if (!update) return;
    float circles[16];
    unsigned count = 0;
    int width, height;
    if (SDL_GetCurrentRenderOutputSize(renderer, &width, &height) && width > 0 && height > 0
            && current.width == frame.width && current.height == frame.height) {
        for (unsigned i = 0; i < current.count && i < 4; ++i) {
            SDL_FPoint center;
            float radius;
            if (!sc_camera_cutout_circle(&current.rects[i], &current, content, orientation, &center, &radius)) continue;
            circles[4*count] = center.x / width;
            circles[4*count+1] = center.y / height;
            circles[4*count+2] = radius / width;
            circles[4*count+3] = radius / height;
            ++count;
        }
    }
    update(SDL_GetRenderWindow(renderer), circles, count);
#endif
}

void
sc_camera_cutout_render(SDL_Renderer *renderer, const SDL_FRect *content,
                       struct sc_size frame, enum sc_orientation orientation) {
    // A geometry message from a previous orientation must never mark the wrong place.
    if (current.width != frame.width || current.height != frame.height || !current.count) return;
    SDL_BlendMode old_blend;
    SDL_GetRenderDrawBlendMode(renderer, &old_blend);
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
    bool had_clip = SDL_RenderClipEnabled(renderer);
    SDL_Rect old_clip;
    SDL_GetRenderClipRect(renderer, &old_clip);
    SDL_Rect clip = {(int) floorf(content->x), (int) floorf(content->y),
                     (int) ceilf(content->w), (int) ceilf(content->h)};
    if (had_clip) SDL_GetRectIntersection(&clip, &old_clip, &clip);
    SDL_SetRenderClipRect(renderer, &clip);
    enum { N = 96 };
    for (unsigned c = 0; c < current.count && c < 4; ++c) {
        SDL_FPoint center;
        float radius;
        if (!sc_camera_cutout_circle(&current.rects[c], &current, content, orientation, &center, &radius)) continue;
        SDL_Vertex vertices[1 + 2 * N];
        int indices[9 * N];
        vertices[0] = (SDL_Vertex){.position = center, .color = {0, 0, 0, 1}};
        float inner = fmaxf(0, radius - 1); // One renderer pixel of antialiasing, inside the reported bounds.
        for (int i = 0; i < N; ++i) {
            float angle = (float) (i * 2 * 3.141592653589793 / N);
            float x = cosf(angle), y = sinf(angle);
            vertices[1 + i] = (SDL_Vertex){.position = {center.x + inner*x, center.y + inner*y}, .color = {0, 0, 0, 1}};
            vertices[1 + N + i] = (SDL_Vertex){.position = {center.x + radius*x, center.y + radius*y}, .color = {0, 0, 0, 0}};
            int next = (i + 1) % N;
            int triangle[] = {0, 1+i, 1+next, 1+i, 1+N+i, 1+N+next, 1+i, 1+N+next, 1+next};
            memcpy(indices + 9*i, triangle, sizeof(triangle));
        }
        SDL_RenderGeometry(renderer, NULL, vertices, 1 + 2*N, indices, 9*N);
    }
    SDL_SetRenderClipRect(renderer, had_clip ? &old_clip : NULL);
    SDL_SetRenderDrawBlendMode(renderer, old_blend);
}
