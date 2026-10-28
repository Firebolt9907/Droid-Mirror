#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include "../scrcpy-5.0/app/src/droidmirror_text_event.h"

static BOOL DMPasteShortcutEvent(NSEvent *event) {
    NSEventModifierFlags modifiers = event.modifierFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagControl |
         NSEventModifierFlagOption | NSEventModifierFlagShift);
    return event.type == NSEventTypeKeyDown && event.keyCode == kVK_ANSI_V &&
        modifiers == NSEventModifierFlagCommand;
}

// Unicode event injection (used by snippet tools) carries text on a dummy
// virtual A key. SDL otherwise forwards that key to UHID and drops non-emoji
// text. Compare with the active layout so a real A key still works on non-US
// keyboards. Never reinterpret command chords as text.
static BOOL DMSyntheticTextEvent(NSEvent *event) {
    if (event.type != NSEventTypeKeyDown || event.keyCode != kVK_ANSI_A ||
        (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
                               NSEventModifierFlagOption)) || !event.characters.length) return NO;
    TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
    if (!source) return NO;
    CFDataRef data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData);
    UniChar chars[16];
    UniCharCount length = 0;
    UInt32 dead = 0;
    UInt32 modifiers = (event.modifierFlags & NSEventModifierFlagShift ? shiftKey : 0) |
                      (event.modifierFlags & NSEventModifierFlagCapsLock ? alphaLock : 0);
    OSStatus status = data ? UCKeyTranslate((const UCKeyboardLayout *)CFDataGetBytePtr(data),
        event.keyCode, kUCKeyActionDown, modifiers >> 8, LMGetKbdType(),
        kUCKeyTranslateNoDeadKeysBit, &dead, 16, &length, chars) : paramErr;
    CFRelease(source);
    if (status != noErr || !length) return NO;
    return ![event.characters isEqualToString:[NSString stringWithCharacters:chars length:length]];
}

static BOOL DMQueueSyntheticText(NSString *text) {
    char *copy = strdup(text.UTF8String);
    if (!copy) return NO;
    SDL_Event event = { .type = SC_EVENT_SYNTHETIC_TEXT };
    event.user.data1 = copy;
    if (SDL_PushEvent(&event)) return YES;
    free(copy);
    return NO;
}
