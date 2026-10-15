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

@interface DMClassicBridge : NSObject <IOBluetoothRFCOMMChannelDelegate, IOBluetoothDeviceAsyncCallbacks> {
    DMClassicWire _wire;
}
@property(nonatomic, strong) IOBluetoothDevice *device;
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *channel;
@property(nonatomic, strong) NSMutableData *pending;
@property(nonatomic, strong) dispatch_source_t acceptSource;
@property(nonatomic) int listener;
@property(nonatomic) int client;
@property(nonatomic) int controlListener;
@property(nonatomic) int controlClient;
@property(nonatomic) uint16_t controlPort;
@property(nonatomic, strong) NSMutableData *controlPending;
@property(nonatomic, strong) NSMutableData *outgoing;
@property(nonatomic, strong) NSData *writeBuffer;
@property(nonatomic) NSTimeInterval outgoingSince;
@property(nonatomic) NSTimeInterval controlSince;
@property(nonatomic) BOOL rfcommReady;
@property(nonatomic) NSTimeInterval lastHeartbeatSent;
@property(nonatomic) uint64_t videoReceived;
@property(nonatomic) uintptr_t writeID;
@property(nonatomic) NSTimeInterval pendingSince;
@property(nonatomic) NSTimeInterval lastData;
@property(nonatomic) BOOL failing;
@property(nonatomic) uint8_t eventMask;
@property(nonatomic, copy) NSString *connectionStage;
@property(nonatomic) BOOL discoveryComplete;
- (BOOL)receiveVideo:(const uint8_t *)data length:(size_t)length;
- (void)receiveEvent:(uint8_t)event;
- (BOOL)receiveControl:(const uint8_t *)data length:(size_t)length;
@end

static bool DMVideo(void *context, const uint8_t *bytes, size_t length) {
    return [(__bridge DMClassicBridge *)context receiveVideo:bytes length:length];
}
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
    if (!_rfcommReady || _writeBuffer || !_outgoing.length) return;
    NSUInteger n = MIN(_outgoing.length, _channel.getMTU);
    if (!n) [self fail:@"Bluetooth control MTU unavailable"];
    _writeBuffer = [_outgoing subdataWithRange:NSMakeRange(0, n)];
    [_outgoing replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0];
    ++_writeID;
    if ([_channel writeAsync:(void *)_writeBuffer.bytes length:(UInt16)n refcon:(void *)_writeID] != kIOReturnSuccess)
        [self fail:@"Bluetooth input transmission failed"];
}
- (void)rfcommChannelWriteComplete:(IOBluetoothRFCOMMChannel *)channel refcon:(void *)refcon status:(IOReturn)status {
    if (!_writeBuffer || (uintptr_t)refcon != _writeID) return;
    if (status != kIOReturnSuccess) [self fail:@"Bluetooth input transmission failed"];
    _writeBuffer = nil;
    _outgoingSince = _outgoing.length ? NSDate.timeIntervalSinceReferenceDate : 0;
    [self sendControl];
}
- (void)rfcommChannelWriteComplete:(IOBluetoothRFCOMMChannel *)channel refcon:(void *)refcon status:(IOReturn)status bytesWritten:(size_t)length {
    [self rfcommChannelWriteComplete:channel refcon:refcon status:status];
}
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
            if (!_outgoing.length && !_writeBuffer) _outgoingSince = NSDate.timeIntervalSinceReferenceDate;
            uint32_t length = htonl((uint32_t)n);
            uint8_t type = 0;
            [_outgoing appendBytes:&type length:1]; [_outgoing appendBytes:&length length:4];
            [_outgoing appendBytes:buffer length:n]; [self sendControl];
        }
    }
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (_client >= 0 && _controlClient >= 0 && now - _lastHeartbeatSent >= 0.1) {
        if (_outgoing.length > DMQueueLimit - 13) [self fail:@"Bluetooth heartbeat backlog exceeded"];
        const uint8_t heartbeat[] = {1, 0, 0, 0, 8};
        uint64_t received = CFSwapInt64HostToBig(_videoReceived);
        if (!_outgoing.length && !_writeBuffer) _outgoingSince = now;
        [_outgoing appendBytes:heartbeat length:sizeof(heartbeat)];
        [_outgoing appendBytes:&received length:sizeof(received)];
        _lastHeartbeatSent = now; [self sendControl];
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
- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)channel data:(void *)data length:(size_t)length {
    if (channel != _channel) return;
    _lastData = NSDate.timeIntervalSinceReferenceDate;
    if (!dm_classic_wire_feed_control(&_wire, data, length, DMVideo, DMEvent, DMControl, (__bridge void *)self))
        [self fail:@"Invalid Bluetooth stream or video backlog exceeded; update the Android companion and Mac app"];
}
- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)channel {
    [self fail:@"Bluetooth stream closed. Reconnect from your Mac."];
}
- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    if (_discoveryComplete) return;
    _discoveryComplete = YES;
    fprintf(stderr, "Bluetooth service discovery completed (0x%08x)\n", status);
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
    _connectionStage = @"opening the Android RFCOMM channel";
    fprintf(stderr, "Opening Bluetooth RFCOMM channel %u\n", channelID);
    if ([device openRFCOMMChannelAsync:&channel withChannelID:channelID delegate:self] != kIOReturnSuccess)
        [self fail:@"Could not connect to the paired Android phone"];
    _channel = channel;
}
- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)channel status:(IOReturn)status {
    if (status != kIOReturnSuccess) [self fail:@"Bluetooth RFCOMM connection failed"];
    _channel = channel;
    _connectionStage = @"waiting for Android video";
    struct sockaddr_in bound;
    socklen_t size = sizeof(bound);
    if (getsockname(_listener, (struct sockaddr *)&bound, &size)) [self fail:@"Could not read bridge port"];
    _rfcommReady = YES;
    printf("READY %u %u\n", ntohs(bound.sin_port), _controlPort);
    fflush(stdout);
}
- (void)start:(NSString *)address {
    _listener = -1; _client = -1; _controlListener = -1; _controlClient = -1;
    _controlPending = [NSMutableData data]; _outgoing = [NSMutableData data];
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
    _connectionStage = @"discovering the Android Bluetooth service";
    [NSTimer scheduledTimerWithTimeInterval:0.02 repeats:YES block:^(NSTimer *timer) {
        [self flush]; [self pollControl];
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
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
    fprintf(stderr, "Discovering DroidMirror service on %s\n", address.UTF8String);
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
        CFRunLoopRun();
    }
    return 0;
}
