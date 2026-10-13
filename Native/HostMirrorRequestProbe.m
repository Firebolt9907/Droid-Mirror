#import <AppKit/AppKit.h>
#import <dlfcn.h>

// Verification-only injection into the retained host: no phone or key required.
__attribute__((constructor)) static void Probe(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        void (*request)(void) = dlsym(RTLD_DEFAULT, "DroidMirrorRequestMirror");
        if (!request) { NSLog(@"FAIL: mirror request export missing"); exit(2); }
        request();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSLog(@"PASS: host Swift mirror request returned without ABI failure");
            [NSApp terminate:nil];
        });
    });
}
