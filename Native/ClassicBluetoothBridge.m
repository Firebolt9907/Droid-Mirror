#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import "ClassicBluetoothWire.h"
#import "BleInputTransport.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <Security/Security.h>

// Private Classic BR/EDR L2CAP PSM, shared with the Shizuku listener.
static const BluetoothL2CAPPSM DMServicePSM = 0x1001;
static const NSUInteger DMQueueLimit = 128 * 1024;

// macOS 26's legacy open wrapper can lose the pending CBL2CAPChannel.
// Optional runtime-checked selectors retain it in the actual completion callback.
@interface NSObject (DMClassicL2capCompatibility)
- (id)classicPeer;
- (void)setConnectL2CAPCallback:(void (^)(id, NSInteger))callback;
- (void)openL2CAPChannel:(uint16_t)psm;
@end
@interface IOBluetoothL2CAPChannel (DMClassicL2capCompatibility)
+ (instancetype)channelFromCBL2CAPChannel:(id)channel;
@end

@interface DMClassicBridge : NSObject <IOBluetoothL2CAPChannelDelegate, DMBleInputDelegate> {
    DMClassicWire _wire, _returnWire;
}
@property(nonatomic, strong) IOBluetoothDevice *device;
@property(nonatomic, strong) NSData *pairingKey;
@property(nonatomic) BOOL benchmark;
@property(nonatomic) uint16_t psm;
@property(nonatomic) uint64_t benchmarkBytes;
@property(nonatomic) NSTimeInterval benchmarkStarted;
@property(nonatomic) NSTimeInterval benchmarkLast;
@property(nonatomic, strong) IOBluetoothL2CAPChannel *channel;
@property(nonatomic, strong) NSMutableData *pending;
@property(nonatomic, strong) dispatch_source_t acceptSource;
@property(nonatomic) int listener;
@property(nonatomic) int client;
@property(nonatomic) int controlListener;
@property(nonatomic) int controlClient;
@property(nonatomic) uint16_t controlPort;
@property(nonatomic, strong) NSMutableData *controlPending;
@property(nonatomic, strong) NSMutableData *outgoing;
@property(nonatomic, strong) DMBleInputTransport *ble;
@property(nonatomic) BOOL announcedReady;
@property(nonatomic) NSTimeInterval outgoingSince;
@property(nonatomic) NSTimeInterval controlSince;
@property(nonatomic) BOOL l2capReady;
@property(nonatomic, strong) id rawChannel;
@property(nonatomic, strong) id classicPeer;
@property(nonatomic) NSTimeInterval lastHeartbeatSent;
@property(nonatomic) uint64_t videoReceived;
@property(nonatomic) NSTimeInterval pendingSince;
@property(nonatomic) NSTimeInterval lastData;
@property(nonatomic) BOOL failing;
@property(nonatomic) uint8_t eventMask;
@property(nonatomic, copy) NSString *connectionStage;
- (BOOL)receiveVideo:(const uint8_t *)data length:(size_t)length;
- (void)receiveEvent:(uint8_t)event;
- (BOOL)receiveControl:(const uint8_t *)data length:(size_t)length;
@end

static bool DMVideo(void *context, const uint8_t *bytes, size_t length) {
    return [(__bridge DMClassicBridge *)context receiveVideo:bytes length:length];
}
static bool DMReject(void *context, const uint8_t *bytes, size_t length) { return false; }
static bool DMControl(void *context, const uint8_t *bytes, size_t length) {
    return [(__bridge DMClassicBridge *)context receiveControl:bytes length:length];
}
static void DMEvent(void *context, uint8_t event) { [(__bridge DMClassicBridge *)context receiveEvent:event]; }

