// Compile with BleInputQueue.m, BleInputCrypto.c and ClassicBluetoothWire.c,
// linking Foundation, IOBluetooth, CoreBluetooth and Security.
#import "BleInputTransport.m"
#define main DMClassicHelperMain
#import "ClassicBluetoothBridge.m"
#undef main
#include <assert.h>

@interface DMStartupDevice : NSObject
@property(nonatomic) BOOL connected;
@property(nonatomic) NSUInteger requests;
@property(nonatomic) IOReturn result;
@end
@implementation DMStartupDevice
- (BOOL)isConnected { return _connected; }
- (IOReturn)openConnection:(id)target { ++_requests; return _result; }
@end

@interface DMStartupBridge : DMClassicBridge
@property(nonatomic) NSUInteger opens;
@end
@implementation DMStartupBridge
- (void)openClassicChannel { ++_opens; self.openingL2cap=YES; }
- (void)fail:(NSString *)reason { @throw [NSException exceptionWithName:@"ConnectionFailed" reason:reason userInfo:nil]; }
@end

@interface DMStartupPeripheral : NSObject
@property(nonatomic, strong) NSUUID *identifier;
@property(nonatomic, weak) id delegate;
@end
@implementation DMStartupPeripheral
@end

@interface DMStartupManager : NSObject
@property(nonatomic, strong) NSArray *connected;
@property(nonatomic, strong) id candidate;
@property(nonatomic) NSUInteger scans;
@end
@implementation DMStartupManager
- (CBManagerState)state { return CBManagerStatePoweredOn; }
- (NSArray *)retrieveConnectedPeripheralsWithServices:(NSArray *)services { return _connected; }
- (void)connectPeripheral:(id)peripheral options:(NSDictionary *)options { _candidate=peripheral; }
- (void)stopScan {}
- (void)scanForPeripheralsWithServices:(NSArray *)services options:(NSDictionary *)options { ++_scans; }
@end

@interface DMFallbackBLE : NSObject
@property(nonatomic) NSUInteger requests;
@property(nonatomic) uint64_t received;
@property(nonatomic, strong) NSData *nonce;
@end
@implementation DMFallbackBLE
- (BOOL)requestBluetoothVideo:(uint64_t)count nonce:(NSData *)nonce {
    ++_requests; _received=count; _nonce=nonce; return YES;
}
@end

@interface DMVideoAckBLE : NSObject
@property(nonatomic) BOOL ready;
@property(nonatomic) NSUInteger requests;
@property(nonatomic) uint64_t received;
@end
@implementation DMVideoAckBLE
- (BOOL)acknowledgeVideo:(uint64_t)count { ++_requests; _received=count; return YES; }
@end

@interface DMStreamChannel : NSObject
@property(nonatomic, strong) NSInputStream *inputStream;
@property(nonatomic, strong) NSOutputStream *outputStream;
@end
@implementation DMStreamChannel
@end

@interface DMStreamBridge : DMStartupBridge
@property(nonatomic) BOOL receivedHeader;
@property(nonatomic, strong) NSMutableData *videoBytes;
@end
@implementation DMStreamBridge
- (instancetype)init {
    if ((self = [super init])) {
        dm_classic_wire_init_video_only(&_wire);
        _videoBytes = [NSMutableData data];
    }
    return self;
}
- (void)startBleWhenAndroidReady { self.receivedHeader = _wire.decided; }
- (BOOL)receiveVideo:(const uint8_t *)bytes length:(size_t)length {
    [self.videoBytes appendBytes:bytes length:length]; return YES;
}
@end

