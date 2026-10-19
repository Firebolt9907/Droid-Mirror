#import "ScrcpyWindowStyle.m"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        assert(SDL_Init(SDL_INIT_VIDEO));
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
        NSString *phoneA = [directory stringByAppendingPathComponent:@"phone-a.json"];
        NSString *phoneB = [directory stringByAppendingPathComponent:@"phone-b.json"];
        setenv("DROIDMIRROR_APPEARANCE_CACHE",phoneA.UTF8String,1);
        SDL_Window *sdl = SDL_CreateWindow("Cutout cache test",400,800,SDL_WINDOW_HIDDEN);
        assert(sdl);
        NSWindow *window = (__bridge NSWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(sdl),SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,NULL);
        [window orderFront:nil];
        DMWindowController *controller = [DMWindowController new];
        controller.window=window; controller.screenView=window.contentView; controller.sdlWindow=sdl;
        [controller buildToolbar];
        objc_setAssociatedObject(window,DMControllerKey,controller,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DroidMirrorSetCameraCutoutPresence(sdl,false);
        assert(controller.cameraCutoutPresenceKnown && !controller.deviceHasCameraCutout);
        assert([DMReadPhoneAppearance()[@"hasCameraCutout"] isEqual:@"no"]);
        assert(controller.toolbarWindow.visible);
        float circle[] = {.5,.05,.025,.0125};
        DroidMirrorSetCameraCutouts(sdl,circle,1);
        assert(controller.deviceHasCameraCutout && !controller.toolbarWindow.visible);
        assert([DMReadPhoneAppearance()[@"hasCameraCutout"] isEqual:@"yes"]);
        NSData *cached = [NSData dataWithContentsOfFile:phoneA];

        // Missing geometry followed by a valid empty landscape response must not
        // expose the toolbar during or immediately after the turn.
        SDL_SetBooleanProperty(SDL_GetWindowProperties(sdl),SC_ROTATION_PRESENTATION_PROP,true);
        DroidMirrorRotationChrome(sdl,true);
        DroidMirrorSetCameraCutouts(sdl,NULL,0);
        DroidMirrorSetCameraCutoutPresence(sdl,false);
        assert(controller.cameraCutouts.count==0 && controller.deviceHasCameraCutout);
        SDL_SetBooleanProperty(SDL_GetWindowProperties(sdl),SC_ROTATION_PRESENTATION_PROP,false);
        DroidMirrorRotationChrome(sdl,false);
        DroidMirrorSessionChrome(window,YES);
        assert(!controller.toolbarWindow.visible && !controller.toolbarWindow.parentWindow);
        assert(![controller.toolbarContainer.layer animationForKey:DMToolbarRevealKey]);
        assert([cached isEqual:[NSData dataWithContentsOfFile:phoneA]]);

        // A fresh controller must hide chrome from the cache before metadata arrives.
        DMWindowController *reconnected = [DMWindowController new];
        reconnected.window=window; reconnected.screenView=window.contentView;
        [reconnected buildToolbar]; [reconnected showToolbar];
        assert(reconnected.cameraCutoutPresenceKnown && reconnected.deviceHasCameraCutout);
        assert(reconnected.cameraCutouts.count==0 && !reconnected.toolbarWindow.visible);

        // The other phone's confirmed absence is persisted independently.
        setenv("DROIDMIRROR_APPEARANCE_CACHE",phoneB.UTF8String,1);
        [reconnected setCameraCutoutPresence:NO];
        assert(reconnected.cameraCutoutPresenceKnown && !reconnected.deviceHasCameraCutout);
        assert(reconnected.toolbarWindow.visible);
        assert([DMReadPhoneAppearance()[@"hasCameraCutout"] isEqual:@"no"]);
        DMWindowController *absent = [DMWindowController new];
        absent.window=window; absent.screenView=window.contentView;
        [absent buildToolbar]; [absent showToolbar];
        assert(absent.cameraCutoutPresenceKnown && !absent.deviceHasCameraCutout && absent.toolbarWindow.visible);
        [absent hideToolbar];
        setenv("DROIDMIRROR_APPEARANCE_CACHE",phoneA.UTF8String,1);
        [reconnected showToolbar];
        assert(reconnected.deviceHasCameraCutout && !reconnected.toolbarWindow.visible);
        assert([cached isEqual:[NSData dataWithContentsOfFile:phoneA]]);
        [controller hideToolbar]; [reconnected hideToolbar];
        objc_setAssociatedObject(window,DMControllerKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        unsetenv("DROIDMIRROR_APPEARANCE_CACHE");
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
        SDL_DestroyWindow(sdl); SDL_Quit();
        puts("PASS: per-device cutout presence/absence cache, empty/stale geometry, rotation-end chrome suppression, reconnect and device isolation");
    }
}
