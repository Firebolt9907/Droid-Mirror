#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <assert.h>
#include <string.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "failed-client")) return 42;
        BOOL expectHost = argc == 2 && !strcmp(argv[1], "host");
        Method setter = class_getInstanceMethod(NSTask.class, @selector(setExecutableURL:));
        Dl_info origin = {0};
        assert(dladdr((const void *)method_getImplementation(setter), &origin));
        BOOL hooked = strstr(origin.dli_fname, "HostShim") != NULL;
        assert(hooked == expectHost);
        if (expectHost) {
            assert(getenv("DYLD_INSERT_LIBRARIES") == NULL);
            // Force inheritance of a cached/pre-cleanup environment anyway.
            NSTask *child = [NSTask new];
            child.executableURL = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Helpers/DroidMirrorBluetooth"];
            child.environment = @{@"DYLD_INSERT_LIBRARIES": @(origin.dli_fname)};
            [child launch]; [child waitUntilExit];
            assert(child.terminationStatus == 0);
            if (getenv("DROIDMIRROR_TEST_FAILED_CLIENT")) {
                [NSApplication sharedApplication];
                // Install the shim's termination observer on the main queue.
                [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                NSTask *client=[NSTask new];
                client.executableURL=[NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Helpers/scrcpy"];
                client.arguments=@[@"failed-client"];
                [client launch]; [client waitUntilExit];
                assert(client.terminationStatus==42);
                [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                puts("PASS: failed mirror leaves host alive for error display and retry");
            }
        }
        puts(expectHost ? "PASS: launcher activates host hooks and inherited helpers stay isolated" :
            "PASS: helper does not install host hooks even with inherited injection");
    }
    return 0;
}
