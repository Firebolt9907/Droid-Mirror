// Match the release client's struct layout while keeping test assertions enabled.
#define NDEBUG
#include "screen.h"
#undef NDEBUG
#include <assert.h>
#include "rotation.h"
#import "ScrcpyWindowStyle.m"

static BOOL reduceMotion;
static BOOL TestReduceMotion(id workspace, SEL selector) { return reduceMotion; }
static void near(double a, double b) { assert(fabs(a-b) < 2); }

static SDL_FPoint windowCenter(SDL_Window *window) {
    int x, y, w, h;
    assert(SDL_GetWindowPosition(window, &x, &y));
    assert(SDL_GetWindowSize(window, &w, &h));
    return (SDL_FPoint){x + w/2.f, y + h/2.f};
}
static void anchored(SDL_Window *window, SDL_FPoint anchor) {
    SDL_FPoint current = windowCenter(window);
    assert(fabs(current.x-anchor.x) <= .5 && fabs(current.y-anchor.y) <= .5);
    NSWindow *native = (__bridge NSWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(window),
        SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    NSSize aspect = native.contentAspectRatio;
    assert(isfinite(aspect.width) && isfinite(aspect.height) && aspect.width > 0 && aspect.height > 0);
}

static void finish(struct sc_screen *screen) {
    screen->rotation.start = SDL_GetTicks() - SC_ROTATION_DURATION_MS;
    screen->rotation.next_tick = 0;
    sc_screen_tick(screen);
    assert(!screen->rotation.active);
}

static void upload(struct sc_screen *screen, AVFrame *frame, int width, int height, int luma) {
    av_frame_unref(frame);
    frame->width=width; frame->height=height; frame->format=AV_PIX_FMT_YUV420P;
    assert(av_frame_get_buffer(frame,32)==0);
    for (int p=0;p<3;++p) memset(frame->data[p],p?128:luma,frame->linesize[p]*(p?height/2:height));
    assert(sc_texture_update(&screen->tex,frame));
    // Verify the real 2x MetalFX output is used, rather than a silent fallback.
    float output_width, output_height;
    assert(SDL_GetTextureSize(sc_texture_get(&screen->tex), &output_width, &output_height));
    assert(output_width == width * 2 && output_height == height * 2);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        Method getter = class_getInstanceMethod(NSWorkspace.class, @selector(accessibilityDisplayShouldReduceMotion));
        IMP original = method_setImplementation(getter, (IMP)TestReduceMotion);
        assert(SDL_Init(SDL_INIT_VIDEO));
        // The turn starts/settles gently, stays monotonic, and keeps its midpoint.
        Uint64 curveStart = 1000;
        assert(sc_rotation_progress(curveStart,curveStart) == 0);
        assert(sc_rotation_progress(curveStart+SC_ROTATION_DURATION_MS,curveStart) == 1);
        double quarter = sc_rotation_progress(curveStart+SC_ROTATION_DURATION_MS/4,curveStart);
        double midpoint = sc_rotation_progress(curveStart+SC_ROTATION_DURATION_MS/2,curveStart);
        double threeQuarters = sc_rotation_progress(curveStart+3*SC_ROTATION_DURATION_MS/4,curveStart);
        assert(quarter < .15 && threeQuarters > .85 && fabs(midpoint-.5) < 1e-9);
        double previous = 0;
        for (int elapsed=0;elapsed<=SC_ROTATION_DURATION_MS;++elapsed) {
            double current = sc_rotation_progress(curveStart+elapsed,curveStart);
            assert(current >= previous && current <= 1);
            previous = current;
        }
        assert(sc_rotation_frame_interval(120) == 8);
        assert(sc_rotation_frame_interval(0) == 16);
        assert(sc_rotation_wait_ms(105,108) == 3);
        assert(sc_rotation_wait_ms(110,108) == 0);
        // Keep timestamps above the animation duration for deterministic completion.
        SDL_Delay(SC_ROTATION_DURATION_MS);
        struct sc_screen screen = {0};
        screen.video = screen.window_shown = screen.window_aspect_ratio_lock = true;
        screen.render_fit = SC_RENDER_FIT_LETTERBOX;
        screen.frame_size = screen.content_size = (struct sc_size){180, 320};
        screen.window = SDL_CreateWindow("Rotation test", 180, 320, SDL_WINDOW_HIDDEN | SDL_WINDOW_RESIZABLE);
        assert(screen.window);
        assert(SDL_SetWindowPosition(screen.window, 400, 250));
        SDL_FPoint anchor = windowCenter(screen.window);
        screen.renderer = SDL_CreateRenderer(screen.window, "metal");
        assert(screen.renderer);
        assert(sc_texture_init(&screen.tex, screen.renderer, false, SC_HWDEC_MODE_DISABLED));
        SDL_PropertiesID properties = SDL_GetWindowProperties(screen.window);
        assert(SDL_GetBooleanProperty(properties, SC_SPATIAL_SUPPORTED_PROP, false));
        SDL_SetBooleanProperty(properties, SC_SPATIAL_FILTER_PROP, true);
        AVFrame *frame = av_frame_alloc();
        frame->width = 180; frame->height = 320; frame->format = AV_PIX_FMT_YUV420P;
        assert(av_frame_get_buffer(frame, 32) == 0);
        for (int p = 0; p < 3; ++p)
            memset(frame->data[p], p ? 128 : 90, frame->linesize[p] * (p ? 160 : 320));
        assert(sc_texture_update(&screen.tex, frame));

        // The connecting screen creates an Auto Layout engine on the SDL window.
        // It persists after the status view is removed when video appears.
        NSWindow *native = (__bridge NSWindow *)SDL_GetPointerProperty(properties,
            SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
        NSView *loading = [[NSView alloc] initWithFrame:native.contentView.bounds];
        [native.contentView addSubview:loading];
        NSTextField *status = [NSTextField labelWithString:@"Connecting…"];
        status.translatesAutoresizingMaskIntoConstraints = NO;
        [loading addSubview:status];
        [NSLayoutConstraint activateConstraints:@[
            [status.centerXAnchor constraintEqualToAnchor:loading.centerXAnchor],
            [status.centerYAnchor constraintEqualToAnchor:loading.centerYAnchor]]];
        [native.contentView layoutSubtreeIfNeeded];
        [loading removeFromSuperview];

        // Live sessions lock their initial aspect before the first app rotation.
        assert(SDL_SetWindowAspectRatio(screen.window, 180.f/320, 180.f/320));

        // App-triggered stream changes use the production frame-size path.
        assert(!sc_rotation_is_orientation_change(180,320,360,640));
        assert(!sc_rotation_is_orientation_change(180,320,320,300));
        sc_screen_set_frame_size(&screen, (struct sc_size){320,180}, true);
        assert(screen.rotation.active && screen.orientation == SC_ORIENTATION_0);
        near(screen.rotation.from, 90);
        upload(&screen, frame, 320, 180, 180);
        // Measure repeated pose updates without new video frames or upscaling work.
        if (getenv("DROIDMIRROR_ROTATION_BENCHMARK")) {
            double costs[60];
            for (int i=0;i<60;++i) {
                screen.rotation.start = SDL_GetTicks() - (SC_ROTATION_DURATION_MS-1)*i/60;
                screen.rotation.next_tick = 0;
                Uint64 began = SDL_GetTicksNS();
                sc_screen_tick(&screen);
                costs[i] = (SDL_GetTicksNS()-began)/1e6;
            }
            for (int i=0;i<60;++i) for (int j=i+1;j<60;++j)
                if (costs[j]<costs[i]) { double swap=costs[i]; costs[i]=costs[j]; costs[j]=swap; }
            printf("Rotation pose update: median %.2f ms, p95 %.2f ms\n",costs[30],costs[57]);
        }
        int canvas_width, canvas_height;
        assert(SDL_GetWindowSize(screen.window, &canvas_width, &canvas_height));
        assert(canvas_width == canvas_height && canvas_width >= hypot(320,180));
        // Only the angle changes: no window resizing, fitting, or surface scaling.
        NSUInteger shadowRasterizations = 0;
        id shadowView = nil;
        for (int step = 1; step <= 3; ++step) {
            screen.rotation.start = SDL_GetTicks() - SC_ROTATION_DURATION_MS*step/4;
            screen.rotation.next_tick = 0;
            sc_screen_tick(&screen);
            int width, height;
            SDL_GetWindowSize(screen.window, &width, &height);
            assert(width == canvas_width && height == canvas_height);
            near(screen.rotation.rect.w, 320); near(screen.rotation.rect.h, 180);
            double radians = screen.rotation.angle*M_PI/180;
            CAShapeLayer *mask = (CAShapeLayer *)native.contentView.layer.mask;
            CGRect silhouette = CGPathGetBoundingBox(mask.path);
            near(silhouette.size.width, fabs(cos(radians))*320 + fabs(sin(radians))*180);
            near(silhouette.size.height, fabs(sin(radians))*320 + fabs(cos(radians))*180);
            assert(CGPathEqualToPath(mask.path, native.contentView.layer.shadowPath));
            for (NSWindow *child in native.childWindows)
                if ([child.contentView isKindOfClass:NSClassFromString(@"DMPhoneShadowView")]) shadowView = child.contentView;
            assert(shadowView);
            NSUInteger rasterizations = [[shadowView valueForKey:@"rotationRasterizations"] unsignedIntegerValue];
            if (step == 1) shadowRasterizations = rasterizations;
            assert(rasterizations == shadowRasterizations && rasterizations > 0);
            CALayer *cachedShadow = [shadowView valueForKey:@"rotationLayer"];
            assert(cachedShadow.contents && !cachedShadow.hidden);
            if (step == 1) {
                CGImageRef shadowImage = (__bridge CGImageRef)cachedShadow.contents;
                CFDataRef pixels = CGDataProviderCopyData(CGImageGetDataProvider(shadowImage));
                const UInt8 *bytes = CFDataGetBytePtr(pixels);
                size_t w = CGImageGetWidth(shadowImage), h = CGImageGetHeight(shadowImage);
                size_t stride = CGImageGetBytesPerRow(shadowImage);
                assert(CGImageGetBitsPerPixel(shadowImage) == 32);
                assert(bytes[(h/2)*stride + (w/2)*4 + 3] == 0); // no solid caster
                bool hasShadow = false;
                for (size_t y=0;y<h && !hasShadow;++y) for (size_t x=0;x<w;++x)
                    if (bytes[y*stride+x*4+3] > 0) { hasShadow = true; break; }
                assert(hasShadow);
                CFRelease(pixels);
            }
            CGAffineTransform transform = cachedShadow.affineTransform;
            near(atan2(transform.b, transform.a)*180/M_PI, -screen.rotation.angle);
            assert(!CGPathContainsPoint(mask.path,NULL,CGPointMake(1,1),NO));
            anchored(screen.window, anchor);
        }
        screen.rotation.next_tick = 0;
        screen.rotation.start = SDL_GetTicks() - SC_ROTATION_DURATION_MS/2;
        sc_screen_tick(&screen);
        near(screen.rotation.angle, 45);
        // A source point to the right of center starts below center and turns
        // upward as landscape settles; this checks direction, not just bounds.
        SDL_FPoint center = {screen.rotation.rect.x + screen.rotation.rect.w/2,
                             screen.rotation.rect.y + screen.rotation.rect.h/2};
        SDL_FPoint marker = sc_rotation_point((SDL_FPoint){center.x + 40, center.y},
                                               center, screen.rotation.angle);
        assert(marker.x > center.x && marker.y > center.y);
        anchored(screen.window, anchor);
        SDL_FRect rect = screen.rotation.rect;
        SDL_FPoint p = sc_rotation_point((SDL_FPoint){rect.x+rect.w*.25f,rect.y+rect.h*.75f},
            (SDL_FPoint){rect.x+rect.w/2,rect.y+rect.h/2},screen.rotation.angle);
        struct sc_point mapped = sc_screen_convert_window_to_frame_coords(&screen,lround(p.x),lround(p.y));
        near(mapped.x,80); near(mapped.y,135);
        // A video quality upgrade during rotation must not cancel or restart it.
        sc_screen_set_frame_size(&screen,(struct sc_size){640,360},true);
        assert(screen.rotation.active);
        near(screen.rotation.angle,45);
        upload(&screen,frame,640,360,110);
        finish(&screen);
        anchored(screen.window,anchor);
        int width,height;
        SDL_GetWindowSize(screen.window,&width,&height);
        assert(width==320 && height==180);
        // Exiting fullscreen returns to portrait around the same center.
        sc_screen_set_frame_size(&screen,(struct sc_size){180,320},true);
        near(screen.rotation.from,-90);
        upload(&screen,frame,180,320,100);
        finish(&screen);
        anchored(screen.window,anchor);
        SDL_GetWindowSize(screen.window,&width,&height);
        assert(width==180 && height==320);
        // Reverse an in-flight app orientation change from its visible angle.
        sc_screen_set_frame_size(&screen,(struct sc_size){320,180},true);
        upload(&screen,frame,320,180,110);
        screen.rotation.start=SDL_GetTicks()-SC_ROTATION_DURATION_MS/2;
        screen.rotation.next_tick=0;
        sc_screen_tick(&screen);
        near(screen.rotation.angle,45);
        sc_screen_set_frame_size(&screen,(struct sc_size){180,320},true);
        near(screen.rotation.from,-45);
        upload(&screen,frame,180,320,120);
        finish(&screen);
        anchored(screen.window,anchor);
        // Quality changes alone do not animate an orientation change.
        sc_screen_set_frame_size(&screen,(struct sc_size){360,640},true);
        assert(!screen.rotation.active);
        upload(&screen,frame,360,640,130);
        reduceMotion=YES;
        anchor=windowCenter(screen.window);
        sc_screen_set_frame_size(&screen,(struct sc_size){640,360},true);
        assert(!screen.rotation.active);
        anchored(screen.window,anchor);
        upload(&screen,frame,640,360,140);
        // Moving the window establishes a new center for the next turn.
        assert(SDL_SetWindowPosition(screen.window,500,300));
        anchor=windowCenter(screen.window);
        reduceMotion=NO;
        sc_screen_set_frame_size(&screen,(struct sc_size){360,640},true);
        upload(&screen,frame,360,640,150);
        finish(&screen);
        anchored(screen.window,anchor);
        sc_screen_set_frame_size(&screen,(struct sc_size){640,360},false);
        assert(!screen.rotation.active); // honor user resize suppression
        // Ending a session during a turn restores normal bounds and its mask.
        sc_screen_set_frame_size(&screen,(struct sc_size){360,640},true);
        upload(&screen,frame,360,640,150);
        assert(screen.rotation.active);
        sc_screen_hide_window(&screen);
        assert(!screen.rotation.active && !screen.window_shown);
        assert(!SDL_GetBooleanProperty(properties,SC_ROTATION_PRESENTATION_PROP,true));
        CAShapeLayer *restored = (CAShapeLayer *)native.contentView.layer.mask;
        CGRect restored_bounds = CGPathGetBoundingBox(restored.path);
        assert(CGRectEqualToRect(restored_bounds,NSRectToCGRect(native.contentView.bounds)));
        method_setImplementation(getter, original);
        sc_texture_destroy(&screen.tex);
        av_frame_free(&frame);
        SDL_DestroyRenderer(screen.renderer);
        SDL_DestroyWindow(screen.window);
        SDL_Quit();
        puts("PASS: Auto Layout crash regression, finite aspect ratios, actual 2x MetalFX, live rotation, input, quality changes, interruption, cached shadow, refresh-aware pacing, rigid rotation, fixed center and Reduce Motion");
    }
}
