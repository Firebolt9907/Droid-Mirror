#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import "ClassicBluetoothWire.h"

// The UUID is shared with BluetoothCompanion. This is RFCOMM, not CoreBluetooth.
static NSString *const DMServiceUUID = @"c356a44e-6f2b-4da9-85e5-397991b8a603";
static const NSUInteger DMQueueLimit = 128 * 1024;

@interface DMClassicBridge : NSObject <IOBluetoothRFCOMMChannelDelegate> {
    DMClassicWire _wire;
}
@property(nonatomic, strong) IOBluetoothDevice *device;
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *channel;
@property(nonatomic, strong) NSMutableData *pending;
@property(nonatomic, strong) dispatch_source_t acceptSource;
@property(nonatomic) int listener;
@property(nonatomic) int client;
@property(nonatomic) NSTimeInterval pendingSince;
@property(nonatomic) NSTimeInterval lastData;
@property(nonatomic) BOOL failing;
@property(nonatomic) uint8_t eventMask;
- (BOOL)receiveVideo:(const uint8_t *)data length:(size_t)length;
- (void)receiveEvent:(uint8_t)event;
@end

static bool DMVideo(void *context, const uint8_t *bytes, size_t length) {
    return [(__bridge DMClassicBridge *)context receiveVideo:bytes length:length];
}
static void DMEvent(void *context, uint8_t event) { [(__bridge DMClassicBridge *)context receiveEvent:event]; }

@implementation DMClassicBridge
- (void)fail:(NSString *)reason {
    if (_failing) return;
    _failing = YES;
    fprintf(stderr, "%s\n", reason.UTF8String);
    if (_client >= 0) close(_client);
    if (_listener >= 0) close(_listener);
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
- (BOOL)receiveVideo:(const uint8_t *)data length:(size_t)length {
    if (length > DMQueueLimit - _pending.length) return NO;
    if (!_pending.length) _pendingSince = NSDate.timeIntervalSinceReferenceDate;
    [_pending appendBytes:data length:length]; [self flush]; return YES;
}
- (void)receiveEvent:(uint8_t)event {
    uint8_t mask = (uint8_t)(1u << (event - 1));
    if (_eventMask & mask) return;
    _eventMask |= mask;
    const char *names[] = {"PHONE_ON", "SESSION_ENDED", "PHONE_LOCAL_USE", "STREAM_STARTED", "CAPTURE_FAILED"};
    printf("EVENT %s\n", names[event - 1]); fflush(stdout);
}
- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)channel data:(void *)data length:(size_t)length {
    if (channel != _channel) return;
    _lastData = NSDate.timeIntervalSinceReferenceDate;
    if (!dm_classic_wire_feed(&_wire, data, length, DMVideo, DMEvent, (__bridge void *)self))
        [self fail:@"Invalid Bluetooth stream or video backlog exceeded; update the Android companion and Mac app"];
}
- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)channel {
    [self fail:@"Bluetooth stream closed. Reconnect from your Mac."];
}
- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    if (status != kIOReturnSuccess) [self fail:@"Bluetooth service discovery failed"];
    uuid_t bytes;
    NSUUID *identifier = [[NSUUID alloc] initWithUUIDString:DMServiceUUID];
    [identifier getUUIDBytes:bytes];
    IOBluetoothSDPUUID *uuid = [IOBluetoothSDPUUID uuidWithBytes:bytes length:sizeof(bytes)];
    IOBluetoothSDPServiceRecord *record = [device getServiceRecordForUUID:uuid];
    BluetoothRFCOMMChannelID channelID = 0;
    if (!record || [record getRFCOMMChannelID:&channelID] != kIOReturnSuccess)
        [self fail:@"DroidMirror capture service not found. Enable Mac connections in Android setup first."];
    IOBluetoothRFCOMMChannel *channel = nil;
    if ([device openRFCOMMChannelAsync:&channel withChannelID:channelID delegate:self] != kIOReturnSuccess)
        [self fail:@"Could not connect to the paired Android phone"];
    _channel = channel;
}
- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)channel status:(IOReturn)status {
    if (status != kIOReturnSuccess) [self fail:@"Bluetooth RFCOMM connection failed"];
    _channel = channel;
    struct sockaddr_in bound;
    socklen_t size = sizeof(bound);
    if (getsockname(_listener, (struct sockaddr *)&bound, &size)) [self fail:@"Could not read bridge port"];
    printf("READY %u\n", ntohs(bound.sin_port));
    fflush(stdout);
}
- (void)start:(NSString *)address {
    _listener = -1; _client = -1;
    _pending = [NSMutableData data];
    dm_classic_wire_init(&_wire);
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
        [self flush];
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        if (self.pendingSince && now - self.pendingSince > 1.0) [self fail:@"Video bridge stalled for one second; reconnect"];
        if (now - self.lastData > 20.0) [self fail:@"Bluetooth capture timed out"];
        if (self.client >= 0) {
            char byte;
            ssize_t count = recv(self.client, &byte, 1, MSG_PEEK);
            if (!count || count > 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR))
                [self fail:@"Video client closed"];
        }
    }];
    if ([_device performSDPQuery:self] != kIOReturnSuccess) [self fail:@"Could not start Bluetooth service discovery"];
}
@end

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
        if (argc != 2) { fprintf(stderr, "Usage: DroidMirrorBluetooth ADDRESS | --list\n"); return 2; }
        DMClassicBridge *bridge = [DMClassicBridge new];
        [bridge start:[NSString stringWithUTF8String:argv[1]]];
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
