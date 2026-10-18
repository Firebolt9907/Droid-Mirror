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
@property(nonatomic, strong) NSArray *services;
@property(nonatomic) NSUInteger discoveries;
@property(nonatomic) NSUInteger characteristicDiscoveries;
@property(nonatomic) NSUInteger reads;
@end
@implementation DMStartupPeripheral
- (void)discoverServices:(NSArray *)services { ++_discoveries; }
- (void)discoverCharacteristics:(NSArray *)characteristics forService:(id)service { ++_characteristicDiscoveries; }
- (void)readValueForCharacteristic:(id)characteristic { ++_reads; }
- (NSUInteger)maximumWriteValueLengthForType:(CBCharacteristicWriteType)type { return 512; }
- (void)writeValue:(NSData *)value forCharacteristic:(id)characteristic type:(CBCharacteristicWriteType)type {}
@end

@interface DMStartupManager : NSObject
@property(nonatomic, strong) NSArray *connected;
@property(nonatomic, strong) id candidate;
@property(nonatomic) NSUInteger scans;
@property(nonatomic) NSUInteger cancellations;
@end
@implementation DMStartupManager
- (CBManagerState)state { return CBManagerStatePoweredOn; }
- (NSArray *)retrieveConnectedPeripheralsWithServices:(NSArray *)services { return _connected; }
- (void)connectPeripheral:(id)peripheral options:(NSDictionary *)options { _candidate=peripheral; }
- (void)stopScan {}
- (void)cancelPeripheralConnection:(id)peripheral { ++_cancellations; }
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

@interface DMRecoveryTransport : DMBleInputTransport
@property(nonatomic, strong) NSString *failure;
@property(nonatomic) NSUInteger readyCount;
@property(nonatomic, strong) NSData *delivered;
- (DMBleInputKeys)testKeys:(BOOL)returning;
- (NSData *)testReturnPacket;
- (NSData *)testProof;
- (NSData *)testClock;
- (NSData *)testResume:(uint64_t)next;
@end
@implementation DMRecoveryTransport
- (void)reportFailure:(NSString *)reason { self.failure=reason; }
- (void)reportReady { ++self.readyCount; }
- (void)deliver:(NSData *)bytes { self.delivered=bytes; }
- (void)drain {} // Test controls ATT completions explicitly.
- (DMBleInputKeys)testKeys:(BOOL)returning {
    uint8_t session[32]; DMBleInputKeys keys;
    dm_ble_session_key(self.pairingKey.bytes,self.sessionNonce.bytes,session);
    if (returning) dm_ble_output_keys(session,&keys); else dm_ble_input_keys(session,&keys);
    return keys;
}
- (NSData *)testReturnPacket {
    DMBleInputKeys keys=[self testKeys:YES];
    uint8_t packet[25]; assert(dm_ble_input_seal(&keys,self.receiveSequence,(const uint8_t *)"x",1,packet));
    return [NSData dataWithBytes:packet length:sizeof(packet)];
}
- (NSData *)testProof {
    DMBleInputKeys keys=[self testKeys:NO];
    uint8_t proof[32]; dm_ble_input_proof(&keys,self.challenge.bytes,proof);
    return [NSData dataWithBytes:proof length:sizeof(proof)];
}
- (NSData *)testResume:(uint64_t)next {
    DMBleInputKeys keys=[self testKeys:NO]; uint8_t bytes[40];
    uint64_t encoded=CFSwapInt64HostToBig(next); memcpy(bytes,&encoded,8);
    dm_ble_resume_proof(&keys,self.challenge.bytes,bytes,bytes+8);
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}
- (NSData *)testClock {
    DMBleInputKeys keys=[self testKeys:NO];
    uint8_t bytes[40]={0}; dm_ble_clock_proof(&keys,bytes,bytes+8);
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}
@end

static CBMutableService *RecoveryService(void) {
    CBMutableService *service=[[CBMutableService alloc] initWithType:[CBUUID UUIDWithString:DMInputService] primary:YES];
    NSMutableArray *attributes=[NSMutableArray array];
    for (NSString *uuid in @[DMInputCharacteristic,DMInputProof,DMInputReturn,DMInputKey,DMInputClock,DMInputResume,DMInputReplay])
        [attributes addObject:[[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:uuid]
            properties:CBCharacteristicPropertyRead|CBCharacteristicPropertyWrite value:nil
            permissions:CBAttributePermissionsReadable|CBAttributePermissionsWriteable]];
    service.characteristics=attributes; return service;
}

