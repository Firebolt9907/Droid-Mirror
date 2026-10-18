#ifndef SC_VIDEO_FILTER_H
#define SC_VIDEO_FILTER_H

#include <SDL3/SDL.h>

#define SC_VIDEO_FILTER_PROP "droidmirror.video.sharpen"
#define SC_SPATIAL_FILTER_PROP "droidmirror.video.spatial"
#define SC_SPATIAL_SUPPORTED_PROP "droidmirror.video.spatial.supported"

struct AVFrame;
struct sc_video_filter;

struct sc_video_filter *sc_video_filter_new(void);
bool sc_video_filter_supports_spatial(SDL_Renderer *renderer);
void sc_video_filter_delete(struct sc_video_filter *filter);
void sc_video_filter_set_frame(struct sc_video_filter *filter,
                               const struct AVFrame *frame);
SDL_Texture *sc_video_filter_get(struct sc_video_filter *filter,
                                SDL_Renderer *renderer);

#endif