static void TestNativeClassicStreams(void) {
    const uint8_t bytes[] = {'D','M','B','T','0','0','0','6',0,0,0,0,3,'a','b','c'};
    DMStreamChannel *raw = [DMStreamChannel new];
    raw.inputStream = [NSInputStream inputStreamWithData:[NSData dataWithBytes:bytes length:sizeof(bytes)]];
    raw.outputStream = [NSOutputStream outputStreamToMemory];
    DMStreamBridge *bridge = [DMStreamBridge new];
    [bridge attachClassicStreams:raw];
    assert(bridge.rawChannel == raw && bridge.channel == nil && bridge.l2capReady);
    assert(!bridge.receivedHeader); // Opening locally is not Android readiness.
    assert(raw.inputStream.streamStatus == NSStreamStatusOpen && raw.outputStream.streamStatus == NSStreamStatusOpen);
    [bridge stream:raw.inputStream handleEvent:NSStreamEventHasBytesAvailable];
    assert(bridge.receivedHeader);
    assert([bridge.videoBytes isEqual:[NSData dataWithBytes:"abc" length:3]]);
    assert([[raw.outputStream propertyForKey:NSStreamDataWrittenToMemoryStreamKey] length] == 0);
    NSInputStream *stale = raw.inputStream;
    [bridge closeClassicStreams];
    assert(bridge.rawChannel == nil && bridge.classicInput == nil && bridge.classicOutput == nil);
    assert(raw.inputStream.streamStatus == NSStreamStatusClosed && raw.outputStream.streamStatus == NSStreamStatusClosed);
    [bridge stream:stale handleEvent:NSStreamEventErrorOccurred]; // A closed stream cannot affect the next session.
    puts("Classic streams: retained channel, Android header, video delivery, zero reverse payload, cleanup and stale events passed");
}

static void TestVideoAckCadence(void) {
    DMStartupBridge *bridge=[DMStartupBridge new];
    DMVideoAckBLE *ble=[DMVideoAckBLE new]; bridge.ble=(DMBleInputTransport *)ble;
    bridge.lastHeartbeatSent=10; bridge.videoReceived=2683;
    [bridge acknowledgeVideoAtTime:10.1]; assert(ble.requests==0); // Not authenticated.
    ble.ready=YES;
    [bridge acknowledgeVideoAtTime:10.1]; assert(ble.requests==0); // Classic not ready.
    bridge.l2capReady=YES;
    [bridge acknowledgeVideoAtTime:10.02]; assert(ble.requests==0);
    [bridge acknowledgeVideoAtTime:10.05]; assert(ble.requests==1 && ble.received==2683);
    [bridge acknowledgeVideoAtTime:10.10]; assert(ble.requests==1); // No busy idle ACKs.
    [bridge acknowledgeVideoAtTime:10.31]; assert(ble.requests==2); // Idle heartbeat.
    bridge.videoReceived=8192;
    [bridge acknowledgeVideoAtTime:10.36]; assert(ble.requests==3 && ble.received==8192);
    bridge.wifiActive=YES; bridge.videoReceived=32768;
    [bridge acknowledgeVideoAtTime:10.41]; assert(ble.requests==3);
    [bridge acknowledgeVideoAtTime:10.62]; assert(ble.requests==4 && ble.received==32768);
    bridge.wifiActive=NO; bridge.videoReceived=35451;
    [bridge acknowledgeVideoAtTime:10.67]; assert(ble.requests==5 && ble.received==35451);
    puts("Video ACKs: active Classic cadence, idle heartbeat, readiness, Wi-Fi and fallback passed");
}