static void TestActiveServiceRecovery(void) {
    DMRecoveryTransport *ble=[DMRecoveryTransport new];
    DMStartupPeripheral *peer=[DMStartupPeripheral new]; peer.identifier=[NSUUID UUID];
    ble.peripheral=(CBPeripheral *)peer; ble.pending=[DMBleInputQueue new];
    ble.pairingKey=[NSMutableData dataWithLength:32]; ble.sessionNonce=[NSMutableData dataWithLength:32];
    CBMutableCharacteristic *initialNonce=[[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:DMInputKey]
        properties:CBCharacteristicPropertyRead value:ble.sessionNonce permissions:CBAttributePermissionsReadable];
    ble.nonceCharacteristic=initialNonce;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:initialNonce error:nil];
    ble.sequence=17; ble.receiveSequence=23;
    CBMutableService *old=RecoveryService();
    ble.inputService=old; ble.returning=old.characteristics[2];
    ble.ready=YES; ble.proofVerified=YES; ble.readPending=YES;
    NSData *lostReturn=[ble testReturnPacket];
    CBMutableCharacteristic *returning=(CBMutableCharacteristic *)ble.returning;
    [ble peripheral:(CBPeripheral *)peer didModifyServices:@[old]];
    assert(!ble.ready && ble.recovering && !ble.failure && peer.discoveries==1);
    NSTimeInterval deadline=ble.recoveryDeadline;
    [ble peripheral:(CBPeripheral *)peer didModifyServices:@[old]];
    assert(ble.recoveryDeadline==deadline); // Repeated invalidations cannot extend recovery.
    returning.value=lostReturn;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:returning error:nil];
    assert(ble.receiveSequence==23 && !ble.delivered); // Ignore old ATT completion.
    [ble recoverInputServiceAtTime:deadline-0.01]; assert(peer.discoveries==1);
    CBMutableService *fresh=RecoveryService(); peer.services=@[fresh];
    [ble peripheral:(CBPeripheral *)peer didDiscoverServices:nil];
    [ble peripheral:(CBPeripheral *)peer didDiscoverCharacteristicsForService:fresh error:nil];
    CBMutableCharacteristic *nonce=(CBMutableCharacteristic *)ble.nonceCharacteristic;
    nonce.value=ble.sessionNonce;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:nonce error:nil];
    assert(ble.challenge.length==16 && ble.sequence==17 && ble.receiveSequence==23);
    CBMutableCharacteristic *proof=(CBMutableCharacteristic *)ble.proof; proof.value=[ble testProof];
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:proof error:nil];
    CBMutableCharacteristic *resume=(CBMutableCharacteristic *)ble.resumeCharacteristic; resume.value=[ble testResume:17];
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:resume error:nil];
    CBMutableCharacteristic *replay=(CBMutableCharacteristic *)ble.replayCharacteristic; replay.value=lostReturn;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:replay error:nil];
    assert(ble.receiveSequence==24 && [ble.delivered isEqual:[NSData dataWithBytes:"x" length:1]]);
    CBMutableCharacteristic *clock=(CBMutableCharacteristic *)ble.clockCharacteristic; clock.value=[ble testClock];
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:clock error:nil];
    assert(ble.ready && !ble.recovering && ble.readyCount==1 && !ble.failure);
    assert(ble.sequence==17 && ble.receiveSequence==24); // No CTR nonce reuse or replay acceptance.
    for (NSUInteger accepted=0; accepted<2; ++accepted) {
        ble.recovering=YES; ble.ready=NO; ble.proofVerified=YES;
        ble.inFlightPacket=[NSData dataWithBytes:"ciphertext" length:10];
        resume.value=[ble testResume:accepted ? 17 : 16];
        [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:resume error:nil];
        assert(ble.retryInput==!accepted && ble.sequence==17);
        if (!accepted) assert(ble.inFlightPacket.length==10); else assert(!ble.inFlightPacket);
        clock.value=[ble testClock];
        [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:clock error:nil];
        assert(ble.ready && !ble.failure);
    }
    // A valid MAC cannot authorize an input sequence outside the outstanding packet.
    ble.recovering=YES; ble.ready=NO; ble.proofVerified=YES;
    resume.value=[ble testResume:15];
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:resume error:nil];
    assert([ble.failure containsString:@"sequence"] && ble.sequence==17);
    ble.failure=nil; ble.ready=YES; ble.recovering=NO;
    [ble peripheral:(CBPeripheral *)peer didModifyServices:@[fresh]];
    [ble recoverInputServiceAtTime:ble.recoveryDeadline];
    assert([ble.failure containsString:@"timed out"]);
    ble.failure=nil;
    // A replacement app/session cannot inherit the old mirror's authentication.
    CBMutableService *replacement=RecoveryService(); peer.services=@[replacement];
    [ble peripheral:(CBPeripheral *)peer didDiscoverServices:nil];
    [ble peripheral:(CBPeripheral *)peer didDiscoverCharacteristicsForService:replacement error:nil];
    nonce=(CBMutableCharacteristic *)ble.nonceCharacteristic;
    NSMutableData *different=[ble.sessionNonce mutableCopy]; ((uint8_t *)different.mutableBytes)[0]=1; nonce.value=different;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:nonce error:nil];
    assert([ble.failure containsString:@"replaced"] && !ble.ready && ble.sequence==17 && ble.receiveSequence==24);
    puts("BLE active recovery: in-flight completion, fresh proof, same-session nonce, preserved sequences, stale callbacks and bounded failure passed");
}

