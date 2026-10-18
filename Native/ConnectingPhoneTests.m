#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <SDL3/SDL.h>
#import <assert.h>
#import "ConnectingPhone.h"
#import "DeviceCorners.h"
#import "PhoneAppearance.h"
#undef MIN
#undef MAX
#include "util/sdl.h"
#include "util/log.h"

// The SDL utility logs only on failure; keep this focused test independent of FFmpeg.
void sc_log(enum sc_log_level level, const char *format, ...) { abort(); }
extern void DroidMirrorShowConnecting(SDL_Window *window);

int main(void) {
    @autoreleasepool {
        assert(SDL_Init(SDL_INIT_VIDEO));
        NSString *cache = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        setenv("DROIDMIRROR_APPEARANCE_CACHE", cache.UTF8String, 1);
        setenv("DROIDMIRROR_DEVICE_NAME", "Test Phone", 1);
        NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:2
            bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        NSUInteger red[] = {255, 0, 0};
        for (NSInteger x=0; x<2; x++) for (NSInteger y=0; y<2; y++) [image setPixel:red atX:x y:y];
        NSData *png = [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        DMCachePhoneAppearance(@{@"wallpaper": [png base64EncodedStringWithOptions:0]});
        NSMenu *menu = [NSMenu new];
        NSMenuItem *application = [NSMenuItem new];
        application.submenu = [NSMenu new];
        NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"Settings…" action:NULL keyEquivalent:@""];
        settings.enabled = NO;
        [application.submenu addItem:settings];
        [menu addItem:application];
        NSApp.mainMenu = menu;
        DroidMirrorInstallSessionMenu();
        assert(settings.enabled && settings.target && settings.action == NSSelectorFromString(@"settings:"));
        assert([settings.keyEquivalent isEqualToString:@","]);
        NSMenuItem *setup = [application.submenu itemWithTag:0x444d5355];
        assert(setup && setup.enabled && setup.target && setup.action == NSSelectorFromString(@"setup:"));
        NSInteger count = application.submenu.numberOfItems;
        DroidMirrorInstallSessionMenu();
        assert(application.submenu.numberOfItems == count);

        SDL_Window *loading = sc_sdl_create_window("DroidMirror — Test", 100, 100, 360, 720,
            SDL_WINDOW_BORDERLESS | SDL_WINDOW_RESIZABLE);
        assert(loading);
        NSWindow *native = (__bridge NSWindow *)SDL_GetPointerProperty(
            SDL_GetWindowProperties(loading), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
        NSInteger number = native.windowNumber;
        DroidMirrorShowConnecting(loading);
        assert(!(native.styleMask & NSWindowStyleMaskTitled));
        assert(native.collectionBehavior & NSWindowCollectionBehaviorPrimary);
        assert(native.collectionBehavior & NSWindowCollectionBehaviorManaged);
        assert(!(native.collectionBehavior & (NSWindowCollectionBehaviorAuxiliary |
            NSWindowCollectionBehaviorCanJoinAllApplications | NSWindowCollectionBehaviorTransient |
            NSWindowCollectionBehaviorStationary)));
        assert(native.level == NSNormalWindowLevel);
        assert(![native standardWindowButton:NSWindowCloseButton] || [native standardWindowButton:NSWindowCloseButton].hidden);
        assert(native.contentView.subviews.count > 0);
        NSView *overlay = native.contentView.subviews.lastObject;
        assert([overlay.identifier isEqual:@"DroidMirrorConnecting"]);
        assert([overlay valueForKey:@"wallpaper"] != nil);
        NSStackView *stack = (NSStackView *)overlay.subviews.firstObject;
        assert([((NSTextField *)stack.arrangedSubviews[1]).stringValue isEqual:@"Connecting to Test Phone…"]);
        NSBitmapImageRep *render = [overlay bitmapImageRepForCachingDisplayInRect:overlay.bounds];
        [overlay cacheDisplayInRect:overlay.bounds toBitmapImageRep:render];
        NSColor *pixel = [[render colorAtX:10 y:100] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        assert(pixel.redComponent > .2 && pixel.redComponent < .6 && pixel.greenComponent < .1);
        [NSFileManager.defaultManager removeItemAtPath:cache error:nil];
        CAShapeLayer *mask = (CAShapeLayer *)native.contentView.layer.mask;
        CGPathRef loadingPath = CGPathCreateCopy(mask.path);
        assert(loadingPath);
        sc_sdl_keep_connecting_window(loading);
        SDL_Window *video = sc_sdl_create_window("DroidMirror — Test", 0, 0, 256, 256, SDL_WINDOW_HIDDEN);
        assert(video == loading);
        assert(native.windowNumber == number);
        DMFinishConnectingPhone();
        assert(CGPathEqualToPath(loadingPath, ((CAShapeLayer *)native.contentView.layer.mask).path));
        for (NSView *view in native.contentView.subviews)
            assert(![view.identifier isEqualToString:@"DroidMirrorConnecting"]);
        assert(native.windowNumber == number);
        CGPathRelease(loadingPath);
        SDL_DestroyWindow(video);
        SDL_Quit();
        puts("PASS: spinner and video share the same SDL/NSWindow, borderless chrome and exact corner path");
    }
}