static void TestDroppedADB(void) {
    for (int silent=0; silent<2; ++silent) {
    int video[2], output[2]; assert(!socketpair(AF_UNIX,SOCK_STREAM,0,video));
    assert(!socketpair(AF_UNIX,SOCK_STREAM,0,output));
    DMStartupBridge *bridge=[DMStartupBridge new];
    DMFallbackBLE *ble=[DMFallbackBLE new]; bridge.ble=(DMBleInputTransport *)ble;
    bridge.commands=[NSMutableData data]; bridge.pending=[NSMutableData data];
    bridge.wifiSocket=video[1]; bridge.client=output[1]; bridge.wifiActive=YES;
    bridge.wifiNonce=[NSMutableData dataWithLength:32]; bridge.videoReceived=123;
    bridge.wifiLastData=NSDate.timeIntervalSinceReferenceDate-(silent ? 5 : 0);
    if (!silent) close(video[0]);
    [bridge pollWiFi];
    assert(bridge.wifiSocket==-1 && !bridge.wifiActive && bridge.wifiRecovering);
    assert(ble.requests==1 && ble.received==123 && [ble.nonce isEqual:bridge.wifiNonce]);
    bridge.wifiRecoveryRequested=NSDate.timeIntervalSinceReferenceDate-2;
    [bridge pollWiFi]; assert(ble.requests==2 && ble.received==123);
    [bridge pollWiFi]; assert(ble.requests==2); // Back off between attempts.
    bridge.videoReceived=124;
    bridge.channel=nil;
    // Classic data confirms that the existing channel resumed.
    [bridge l2capChannelData:nil data:"DMBT0006" length:8];
    assert(!bridge.wifiRecovering);
    bridge.wifiRecoveryRequested=NSDate.timeIntervalSinceReferenceDate-2;
    [bridge pollWiFi]; assert(ble.requests==2);
    // The existing scrcpy socket remains open and connected.
    assert(bridge.client==output[1] && send(bridge.client,"x",1,0)==1);
    char byte; assert(recv(output[0],&byte,1,0)==1 && byte=='x');
    close(output[0]); close(output[1]);
    if (silent) close(video[0]);
    }
    puts("Dropped ADB: real socket EOF requests BLE recovery with exact offset and nonce, preserving scrcpy socket");
}

static void TestColdPeerConnection(void) {
    int listener=socket(AF_INET,SOCK_STREAM,0); assert(listener>=0);
    struct sockaddr_in address={0}; address.sin_family=AF_INET;
    address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    assert(!bind(listener,(struct sockaddr *)&address,sizeof(address)) && !listen(listener,1));
    socklen_t size=sizeof(address); assert(!getsockname(listener,(struct sockaddr *)&address,&size));
    DMStartupBridge *bridge=[DMStartupBridge new];
    bridge.wifiSocket=-1; bridge.peerPort=ntohs(address.sin_port);
    bridge.pairingKey=[NSMutableData dataWithLength:32];
    bridge.wirelessProfile=[NSMutableData dataWithLength:12];
    dispatch_semaphore_t completed=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        int peer=accept(listener,NULL,NULL); assert(peer>=0);
        int yes=1; setsockopt(peer,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
        // Model a relay/DNS cold start longer than the former two-second budget.
        [NSThread sleepForTimeInterval:3];
        uint8_t hello[40]={0}; memcpy(hello,"DMWIFI03",8);
        assert(send(peer,hello,sizeof(hello),0)==sizeof(hello));
        uint8_t request[44]; assert(DMReadExact(peer,request,sizeof(request)));
        NSData *proof=DMUpgradeProof(bridge.pairingKey,"client",hello+8,request,12);
        assert(!memcmp(proof.bytes,request+12,32));
        uint8_t response[48]={0};
        NSMutableData *authenticated=[bridge.wirelessProfile mutableCopy];
        [authenticated appendBytes:response length:8];
        NSData *server=DMUpgradeProof(bridge.pairingKey,"server",hello+8,authenticated.bytes,authenticated.length);
        memcpy(response+8,server.bytes,32); memcpy(response+40,"DMBT0006",8);
        assert(send(peer,response,sizeof(response),0)==sizeof(response));
        close(peer); close(listener); dispatch_semaphore_signal(completed);
    });
    [bridge probeWiFi:bridge.peerPort];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:6];
    do { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]]; }
    while (bridge.wifiSocket<0 && deadline.timeIntervalSinceNow>0);
    assert(bridge.wifiSocket>=0 && bridge.wifiCutoff==0 && bridge.wifiNonce.length==32);
    close(bridge.wifiSocket);
    assert(!dispatch_semaphore_wait(completed,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)));
    puts("Cold Iroh startup: delayed challenge survives discovery, authenticates and preserves video cutoff");
}