static void TestStalledCandidateRecovery(void) {
    DMBleInputTransport *ble=[DMBleInputTransport new];
    DMStartupManager *manager=[DMStartupManager new];
    DMStartupPeripheral *stalled=[DMStartupPeripheral new]; stalled.identifier=[NSUUID UUID];
    DMStartupPeripheral *live=[DMStartupPeripheral new]; live.identifier=[NSUUID UUID];
    ble.manager=(CBCentralManager *)manager; ble.rejected=[NSMutableSet set];
    [ble centralManager:(CBCentralManager *)manager didDiscoverPeripheral:(CBPeripheral *)stalled advertisementData:@{} RSSI:@0];
    NSTimeInterval deadline=ble.candidateConnectionDeadline;
    [ble recoverConnectingCandidateAtTime:deadline-0.01];
    assert(ble.peripheral==(CBPeripheral *)stalled && manager.cancellations==0);
    // The phone's new identity becomes a system-connected link while the old
    // advertising identity is still silently retrying in CoreBluetooth.
    manager.connected=@[stalled,live];
    [ble recoverConnectingCandidateAtTime:deadline];
    assert(manager.cancellations==1 && ble.peripheral==(CBPeripheral *)live && manager.candidate==live);
    assert(ble.rejected.count==0 && [ble.deferredCandidate isEqual:stalled.identifier]);
    [ble centralManager:(CBCentralManager *)manager didConnectPeripheral:(CBPeripheral *)stalled];
    [ble centralManager:(CBCentralManager *)manager didDisconnectPeripheral:(CBPeripheral *)stalled error:nil];
    assert(ble.peripheral==(CBPeripheral *)live && live.discoveries==0);
    [ble centralManager:(CBCentralManager *)manager didConnectPeripheral:(CBPeripheral *)live];
    assert(live.discoveries==1 && ble.candidateConnectionDeadline==0);
    [ble recoverConnectingCandidateAtTime:deadline+100];
    assert(manager.cancellations==1 && ble.peripheral==(CBPeripheral *)live);

    DMBleInputTransport *cancelled=[DMBleInputTransport new];
    cancelled.manager=(CBCentralManager *)manager; cancelled.peripheral=(CBPeripheral *)stalled;
    cancelled.candidateConnectionDeadline=1; cancelled.closed=YES;
    [cancelled recoverConnectingCandidateAtTime:2]; assert(manager.cancellations==1);
    DMBleInputTransport *slow=[DMBleInputTransport new];
    DMStartupManager *slowManager=[DMStartupManager new]; slowManager.connected=@[stalled];
    slow.manager=(CBCentralManager *)slowManager; slow.rejected=[NSMutableSet set];
    slow.peripheral=(CBPeripheral *)stalled; slow.candidateConnectionDeadline=NSDate.timeIntervalSinceReferenceDate;
    [slow recoverConnectingCandidateAtTime:slow.candidateConnectionDeadline];
    assert(slow.peripheral==nil && slow.rejected.count==0);
    [slow recoverConnectingCandidateAtTime:slow.candidateRetryAfter];
    assert(slow.peripheral==(CBPeripheral *)stalled); // A slow valid phone isn't permanently excluded.
    puts("BLE startup: stalled identity replaced by live link, cooldown retry, late callbacks and cancellation passed");
}

