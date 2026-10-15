// Experimental macOS SPI probe. Keep private selectors out of the main app.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

@protocol DMAwareCapabilities
+ (id)currentDeviceCapabilities;
- (BOOL)supportsDataTransfer;
- (NSInteger)maxDatapaths;
- (NSInteger)maxPublishers;
- (NSInteger)maxSubscribers;
@end
@protocol DMAwareConfiguration
- (id)initWithServiceName:(NSString *)name;
@end
@protocol DMAwareSubscriber
- (id)initWithConfiguration:(id)configuration;
- (void)setDelegate:(id)delegate;
- (void)start;
- (void)stop;
@end

static void emit(NSDictionary *result) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
    if (data) { fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout); }
}

@interface DMDiscoveryProbe : NSObject
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL started;
@property(nonatomic) NSInteger failure;
@end
@implementation DMDiscoveryProbe
- (void)subscriber:(id)sender failedToStartWithError:(NSInteger)error {
    @synchronized(self) { self.failure = error; self.finished = YES; }
}
- (void)subscriber:(id)sender startedWithInstanceID:(unsigned char)instanceID {
    @synchronized(self) { self.started = YES; self.finished = YES; }
}
- (void)subscriber:(id)sender terminatedWithReason:(NSInteger)reason {
    @synchronized(self) { self.failure = reason; self.finished = YES; }
}
@end

static BOOL hasInstanceMethod(Class cls, SEL selector) { return cls && class_getInstanceMethod(cls, selector) != NULL; }

int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc != 2 || (strcmp(argv[1], "--probe") && strcmp(argv[1], "--test-discovery"))) {
        fprintf(stderr, "Usage: DroidMirrorWiFiAware --probe | --test-discovery\n"); return 64;
    }
    // dlopen handles deliberately live until process exit: classes depend on their images.
    BOOL framework = dlopen("/System/Library/Frameworks/WiFiAware.framework/WiFiAware", RTLD_NOW | RTLD_LOCAL) != NULL;
    BOOL spi = dlopen("/System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/WiFiPeerToPeer", RTLD_NOW | RTLD_LOCAL) != NULL;
    Class capabilitiesClass = NSClassFromString(@"WiFiAwareDeviceCapabilities");
    id<DMAwareCapabilities> capabilities = nil;
    @try {
        if ([capabilitiesClass respondsToSelector:@selector(currentDeviceCapabilities)])
            capabilities = [(id<DMAwareCapabilities>)capabilitiesClass currentDeviceCapabilities];
        for (NSString *selector in @[@"supportsDataTransfer", @"maxDatapaths", @"maxPublishers", @"maxSubscribers"])
            if (capabilities && ![(id)capabilities respondsToSelector:NSSelectorFromString(selector)]) capabilities = nil;
        BOOL dataTransfer = capabilities && capabilities.supportsDataTransfer;
        NSMutableDictionary *result = [@{
            @"frameworkPresent": @(framework), @"privateFrameworkPresent": @(spi),
            @"capabilitiesAvailable": capabilities != nil ? @YES : @NO, @"supportsDataTransfer": @(dataTransfer),
            @"maxDatapaths": @(capabilities ? capabilities.maxDatapaths : 0),
            @"maxPublishers": @(capabilities ? capabilities.maxPublishers : 0),
            @"maxSubscribers": @(capabilities ? capabilities.maxSubscribers : 0),
            // Discovery capability alone never means the stream transport is implemented.
            @"streamImplemented": @NO,
            @"message": !spi ? @"Wi-Fi Aware private framework is unavailable on this Mac." :
                !capabilities ? @"Wi-Fi Aware is installed, but macOS returned no capabilities. Direct mirroring is unavailable." :
                !dataTransfer ? @"macOS reports no Wi-Fi Aware data-transfer support." :
                @"Wi-Fi Aware capabilities are accessible. Direct stream integration is still experimental and unavailable."
        } mutableCopy];
        if (!strcmp(argv[1], "--test-discovery")) {
            Class configClass = NSClassFromString(@"WiFiAwareSubscribeConfiguration");
            Class subscriberClass = NSClassFromString(@"WiFiAwareSubscriber");
            if (!hasInstanceMethod(configClass, @selector(initWithServiceName:)) ||
                !hasInstanceMethod(subscriberClass, @selector(initWithConfiguration:)) ||
                !hasInstanceMethod(subscriberClass, @selector(setDelegate:)) ||
                !hasInstanceMethod(subscriberClass, @selector(start)) ||
                !hasInstanceMethod(subscriberClass, @selector(stop))) {
                result[@"discoveryStatus"] = @"apiUnavailable";
            } else {
                id configuration = [(id<DMAwareConfiguration>)[configClass alloc] initWithServiceName:@"_droidmirror._tcp"];
                id<DMAwareSubscriber> subscriber = [(id<DMAwareSubscriber>)[subscriberClass alloc] initWithConfiguration:configuration];
                DMDiscoveryProbe *delegate = [DMDiscoveryProbe new];
                [subscriber setDelegate:delegate];
                [subscriber start];
                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
                BOOL done = NO, started = NO; NSInteger failure = 0;
                do {
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                    @synchronized(delegate) { done = delegate.finished; started = delegate.started; failure = delegate.failure; }
                } while (!done && deadline.timeIntervalSinceNow > 0);
                [subscriber stop];
                result[@"discoveryStatus"] = started ? @"started" : done ? @"rejected" : @"timeout";
                if (done && !started) result[@"discoveryError"] = @(failure);
            }
        }
        emit(result);
    } @catch (NSException *exception) {
        emit(@{@"error": @"Private Wi-Fi Aware API changed or raised an exception.", @"exception": exception.name});
        return 1;
    }
    return 0;
} }