int main(void) {
    @autoreleasepool {
        TestNativeClassicStreams();
        TestVideoAckCadence();
        TestDroppedADB();
        TestColdPeerConnection();
        DMStartupDevice *device=[DMStartupDevice new];
        DMStartupBridge *bridge=[DMStartupBridge new];
        bridge.device=(IOBluetoothDevice *)device;
        [bridge connectClassicBaseband];
        assert(device.requests==1 && bridge.opens==0);
        // L2CAP must wait for the asynchronous baseband completion.
        device.connected=YES;
        [bridge connectionComplete:(IOBluetoothDevice *)device status:kIOReturnSuccess];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        assert(bridge.opens==1);
        [bridge connectionComplete:(IOBluetoothDevice *)device status:kIOReturnSuccess];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        assert(bridge.opens==1);

        DMStartupBridge *alreadyConnected=[DMStartupBridge new];
        alreadyConnected.device=(IOBluetoothDevice *)device;
        [alreadyConnected connectClassicBaseband];
        assert(alreadyConnected.opens==1 && device.requests==1);
        device.connected=NO; device.result=kIOReturnError;
        @try {
            DMStartupBridge *failed=[DMStartupBridge new]; failed.device=(IOBluetoothDevice *)device;
            [failed connectClassicBaseband]; assert(false);
        } @catch (NSException *error) { assert([error.name isEqual:@"ConnectionFailed"]); }

        // A local open callback is insufficient: wait for Android's complete
        // protocol header before starting its per-session BLE discovery budget.
        // A nil pairing key prevents a real CBCentralManager in this unit test.
        DMClassicBridge *waiting=[DMClassicBridge new];
        IOBluetoothL2CAPChannel *channel=(IOBluetoothL2CAPChannel *)[NSObject new];
        [waiting l2capChannelOpenComplete:channel status:kIOReturnSuccess];
        assert(waiting.ble==nil && [waiting.connectionStage containsString:@"accept the Classic session"]);
        [waiting l2capChannelData:channel data:"DMBT" length:4];
        assert([waiting.connectionStage containsString:@"accept the Classic session"]);
        [waiting l2capChannelData:channel data:"0006" length:4];
        assert([waiting.connectionStage containsString:@"authenticating"]);

        // An existing system BLE connection must be usable without advertising.
        DMBleInputTransport *ble=[DMBleInputTransport new];
        DMStartupManager *manager=[DMStartupManager new];
        DMStartupPeripheral *peer=[DMStartupPeripheral new]; peer.identifier=[NSUUID UUID];
        manager.connected=@[peer]; ble.manager=(CBCentralManager *)manager;
        ble.rejected=[NSMutableSet set];
        [ble scan];
        assert(manager.candidate==peer && ble.peripheral==(CBPeripheral *)peer && manager.scans==0);
        // Late disconnect/failure callbacks from an old candidate must not erase
        // the new candidate or clear its in-progress authentication state.
        DMStartupPeripheral *old=[DMStartupPeripheral new]; old.identifier=[NSUUID UUID];
        [ble centralManager:(CBCentralManager *)manager didDisconnectPeripheral:(CBPeripheral *)old error:nil];
        [ble centralManager:(CBCentralManager *)manager didFailToConnectPeripheral:(CBPeripheral *)old error:nil];
        assert(ble.peripheral==(CBPeripheral *)peer && ble.rejected.count==0);
        ble.peripheral=nil; [ble.rejected addObject:peer.identifier];
        [ble scan]; assert(manager.scans==1);
        puts("Bluetooth startup tests passed (baseband ordering, Android header readiness, connected BLE reuse, stale callbacks)");
    }
    return 0;
}
