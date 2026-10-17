#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <unistd.h>
#import <errno.h>
#import <signal.h>
#import <string.h>
#import "ClassicBluetoothWire.h"
#import "BleInputTransport.h"
#import "BleInputCrypto.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonHMAC.h>
#import <dlfcn.h>

typedef void *(*DMPeerStart)(const uint8_t *, uint16_t *);
typedef void (*DMPeerStop)(void *);

// Private Classic BR/EDR L2CAP PSM, shared with the Shizuku listener.
// Avoid 0x1001: Android system Bluetooth can already allocate that PSM.
static const BluetoothL2CAPPSM DMServicePSM = 0xD001;
static const NSUInteger DMQueueLimit = 128 * 1024;

// macOS 26's legacy open wrapper can lose the pending CBL2CAPChannel.
// Retain the channel from the completion callback and use its native streams.
@interface NSObject (DMClassicL2capCompatibility)
- (id)classicPeer;
- (void)setConnectL2CAPCallback:(void (^)(id, NSInteger))callback;
- (void)openL2CAPChannel:(uint16_t)psm;
@end

// Blocking handshake runs on a worker; the video/control run loop never waits for ADB.
static BOOL DMReadExact(int fd, void *data, size_t length) {
    uint8_t *bytes=data;
    while (length) {
        ssize_t count=recv(fd,bytes,length,0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        bytes+=count; length-=count;
    }
    return YES;
}
static NSData *DMUpgradeProof(NSData *key, const char *direction, const uint8_t *nonce, const void *offset, size_t length) {
    CCHmacContext context;
    CCHmacInit(&context,kCCHmacAlgSHA256,key.bytes,key.length);
    NSString *label=[NSString stringWithFormat:@"DroidMirror Wi-Fi %s v1",direction];
    CCHmacUpdate(&context,label.UTF8String,strlen(label.UTF8String));
    CCHmacUpdate(&context,nonce,32);
    if (length) CCHmacUpdate(&context,offset,length);
    uint8_t proof[32]; CCHmacFinal(&context,proof);
    return [NSData dataWithBytes:proof length:32];
}

@interface DMClassicBridge : NSObject <IOBluetoothL2CAPChannelDelegate, DMBleInputDelegate, NSStreamDelegate> {
    DMClassicWire _wire, _returnWire, _wifiWire;
}
@property(nonatomic) int wifiSocket;
@property(nonatomic) BOOL probingWiFi;
@property(nonatomic) void *peerLibrary;
@property(nonatomic) void *peerHandle;
@property(nonatomic) uint16_t peerPort;
@property(nonatomic) DMPeerStop peerStop;
@property(nonatomic) BOOL reportedMissingPeer;
@property(nonatomic) NSUInteger videoProbeAttempts;
@property(nonatomic) BOOL wifiActive;
@property(nonatomic) BOOL wifiRecovering;
@property(nonatomic) NSTimeInterval wifiLastData;
@property(nonatomic) NSTimeInterval wifiRecoveryRequested;
@property(nonatomic) uint64_t wifiCutoff;
@property(nonatomic) NSTimeInterval wifiPendingSince;
@property(nonatomic, strong) NSData *wirelessProfile;
@property(nonatomic, strong) NSData *wifiNonce;
@property(nonatomic, strong) NSMutableData *commands;
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
@property(nonatomic) BOOL openingL2cap;
@property(nonatomic, strong) dispatch_source_t terminationSource;
@property(nonatomic, strong) id rawChannel;
@property(nonatomic, strong) NSInputStream *classicInput;
@property(nonatomic, strong) NSOutputStream *classicOutput;
@property(nonatomic, strong) id classicPeer;
@property(nonatomic) NSTimeInterval lastHeartbeatSent;
@property(nonatomic) uint64_t videoReceived;
@property(nonatomic) uint64_t lastVideoAcknowledged;
@property(nonatomic) NSTimeInterval pendingSince;
@property(nonatomic) NSTimeInterval lastData;
@property(nonatomic) BOOL failing;
@property(nonatomic) uint8_t eventMask;
@property(nonatomic, copy) NSString *connectionStage;
- (void)startBleWhenAndroidReady;
- (void)shutdownForTermination;
- (void)connectClassicBaseband;
- (void)openClassicChannel;
- (void)attachClassicStreams:(id)rawChannel;
- (void)closeClassicStreams;
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
- (void)probePeer {
    if (_failing || _benchmark || _wifiActive || _wifiRecovering || _probingWiFi || _wifiSocket >= 0) return;
    if (!_peerHandle) {
        NSString *executable=NSProcessInfo.processInfo.arguments.firstObject;
        NSString *library=[[[executable stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"Frameworks/libdroidmirror_peer.dylib"];
        if (!_peerLibrary) _peerLibrary=dlopen(library.fileSystemRepresentation, RTLD_NOW|RTLD_LOCAL);
        DMPeerStart start=_peerLibrary ? (DMPeerStart)dlsym(_peerLibrary,"dm_peer_start") : NULL;
        _peerStop=_peerLibrary ? (DMPeerStop)dlsym(_peerLibrary,"dm_peer_stop") : NULL;
        if (!start || !_peerStop) {
            if (!_reportedMissingPeer) fprintf(stderr,"Iroh video transport missing; rebuild matching Mac and Android apps\n");
            _reportedMissingPeer=YES;
            printf("EVENT LAN_UNAVAILABLE\n"); fflush(stdout);
            return;
        }
        uint16_t port=0;
        _peerHandle=start(_pairingKey.bytes,&port); _peerPort=port;
        if (!_peerHandle || !_peerPort) { printf("EVENT LAN_UNAVAILABLE\n"); fflush(stdout); return; }
    }
    [self probeWiFi:_peerPort];
}
- (void)stopPeer {
    if (_peerHandle && _peerStop) _peerStop(_peerHandle);
    _peerHandle=NULL; _peerPort=0;
    // Rust threads are stopped before the dylib may be unloaded at process exit.
}
- (void)probeWiFi:(uint16_t)port {
    if (_probingWiFi || _wifiSocket >= 0 || _wifiRecovering || _benchmark) return;
    _probingWiFi=YES;
    if (_videoProbeAttempts++ < 3) fprintf(stderr,"Trying %s video\n",port == _peerPort ? "direct LAN" : "wireless ADB");
    NSData *key=_pairingKey;
    NSData *profile=_wirelessProfile;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        int fd=socket(AF_INET,SOCK_STREAM,0);
        BOOL valid=NO; uint64_t cutoff=0; NSData *nonce=nil;
        if (fd >= 0) {
            // Iroh may need DNS discovery, relay registration and NAT traversal
            // before the application challenge can arrive. This worker must not
            // abandon its local socket while the native dial is still pending.
            struct timeval timeout={port == self.peerPort ? 20 : 2,0}; int yes=1;
            setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
            setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
            setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
            struct sockaddr_in address={0}; address.sin_family=AF_INET;
            address.sin_addr.s_addr=htonl(INADDR_LOOPBACK); address.sin_port=htons(port);
            uint8_t hello[40], response[48];
            if (!connect(fd,(struct sockaddr *)&address,sizeof(address)) && DMReadExact(fd,hello,sizeof(hello)) && !memcmp(hello,"DMWIFI03",8)) {
                nonce=[NSData dataWithBytes:hello+8 length:32];
                NSData *proof=DMUpgradeProof(key,"client",hello+8,profile.bytes,profile.length);
                NSMutableData *request=[profile mutableCopy]; [request appendData:proof];
                size_t sent=0;
                while (sent < request.length) {
                    ssize_t n=send(fd,(const uint8_t *)request.bytes+sent,request.length-sent,0);
                    if (n < 0 && errno == EINTR) continue;
                    if (n <= 0) break;
                    sent+=n;
                }
                if (sent == request.length && DMReadExact(fd,response,sizeof(response))) {
                    NSMutableData *authenticated=[profile mutableCopy]; [authenticated appendBytes:response length:8];
                    NSData *expected=DMUpgradeProof(key,"server",hello+8,authenticated.bytes,authenticated.length);
                    uint8_t difference=0;
                    for (size_t i=0;i<32;++i) difference |= ((const uint8_t *)expected.bytes)[i]^response[8+i];
                    memcpy(&cutoff,response,8); cutoff=CFSwapInt64BigToHost(cutoff);
                    valid=difference==0 && !memcmp(response+40,"DMBT0006",8);
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.probingWiFi=NO;
            if (self.failing) { if (fd >= 0) close(fd); return; }
            if (!valid) {
                if (fd >= 0) close(fd);
                // A response can be lost after the phone has committed. A BLE
                // request is harmless if this probe never committed.
                if (self.ble.ready && nonce) [self.ble requestBluetoothVideo:self.videoReceived nonce:nonce];
                if (port == self.peerPort) { printf("EVENT LAN_UNAVAILABLE\n"); fflush(stdout); }
                return;
            }
            if (cutoff < self.videoReceived) { close(fd); [self fail:@"Invalid Wi-Fi video cutoff"]; return; }
            fcntl(fd,F_SETFL,O_NONBLOCK);
            fprintf(stderr,"Video handoff authenticated over %s\n",port == self.peerPort ? "direct LAN" : "wireless ADB");
            self.wifiNonce=nonce;
            self.wifiSocket=fd; self.wifiCutoff=cutoff; self.wifiLastData=NSDate.timeIntervalSinceReferenceDate;
            self.wifiPendingSince=NSDate.timeIntervalSinceReferenceDate;
            dm_classic_wire_init_video_only(&self->_wifiWire);
            // The worker consumed the complete authenticated header and magic
            // before committing, so a truncated probe cannot replace Bluetooth.
            const uint8_t magic[]="DMBT0006";
            if (!dm_classic_wire_feed_ble(&self->_wifiWire,magic,8,DMVideo,DMEvent,NULL,NULL,(__bridge void *)self))
                [self fail:@"Invalid wireless video header"];
        });
    });
}
- (void)fallbackToBluetooth {
    if (_wifiSocket>=0) close(_wifiSocket);
    _wifiSocket=-1; _wifiActive=NO; _wifiRecovering=YES;
    _wifiRecoveryRequested=NSDate.timeIntervalSinceReferenceDate;
    printf("EVENT WIFI_RECOVERING\n"); fflush(stdout);
    // The offset counts bytes already accepted by scrcpy's local bridge, even
    // if the ADB socket ended in the middle of an envelope or codec packet.
    if (![_ble requestBluetoothVideo:_videoReceived nonce:_wifiNonce]) [self fail:@"BLE video recovery request failed"];
    fprintf(stderr,"Peer video dropped; requested Bluetooth video over BLE\n");
}
- (void)pollWiFi {
    uint8_t command[256];
    ssize_t n=read(STDIN_FILENO,command,sizeof(command));
    if (n > 0) {
        [_commands appendBytes:command length:n];
        if (_commands.length > 4096) [self fail:@"Invalid bridge command"];
        while (YES) {
            const uint8_t *bytes=_commands.bytes;
            const uint8_t *newline=memchr(bytes,'\n',_commands.length);
            if (!newline) break;
            NSUInteger length=newline-bytes;
            NSString *line=[[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
            [_commands replaceBytesInRange:NSMakeRange(0,length+1) withBytes:NULL length:0];
            if ([line hasPrefix:@"UPGRADE "]) {
                NSInteger port=[[line substringFromIndex:8] integerValue];
                if (port > 0 && port <= UINT16_MAX) [self probeWiFi:(uint16_t)port];
            }
            if ([line isEqualToString:@"UPGRADE_PEER"]) [self probePeer];

        }
    }
    if (_wifiSocket < 0) {
        // Retry until Classic delivers data. Nonce checks and the phone's
        // recovery guard make duplicate BLE requests harmless.
        NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
        if (_wifiRecovering && now-_wifiRecoveryRequested >= 1) {
            _wifiRecoveryRequested=now;
            if (![_ble requestBluetoothVideo:_videoReceived nonce:_wifiNonce]) [self fail:@"BLE video recovery request failed"];
        }
        return;
    }
    if (NSDate.timeIntervalSinceReferenceDate-_wifiLastData > 4) {
        fprintf(stderr,"Peer video stalled: queued=%lu received=%llu\n",(unsigned long)_pending.length,(unsigned long long)_videoReceived);
        [self fallbackToBluetooth]; return;
    }
    if (!_wifiActive) {
        if (_videoReceived != _wifiCutoff) {
            if (NSDate.timeIntervalSinceReferenceDate-_wifiPendingSince > 3) [self fallbackToBluetooth];
            return;
        }
        if (!dm_classic_wire_complete(&_wire)) [self fail:@"Wi-Fi handoff split a Bluetooth record"];
        const uint8_t ready=1;
        ssize_t sent=send(_wifiSocket,&ready,1,0);
        if (sent < 0 && (errno==EAGAIN || errno==EWOULDBLOCK || errno==EINTR)) return;
        if (sent != 1) { [self fallbackToBluetooth]; return; }
        _wifiActive=YES;
        printf("EVENT WIFI_ACTIVE\n"); fflush(stdout);
    }
    // Drain enough per tick for the Wi-Fi bitrate, while bounding queued video
    // and yielding to BLE input and the main run loop.
    for (size_t total=0; total<512*1024;) {
        size_t capacity=MIN((NSUInteger)16384,DMQueueLimit-_pending.length);
        if (!capacity) return;
        uint8_t buffer[16384]; n=recv(_wifiSocket,buffer,capacity,0);
        if (!n || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            fprintf(stderr,"Peer video socket ended: read=%ld error=%d\n",(long)n,n<0 ? errno : 0);
            [self fallbackToBluetooth]; return;
        }
        if (n < 0) return;
        _wifiLastData=NSDate.timeIntervalSinceReferenceDate;
        if (!dm_classic_wire_feed_ble(&_wifiWire,buffer,n,DMVideo,DMEvent,NULL,NULL,(__bridge void *)self))
            [self fail:@"Invalid wireless video stream"];
        total+=n;
    }
}
- (void)remoteNameRequestComplete:(IOBluetoothDevice *)device status:(IOReturn)status {}
- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.failing || self.openingL2cap || self.l2capReady) return;
        fprintf(stderr, "Classic baseband connection completed (0x%08x)\n", status);
        if (status != kIOReturnSuccess && !self.device.isConnected)
            [self fail:[NSString stringWithFormat:@"Could not connect to the paired phone (0x%08x). Check that phone Bluetooth is enabled and in range.", status]];
        [self openClassicChannel];
    });
}
- (void)shutdownForTermination {
    if (_failing) return;
    _failing=YES;
    fprintf(stderr,"Closing Bluetooth session before helper termination\n");
    [self stopPeer];
    [self closeClassicStreams];
    [_channel setDelegate:nil];
    [_channel closeChannel];
    [_ble close];
    // Allow CoreBluetooth cancellation and the Classic close to reach the daemon
    // before process exit. SIGTERM's default action skips all transport cleanup.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ exit(0); });
}
- (void)fail:(NSString *)reason {
    if (_failing) return;
    _failing = YES;
    fprintf(stderr, "%s\n", reason.UTF8String);
    if (_wifiSocket >= 0) close(_wifiSocket);
    if (_client >= 0) close(_client);
    if (_listener >= 0) close(_listener);
    if (_controlClient >= 0) close(_controlClient);
    if (_controlListener >= 0) close(_controlListener);
    [_ble close];
    [self closeClassicStreams];
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
// A short cadence for moving Classic video permits a small radio window.
// Idle sessions and Wi-Fi retain the lower-traffic heartbeat cadence. The BLE
// queue coalesces cumulative counts if a GATT write is already outstanding.
- (void)acknowledgeVideoAtTime:(NSTimeInterval)now {
    BOOL movingClassicVideo = !_wifiActive && _videoReceived != _lastVideoAcknowledged;
    NSTimeInterval interval = movingClassicVideo ? 0.04 : 0.25;
    if (!_l2capReady || !_ble.ready || now - _lastHeartbeatSent < interval) return;
    if (![_ble acknowledgeVideo:_videoReceived]) { [self fail:@"BLE video acknowledgement failed"]; return; }
    _lastVideoAcknowledged = _videoReceived;
    _lastHeartbeatSent = now;
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
            if (!_outgoing.length) _outgoingSince = NSDate.timeIntervalSinceReferenceDate;
            uint32_t length = htonl((uint32_t)n);
            uint8_t type = 0;
            [_outgoing appendBytes:&type length:1]; [_outgoing appendBytes:&length length:4];
            [_outgoing appendBytes:buffer length:n]; [self sendControl];
        }
    }
    [self acknowledgeVideoAtTime:NSDate.timeIntervalSinceReferenceDate];
    [self flushControl];
}
- (BOOL)receiveVideo:(const uint8_t *)data length:(size_t)length {
    if (length > DMQueueLimit - _pending.length) return NO;
    if (!_pending.length) _pendingSince = NSDate.timeIntervalSinceReferenceDate;
    [_pending appendBytes:data length:length]; [self flush]; _videoReceived += length; return YES;
}
- (void)receiveEvent:(uint8_t)event {
    if (event == 6) return; // Peer heartbeat keeps lastData fresh without log growth.
    if (event == 7) {
        // This helper's parent is the owning Swift host, even when
        // LaunchServices reports a stale PID for its exec-based launcher.
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"app.droidmirror.minimizeMirror"
            object:[NSString stringWithFormat:@"%d", getppid()] userInfo:nil deliverImmediately:YES];
        fprintf(stderr, "Minimize command received over capture BLE for host %d\n", getppid());
        return; // Window commands may repeat; lifecycle event deduplication does not apply.
    }
    uint8_t mask = (uint8_t)(1u << (event - 1));
    if (_eventMask & mask) return;
    _eventMask |= mask;
    const char *names[] = {"PHONE_ON", "SESSION_ENDED", "PHONE_LOCAL_USE", "STREAM_STARTED", "CAPTURE_FAILED"};
    printf("EVENT %s\n", names[event - 1]); fflush(stdout);
}
- (void)l2capChannelData:(IOBluetoothL2CAPChannel *)channel data:(void *)data length:(size_t)length {
    if (channel != _channel || _failing) return;
    _lastData = NSDate.timeIntervalSinceReferenceDate;
    if (_wifiRecovering) {
        _wifiRecovering=NO;
        printf("EVENT BLUETOOTH_ACTIVE\n"); fflush(stdout);
    }
    if (_benchmark) {
        if (!_benchmarkStarted) _benchmarkStarted=_lastData;
        const uint8_t *bytes=data;
        for (size_t i=0;i<length;++i) if (bytes[i] != (uint8_t)(_benchmarkBytes+i)) [self fail:@"Benchmark byte loss or corruption"];
        _benchmarkBytes+=length; _benchmarkLast=_lastData; return;
    }
    if (!dm_classic_wire_feed_ble(&_wire, data, length, DMVideo, DMEvent, NULL, NULL, (__bridge void *)self))
        [self fail:@"Invalid Bluetooth stream or video backlog exceeded; update the Android companion and Mac app"];
    [self startBleWhenAndroidReady];
}
- (void)l2capChannelClosed:(IOBluetoothL2CAPChannel *)channel {
    if (_benchmark && _benchmarkBytes) {
        double elapsed=_benchmarkLast-_benchmarkStarted;
        printf("BENCH RECEIVED bytes=%llu duration=%.3f mbps=%.3f integrity=passed\n",(unsigned long long)_benchmarkBytes,elapsed,_benchmarkBytes*8.0/MAX(elapsed,0.001)/1000000.0);
        fflush(stdout); exit(0);
    }
    if (channel != _channel || _failing) return;
    [self fail:@"Bluetooth stream closed. Reconnect from your Mac."];
}
- (void)finishBenchmark {
    double elapsed=_benchmarkLast-_benchmarkStarted;
    printf("BENCH RECEIVED bytes=%llu duration=%.3f mbps=%.3f integrity=passed\n",(unsigned long long)_benchmarkBytes,elapsed,_benchmarkBytes*8.0/MAX(elapsed,0.001)/1000000.0);
    fflush(stdout); exit(0);
}
- (void)l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)channel status:(IOReturn)status {
    if (_l2capReady || _failing) return;
    if (status != kIOReturnSuccess) [self fail:@"Bluetooth Classic L2CAP connection failed"];
    _channel = channel;
    _connectionStage = @"waiting for Android video";
    _l2capReady = YES;
    if (_benchmark) { _lastData=NSDate.timeIntervalSinceReferenceDate; _connectionStage=@"receiving benchmark data"; return; }
    _connectionStage=@"waiting for Android to accept the Classic session";
    _lastData=NSDate.timeIntervalSinceReferenceDate;
    [self startBleWhenAndroidReady];
}
- (void)startBleWhenAndroidReady {
    // macOS can report a local channel open before Android accepts it. The
    // validated wire header is the first actual evidence of an Android session.
    if (_failing || _benchmark || !_l2capReady || !_wire.decided || _ble) return;
    fprintf(stderr,"Android accepted Classic session; starting BLE discovery\n");
    _ble=[[DMBleInputTransport alloc] initWithPairingKey:_pairingKey]; _ble.delegate=self;
    _connectionStage=@"authenticating the paired BLE side channel";
    _lastData=NSDate.timeIntervalSinceReferenceDate;
    [self announceReady];
}
- (void)start:(NSString *)address {
    signal(SIGTERM,SIG_IGN);
    _terminationSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
    dispatch_source_set_event_handler(_terminationSource,^{ [self shutdownForTermination]; });
    dispatch_resume(_terminationSource);
    _wifiSocket=-1; _commands=[NSMutableData data];
    NSDictionary *environment=NSProcessInfo.processInfo.environment;
    NSInteger maxSize=environment[@"DROIDMIRROR_WIFI_MAX_SIZE"] ? [environment[@"DROIDMIRROR_WIFI_MAX_SIZE"] integerValue] : 1920;
    NSInteger fps=environment[@"DROIDMIRROR_WIFI_FPS"] ? [environment[@"DROIDMIRROR_WIFI_FPS"] integerValue] : 60;
    NSInteger bitRate=environment[@"DROIDMIRROR_WIFI_BIT_RATE"] ? [environment[@"DROIDMIRROR_WIFI_BIT_RATE"] integerValue] : 12000000;
    if (maxSize != 0 && (maxSize<128 || maxSize>8192)) maxSize=1920;
    if (fps<1 || fps>240) fps=60;
    if (bitRate<256000 || bitRate>64000000) bitRate=12000000;
    uint32_t profile[]={htonl((uint32_t)maxSize),htonl((uint32_t)fps),htonl((uint32_t)bitRate)};
    _wirelessProfile=[NSData dataWithBytes:profile length:sizeof(profile)];
    fcntl(STDIN_FILENO,F_SETFL,O_NONBLOCK);
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
        if (self.failing) return;
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        // The macOS compatibility wrapper can omit its remote-close callback.
        // A quiet period ends the bounded diagnostic; the script also requires
        // exact agreement with the sender's total before accepting the sample.
        if (self.benchmark && self.benchmarkBytes && now-self.benchmarkLast > 2.0) [self finishBenchmark];
        [self flush]; [self pollControl]; [self pollWiFi];
        if (self.outgoingSince && now - self.outgoingSince > 1.0) [self fail:@"Bluetooth input stalled"];
        if (self.controlSince && now - self.controlSince > 1.0) [self fail:@"Control response stalled"];
        if (self.pendingSince && now - self.pendingSince > 1.0) [self fail:@"Video bridge stalled for one second; reconnect"];
        if (now - self.lastData > 15.0) [self fail:[NSString stringWithFormat:@"Bluetooth timed out while %@%@", self.connectionStage,
            self.ble && !self.ble.ready ? [NSString stringWithFormat:@" (%@)", self.ble.connectionStage] : @""]];
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
        [self connectClassicBaseband];
    }];
}
- (void)connectClassicBaseband {
    self.connectionStage = @"connecting to the paired phone before opening L2CAP";
    self.lastData=NSDate.timeIntervalSinceReferenceDate;
    if (self.device.isConnected) { [self openClassicChannel]; return; }
    fprintf(stderr, "Connecting Classic baseband before opening L2CAP\n");
    IOReturn result=[self.device openConnection:self];
    if (result != kIOReturnSuccess) {
        if (self.device.isConnected) [self openClassicChannel];
        else [self fail:[NSString stringWithFormat:@"Could not start Classic connection (0x%08x)", result]];
    }
}
- (void)attachClassicStreams:(id)rawChannel {
    if (![rawChannel respondsToSelector:@selector(inputStream)] || ![rawChannel respondsToSelector:@selector(outputStream)]) {
        [self fail:@"Classic channel does not expose readable streams"]; return;
    }
    self.rawChannel = rawChannel;
    self.classicInput = [rawChannel inputStream];
    self.classicOutput = [rawChannel outputStream];
    if (!self.classicInput || !self.classicOutput) { [self fail:@"Classic channel streams are unavailable"]; return; }
    self.classicInput.delegate = self;
    self.classicOutput.delegate = self;
    [self.classicInput scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self.classicOutput scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self l2capChannelOpenComplete:nil status:kIOReturnSuccess];
    [self.classicInput open];
    // Keep the reverse stream open but never write application payload to it.
    [self.classicOutput open];
}
- (void)closeClassicStreams {
    self.classicInput.delegate = nil; self.classicOutput.delegate = nil;
    [self.classicInput removeFromRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self.classicOutput removeFromRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self.classicInput close]; [self.classicOutput close];
    self.classicInput = nil; self.classicOutput = nil; self.rawChannel = nil;
}
- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
    if (self.failing || (stream != self.classicInput && stream != self.classicOutput)) return;
    if (event == NSStreamEventHasBytesAvailable && stream == self.classicInput) {
        uint8_t bytes[16384];
        while (self.classicInput.hasBytesAvailable && !self.failing) {
            NSInteger count = [self.classicInput read:bytes maxLength:sizeof(bytes)];
            if (count < 0) { [self fail:@"Classic video stream read failed"]; return; }
            if (count == 0) break;
            [self l2capChannelData:nil data:bytes length:(size_t)count];
        }
    } else if (event == NSStreamEventErrorOccurred)
        [self fail:[NSString stringWithFormat:@"Classic channel stream failed: %@", stream.streamError.localizedDescription ?: @"unknown error"]];
    else if (event == NSStreamEventEndEncountered) [self l2capChannelClosed:nil];
}
- (void)openClassicChannel {
    if (_openingL2cap || _l2capReady || _failing) return;
    _openingL2cap=YES;
    _lastData=NSDate.timeIntervalSinceReferenceDate;
    self.connectionStage = @"opening the Android Classic L2CAP channel";
    fprintf(stderr, "Opening Classic L2CAP PSM 0x%04x\n", self.psm);
    if ([self.device respondsToSelector:@selector(classicPeer)]) {
        id peer = [self.device classicPeer];
        if ([peer respondsToSelector:@selector(setConnectL2CAPCallback:)]
                && [peer respondsToSelector:@selector(openL2CAPChannel:)]) {
            self.classicPeer = peer;
            [peer setConnectL2CAPCallback:^(id rawChannel, NSInteger error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.failing) return;
                    if (error || !rawChannel) [self fail:[NSString stringWithFormat:@"Classic L2CAP connection failed in the macOS Bluetooth framework (error=%ld)", (long)error]];
                    // Wrapping this channel in IOBluetoothL2CAPChannel can lose
                    // or close the live data pipe on newer macOS releases.
                    [self attachClassicStreams:rawChannel];
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
        [self fail:@"Could not open Classic L2CAP. Enable the background bridge and authorize Shizuku on Android."];
    }
    self.channel = channel;
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
    // The notification helper reads this derived credential; the input master
    // stays in its per-phone item. Both are provisioned by the same UI action.
    uint8_t notificationBytes[32];
    dm_ble_notification_pairing_key(key.bytes, notificationBytes);
    NSData *notificationKey = [NSData dataWithBytes:notificationBytes length:32];
    memset(notificationBytes, 0, sizeof(notificationBytes));
    NSDictionary *notificationQuery = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"app.droidmirror.ble.v2", (__bridge id)kSecAttrAccount:@"phone"};
    NSDictionary *notificationValue = @{(__bridge id)kSecValueData:notificationKey};
    status = SecItemUpdate((__bridge CFDictionaryRef)notificationQuery, (__bridge CFDictionaryRef)notificationValue);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *item = [notificationQuery mutableCopy]; [item addEntriesFromDictionary:notificationValue];
        item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    if (status != errSecSuccess) {
        fprintf(stderr, "Could not save notification pairing in Keychain (%d); retry Pair Bluetooth\n", (int)status); return 1;
    }
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