static void TestDelayedInputService(void) {
    DMBleInputTransport *ble=[DMBleInputTransport new];
    DMStartupManager *manager=[DMStartupManager new];
    DMStartupPeripheral *peer=[DMStartupPeripheral new]; peer.identifier=[NSUUID UUID];
    ble.manager=(CBCentralManager *)manager; ble.peripheral=(CBPeripheral *)peer;
    ble.rejected=[NSMutableSet set];
    [ble centralManager:(CBCentralManager *)manager didConnectPeripheral:(CBPeripheral *)peer];
    assert(peer.discoveries==1);
    // Reproduce a notification link whose per-session input service isn't added yet.
    peer.services=@[];
    [ble peripheral:(CBPeripheral *)peer didDiscoverServices:nil];
    assert(ble.rejected.count==0 && manager.cancellations==0 && ble.nextDiscovery>0);
    [ble retryDiscoveryAtTime:ble.nextDiscovery-0.01]; assert(peer.discoveries==1);
    [ble retryDiscoveryAtTime:ble.nextDiscovery]; assert(peer.discoveries==2);
    CBMutableService *service=[[CBMutableService alloc] initWithType:[CBUUID UUIDWithString:DMInputService] primary:YES];
    peer.services=@[service];
    [ble peripheral:(CBPeripheral *)peer didDiscoverServices:nil];
    assert(peer.characteristicDiscoveries==1 && ble.inputService==service);
    // A cached service can also have missing attributes until Service Changed arrives.
    [ble peripheral:(CBPeripheral *)peer didDiscoverCharacteristicsForService:service error:nil];
    assert(ble.rejected.count==0 && ble.nextDiscovery>0);
    [ble peripheral:(CBPeripheral *)peer didModifyServices:@[service]];
    assert(ble.inputService==nil && ble.nextDiscovery>0);
    [ble retryDiscoveryAtTime:ble.nextDiscovery];
    CBMutableService *fresh=[[CBMutableService alloc] initWithType:service.UUID primary:YES];
    NSMutableArray *attributes=[NSMutableArray array];
    for (NSString *uuid in @[DMInputCharacteristic,DMInputProof,DMInputReturn,DMInputKey,DMInputClock,DMInputResume,DMInputReplay]) {
        [attributes addObject:[[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:uuid]
            properties:CBCharacteristicPropertyRead|CBCharacteristicPropertyWrite value:nil
            permissions:CBAttributePermissionsReadable|CBAttributePermissionsWriteable]];
    }
    fresh.characteristics=attributes; peer.services=@[fresh];
    [ble peripheral:(CBPeripheral *)peer didDiscoverServices:nil];
    [ble peripheral:(CBPeripheral *)peer didDiscoverCharacteristicsForService:service error:nil];
    assert(peer.reads==0); // Ignore late discovery from the invalidated service.
    [ble peripheral:(CBPeripheral *)peer didDiscoverCharacteristicsForService:fresh error:nil];
    assert(peer.reads==1 && ble.nonceCharacteristic!=nil && !ble.ready && ble.rejected.count==0);
    // Late values from the invalidated service cannot reject the current session.
    CBMutableCharacteristic *obsolete=[[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:DMInputKey]
        properties:CBCharacteristicPropertyRead value:nil permissions:CBAttributePermissionsReadable];
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:obsolete error:nil];
    assert(ble.rejected.count==0);
    // Even when discovery recovers, an invalid pairing proof still rejects it.
    ble.challenge=[NSMutableData dataWithLength:16];
    CBMutableCharacteristic *proof=(CBMutableCharacteristic *)ble.proof;
    proof.value=[NSMutableData dataWithLength:31];
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:proof error:nil];
    assert(ble.rejected.count==1 && manager.cancellations==1);

    DMBleInputTransport *expired=[DMBleInputTransport new];
    expired.manager=(CBCentralManager *)manager; expired.peripheral=(CBPeripheral *)peer;
    expired.rejected=[NSMutableSet set]; expired.discoveryDeadline=NSDate.timeIntervalSinceReferenceDate-1;
    peer.services=@[];
    [expired peripheral:(CBPeripheral *)peer didDiscoverServices:nil];
    assert(expired.rejected.count==1 && manager.cancellations==2 && expired.nextDiscovery==0);
    expired.closed=YES; expired.nextDiscovery=1;
    NSUInteger count=peer.discoveries;
    [expired retryDiscoveryAtTime:2]; assert(peer.discoveries==count);
    puts("BLE startup: delayed service, stale attributes, Service Changed, bounded retries and authentication rejection passed");
}

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
    [bridge acknowledgeVideoAtTime:10.41]; assert(ble.requests==4 && ble.received==32768);
    [bridge acknowledgeVideoAtTime:10.62]; assert(ble.requests==4); // No busy Wi-Fi ACKs when idle.
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

