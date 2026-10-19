// Run with Native/test-video-filter.sh. Uses a hidden Metal window, no phone.
#include "../scrcpy-5.0/app/src/texture.h"
#include "../scrcpy-5.0/app/src/video_filter.h"
#import "ScrcpyWindowStyle.m"
#import <CoreVideo/CoreVideo.h>
#include <assert.h>

enum { width = 480, height = 1066 };

static SDL_Surface *snapshot(SDL_Renderer *renderer, SDL_Texture *texture) {
    assert(SDL_RenderClear(renderer));
    assert(SDL_RenderTexture(renderer, texture, NULL, NULL));
    SDL_Surface *surface = SDL_RenderReadPixels(renderer, NULL);
    assert(surface);
    assert(SDL_RenderPresent(renderer));
    return surface;
}

static void exercise(SDL_Window *window, SDL_Renderer *renderer,
                     DMWindowController *controller, AVFrame *frame,
                     enum sc_hwdec_mode mode) {
    struct sc_texture texture;
    assert(sc_texture_init(&texture, renderer, false, mode));
    // Reinitializing a texture must preserve the user's menu selection.
    assert(!SDL_GetBooleanProperty(SDL_GetWindowProperties(window), SC_SPATIAL_FILTER_PROP, true));
    assert(sc_texture_update(&texture, frame));
    AVFrame *retained = av_frame_clone(frame);
    assert(retained);
    // Prove that rendering/toggling retains its own reference to decoded data.
    av_frame_unref(frame);
    SDL_Texture *original = sc_texture_get(&texture);
    assert(original == texture.interop->texture);
    SDL_Surface *before = snapshot(renderer, original);
    SDL_FlushEvents(SDL_EVENT_FIRST, SDL_EVENT_LAST);
    NSButton *button = controller.sharpenButtonControl;
    assert(button);
    button.state = NSControlStateValueOn;
    [controller toggleSharpen:button];
    assert(SDL_GetBooleanProperty(SDL_GetWindowProperties(window), SC_VIDEO_FILTER_PROP, false));
    assert([button.toolTip isEqualToString:@"Enhance video: On"]);
    SDL_Event event;
    assert(SDL_PollEvent(&event) && event.type == SDL_EVENT_WINDOW_EXPOSED);
    assert(event.window.windowID == SDL_GetWindowID(window));
    SDL_Texture *filtered = sc_texture_get(&texture);
    assert(filtered && filtered != original);
    assert(sc_texture_get(&texture) == filtered); // cached while idle
    SDL_Surface *after = snapshot(renderer, filtered);
    assert(before->format == after->format && before->pitch == after->pitch);
    assert(memcmp(before->pixels, after->pixels, before->pitch * before->h));
    SDL_Surface *rgb_before = SDL_ConvertSurface(before, SDL_PIXELFORMAT_RGBA32);
    SDL_Surface *rgb_after = SDL_ConvertSurface(after, SDL_PIXELFORMAT_RGBA32);
    assert(rgb_before && rgb_after);
    int max_edge_delta = 0;
    for (int x = 55; x < 72; ++x) {
        int offset = 100 * rgb_before->pitch + 4 * x;
        int delta = abs(((uint8_t *) rgb_before->pixels)[offset]
                      - ((uint8_t *) rgb_after->pixels)[offset]);
        if (delta > max_edge_delta) max_edge_delta = delta;
    }
    int flat_offset = 100 * rgb_before->pitch + 4 * 20;
    assert(abs(((uint8_t *) rgb_before->pixels)[flat_offset]
             - ((uint8_t *) rgb_after->pixels)[flat_offset]) <= 1);
    assert(max_edge_delta > 3); // actual edge enhancement, not a global tint
    int patch_y[] = {60, 160, 250};
    for (unsigned p = 0; p < 3; ++p) for (int channel = 0; channel < 3; ++channel) {
        int offset = patch_y[p] * rgb_before->pitch + 4 * 300 + channel;
        assert(abs(((uint8_t *) rgb_before->pixels)[offset]
                 - ((uint8_t *) rgb_after->pixels)[offset]) <= 1);
    }
    double variance_before = 0, variance_after = 0;
    for (int y = 320; y < 580; ++y) for (int x = 220; x < 380; ++x) {
        int next = y * rgb_before->pitch + x * 4;
        int a = ((uint8_t *) rgb_before->pixels)[next] - ((uint8_t *) rgb_before->pixels)[next + 4];
        int b = ((uint8_t *) rgb_after->pixels)[next] - ((uint8_t *) rgb_after->pixels)[next + 4];
        variance_before += a * a; variance_after += b * b;
    }
    assert(variance_after < variance_before * 0.5);
    printf("%s: edge delta %d levels; compression-noise energy %.0f%% of input\n",
           texture.interop->name, max_edge_delta, variance_after / variance_before * 100);
    SDL_DestroySurface(rgb_before); SDL_DestroySurface(rgb_after);
    button.state = NSControlStateValueOff;
    [controller toggleSharpen:button];
    assert(sc_texture_get(&texture) == original);
    SDL_Surface *restored = snapshot(renderer, sc_texture_get(&texture));
    assert(!memcmp(before->pixels, restored->pixels, before->pitch * before->h));
    button.state = NSControlStateValueOn;
    [controller toggleSharpen:button];
    Uint64 start = SDL_GetTicksNS();
    for (int i = 0; i < 30; ++i) {
        assert(sc_texture_update(&texture, retained));
        assert(sc_texture_get(&texture) != texture.interop->texture);
        assert(SDL_RenderTexture(renderer, sc_texture_get(&texture), NULL, NULL));
        assert(SDL_RenderPresent(renderer));
    }
    printf("%s: %.2f ms/frame at %dx%d (warm filter + render)\n",
           texture.interop->name, (SDL_GetTicksNS() - start) / 30e6, width, height);
    button.state = NSControlStateValueOff;
    [controller toggleSharpen:button];
    NSButton *spatialButton = controller.spatialButtonControl;
    assert(spatialButton && spatialButton.state == NSControlStateValueOff);
    SDL_FlushEvents(SDL_EVENT_FIRST, SDL_EVENT_LAST);
    spatialButton.state = NSControlStateValueOn;
    [controller toggleSpatial:spatialButton];
    assert(SDL_PollEvent(&event) && event.type == SDL_EVENT_WINDOW_EXPOSED);
    assert(SDL_GetBooleanProperty(SDL_GetWindowProperties(window), SC_SPATIAL_FILTER_PROP, false));
    assert(controller.spatialMenuItem.state == NSControlStateValueOn);
    SDL_Texture *upscaled = sc_texture_get(&texture);
    assert(upscaled && upscaled != texture.interop->texture);
    float output_width, output_height;
    assert(SDL_GetTextureSize(upscaled, &output_width, &output_height));
    assert(output_width == width * 2 && output_height == height * 2);
    assert(sc_texture_get(&texture) == upscaled);
    SDL_Surface *spatial_image = snapshot(renderer, upscaled);
    SDL_Surface *spatial_rgb = SDL_ConvertSurface(spatial_image, SDL_PIXELFORMAT_RGBA32);
    SDL_Surface *original_rgb = SDL_ConvertSurface(before, SDL_PIXELFORMAT_RGBA32);
    for (unsigned p = 0; p < 3; ++p) for (int channel = 0; channel < 3; ++channel) {
        int offset = patch_y[p] * spatial_rgb->pitch + 4 * 300 + channel;
        int delta = abs(((uint8_t *) spatial_rgb->pixels)[offset] - ((uint8_t *) original_rgb->pixels)[offset]);
        assert(delta <= 2);
    }
    button.state = NSControlStateValueOn;
    [controller toggleSharpen:button];
    SDL_Texture *combined = sc_texture_get(&texture);
    assert(SDL_GetTextureSize(combined, &output_width, &output_height));
    assert(output_width == width * 2 && output_height == height * 2);
    SDL_Surface *combined_image = snapshot(renderer, combined);
    assert(memcmp(spatial_image->pixels, combined_image->pixels, spatial_image->pitch * spatial_image->h));
    start = SDL_GetTicksNS();
    for (int i = 0; i < 10; ++i) {
        assert(sc_texture_update(&texture, retained));
        assert(SDL_RenderTexture(renderer, sc_texture_get(&texture), NULL, NULL));
        assert(SDL_RenderPresent(renderer));
    }
    printf("%s: %.2f ms/frame with enhancement + MetalFX 2x\n",
           texture.interop->name, (SDL_GetTicksNS() - start) / 10e6);
    spatialButton.state = NSControlStateValueOff;
    [controller toggleSpatial:spatialButton];
    assert(SDL_GetTextureSize(sc_texture_get(&texture), &output_width, &output_height));
    assert(output_width == width && output_height == height);
    button.state = NSControlStateValueOff;
    [controller toggleSharpen:button];
    SDL_Surface *bypass = snapshot(renderer, sc_texture_get(&texture));
    assert(!memcmp(before->pixels, bypass->pixels, before->pitch * before->h));
    SDL_DestroySurface(bypass); SDL_DestroySurface(spatial_image);
    SDL_DestroySurface(combined_image); SDL_DestroySurface(spatial_rgb); SDL_DestroySurface(original_rgb);
    AVFrame *landscape = av_frame_alloc();
    assert(landscape);
    landscape->format = AV_PIX_FMT_YUV420P;
    landscape->width = 320; landscape->height = 180;
    landscape->colorspace = AVCOL_SPC_BT709;
    assert(av_frame_get_buffer(landscape, 32) == 0);
    for (int p = 0; p < 3; ++p) for (int y = 0; y < (p ? 90 : 180); ++y)
        memset(landscape->data[p] + y * landscape->linesize[p], p ? 128 : 48, p ? 160 : 320);
    assert(sc_texture_update(&texture, landscape));
    spatialButton.state = NSControlStateValueOn;
    [controller toggleSpatial:spatialButton];
    assert(SDL_GetTextureSize(sc_texture_get(&texture), &output_width, &output_height));
    assert(output_width == 640 && output_height == 360);
    struct sc_size input_size = sc_texture_get_frame_size(&texture);
    assert(input_size.width == 320 && input_size.height == 180);
    spatialButton.state = NSControlStateValueOff;
    [controller toggleSpatial:spatialButton];
    av_frame_free(&landscape);
    av_frame_free(&retained);
    // Filter resources are invalidated safely when dimensions change/reset.
    sc_texture_reset(&texture);
    assert(sc_texture_get(&texture) == NULL);
    SDL_DestroySurface(before); SDL_DestroySurface(after); SDL_DestroySurface(restored);
    sc_texture_destroy(&texture);
}