@implementation DMClassicBridge
- (void)remoteNameRequestComplete:(IOBluetoothDevice *)device status:(IOReturn)status {}
- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {}
- (void)fail:(NSString *)reason {
    if (_failing) return;
    _failing = YES;
    fprintf(stderr, "%s\n", reason.UTF8String);
    if (_client >= 0) close(_client);
    if (_listener >= 0) close(_listener);
    if (_controlClient >= 0) close(_controlClient);
    if (_controlListener >= 0) close(_controlListener);
    [_ble close];
    [_channel closeChannel];
    exit(1);
}
- (void)flush {
    while (_client >= 0 && _pending.length) {
        ssize_t written = send(_client, _pending.bytes, _pending.length, 0);
        if (written < 0 && errno == EINTR) continue;
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        if (written <= 0) [self fail:@"Video client disconnected"];
        [_pending replaceBytesInRange:NSMakeRange(0, (NSUInteger)written) withBytes:NULL length:0];
    }
    if (!_pending.length) _pendingSince = 0;
}
- (void)flushControl {
    while (_controlClient >= 0 && _controlPending.length) {
        ssize_t n = send(_controlClient, _controlPending.bytes, _controlPending.length, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        if (n <= 0) [self fail:@"Control client disconnected"];
        [_controlPending replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0];
    }
    if (!_controlPending.length) _controlSince = 0;
}
- (BOOL)receiveControl:(const uint8_t *)data length:(size_t)length {
    if (length > DMQueueLimit - _controlPending.length) return NO;
    if (!_controlPending.length) _controlSince = NSDate.timeIntervalSinceReferenceDate;
    [_controlPending appendBytes:data length:length]; [self flushControl]; return YES;
}
- (void)sendControl {
    if (!_ble.ready || !_outgoing.length) return;
    if (![_ble send:_outgoing]) [self fail:@"BLE input backlog exceeded"];
    [_outgoing setLength:0]; _outgoingSince=0;
}
- (BOOL)bleInputReceived:(NSData *)bytes {
    _lastData=NSDate.timeIntervalSinceReferenceDate;
    return dm_classic_wire_feed_ble(&_returnWire,bytes.bytes,bytes.length,DMReject,DMEvent,DMControl,NULL,(__bridge void *)self);
}
- (void)announceReady {
    if (_announcedReady || !_l2capReady || !_ble.ready) return;
    struct sockaddr_in bound; socklen_t size=sizeof(bound);
    if (getsockname(_listener,(struct sockaddr *)&bound,&size)) [self fail:@"Could not read bridge port"];
    _announcedReady=YES;
    printf("READY %u %u\n",ntohs(bound.sin_port),_controlPort); fflush(stdout);
    fprintf(stderr,"BLE side channel authenticated; Classic L2CAP carries video only (phone to Mac)\n");
}
- (void)bleInputReady { [self announceReady]; [self sendControl]; }
- (void)bleInputFailed:(NSString *)reason { [self fail:reason]; }
- (void)pollControl {
    if (_controlListener >= 0 && _controlClient < 0) {
        int peer = accept(_controlListener, NULL, NULL);
        if (peer >= 0) {
            _controlClient = peer; close(_controlListener); _controlListener = -1;
            fcntl(peer, F_SETFL, O_NONBLOCK);
            int yes = 1; setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
            uint8_t dummy = 0; [self receiveControl:&dummy length:1];
        }
    }
    if (_controlClient >= 0) {
        uint8_t buffer[4096];
        ssize_t n = recv(_controlClient, buffer, sizeof(buffer), 0);
        if (!n) [self fail:@"Control client closed"];
        if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) [self fail:@"Control client failed"];
        if (n > 0) {
            if ((NSUInteger)n + 5 > DMQueueLimit - _outgoing.length) [self fail:@"Bluetooth input backlog exceeded"];
            if (!_outgoing.length) _outgoingSince = NSDate.timeIntervalSinceReferenceDate;
            uint32_t length = htonl((uint32_t)n);
            uint8_t type = 0;
            [_outgoing appendBytes:&type length:1]; [_outgoing appendBytes:&length length:4];
            [_outgoing appendBytes:buffer length:n]; [self sendControl];
        }
    }
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (_l2capReady && _ble.ready && now - _lastHeartbeatSent >= 0.25) {
        if (![_ble acknowledgeVideo:_videoReceived]) [self fail:@"BLE video acknowledgement failed"];
        _lastHeartbeatSent=now;
    }
    [self flushControl];
}
- (BOOL)receiveVideo:(const uint8_t *)data length:(size_t)length {
    if (length > DMQueueLimit - _pending.length) return NO;
    if (!_pending.length) _pendingSince = NSDate.timeIntervalSinceReferenceDate;
    [_pending appendBytes:data length:length]; [self flush]; _videoReceived += length; return YES;
}
- (void)receiveEvent:(uint8_t)event {
    if (event == 6) return; // Peer heartbeat keeps lastData fresh without log growth.
    uint8_t mask = (uint8_t)(1u << (event - 1));
    if (_eventMask & mask) return;
    _eventMask |= mask;
    const char *names[] = {"PHONE_ON", "SESSION_ENDED", "PHONE_LOCAL_USE", "STREAM_STARTED", "CAPTURE_FAILED"};
    printf("EVENT %s\n", names[event - 1]); fflush(stdout);
}
- (void)l2capChannelData:(IOBluetoothL2CAPChannel *)channel data:(void *)data length:(size_t)length {
    if (channel != _channel) return;
    _lastData = NSDate.timeIntervalSinceReferenceDate;
    if (_benchmark) {
        if (!_benchmarkStarted) _benchmarkStarted=_lastData;
        const uint8_t *bytes=data;
        for (size_t i=0;i<length;++i) if (bytes[i] != (uint8_t)(_benchmarkBytes+i)) [self fail:@"Benchmark byte loss or corruption"];
        _benchmarkBytes+=length; _benchmarkLast=_lastData; return;
    }
    if (!dm_classic_wire_feed_ble(&_wire, data, length, DMVideo, DMEvent, NULL, NULL, (__bridge void *)self))
        [self fail:@"Invalid Bluetooth stream or video backlog exceeded; update the Android companion and Mac app"];
}
- (void)l2capChannelClosed:(IOBluetoothL2CAPChannel *)channel {
    if (_benchmark && _benchmarkBytes) {
        double elapsed=_benchmarkLast-_benchmarkStarted;
        printf("BENCH RECEIVED bytes=%llu duration=%.3f mbps=%.3f integrity=passed\n",(unsigned long long)_benchmarkBytes,elapsed,_benchmarkBytes*8.0/MAX(elapsed,0.001)/1000000.0);
        fflush(stdout); exit(0);
    }
    [self fail:@"Bluetooth stream closed. Reconnect from your Mac."];
}
- (void)finishBenchmark {
    double elapsed=_benchmarkLast-_benchmarkStarted;
    printf("BENCH RECEIVED bytes=%llu duration=%.3f mbps=%.3f integrity=passed\n",(unsigned long long)_benchmarkBytes,elapsed,_benchmarkBytes*8.0/MAX(elapsed,0.001)/1000000.0);
    fflush(stdout); exit(0);
}
- (void)l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)channel status:(IOReturn)status {
    if (_l2capReady) return;
    if (status != kIOReturnSuccess) [self fail:@"Bluetooth Classic L2CAP connection failed"];
    _channel = channel;
    _connectionStage = @"waiting for Android video";
    _l2capReady = YES;
    if (_benchmark) { _lastData=NSDate.timeIntervalSinceReferenceDate; _connectionStage=@"receiving benchmark data"; return; }
    _ble=[[DMBleInputTransport alloc] initWithPairingKey:_pairingKey]; _ble.delegate=self;
    _connectionStage=@"authenticating the paired BLE side channel";
    _lastData=NSDate.timeIntervalSinceReferenceDate;
    [self announceReady];
}
- (void)start:(NSString *)address {
    _listener = -1; _client = -1; _controlListener = -1; _controlClient = -1;
    _controlPending = [NSMutableData data]; _outgoing = [NSMutableData data];
    _pending = [NSMutableData data];
    dm_classic_wire_init_video_only(&_wire);
    dm_classic_wire_init(&_returnWire);
    const uint8_t returnMagic[]="DMBT0005";
    dm_classic_wire_feed_ble(&_returnWire,returnMagic,8,DMReject,DMEvent,DMControl,NULL,(__bridge void *)self);
    _device = [IOBluetoothDevice deviceWithAddressString:address];
    if (!_device || !_device.isPaired) [self fail:@"Pair the phone in macOS Bluetooth settings first"];
    _listener = socket(AF_INET, SOCK_STREAM, 0);
    if (_listener < 0) [self fail:@"Could not create local bridge socket"];
    fcntl(_listener, F_SETFL, O_NONBLOCK);
    struct sockaddr_in local = {0};
    local.sin_family = AF_INET; local.sin_len = sizeof(local);
    local.sin_addr.s_addr = htonl(INADDR_LOOPBACK); local.sin_port = 0;
    if (bind(_listener, (struct sockaddr *)&local, sizeof(local)) || listen(_listener, 1))
        [self fail:@"Could not listen on loopback"];
    _controlListener = socket(AF_INET, SOCK_STREAM, 0);
    if (_controlListener < 0) [self fail:@"Could not create control bridge socket"];
    fcntl(_controlListener, F_SETFL, O_NONBLOCK);
    if (bind(_controlListener, (struct sockaddr *)&local, sizeof(local)) || listen(_controlListener, 1))
        [self fail:@"Could not listen for input on loopback"];
    socklen_t controlSize = sizeof(local);
    if (getsockname(_controlListener, (struct sockaddr *)&local, &controlSize)) [self fail:@"Could not read control port"];
    _controlPort = ntohs(local.sin_port);
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _listener, 0, dispatch_get_main_queue());
    int listenerFD = _listener;
    dispatch_source_set_cancel_handler(_acceptSource, ^{ close(listenerFD); });
    dispatch_source_set_event_handler(_acceptSource, ^{
        int peer = accept(self.listener, NULL, NULL);
        if (peer < 0) return;
        if (self.client >= 0) { close(peer); return; }
        self.client = peer;
        fcntl(peer, F_SETFL, O_NONBLOCK);
        int enabled = 1;
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
        self.listener = -1;
        dispatch_source_cancel(self.acceptSource);
        [self flush];
    });
    dispatch_resume(_acceptSource);
    _lastData = NSDate.timeIntervalSinceReferenceDate;

    [NSTimer scheduledTimerWithTimeInterval:0.02 repeats:YES block:^(NSTimer *timer) {
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        // The macOS compatibility wrapper can omit its remote-close callback.
        // A quiet period ends the bounded diagnostic; the script also requires
        // exact agreement with the sender's total before accepting the sample.
        if (self.benchmark && self.benchmarkBytes && now-self.benchmarkLast > 2.0) [self finishBenchmark];
        [self flush]; [self pollControl];
        if (self.outgoingSince && now - self.outgoingSince > 1.0) [self fail:@"Bluetooth input stalled"];
        if (self.controlSince && now - self.controlSince > 1.0) [self fail:@"Control response stalled"];
        if (self.pendingSince && now - self.pendingSince > 1.0) [self fail:@"Video bridge stalled for one second; reconnect"];
        if (now - self.lastData > 15.0) [self fail:[NSString stringWithFormat:@"Bluetooth timed out while %@", self.connectionStage]];
        if (self.client >= 0) {
            char byte;
            ssize_t count = recv(self.client, &byte, 1, MSG_PEEK);
            if (!count || count > 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR))
                [self fail:@"Video client closed"];
        }
    }];
    _connectionStage = @"initializing the Mac Bluetooth framework";
    // New macOS IOBluetooth shims initialize their Classic manager asynchronously.
    // Opening in start(), before the run loop runs, reports powered-off API misuse.
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:NO block:^(NSTimer *timer) {
        self.connectionStage = @"opening the Android Classic L2CAP channel";
        fprintf(stderr, "Opening Classic L2CAP PSM 0x%04x\n", self.psm);
        if ([self.device respondsToSelector:@selector(classicPeer)]
                && [IOBluetoothL2CAPChannel respondsToSelector:@selector(channelFromCBL2CAPChannel:)]) {
            id peer = [self.device classicPeer];
            if ([peer respondsToSelector:@selector(setConnectL2CAPCallback:)]
                    && [peer respondsToSelector:@selector(openL2CAPChannel:)]) {
                self.classicPeer = peer;
                [peer setConnectL2CAPCallback:^(id rawChannel, NSInteger error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (error || !rawChannel) [self fail:@"Classic L2CAP connection failed in the macOS Bluetooth framework"];
                        self.rawChannel = rawChannel;
                        self.channel = [IOBluetoothL2CAPChannel channelFromCBL2CAPChannel:rawChannel];
                        if (!self.channel || [self.channel setDelegate:self] != kIOReturnSuccess)
                            [self fail:@"Could not attach the Classic L2CAP stream"];
                        [self l2capChannelOpenComplete:self.channel status:kIOReturnSuccess];
                    });
                }];
                [peer openL2CAPChannel:self.psm];
                return;
            }
        }
        IOBluetoothL2CAPChannel *channel = nil;
        IOReturn result = [self.device openL2CAPChannelAsync:&channel withPSM:self.psm delegate:self];
        if (result != kIOReturnSuccess || !channel) {
            fprintf(stderr, "Classic L2CAP open failed (0x%08x)\n", result);
            [self fail:@"Could not open Classic L2CAP. Enable Mac connections and authorize Shizuku on Android."];
        }
        self.channel = channel;
    }];
}
@end