static void TestPeerAddressFragments(void) {
    DMStartupBridge *bridge=[DMStartupBridge new];
    assert([bridge bleInputReceived:[NSData dataWithBytes:"DMBT0005" length:8]]);
    uint8_t envelope[37]={3,0,0,0,32};
    memcpy(envelope+5,"DMIP0001",8); envelope[13]=4;
    envelope[14]=100; envelope[15]=108; envelope[16]=251; envelope[17]=24;
    envelope[30]=0xB2; envelope[31]=0x6E; // Bound UDP port 45678.
    for (unsigned i=0;i<sizeof(envelope);++i)
        assert([bridge bleInputReceived:[NSData dataWithBytes:envelope+i length:1]]);
    assert(bridge.peerAddresses.count==1 && bridge.controlPending.length==0 && bridge.videoReceived==0);
    NSData *record=bridge.peerAddresses.firstObject;
    const uint8_t *bytes=record.bytes;
    assert(bytes[8]==4 && bytes[9]==100 && bytes[12]==24 && ((unsigned)bytes[25]<<8|bytes[26])==45678);
    // Repeated publications deduplicate; a new snapshot clears previous routes.
    assert([bridge bleInputReceived:[NSData dataWithBytes:envelope length:sizeof(envelope)]]);
    assert(bridge.peerAddresses.count==1);
    memset(envelope+13,0,24);
    assert([bridge bleInputReceived:[NSData dataWithBytes:envelope length:sizeof(envelope)]]);
    assert(bridge.peerAddresses.count==0);
    envelope[13]=9;
    assert(![bridge bleInputReceived:[NSData dataWithBytes:envelope length:sizeof(envelope)]]);
    puts("BLE peer addresses: fragmented Tailscale hints, deduplication, reset, invalid family and decoder isolation passed");
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
        // Model direct discovery longer than the former two-second budget.
        [NSThread sleepForTimeInterval:3];
        uint8_t hello[40]={0}; memcpy(hello,"DMWIFI04",8);
        assert(send(peer,hello,sizeof(hello),0)==sizeof(hello));
        uint8_t request[44]; assert(DMReadExact(peer,request,sizeof(request)));
        NSData *proof=DMUpgradeProof(bridge.pairingKey,"client",hello+8,request,12);
        assert(!memcmp(proof.bytes,request+12,32));
        NSData *preview=DMUpgradeProof(bridge.pairingKey,"preview server",hello+8,request,12);
        assert(send(peer,preview.bytes,32,0)==32);
        // Deliver three preview frames over time before accepting the cutoff.
        for (int i=0;i<3;++i) {
            [NSThread sleepForTimeInterval:0.12];
            const uint8_t frame[]={0,0,0,1,42,0,0,0,0};
            assert(send(peer,frame,sizeof(frame),0)==sizeof(frame));
        }
        uint8_t ready; assert(DMReadExact(peer,&ready,1) && ready==1);
        const uint32_t end=UINT32_MAX;
        assert(send(peer,&end,4,0)==4);
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
        // A loading client may already have consumed/closed the listener before
        // authentication completes. READY must use the retained bound port.
        DMStartupBridge *earlyClient = [DMStartupBridge new];
        DMVideoAckBLE *readyBLE = [DMVideoAckBLE new];
        readyBLE.ready = YES;
        earlyClient.ble = (DMBleInputTransport *)readyBLE;
        earlyClient.listener = -1;
        earlyClient.videoPort = 12345;
        earlyClient.controlPort = 12346;
        earlyClient.l2capReady = NO;
        [earlyClient announceReady]; assert(!earlyClient.announcedReady);
        earlyClient.l2capReady = YES;
        [earlyClient announceReady]; assert(earlyClient.announcedReady);
        DMClassicBridge *busyBridge = [DMClassicBridge new];
        [busyBridge receiveEvent:8];
        [busyBridge receiveEvent:8];
        assert(busyBridge.eventMask == 0x80); // Distinct, deduplicated startup rejection.
        TestActiveServiceRecovery();
        TestStalledCandidateRecovery();
        TestDelayedInputService();
        TestNativeClassicStreams();
        TestVideoAckCadence();
        TestDroppedADB();
        TestColdPeerConnection();
        TestPeerAddressFragments();
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
