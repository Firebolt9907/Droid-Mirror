// clang -fobjc-arc -fblocks -framework Foundation -framework AVFoundation -framework IOBluetooth \
//   -framework CoreBluetooth -framework Security Native/MirrorMinimizeBridgeTests.m \
//   Native/BleInputTransport.m Native/BleInputQueue.m Native/BleInputCrypto.c \
//   Native/ClassicBluetoothWire.c -o /tmp/droidmirror-minimize-bridge-tests
#define main DMBridgeProgramMain
#import "ClassicBluetoothBridge.m"
#undef main
#include <assert.h>

int main(void) {
    @autoreleasepool {
        __block NSUInteger requests = 0;
        NSString *owner = [NSString stringWithFormat:@"%d", getppid()];
        id observer = [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:@"app.droidmirror.minimizeMirror" object:owner queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *event) { assert([event.object isEqual:owner]); ++requests; }];
        DMClassicBridge *bridge = [DMClassicBridge new];
        [bridge receiveEvent:7];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        assert(requests == 1);
        [bridge receiveEvent:7];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        assert(requests == 2); // Repeated taps must not be deduplicated as lifecycle events.
        [bridge receiveEvent:6];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        assert(requests == 2); // Heartbeats cannot minimize the window.
        [[NSDistributedNotificationCenter defaultCenter] removeObserver:observer];
        puts("PASS: capture BLE minimize events target the owning host PID and preserve repeated taps");
    }
}
