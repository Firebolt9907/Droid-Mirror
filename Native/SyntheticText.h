#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <objc/runtime.h>
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

static BOOL (^DMSyntheticInputTarget)(NSEvent *);
static BOOL DMSyntheticAActive, DMSyntheticVActive;
static NSEvent *(*DMOriginalNextInputEvent)(id, SEL, NSEventMask, NSDate *, NSString *, BOOL);

static BOOL DMConsumeSyntheticInput(NSEvent *event) {
    if (event.type == NSEventTypeKeyUp) {
        if (event.keyCode == kVK_ANSI_A && DMSyntheticAActive) {
            DMSyntheticAActive = NO;
            return YES;
        }
        if (event.keyCode == kVK_ANSI_V && DMSyntheticVActive) {
            DMSyntheticVActive = NO;
            return YES;
        }
    }
    if (!DMSyntheticInputTarget(event)) return NO;
    if (DMPasteShortcutEvent(event)) {
        NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
        // Preserve the existing route for non-text clipboards.
        if (!text) return NO;
        if (!event.isARepeat && !DMQueueSyntheticText(text))
            NSLog(@"DroidMirror: could not queue clipboard paste");
        DMSyntheticVActive = YES;
        return YES;
    }
    if (DMSyntheticTextEvent(event)) {
        if (!DMQueueSyntheticText(event.characters))
            NSLog(@"DroidMirror: could not queue synthetic text");
        DMSyntheticAActive = YES;
        return YES;
    }
    return NO;
}

// SDL Cocoa translates keys *before* NSApplication.sendEvent:. Intercept the
// dequeue instead, so consumed Unicode events generate neither a HID A nor a
// second SDL_TEXTINPUT. Peeking must leave both the queue and our state intact.
static NSEvent *DMNextInputEvent(id app, SEL selector, NSEventMask mask,
                               NSDate *until, NSString *mode, BOOL dequeue) {
    for (;;) {
        NSEvent *event = DMOriginalNextInputEvent(app, selector, mask, until, mode, dequeue);
        if (!event || !dequeue || !DMConsumeSyntheticInput(event)) return event;
        // We queued SDL input; do not block waiting for another native event.
        until = NSDate.distantPast;
    }
}

static void DMInstallSyntheticTextRouting(BOOL (^target)(NSEvent *)) {
    DMSyntheticInputTarget = [target copy];
    if (DMOriginalNextInputEvent) return;
    Method method = class_getInstanceMethod(NSApplication.class,
        @selector(nextEventMatchingMask:untilDate:inMode:dequeue:));
    DMOriginalNextInputEvent = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)DMNextInputEvent);
    NSLog(@"DroidMirror synthetic text routing v2: intercept before SDL translation");
}
