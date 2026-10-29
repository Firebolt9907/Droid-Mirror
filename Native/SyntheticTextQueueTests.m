#import "SyntheticText.h"
#include <SDL3/SDL.h>
#include <assert.h>

static void Post(NSString *text, unsigned short key, NSEventModifierFlags flags) {
    for (NSNumber *type in @[@(NSEventTypeKeyDown), @(NSEventTypeKeyUp)]) {
        CGEventRef raw = CGEventCreateKeyboardEvent(NULL, key, type.unsignedIntegerValue == NSEventTypeKeyDown);
        UniChar chars[text.length];
        [text getCharacters:chars range:NSMakeRange(0, text.length)];
        CGEventKeyboardSetUnicodeString(raw, text.length, chars);
        CGEventSetFlags(raw, (CGEventFlags)flags);
        NSEvent *event = [NSEvent eventWithCGEvent:raw];
        CFRelease(raw);
        [NSApp postEvent:event atStart:NO];
    }
}

static void Check(unsigned synthetic, unsigned keys, unsigned texts) {
    SDL_PumpEvents();
    SDL_Event event;
    unsigned s = 0, k = 0, t = 0;
    while (SDL_PeepEvents(&event, 1, SDL_GETEVENT, SDL_EVENT_FIRST, SDL_EVENT_LAST) == 1) {
        if (event.type == SC_EVENT_SYNTHETIC_TEXT) { ++s; free(event.user.data1); }
        if (event.type == SDL_EVENT_KEY_DOWN || event.type == SDL_EVENT_KEY_UP) ++k;
        if (event.type == SDL_EVENT_TEXT_INPUT) ++t;
    }
    fprintf(stderr, "SDL queue: synthetic=%u keys=%u text=%u\n", s, k, t);
    assert(s == synthetic && k == keys && t == texts);
}

int main(void) {
    @autoreleasepool {
        assert(SDL_Init(SDL_INIT_VIDEO));
        SDL_Window *window = SDL_CreateWindow("DroidMirror input regression test", 200, 100, 0);
        assert(window);
        SDL_SetWindowKeyboardGrab(window, false);
        SDL_RaiseWindow(window);
        assert(SDL_StartTextInput(window));
        SDL_PumpEvents();
        SDL_FlushEvents(SDL_EVENT_FIRST, SDL_EVENT_LAST);
        // Reproduce SDL's original physical A + committed emoji first.
        Post(@"😀", kVK_ANSI_A, 0);
        Check(0, 2, 1);
        DMInstallSyntheticTextRouting(^BOOL(__unused NSEvent *event) { return YES; });
        Post(@"😀", kVK_ANSI_A, 0);
        Check(1, 0, 0);
        Post(@"👩🏽‍💻", kVK_ANSI_A, 0);
        // A queue peek must not inject text or consume the down/up pair.
        assert([NSApp nextEventMatchingMask:NSEventMaskKeyDown untilDate:NSDate.distantPast
            inMode:NSDefaultRunLoopMode dequeue:NO]);
        Check(1, 0, 0);
        Post(@"😀", kVK_ANSI_A, 0);
        Post(@"😀", kVK_ANSI_A, 0);
        Check(2, 0, 0);
        Post(@"https://example.com/", kVK_ANSI_A, 0);
        Check(1, 0, 0);
        // Read the current clipboard for Command-V without touching its data.
        if ([NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]) {
            Post(@"v", kVK_ANSI_V, NSEventModifierFlagCommand);
            Check(1, 0, 0);
        }
        Post(@"a", kVK_ANSI_A, 0);
        Check(0, 2, 1);
        DMInstallSyntheticTextRouting(^BOOL(__unused NSEvent *event) { return NO; });
        Post(@"😀", kVK_ANSI_A, 0);
        Check(0, 2, 1);
        SDL_DestroyWindow(window);
        SDL_Quit();
        puts("PASS: real Cocoa→SDL queue, one emoji/URL paste, no stray A or duplicate text, normal A preserved");
    }
}
