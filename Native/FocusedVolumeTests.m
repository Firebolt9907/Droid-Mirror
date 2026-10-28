// Exercise the installed shim entry point, not only the underlying decoder.
#import "ScrcpyWindowStyle.m"
#import "KeyboardPassthroughShim.m"
#include <assert.h>

@interface DMVolumeTestApplication : NSObject
@property BOOL isActive;
@end
@implementation DMVolumeTestApplication
@end
static unsigned passedThrough;
static void DMVolumeTestOriginal(NSApplication *app, SEL selector, NSEvent *event) {
    ++passedThrough;
}
int main(void) {
    @autoreleasepool {
        SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "dummy");
        assert(SDL_Init(SDL_INIT_VIDEO));
        SDL_Window *window = SDL_CreateWindow("test", 430, 860, SDL_WINDOW_HIDDEN);
        assert(window);
        DMWindowController *controller = [DMWindowController new];
        controller.bluetoothStream = YES;
        controller.sessionActive = YES;
        controller.sdlWindow = window;
        DMSecureController = controller;
        DMOriginalSendEvent = DMVolumeTestOriginal;
        DMVolumeTestApplication *app = [DMVolumeTestApplication new];
        SDL_FlushEvents(SDL_EVENT_FIRST, SDL_EVENT_LAST);
        for (unsigned active = 0; active < 2; ++active) {
            app.isActive = active;
            for (unsigned key = 0; key < 3; ++key) {
                for (unsigned flags = 0xa00; flags <= 0xb00; flags += 0x80) {
                    NSEvent *event = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                        location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
                        context:nil subtype:8 data1:(key << 16) | flags data2:0];
                    unsigned before = passedThrough;
                    DMSendEvent((NSApplication *)app, @selector(sendEvent:), event);
                    BOOL consumed = active && key < 2;
                    assert(passedThrough == before + !consumed);
                    SDL_Event sent;
                    if (consumed && flags < 0xb00) {
                        for (int edge = 0; edge < 2; ++edge) {
                            assert(SDL_PollEvent(&sent));
                            assert(sent.type == (edge ? SDL_EVENT_KEY_UP : SDL_EVENT_KEY_DOWN));
                            assert(sent.key.key == (key ? SDLK_DOWN : SDLK_UP));
                            assert(sent.key.mod == SDL_KMOD_LALT);
                        }
                    }
                    assert(!SDL_PollEvent(&sent));
                }
            }
        }
        controller.sdlWindow = NULL;
        SDL_DestroyWindow(window);
        SDL_Quit();
        puts("PASS: installed sendEvent hook forwards focused volume presses/repeats, consumes releases, and passes other events");
    }
}