int main(void) {
    @autoreleasepool {
        assert(SDL_Init(SDL_INIT_VIDEO));
        SDL_Window *window = SDL_CreateWindow("DroidMirror filter test", width, height, SDL_WINDOW_HIDDEN);
        assert(window);
        SDL_Renderer *renderer = SDL_CreateRenderer(window, "metal");
        assert(renderer);
        DMWindowController *controller = [DMWindowController new];
        controller.sdlWindow = window;
        controller.window = (__bridge NSWindow *) SDL_GetPointerProperty(
            SDL_GetWindowProperties(window), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
        controller.screenView = controller.window.contentView;
        struct sc_texture initial;
        assert(sc_texture_init(&initial, renderer, false, SC_HWDEC_MODE_DISABLED));
        SDL_PropertiesID properties = SDL_GetWindowProperties(window);
        assert(SDL_GetBooleanProperty(properties, SC_SPATIAL_SUPPORTED_PROP, false));
        assert(SDL_GetBooleanProperty(properties, SC_SPATIAL_FILTER_PROP, false));
        sc_texture_destroy(&initial);
        [controller buildToolbar];
        assert(controller.spatialButtonControl.state == NSControlStateValueOn);
        assert(controller.spatialMenuItem.state == NSControlStateValueOn);
        NSMenu *viewMenu = [NSApp.mainMenu itemWithTitle:@"View"].submenu;
        NSInteger itemCount = viewMenu.numberOfItems;
        [controller ensureVideoMenu];
        assert(viewMenu.numberOfItems == itemCount);
        SDL_FlushEvents(SDL_EVENT_FIRST, SDL_EVENT_LAST);
        // Menu action immediately updates both controls and redraws an idle frame.
        assert([NSApp sendAction:controller.spatialMenuItem.action to:controller.spatialMenuItem.target from:controller.spatialMenuItem]);
        assert(!SDL_GetBooleanProperty(properties, SC_SPATIAL_FILTER_PROP, true));
        assert(controller.spatialButtonControl.state == NSControlStateValueOff);
        assert(controller.spatialMenuItem.state == NSControlStateValueOff);
        SDL_Event menuEvent;
        assert(SDL_PollEvent(&menuEvent) && menuEvent.type == SDL_EVENT_WINDOW_EXPOSED);
        [controller toggleSpatialFromMenu:controller.spatialMenuItem];
        assert(SDL_GetBooleanProperty(properties, SC_SPATIAL_FILTER_PROP, false));
        assert(controller.spatialButtonControl.state == NSControlStateValueOn);
        [controller toggleSpatialFromMenu:controller.spatialMenuItem];
        SDL_SetBooleanProperty(properties, SC_SPATIAL_SUPPORTED_PROP, false);
        assert(![controller validateMenuItem:controller.spatialMenuItem]);
        assert(!controller.spatialMenuItem.enabled && !controller.spatialButtonControl.enabled);
        [controller toggleSpatialFromMenu:controller.spatialMenuItem];
        assert(!SDL_GetBooleanProperty(properties, SC_SPATIAL_FILTER_PROP, true));
        SDL_SetBooleanProperty(properties, SC_SPATIAL_SUPPORTED_PROP, true);
        assert([controller validateMenuItem:controller.spatialMenuItem]);
        assert(controller.sharpenButtonControl.state == NSControlStateValueOff);
        assert([controller.sharpenButtonControl.accessibilityLabel isEqualToString:@"Enhance video"]);
        AVFrame *frame = av_frame_alloc();
        assert(frame);
        frame->format = AV_PIX_FMT_YUV420P;
        frame->width = width; frame->height = height;
        frame->color_range = AVCOL_RANGE_MPEG; frame->colorspace = AVCOL_SPC_BT709;
        assert(av_frame_get_buffer(frame, 32) == 0);
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                // A slightly soft edge, with flat dark/light regions.
                frame->data[0][y * frame->linesize[0] + x] =
                    x < 62 ? 48 : x > 65 ? 200 : 48 + (x - 61) * 30;
            }
        }
        for (int p = 1; p < 3; ++p)
            for (int y = 0; y < height / 2; ++y) memset(frame->data[p] + y * frame->linesize[p], 128, width / 2);
        for (int y = 40; y < 280; ++y) for (int x = 280; x < 340; ++x)
            frame->data[0][y * frame->linesize[0] + x] = y < 100 ? 235 : y < 200 ? 16 : 128;
        for (int y = 300; y < 600; ++y) for (int x = 200; x < 400; ++x)
            frame->data[0][y * frame->linesize[0] + x] = 100 + ((x / 3 + y / 3) % 2 ? 4 : -4);
        for (int y = 120; y < 140; ++y) for (int x = 140; x < 170; ++x) {
            frame->data[1][y * frame->linesize[1] + x] = 90;
            frame->data[2][y * frame->linesize[2] + x] = 180;
        }
        AVFrame *hardware = av_frame_alloc();
        assert(hardware);
        AVBufferRef *device = NULL;
        assert(av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) == 0);
        AVBufferRef *frames = av_hwframe_ctx_alloc(device);
        assert(frames);
        AVHWFramesContext *ctx = (AVHWFramesContext *) frames->data;
        ctx->format = AV_PIX_FMT_VIDEOTOOLBOX; ctx->sw_format = AV_PIX_FMT_NV12;
        ctx->width = width; ctx->height = height;
        assert(av_hwframe_ctx_init(frames) == 0);
        assert(av_hwframe_get_buffer(frames, hardware, 0) == 0);
        CVPixelBufferRef buffer = (CVPixelBufferRef) hardware->data[3];
        assert(CVPixelBufferLockBaseAddress(buffer, 0) == kCVReturnSuccess);
        uint8_t *y_plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
        uint8_t *uv_plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
        for (int y = 0; y < height; ++y)
            memcpy(y_plane + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), frame->data[0] + y * frame->linesize[0], width);
        for (int y = 0; y < height / 2; ++y) for (int x = 0; x < width / 2; ++x) {
            size_t offset = y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + x * 2;
            uv_plane[offset] = frame->data[1][y * frame->linesize[1] + x];
            uv_plane[offset + 1] = frame->data[2][y * frame->linesize[2] + x];
        }
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        hardware->color_range = AVCOL_RANGE_MPEG; hardware->colorspace = AVCOL_SPC_BT709;
        exercise(window, renderer, controller, frame, SC_HWDEC_MODE_DISABLED);
        exercise(window, renderer, controller, hardware, SC_HWDEC_MODE_VIDEOTOOLBOX);
        const char *reference = getenv("DM_FILTER_REFERENCE");
        if (reference) {
            FILE *file = fopen(reference, "rb");
            assert(file);
            frame->format = AV_PIX_FMT_YUV420P; frame->width = width; frame->height = height;
            frame->colorspace = AVCOL_SPC_BT709; frame->color_range = AVCOL_RANGE_MPEG;
            assert(av_frame_get_buffer(frame, 32) == 0);
            for (int p = 0; p < 3; ++p) for (int y = 0; y < (p ? height / 2 : height); ++y)
                assert(fread(frame->data[p] + y * frame->linesize[p], 1, p ? width / 2 : width, file) == (size_t)(p ? width / 2 : width));
            fclose(file);
            struct sc_texture texture;
            assert(sc_texture_init(&texture, renderer, false, SC_HWDEC_MODE_DISABLED));
            assert(sc_texture_update(&texture, frame));
            SDL_Surface *before = snapshot(renderer, sc_texture_get(&texture));
            assert(SDL_SaveBMP(before, "/tmp/droidmirror-filter-before.bmp"));
            controller.sharpenButtonControl.state = NSControlStateValueOn;
            [controller toggleSharpen:controller.sharpenButtonControl];
            SDL_Surface *after = snapshot(renderer, sc_texture_get(&texture));
            assert(SDL_SaveBMP(after, "/tmp/droidmirror-filter-after.bmp"));
            SDL_DestroySurface(before); SDL_DestroySurface(after);
            sc_texture_destroy(&texture);
        }
        av_frame_free(&frame); av_frame_free(&hardware);
        av_buffer_unref(&frames); av_buffer_unref(&device);
        controller.sdlWindow = NULL;
        SDL_DestroyRenderer(renderer); SDL_DestroyWindow(window); SDL_Quit();
        puts("PASS: enhancement and MetalFX 2x work independently/together on software and VideoToolbox frames; color, bypass, idle redraw, and size changes verified");
    }
}
