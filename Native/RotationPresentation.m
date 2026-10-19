#import <AppKit/AppKit.h>
#import <SDL3/SDL.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#import "DeviceCorners.h"

// The transparent native canvas remains fixed for the duration of a turn.
// SDL rotates live video; this mask rotates the phone outline and shadow with it.
void DroidMirrorRotationPresentation(SDL_Window *sdlWindow, const float *rect, double angle) {
    NSWindow *window = (__bridge NSWindow *)SDL_GetPointerProperty(
        SDL_GetWindowProperties(sdlWindow), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    if (!window) return;
    static char rotatingKey;
    BOOL wasRotating = [objc_getAssociatedObject(window, &rotatingKey) boolValue];
    BOOL rotating = rect != NULL;
    if (rotating != wasRotating) {
        objc_setAssociatedObject(window, &rotatingKey, @(rotating), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        window.opaque = NO;
        window.backgroundColor = NSColor.clearColor;
    }
    DMSetDeviceRotation(window.contentView, rect, angle);
    if (rotating != wasRotating) {
        void (*chrome)(SDL_Window *, bool) = dlsym(RTLD_DEFAULT, "DroidMirrorRotationChrome");
        if (chrome) chrome(sdlWindow, rotating);
    }
}
