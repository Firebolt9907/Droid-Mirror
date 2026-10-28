#import "SyntheticText.h"
#include <SDL3/SDL_init.h>
#include <assert.h>

static NSEvent *Input(NSString *text, unsigned short key, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:flags timestamp:0 windowNumber:0 context:nil
        characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:key];
}

int main(void) {
    @autoreleasepool {
        assert(DMSyntheticTextEvent(Input(@"😀", kVK_ANSI_A, 0)));
        assert(DMSyntheticTextEvent(Input(@"https://example.com/path?q=hello", kVK_ANSI_A, 0)));
        assert(DMSyntheticTextEvent(Input(@"hello\nworld", kVK_ANSI_A, 0)));
        assert(!DMSyntheticTextEvent(Input(@"a", kVK_ANSI_A, NSEventModifierFlagCommand)));
        assert(!DMSyntheticTextEvent(Input(@"v", kVK_ANSI_V, NSEventModifierFlagCommand)));
        // A tool may synthesize only V down/up with Command in its flags,
        // without a modifier down event. Recognize the chord from those flags.
        assert(DMPasteShortcutEvent(Input(@"v", kVK_ANSI_V, NSEventModifierFlagCommand)));
        assert(!DMPasteShortcutEvent(Input(@"v", kVK_ANSI_V, 0)));
        assert(!DMPasteShortcutEvent(Input(@"v", kVK_ANSI_V, NSEventModifierFlagControl)));
        assert(!DMPasteShortcutEvent(Input(@"v", kVK_ANSI_V,
            NSEventModifierFlagCommand | NSEventModifierFlagShift)));
        assert(!DMPasteShortcutEvent(Input(@"c", kVK_ANSI_C, NSEventModifierFlagCommand)));
        assert(!DMSyntheticTextEvent(Input(@"", kVK_ANSI_A, 0)));
        // Use the actual current layout's A, including Shift and Caps Lock.
        TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
        CFDataRef layout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData);
        for (unsigned flags = 0; flags < 3; flags++) {
            UInt32 dead = 0; UniChar chars[16]; UniCharCount count = 0;
            UInt32 mod = flags == 1 ? shiftKey : flags == 2 ? alphaLock : 0;
            assert(UCKeyTranslate((const UCKeyboardLayout *)CFDataGetBytePtr(layout), kVK_ANSI_A,
                kUCKeyActionDown, mod >> 8, LMGetKbdType(), kUCKeyTranslateNoDeadKeysBit,
                &dead, 16, &count, chars) == noErr);
            assert(!DMSyntheticTextEvent(Input([NSString stringWithCharacters:chars length:count],
                kVK_ANSI_A, flags == 1 ? NSEventModifierFlagShift : flags == 2 ? NSEventModifierFlagCapsLock : 0)));
        }
        CFRelease(source);
        assert(SDL_Init(SDL_INIT_EVENTS));
        assert(DMQueueSyntheticText(@"😀 https://example.com/"));
        SDL_Event event;
        assert(SDL_PollEvent(&event));
        assert(event.type == SC_EVENT_SYNTHETIC_TEXT);
        assert(strcmp(event.user.data1, "😀 https://example.com/") == 0);
        free(event.user.data1);
        SDL_Quit();
        puts("PASS: synthetic emoji/URL text, native layout keys, modifiers, and SDL text delivery");
    }
}