static NSDictionary *DMPairingQuery(NSString *address) {
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService:@"app.droidmirror.classic.ble.v2",
             (__bridge id)kSecAttrAccount:[[address stringByReplacingOccurrencesOfString:@"-" withString:@":"] lowercaseString]};
}
static NSData *DMLoadPairing(NSString *address) {
    NSMutableDictionary *query=[DMPairingQuery(address) mutableCopy];
    query[(__bridge id)kSecReturnData]=@YES;
    CFTypeRef result=NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query,&result)!=errSecSuccess) return nil;
    NSData *key=CFBridgingRelease(result); return key.length==32 ? key : nil;
}
static int DMSavePairing(NSString *address) {
    uint8_t bytes[32];
    if (fread(bytes,1,sizeof(bytes),stdin)!=sizeof(bytes)) return 2;
    NSData *key=[NSData dataWithBytes:bytes length:sizeof(bytes)]; memset(bytes,0,sizeof(bytes));
    NSDictionary *query=DMPairingQuery(address);
    NSDictionary *value=@{(__bridge id)kSecValueData:key};
    OSStatus status=SecItemUpdate((__bridge CFDictionaryRef)query,(__bridge CFDictionaryRef)value);
    if (status==errSecItemNotFound) {
        NSMutableDictionary *item=[query mutableCopy]; [item addEntriesFromDictionary:value];
        item[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status=SecItemAdd((__bridge CFDictionaryRef)item,NULL);
    }
    if (status!=errSecSuccess) { fprintf(stderr,"Could not save BLE pairing code in Keychain (%d)\n",(int)status); return 1; }
    return 0;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--list")) {
            NSMutableArray *devices = [NSMutableArray array];
            for (IOBluetoothDevice *device in [IOBluetoothDevice pairedDevices]) {
                [devices addObject:@{@"address": device.addressString ?: @"", @"name": device.name ?: @"Bluetooth device"}];
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:devices options:0 error:NULL];
            fwrite(json.bytes, 1, json.length, stdout);
            return 0;
        }
        if (argc==3 && !strcmp(argv[1],"--benchmark")) {
            DMClassicBridge *bridge=[DMClassicBridge new]; bridge.benchmark=YES; bridge.psm=0x1003;
            [bridge start:[NSString stringWithUTF8String:argv[2]]]; CFRunLoopRun(); return 0;
        }
        if (argc==3 && !strcmp(argv[1],"--pair")) return DMSavePairing([NSString stringWithUTF8String:argv[2]]);
        if (argc != 2) { fprintf(stderr, "Usage: DroidMirrorBluetooth ADDRESS | --list\n"); return 2; }
        NSData *pairing=DMLoadPairing([NSString stringWithUTF8String:argv[1]]);
        if (!pairing) { fprintf(stderr,"Pair BLE once in DroidMirror Settings using the code from the Android companion.\n"); return 2; }
        DMClassicBridge *bridge = [DMClassicBridge new]; bridge.pairingKey=pairing; bridge.psm=DMServicePSM;
        [bridge start:[NSString stringWithUTF8String:argv[1]]];
        CFRunLoopRun();
    }
    return 0;
}
