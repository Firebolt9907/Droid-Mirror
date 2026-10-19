// Exercise the shared chrome's Bluetooth actions without ADB or a phone.
// clang -fobjc-arc -fblocks -I/opt/homebrew/include -L/opt/homebrew/lib \
//   -lSDL3 -framework Cocoa -framework QuartzCore \
//   Native/BluetoothWindowStyleTests.m -o /tmp/droidmirror-style-tests
#import "ScrcpyWindowStyle.m"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "dummy");
        assert(SDL_Init(SDL_INIT_VIDEO));
        SDL_Window *window = SDL_CreateWindow("test", 430, 860, SDL_WINDOW_HIDDEN);
        assert(window);
        DMWindowController *controller = [DMWindowController new];
        controller.bluetoothStream = YES;
        controller.sdlWindow = window;
        controller.screenView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 430, 860)];
        SDL_FlushEvents(SDL_EVENT_FIRST, SDL_EVENT_LAST);
        NSArray *keys = @[@"KEYCODE_BACK", @"KEYCODE_HOME", @"KEYCODE_APP_SWITCH",
                          @"KEYCODE_POWER", @"KEYCODE_VOLUME_DOWN", @"KEYCODE_VOLUME_UP"];
        SDL_Keycode expected[] = {SDLK_B, SDLK_H, SDLK_S, SDLK_P, SDLK_DOWN, SDLK_UP};
        for (NSUInteger i = 0; i < keys.count; ++i) {
            [controller runAndroidKey:keys[i]];
            SDL_Event event;
            for (int j = 0; j < 2; ++j) {
                assert(SDL_PollEvent(&event));
                assert(event.type == (j == 0 ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP));
                assert(event.key.key == expected[i]);
                assert(event.key.mod == SDL_KMOD_LALT);
                assert(event.key.windowID == SDL_GetWindowID(window));
                assert(event.key.down == (j == 0));
            }
            assert(!SDL_PollEvent(&event));
        }
        controller.pendingScrollX = 2;
        controller.pendingScrollY = -3;
        [controller flushSwipe];
        SDL_Event event;
        assert(SDL_PollEvent(&event) && event.type == SDL_EVENT_MOUSE_BUTTON_DOWN);
        assert(SDL_PollEvent(&event) && event.type == SDL_EVENT_MOUSE_MOTION);
        assert(event.motion.x > 215 && event.motion.y < 430);
        assert(SDL_PollEvent(&event) && event.type == SDL_EVENT_MOUSE_BUTTON_UP);
        assert(!controller.touchActive && !controller.adbShell);
        assert(!controller.adbShellInput);
        controller.sdlWindow = NULL;
        SDL_DestroyWindow(window);
        SDL_Quit();
        puts("PASS: Bluetooth toolbar navigation/power and swipe events use SDL without ADB");
    }
}
