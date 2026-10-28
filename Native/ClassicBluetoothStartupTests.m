// Compile with BleInputQueue.m, BleInputCrypto.c and ClassicBluetoothWire.c,
// linking Foundation, AVFoundation, IOBluetooth, CoreBluetooth and Security.
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
@property(nonatomic, strong) NSData *lastWrite;
@property(nonatomic) NSUInteger writes;
@property(nonatomic) NSUInteger subscriptions;
@end
@implementation DMStartupPeripheral
- (void)discoverServices:(NSArray *)services { ++_discoveries; }
- (void)discoverCharacteristics:(NSArray *)characteristics forService:(id)service { ++_characteristicDiscoveries; }
- (void)readValueForCharacteristic:(id)characteristic { ++_reads; }
- (void)setNotifyValue:(BOOL)enabled forCharacteristic:(id)characteristic { assert(enabled); ++_subscriptions; }
- (NSUInteger)maximumWriteValueLengthForType:(CBCharacteristicWriteType)type { return 512; }
- (void)writeValue:(NSData *)value forCharacteristic:(id)characteristic type:(CBCharacteristicWriteType)type { self.lastWrite=value; ++self.writes; }
@end

@interface DMIndicatedCharacteristic : CBMutableCharacteristic
@property(nonatomic) BOOL subscribed;
@end
@implementation DMIndicatedCharacteristic
- (BOOL)isNotifying { return self.subscribed; }
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
@property(nonatomic, strong) NSData *sent;
@end
@implementation DMVideoAckBLE
- (BOOL)acknowledgeVideo:(uint64_t)count { ++_requests; _received=count; return YES; }
- (BOOL)send:(NSData *)bytes { self.sent=[bytes copy]; return YES; }
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

@interface DMWirelessAppearanceBridge : DMStreamBridge
- (BOOL)feedWireless:(const uint8_t *)bytes length:(size_t)length;
@end
@implementation DMWirelessAppearanceBridge
- (BOOL)feedWireless:(const uint8_t *)bytes length:(size_t)length {
    return dm_classic_wire_feed_ble(&_wifiWire,bytes,length,DMVideo,DMEvent,NULL,NULL,(__bridge void *)self);
}
@end

static void TestWirelessStartupAppearance(void) {
    NSData *appearance=[@"{\"deviceName\":\"Pixel\",\"hasCameraCutout\":\"true\"}\n" dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t video[]={0,42,0,7};
    NSMutableData *stream=[NSMutableData data];
    uint8_t type=4; uint32_t length=htonl((uint32_t)appearance.length);
    [stream appendBytes:&type length:1]; [stream appendBytes:&length length:4]; [stream appendData:appearance];
    type=0; length=htonl(sizeof(video));
    [stream appendBytes:&type length:1]; [stream appendBytes:&length length:4]; [stream appendBytes:video length:sizeof(video)];
    const size_t fragments[]={1,2,7,4096};
    for (size_t i=0;i<sizeof(fragments)/sizeof(fragments[0]);++i) {
        DMWirelessAppearanceBridge *bridge=[DMWirelessAppearanceBridge new];
        [bridge prepareWirelessVideo];
        for (size_t offset=0;offset<stream.length;) {
            size_t take=MIN(fragments[i],stream.length-offset);
            assert([bridge feedWireless:(const uint8_t *)stream.bytes+offset length:take]);
            offset+=take;
        }
        assert(bridge.appearanceBuffer.length==0);
        assert([bridge.videoBytes isEqualToData:[NSData dataWithBytes:video length:sizeof(video)]]);
        // Enabling metadata on Wi-Fi must retain JSON validation.
        const uint8_t invalid[]={4,0,0,0,2,'x','\n'};
        assert(![bridge feedWireless:invalid length:sizeof(invalid)]);
    }
    puts("Wireless startup appearance: metadata before first video, fragmented/coalesced records, decoder isolation and invalid JSON rejection passed");
}

// Keep regression tests away from real pairing preferences and radio managers.
@interface DMDiscoveryTestTransport : DMBleInputTransport
@property(nonatomic, strong) NSUUID *trustedPeer;
@end
@implementation DMDiscoveryTestTransport
- (instancetype)init {
    if ((self=[super init])) self.pairingKey=[NSMutableData dataWithLength:32];
    return self;
}
- (NSUUID *)rememberedPeer { return self.trustedPeer; }
- (void)rememberAuthenticatedPeer:(NSUUID *)peer { self.trustedPeer=peer; }
@end

@interface DMRecoveryTransport : DMDiscoveryTestTransport
@property(nonatomic, strong) NSString *failure;
@property(nonatomic) NSUInteger readyCount;
@property(nonatomic) BOOL drainEnabled;
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
- (void)drain { if (self.drainEnabled) [super drain]; } // Test controls ATT completions explicitly.
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

static void TestInputReadFairness(void) {
    DMRecoveryTransport *ble=[DMRecoveryTransport new];
    DMStartupPeripheral *peer=[DMStartupPeripheral new];
    ble.peripheral=(CBPeripheral *)peer; ble.pending=[DMBleInputQueue new];
    ble.pairingKey=[NSMutableData dataWithLength:32]; ble.sessionNonce=[NSMutableData dataWithLength:32];
    CBMutableCharacteristic *nonce=[[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:DMInputKey]
        properties:CBCharacteristicPropertyRead value:ble.sessionNonce permissions:CBAttributePermissionsReadable];
    ble.nonceCharacteristic=nonce;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:nonce error:nil];
    CBMutableService *service=RecoveryService();
    ble.input=service.characteristics[0]; ble.returning=service.characteristics[2];
    ble.ready=YES; ble.sequence=1; ble.receiveSequence=1; ble.drainEnabled=YES;
    [ble drain]; assert(ble.readPending);
    // A continuous return stream and continuous keys must each make progress.
    const uint8_t key[]={0,0,0,0,14, 0,0,0,0,0,29,0,0,0,0,0,0,0,0};
    NSData *record=[NSData dataWithBytes:key length:sizeof(key)];
    for (NSUInteger i=0;i<100;++i) {
        assert([ble.pending appendRecords:record]);
        NSUInteger writes=peer.writes, reads=peer.reads;
        [ble drain]; assert(peer.writes==writes); // Never overlap ATT operations.
        CBMutableCharacteristic *returning=(CBMutableCharacteristic *)ble.returning;
        returning.value=[ble testReturnPacket];
        [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:returning error:nil];
        assert(ble.writePending && !ble.readPending && peer.writes==writes+1);
        assert(peer.reads==reads && !ble.pending.hasWork);
        DMBleInputKeys keys=[ble testKeys:NO]; uint8_t plain[sizeof(key)];
        assert(dm_ble_input_open(&keys,i+1,peer.lastWrite.bytes,peer.lastWrite.length,plain));
        assert(!memcmp(plain,key,sizeof(key))); // Order and authenticated sequences survive interleaving.
        [ble peripheral:(CBPeripheral *)peer didWriteValueForCharacteristic:ble.input error:nil];
        assert(ble.readPending && !ble.writePending && peer.reads==reads+1);
    }
    // With no input, replies still drain immediately and an empty read backs off.
    CBMutableCharacteristic *returning=(CBMutableCharacteristic *)ble.returning;
    returning.value=[ble testReturnPacket]; NSUInteger reads=peer.reads;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:returning error:nil];
    assert(ble.readPending && peer.reads==reads+1);
    returning.value=[NSData data];
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:returning error:nil];
    assert(!ble.readPending && !ble.writePending && !ble.failure);
    puts("BLE fairness: 100 authenticated input/return turns, no overlapping ATT, immediate reply draining and idle backoff passed");
}

static void TestIndicatedReturnsDoNotBlockInput(void) {
    DMRecoveryTransport *ble=[DMRecoveryTransport new];
    DMStartupPeripheral *peer=[DMStartupPeripheral new];
    ble.peripheral=(CBPeripheral *)peer; ble.pending=[DMBleInputQueue new];
    ble.sessionNonce=[NSMutableData dataWithLength:32];
    CBMutableCharacteristic *nonce=[[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:DMInputKey]
        properties:CBCharacteristicPropertyRead value:ble.sessionNonce permissions:CBAttributePermissionsReadable];
    ble.nonceCharacteristic=nonce;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:nonce error:nil];
    CBMutableService *service=RecoveryService();
    ble.input=service.characteristics[0]; ble.clockCharacteristic=service.characteristics[4];
    DMIndicatedCharacteristic *returning=[[DMIndicatedCharacteristic alloc] initWithType:[CBUUID UUIDWithString:DMInputReturn]
        properties:CBCharacteristicPropertyRead|CBCharacteristicPropertyIndicate value:nil permissions:CBAttributePermissionsReadable];
    ble.returning=returning; ble.proofVerified=YES; ble.sequence=1; ble.receiveSequence=1; ble.drainEnabled=YES;
    ((CBMutableCharacteristic *)ble.clockCharacteristic).value=[ble testClock];
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:ble.clockCharacteristic error:nil];
    assert(!ble.ready && ble.awaitingReturnSubscription && peer.subscriptions==1);
    returning.subscribed=YES;
    [ble peripheral:(CBPeripheral *)peer didUpdateNotificationStateForCharacteristic:returning error:nil];
    assert(ble.ready && ble.returnIndications && ble.readyCount==1);
    NSUInteger reads=peer.reads, writes=peer.writes;
    // No return packets for a long period: ACK/input writes must still progress.
    for (NSUInteger i=0;i<100;++i) {
        ble.nextRead=0;
        [ble.pending acknowledgeVideo:(i+1)*1024]; [ble drain];
        assert(ble.writePending && !ble.readPending && peer.writes==writes+i+1);
        [ble peripheral:(CBPeripheral *)peer didWriteValueForCharacteristic:ble.input error:nil];
        assert(!ble.writePending && !ble.readPending && peer.reads==reads && !ble.failure);
    }
    [ble.pending acknowledgeVideo:103424]; [ble drain]; assert(ble.writePending);
    NSTimeInterval started=ble.progress;
    NSData *packet=[ble testReturnPacket]; returning.value=packet;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:returning error:nil];
    assert(ble.receiveSequence==2 && [ble.delivered isEqual:[NSData dataWithBytes:"x" length:1]]);
    assert(ble.writePending && !ble.readPending && peer.reads==reads && ble.progress==started);
    // Indications do not reset pending-write progress, and replays still fail.
    returning.value=packet;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:returning error:nil];
    assert([ble.failure containsString:@"Invalid BLE return record"] && ble.receiveSequence==2);
    ble.failure=nil; ble.inputService=service;
    [ble peripheral:(CBPeripheral *)peer didModifyServices:@[service]];
    assert(ble.recovering && ble.recoveryNeedsReturn && !ble.returnIndications && !ble.readPending);
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:returning error:nil];
    assert(!ble.failure && ble.receiveSequence==2); // Discard callbacks from invalidated attributes.
    ble.recovering=NO; ble.returning=returning; ble.awaitingReturnSubscription=YES;
    returning.subscribed=NO;
    [ble peripheral:(CBPeripheral *)peer didUpdateNotificationStateForCharacteristic:returning error:nil];
    assert([ble.failure containsString:@"subscription failed"] && !ble.ready);
    puts("BLE indicated returns: subscription before READY, 100 independent ACKs, authenticated receive, replay rejection, stale callbacks and bounded subscription failure passed");
}

static void TestDelayedVideoAcknowledgement(void) {
    DMRecoveryTransport *ble=[DMRecoveryTransport new];
    DMStartupPeripheral *peer=[DMStartupPeripheral new];
    ble.peripheral=(CBPeripheral *)peer; ble.pending=[DMBleInputQueue new];
    ble.sessionNonce=[NSMutableData dataWithLength:32];
    CBMutableCharacteristic *nonce=[[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:DMInputKey]
        properties:CBCharacteristicPropertyRead value:ble.sessionNonce permissions:CBAttributePermissionsReadable];
    ble.nonceCharacteristic=nonce;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:nonce error:nil];
    CBMutableService *service=RecoveryService();
    ble.input=service.characteristics[0]; ble.returning=service.characteristics[2];
    ble.ready=YES; ble.sequence=1; ble.drainEnabled=YES;
    ble.nextRead=NSDate.timeIntervalSinceReferenceDate+1000;
    peer.writes=0;
    [ble.pending acknowledgeVideo:1024]; [ble drain];
    assert(ble.writePending && peer.writes==1 && ble.sequence==2);
    NSTimeInterval started=ble.progress;
    NSData *inFlight=peer.lastWrite;
    // Capture startup can delay the ATT completion beyond two seconds even
    // after Android accepted the heartbeat. Queue/coalesce newer frame ACKs.
    [ble.pending acknowledgeVideo:2048];
    [ble.pending acknowledgeVideo:4096];
    [ble drain];
    [ble checkOperationProgressAtTime:started+2.8];
    assert(!ble.failure && peer.writes==1 && ble.sequence==2);
    assert([peer.lastWrite isEqual:inFlight]); // No ambiguous ciphertext retry.
    [ble peripheral:(CBPeripheral *)peer didWriteValueForCharacteristic:ble.input error:nil];
    assert(!ble.failure && ble.writePending && peer.writes==2 && ble.sequence==3);
    DMBleInputKeys keys=[ble testKeys:NO]; uint8_t plain[13];
    assert(peer.lastWrite.length==sizeof(plain)+24);
    assert(dm_ble_input_open(&keys,2,peer.lastWrite.bytes,peer.lastWrite.length,plain));
    const uint8_t expected[]={1,0,0,0,8,0,0,0,0,0,0,0x10,0};
    assert(!memcmp(plain,expected,sizeof(expected)));
    [ble peripheral:(CBPeripheral *)peer didWriteValueForCharacteristic:ble.input error:nil];
    assert(!ble.writePending && !ble.pending.hasWork);
    [ble checkOperationProgressAtTime:ble.progress+100];
    assert(!ble.failure); // Idle time is not a stalled operation.
    ble.nextRead=0; [ble drain]; assert(ble.readPending);
    [ble checkOperationProgressAtTime:ble.progress+4.3];
    assert([ble.failure containsString:@"BLE operation stalled"]);
    ble.failure=nil; ble.recovering=YES;
    [ble checkOperationProgressAtTime:ble.progress+100]; assert(!ble.failure);
    puts("BLE delayed ACK: startup latency, coalesced cumulative progress, authenticated ordering, no duplicate writes and bounded failure passed");
}

static void TestInputSocketWakeup(void) {
    DMStartupBridge *bridge=[DMStartupBridge new];
    DMVideoAckBLE *ble=[DMVideoAckBLE new]; ble.ready=YES;
    bridge.ble=(DMBleInputTransport *)ble;
    bridge.outgoing=[NSMutableData data]; bridge.controlPending=[NSMutableData data];
    bridge.controlClient=-1;
    int listener=socket(AF_INET,SOCK_STREAM,0); assert(listener>=0);
    struct sockaddr_in address={.sin_len=sizeof(address),.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    assert(!bind(listener,(struct sockaddr *)&address,sizeof(address)) && !listen(listener,1));
    socklen_t length=sizeof(address); assert(!getsockname(listener,(struct sockaddr *)&address,&length));
    int client=socket(AF_INET,SOCK_STREAM,0); assert(client>=0);
    assert(!connect(client,(struct sockaddr *)&address,sizeof(address)));
    bridge.controlListener=listener;
    [bridge pollControl]; assert(bridge.controlReadSource && bridge.controlClient>=0);
    int noDelay=0; length=sizeof(noDelay);
    assert(!getsockopt(bridge.controlClient,IPPROTO_TCP,TCP_NODELAY,&noDelay,&length) && noDelay);
    const uint8_t input[]={0,1,2}; assert(send(client,input,sizeof(input),0)==sizeof(input));
    // No housekeeping timer or manual poll: socket readiness alone must forward input.
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:1];
    while (!ble.sent && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    const uint8_t expected[]={0,0,0,0,3,0,1,2};
    assert([ble.sent isEqual:[NSData dataWithBytes:expected length:sizeof(expected)]]);
    dispatch_source_cancel(bridge.controlReadSource); bridge.controlReadSource=nil;
    bridge.controlClient=-1; close(client); // The source closes its descriptor after cancellation.
    puts("Input socket: readiness forwards input without the polling timer; TCP_NODELAY enabled");
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
    // Reproduce service invalidation after only 20 of 39 framed bytes.
    NSMutableData *partial=[NSMutableData dataWithLength:39];
    ((uint8_t *)partial.mutableBytes)[1]=37;
    ble.commandFrame=partial; ble.commandOffset=20;
    NSData *outstanding=[partial subdataWithRange:NSMakeRange(2,37)];
    NSData *lostReturn=[ble testReturnPacket];
    CBMutableCharacteristic *returning=(CBMutableCharacteristic *)ble.returning;
    [ble peripheral:(CBPeripheral *)peer didModifyServices:@[old]];
    assert(!ble.ready && ble.recovering && !ble.failure && peer.discoveries==1);
    assert(!ble.commandFrame && !ble.commandOffset && [ble.inFlightPacket isEqual:outstanding]);
    assert(ble.reliableAfterFragmentRecovery); // Older phones may retain their partial buffer.
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
    // The server may still be notifying while the Mac reads the replacement
    // nonce. A reused characteristic must not route that return to proof parsing.
    CBMutableCharacteristic *earlyReturn=(CBMutableCharacteristic *)ble.returning;
    earlyReturn.value=lostReturn;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:earlyReturn error:nil];
    CBMutableCharacteristic *earlyClock=(CBMutableCharacteristic *)ble.clockCharacteristic;
    earlyClock.value=[NSMutableData dataWithLength:40];
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:earlyClock error:nil];
    assert(!ble.failure && ble.recovering && !ble.proofVerified && ble.receiveSequence==23 && !ble.delivered);
    CBMutableCharacteristic *nonce=(CBMutableCharacteristic *)ble.nonceCharacteristic;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:nonce
        error:[NSError errorWithDomain:CBATTErrorDomain code:CBATTErrorInvalidHandle userInfo:nil]];
    assert(ble.recovering && !ble.failure && ble.nextDiscovery>0 && ble.recoveryDeadline==deadline);
    [ble retryDiscoveryAtTime:ble.nextDiscovery+0.01];
    [ble peripheral:(CBPeripheral *)peer didDiscoverServices:nil];
    [ble peripheral:(CBPeripheral *)peer didDiscoverCharacteristicsForService:fresh error:nil];
    nonce=(CBMutableCharacteristic *)ble.nonceCharacteristic;
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
        NSData *originalPacket=ble.inFlightPacket;
        NSUInteger writes=peer.writes; ble.drainEnabled=YES;
        clock.value=[ble testClock];
        [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:clock error:nil];
        assert(ble.ready && !ble.failure && ble.sequence==17);
        if (!accepted) {
            assert(peer.writes==writes+1 && [peer.lastWrite isEqual:originalPacket] && ble.writePending);
            [ble peripheral:(CBPeripheral *)peer didWriteValueForCharacteristic:ble.input error:nil];
            assert(!ble.inFlightPacket && !ble.writePending && ble.sequence==17);
        } else assert(peer.writes==writes); // Already-accepted input is never resent.
        ble.drainEnabled=NO;
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
    DMBleInputTransport *ble=[DMDiscoveryTestTransport new];
    DMStartupManager *manager=[DMStartupManager new];
    DMStartupPeripheral *stalled=[DMStartupPeripheral new]; stalled.identifier=[NSUUID UUID];
    DMStartupPeripheral *live=[DMStartupPeripheral new]; live.identifier=[NSUUID UUID];
    ble.manager=(CBCentralManager *)manager; ble.rejected=[NSMutableSet set];
    NSDictionary *advertisement=@{CBAdvertisementDataServiceUUIDsKey: @[[CBUUID UUIDWithNSUUID:ble.discoveryUUID]]};
    [ble centralManager:(CBCentralManager *)manager didDiscoverPeripheral:(CBPeripheral *)stalled advertisementData:advertisement RSSI:@0];
    NSTimeInterval deadline=ble.candidateConnectionDeadline;
    [ble recoverConnectingCandidateAtTime:deadline-0.01];
    assert(ble.peripheral==(CBPeripheral *)stalled && manager.cancellations==0);
    // The phone's new identity becomes a system-connected link while the old
    // advertising identity is still silently retrying in CoreBluetooth.
    manager.connected=@[stalled,live];
    [ble recoverConnectingCandidateAtTime:deadline];
    assert(manager.cancellations==1 && ble.peripheral==nil); // Unknown cached links are never probed.
    [ble centralManager:(CBCentralManager *)manager didDiscoverPeripheral:(CBPeripheral *)live advertisementData:advertisement RSSI:@0];
    assert(ble.peripheral==(CBPeripheral *)live && manager.candidate==live);
    assert(ble.rejected.count==0 && [ble.deferredCandidate isEqual:stalled.identifier]);
    [ble centralManager:(CBCentralManager *)manager didConnectPeripheral:(CBPeripheral *)stalled];
    [ble centralManager:(CBCentralManager *)manager didDisconnectPeripheral:(CBPeripheral *)stalled error:nil];
    assert(ble.peripheral==(CBPeripheral *)live && live.discoveries==0);
    [ble centralManager:(CBCentralManager *)manager didConnectPeripheral:(CBPeripheral *)live];
    assert(live.discoveries==1 && ble.candidateConnectionDeadline==0);
    [ble recoverConnectingCandidateAtTime:deadline+100];
    assert(manager.cancellations==1 && ble.peripheral==(CBPeripheral *)live);

    DMBleInputTransport *cancelled=[DMDiscoveryTestTransport new];
    cancelled.manager=(CBCentralManager *)manager; cancelled.peripheral=(CBPeripheral *)stalled;
    cancelled.candidateConnectionDeadline=1; cancelled.closed=YES;
    [cancelled recoverConnectingCandidateAtTime:2]; assert(manager.cancellations==1);
    DMBleInputTransport *slow=[DMDiscoveryTestTransport new];
    DMStartupManager *slowManager=[DMStartupManager new]; slowManager.connected=@[stalled];
    slow.manager=(CBCentralManager *)slowManager; slow.rejected=[NSMutableSet set];
    ((DMDiscoveryTestTransport *)slow).trustedPeer=stalled.identifier;
    slow.peripheral=(CBPeripheral *)stalled; slow.candidateConnectionDeadline=NSDate.timeIntervalSinceReferenceDate;
    [slow recoverConnectingCandidateAtTime:slow.candidateConnectionDeadline];
    assert(slow.peripheral==nil && slow.rejected.count==0);
    [slow recoverConnectingCandidateAtTime:slow.candidateRetryAfter];
    assert(slow.peripheral==(CBPeripheral *)stalled); // A slow valid phone isn't permanently excluded.
    puts("BLE startup: stalled identity replaced by live link, cooldown retry, late callbacks and cancellation passed");
}

static void TestDelayedInputService(void) {
    DMBleInputTransport *ble=[DMDiscoveryTestTransport new];
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
    assert(!ble.pairingProofRejected); // A malformed response isn't a code mismatch.

    // A complete but incorrect proof marks a mismatch; a later matching phone
    // clears it so unrelated failures cannot inherit the pairing diagnosis.
    ble.proof=proof; ble.challenge=[NSMutableData dataWithLength:16];
    DMBleInputKeys keys={0}; uint8_t expected[32];
    dm_ble_input_proof(&keys,ble.challenge.bytes,expected);
    NSMutableData *wrong=[NSMutableData dataWithBytes:expected length:sizeof(expected)];
    ((uint8_t *)wrong.mutableBytes)[0]^=1; proof.value=wrong;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:proof error:nil];
    assert(ble.pairingProofRejected && !ble.proofVerified && !ble.ready);
    ble.proof=proof; ble.challenge=[NSMutableData dataWithLength:16];
    proof.value=[NSData dataWithBytes:expected length:sizeof(expected)];
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:proof error:nil];
    assert(!ble.pairingProofRejected && ble.proofVerified);

    DMBleInputTransport *expired=[DMDiscoveryTestTransport new];
    expired.manager=(CBCentralManager *)manager; expired.peripheral=(CBPeripheral *)peer;
    expired.rejected=[NSMutableSet set]; expired.discoveryDeadline=NSDate.timeIntervalSinceReferenceDate-1;
    peer.services=@[];
    [expired peripheral:(CBPeripheral *)peer didDiscoverServices:nil];
    assert(expired.rejected.count==1 && manager.cancellations==3 && expired.nextDiscovery==0);
    expired.closed=YES; expired.nextDiscovery=1;
    NSUInteger count=peer.discoveries;
    [expired retryDiscoveryAtTime:2]; assert(peer.discoveries==count);
    puts("BLE startup: delayed service, stale attributes, Service Changed, bounded retries and authentication rejection passed");
}

@interface DMClosingClassicPeer : NSObject
@property(nonatomic) NSUInteger closes;
@property(nonatomic) uint16_t closedPSM;
@property(nonatomic) BOOL callbackCleared;
@end
@implementation DMClosingClassicPeer
- (void)closeL2CAPChannel:(uint16_t)psm { ++_closes; _closedPSM=psm; }
- (void)setConnectL2CAPCallback:(void (^)(id, NSInteger))callback { assert(callback==nil); _callbackCleared=YES; }
@end

static void TestNativeClassicStreams(void) {
    const uint8_t bytes[] = {'D','M','B','T','0','0','0','6',0,0,0,0,3,'a','b','c'};
    DMStreamChannel *raw = [DMStreamChannel new];
    raw.inputStream = [NSInputStream inputStreamWithData:[NSData dataWithBytes:bytes length:sizeof(bytes)]];
    raw.outputStream = [NSOutputStream outputStreamToMemory];
    DMStreamBridge *bridge = [DMStreamBridge new];
    DMClosingClassicPeer *classic=[DMClosingClassicPeer new];
    bridge.classicPeer=classic; bridge.psm=DMServicePSM;
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
    assert(classic.closes==1 && classic.closedPSM==DMServicePSM && classic.callbackCleared && !bridge.classicPeer);
    [bridge closeClassicStreams]; assert(classic.closes==1);
    DMStreamBridge *pending=[DMStreamBridge new]; pending.psm=DMServicePSM;
    pending.classicPeer=classic; pending.openingL2cap=YES;
    [pending closeClassicStreams]; assert(classic.closes==2); // Cancel an unfinished open too.
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
    for (int silent=0; silent<4; ++silent) {
    int video[2], output[2]; assert(!socketpair(AF_UNIX,SOCK_STREAM,0,video));
    assert(!socketpair(AF_UNIX,SOCK_STREAM,0,output));
    DMStartupBridge *bridge=[DMStartupBridge new];
    DMFallbackBLE *ble=[DMFallbackBLE new]; bridge.ble=(DMBleInputTransport *)ble;
    bridge.commands=[NSMutableData data]; bridge.pending=[NSMutableData data];
    fcntl(video[1],F_SETFL,O_NONBLOCK); // Match the production candidate socket.
    bridge.wifiSocket=video[1]; bridge.client=output[1]; bridge.wifiActive=YES;
    bridge.announcedReady=silent!=3;
    bridge.wifiNonce=[NSMutableData dataWithLength:32]; bridge.videoReceived=123;
    bridge.wifiLastData=NSDate.timeIntervalSinceReferenceDate-((silent==1 || silent==3) ? 5 : 0);
    if (silent==2) {
        bridge.wifiIsPeer=YES;
        uint64_t now=(uint64_t)(NSProcessInfo.processInfo.systemUptime*1e9);
        for (int i=0;i<7;i++) { [bridge recordLatency:now wireless:NO]; [bridge recordLatency:now-200000000 wireless:YES]; }
        assert(bridge.latencyBadSince>0);
        bridge.latencyBadSince-=3;
    }
    if (silent==3) {
        [bridge pollWiFi];
        assert(bridge.wifiSocket==video[1] && bridge.wifiActive && !bridge.wifiRecovering);
        bridge.wifiLastData-=11; // Initial path has a bounded 15-second capture budget.
    }
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

@interface DMInitialBridge : DMStartupBridge
@property(nonatomic) NSUInteger bleStarts;
@end
@implementation DMInitialBridge
- (void)startBleWhenAndroidReady { ++_bleStarts; }
@end

static void TestColdPeerConnection(BOOL slow, BOOL initial) {
    int listener=socket(AF_INET,SOCK_STREAM,0); assert(listener>=0);
    struct sockaddr_in address={0}; address.sin_family=AF_INET;
    address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    assert(!bind(listener,(struct sockaddr *)&address,sizeof(address)) && !listen(listener,1));
    socklen_t size=sizeof(address); assert(!getsockname(listener,(struct sockaddr *)&address,&size));
    DMStartupBridge *bridge=initial ? [DMInitialBridge new] : [DMStartupBridge new];
    bridge.wifiSocket=-1; bridge.peerPort=ntohs(address.sin_port);
    bridge.pairingKey=[NSMutableData dataWithLength:32];
    bridge.wirelessProfile=[NSMutableData dataWithLength:12];
    dispatch_semaphore_t completed=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        int peer=accept(listener,NULL,NULL); assert(peer>=0);
        int yes=1; setsockopt(peer,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
        // Model direct discovery longer than the former two-second budget.
        [NSThread sleepForTimeInterval:slow ? 0 : 3];
        uint8_t hello[40]={0}; memcpy(hello,initial ? "DMWIFI06" : "DMWIFI05",8);
        assert(send(peer,hello,sizeof(hello),0)==sizeof(hello));
        uint8_t request[44]; assert(DMReadExact(peer,request,sizeof(request)));
        NSData *proof=DMUpgradeProof(bridge.pairingKey,"client",hello+8,request,12);
        assert(!memcmp(proof.bytes,request+12,32));
        NSData *preview=DMUpgradeProof(bridge.pairingKey,"preview server",hello+8,request,12);
        assert(send(peer,preview.bytes,32,0)==32);
        if (!initial) {
            // Deliver three preview frames over time before accepting the cutoff.
            for (int i=0;i<3;++i) {
                [NSThread sleepForTimeInterval:0.12];
                uint64_t stamp=CFSwapInt64HostToBig((uint64_t)(NSProcessInfo.processInfo.systemUptime*1e9));
                dispatch_sync(dispatch_get_main_queue(), ^{ [bridge recordLatency:CFSwapInt64BigToHost(stamp) wireless:NO]; });
                if (slow) [NSThread sleepForTimeInterval:0.08];
                const uint32_t marker=htonl((uint32_t)-2);
                assert(send(peer,&marker,4,0)==4 && send(peer,&stamp,8,0)==8);
                const uint8_t frame[]={0,0,0,1,42,0,0,0,0};
                assert(send(peer,frame,sizeof(frame),0)==sizeof(frame));
            }
            uint8_t ready;
            if (slow) {
                assert(!DMReadExact(peer,&ready,1));
                close(peer); close(listener); dispatch_semaphore_signal(completed); return;
            }
            assert(DMReadExact(peer,&ready,1) && ready==1);
            const uint32_t end=UINT32_MAX;
            assert(send(peer,&end,4,0)==4);
        } else {
            const uint32_t first=htonl((uint32_t)-3);
            assert(send(peer,&first,4,0)==4);
        }
        uint8_t response[48]={0};
        NSMutableData *authenticated=[bridge.wirelessProfile mutableCopy];
        [authenticated appendBytes:response length:8];
        NSData *server=DMUpgradeProof(bridge.pairingKey,initial ? "initial server" : "server",hello+8,authenticated.bytes,authenticated.length);
        memcpy(response+8,server.bytes,32); memcpy(response+40,"DMBT0006",8);
        assert(send(peer,response,sizeof(response),0)==sizeof(response));
        close(peer); close(listener); dispatch_semaphore_signal(completed);
    });
    [bridge probeWiFi:bridge.peerPort];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:6];
    do { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]]; }
    while (bridge.probingWiFi && deadline.timeIntervalSinceNow>0);
    if (slow) {
        assert(bridge.wifiSocket==-1 && !bridge.wifiActive && bridge.latencyRetryAfter>NSProcessInfo.processInfo.systemUptime);
        assert(!dispatch_semaphore_wait(completed,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)));
        puts("Slow Iroh preview: rejects continuously delivered frames before cutoff and cools down retries"); return;
    }
    assert(bridge.wifiSocket>=0 && bridge.wifiCutoff==0 && bridge.wifiNonce.length==32);
    if (initial) assert(bridge.wifiInitial && ((DMInitialBridge *)bridge).bleStarts==1 && !bridge.l2capReady);
    close(bridge.wifiSocket);
    assert(!dispatch_semaphore_wait(completed,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)));
    puts("Cold Iroh startup: delayed challenge survives discovery, authenticates and preserves video cutoff");
}

static int testUSBConnected(void *context) { return context==(void *)1; }
@interface DMUSBSelectionBridge : DMStartupBridge
@property(nonatomic) uint16_t probedPort;
@property(nonatomic) NSUInteger recoveries;
@end
@implementation DMUSBSelectionBridge
- (void)probeWiFi:(uint16_t)port { self.probedPort=port; }
- (void)fallbackToBluetooth { self.recoveries++; }
@end
@interface DMFlowControlledPeripheral : DMStartupPeripheral
@property(nonatomic) BOOL credit;
@property(nonatomic) CBCharacteristicWriteType lastType;
@property(nonatomic) NSUInteger commandLimit;
@property(nonatomic, strong) NSMutableData *submitted;
@end
@implementation DMFlowControlledPeripheral
- (BOOL)canSendWriteWithoutResponse { return self.credit; }
- (NSUInteger)maximumWriteValueLengthForType:(CBCharacteristicWriteType)type { return type==CBCharacteristicWriteWithoutResponse && self.commandLimit ? self.commandLimit : 182; }
- (void)writeValue:(NSData *)value forCharacteristic:(id)characteristic type:(CBCharacteristicWriteType)type {
    [super writeValue:value forCharacteristic:characteristic type:type];
    self.lastType=type; self.credit=NO; [self.submitted appendData:value];
}
@end
static void testStreamingInputFlowControl(void) {
    DMRecoveryTransport *ble=[DMRecoveryTransport new];
    DMFlowControlledPeripheral *peer=[DMFlowControlledPeripheral new];
    ble.peripheral=(CBPeripheral *)peer; ble.pending=[DMBleInputQueue new];
    ble.queue=dispatch_get_main_queue(); ble.sessionNonce=[NSMutableData dataWithLength:32];
    CBMutableCharacteristic *nonce=[[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:DMInputKey]
        properties:CBCharacteristicPropertyRead value:ble.sessionNonce permissions:CBAttributePermissionsReadable];
    ble.nonceCharacteristic=nonce;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:nonce error:nil];
    ble.input=[[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:DMInputCharacteristic]
        properties:CBCharacteristicPropertyWrite|CBCharacteristicPropertyWriteWithoutResponse value:nil permissions:CBAttributePermissionsWriteable];
    ble.ready=YES; ble.sequence=1; ble.drainEnabled=YES;
    ble.returnIndications=YES; peer.writes=0;
    [ble.pending acknowledgeVideo:1024]; [ble drain];
    assert(peer.writes==0 && ble.sequence==1 && ble.pending.hasWork);
    peer.credit=YES; [ble peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peer];
    assert(peer.writes==1 && peer.lastType==CBCharacteristicWriteWithoutResponse);
    assert(ble.sequence==2 && !ble.writePending && !ble.inFlightPacket);
    DMBleInputKeys keys=[ble testKeys:NO]; uint8_t plain[13];
    assert(dm_ble_input_open(&keys,1,peer.lastWrite.bytes,peer.lastWrite.length,plain));
    [ble.pending acknowledgeVideo:2048]; [ble drain];
    assert(peer.writes==1 && ble.sequence==2);
    peer.credit=YES; [ble peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peer];
    assert(peer.writes==2 && ble.sequence==3 && !ble.pending.hasWork);
    assert(dm_ble_input_open(&keys,2,peer.lastWrite.bytes,peer.lastWrite.length,plain));
    // A missing readiness callback must not leave unsent input stranded until
    // the lease/watchdog expires. The fallback seals a fresh reliable record.
    [ble.pending acknowledgeVideo:3072];
    ble.creditWaitSince=NSDate.timeIntervalSinceReferenceDate-0.5;
    [ble drain];
    assert(peer.writes==3 && peer.lastType==CBCharacteristicWriteWithResponse && ble.writePending);
    assert(dm_ble_input_open(&keys,3,peer.lastWrite.bytes,peer.lastWrite.length,plain));
    [ble peripheral:(CBPeripheral *)peer didWriteValueForCharacteristic:ble.input error:nil];
    assert(!ble.writePending && !ble.inFlightPacket);
    // A minimum-MTU link transports the same authenticated record as ordered
    // 20-byte commands, pausing mid-frame when radio credits run out.
    peer.commandLimit=20; peer.submitted=[NSMutableData data];
    [ble.pending acknowledgeVideo:4096]; peer.credit=YES; [ble drain];
    assert(ble.commandFrame.length && !ble.writePending && ble.sequence==5);
    NSUInteger partialWrites=peer.writes; [ble drain]; assert(peer.writes==partialWrites);
    while (ble.commandFrame.length) {
        peer.credit=YES; [ble peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peer];
        assert(peer.lastWrite.length<=20 && peer.lastType==CBCharacteristicWriteWithoutResponse);
    }
    assert(peer.submitted.length==39);
    uint16_t framed; memcpy(&framed,peer.submitted.bytes,2); assert(CFSwapInt16BigToHost(framed)==37);
    assert(dm_ble_input_open(&keys,4,(const uint8_t *)peer.submitted.bytes+2,37,plain));
    ble.closed=YES;
    puts("Streaming BLE input: respects radio credits, resumes on readiness, preserves encrypted sequence and never retries uncertain input");
}
static void testUSBSelection(void) {
    DMUSBSelectionBridge *bridge=[DMUSBSelectionBridge new];
    bridge.usbConnected=testUSBConnected; bridge.usbHandle=(void *)1; bridge.usbPort=12345;
    bridge.wifiSocket=-1;
    [bridge pollUSB]; assert(bridge.probedPort==12345);
    bridge.probedPort=0; bridge.wifiRecovering=YES;
    [bridge pollUSB]; assert(!bridge.probedPort);
    bridge.wifiRecovering=NO; bridge.wifiSocket=42; bridge.wifiActive=YES;
    [bridge pollUSB]; assert(bridge.recoveries==1);
    bridge.wifiIsUSB=YES;
    [bridge pollUSB]; assert(bridge.recoveries==1);
    bridge.usbHandle=NULL; bridge.wifiSocket=-1;
    [bridge pollUSB]; assert(!bridge.probedPort);
    puts("Automatic USB: prefers available USB, recovers network before switching, waits for recovery, and preserves active USB");
}

static void testAcknowledgedReturns(void) {
    DMRecoveryTransport *ble=[DMRecoveryTransport new];
    DMFlowControlledPeripheral *peer=[DMFlowControlledPeripheral new];
    ble.peripheral=(CBPeripheral *)peer; ble.pending=[DMBleInputQueue new];
    ble.queue=dispatch_get_main_queue();
    ble.pairingKey=[NSMutableData dataWithLength:32]; ble.sessionNonce=[NSMutableData dataWithLength:32];
    CBMutableCharacteristic *nonce=[[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:DMInputKey]
        properties:CBCharacteristicPropertyRead value:ble.sessionNonce permissions:CBAttributePermissionsReadable];
    ble.nonceCharacteristic=nonce;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:nonce error:nil];
    ble.input=[[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:DMInputCharacteristic]
        properties:CBCharacteristicPropertyWriteWithoutResponse value:nil permissions:CBAttributePermissionsWriteable];
    CBMutableCharacteristic *output=[[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:DMInputReturn]
        properties:CBCharacteristicPropertyNotify value:nil permissions:CBAttributePermissionsReadable];
    ble.returning=output; ble.ready=YES; ble.returnIndications=YES;
    ble.sequence=1; ble.receiveSequence=1; ble.drainEnabled=YES;
    peer.writes=0; // Exclude the authentication challenge from transport writes.
    NSData *packet=[ble testReturnPacket]; output.value=packet;
    // Exhausted radio credits retain the ACK; delivery still happens once.
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:output error:nil];
    assert(ble.receiveSequence==2 && ble.delivered.length==1 && peer.writes==0);
    assert(ble.pendingReturnAcknowledgement.unsignedLongLongValue==1);
    peer.credit=YES; [ble peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peer];
    DMBleInputKeys keys=[ble testKeys:NO]; uint8_t plain[13];
    assert(dm_ble_input_open(&keys,1,peer.lastWrite.bytes,peer.lastWrite.length,plain));
    const uint8_t expected[]={3,0,0,0,8,0,0,0,0,0,0,0,1};
    assert(!memcmp(plain,expected,sizeof(expected)));
    // Simulate a lost ACK and missing Android completion: exact retransmission
    // is re-ACKed under a NEW input nonce, without delivering its action again.
    ble.delivered=nil; peer.credit=YES;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:output error:nil];
    assert(!ble.delivered && ble.receiveSequence==2 && peer.writes==2);
    assert(dm_ble_input_open(&keys,2,peer.lastWrite.bytes,peer.lastWrite.length,plain));
    assert(!memcmp(plain,expected,sizeof(expected)));
    // A queued control/lease envelope can share the ACK's authenticated packet.
    [ble.pending acknowledgeVideo:1234];
    output.value=[ble testReturnPacket]; peer.credit=YES;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:output error:nil];
    uint8_t combined[26];
    assert(ble.receiveSequence==3 && peer.writes==3 && ble.delivered.length==1);
    assert(dm_ble_input_open(&keys,3,peer.lastWrite.bytes,peer.lastWrite.length,combined));
    assert(combined[0]==3 && combined[4]==8 && combined[12]==2);
    assert(combined[13]==1 && combined[17]==8 && !ble.pending.hasWork);
    ble.delivered=nil;
    // A modified old record is never accepted as a duplicate.
    NSMutableData *tampered=[packet mutableCopy]; ((uint8_t *)tampered.mutableBytes)[8]^=1;
    output.value=tampered;
    [ble peripheral:(CBPeripheral *)peer didUpdateValueForCharacteristic:output error:nil];
    assert(ble.failure && !ble.delivered && ble.receiveSequence==3 && peer.writes==3);
    puts("BLE acknowledged returns: lost ACK retried, action delivered once, fresh ACK nonces, flow control and tamper rejection passed");
}

static void testLiveVideoRecovery(void) {
    DMClassicBridge *bridge=[DMClassicBridge new];
    bridge.client=-1; bridge.pending=[NSMutableData data]; bridge.videoStartupRemaining=69;
    uint8_t startup[69]={0}; assert([bridge receiveVideo:startup length:69]);
    [bridge.pending setLength:0];
    uint8_t packet[16]={0}; packet[11]=4; packet[12]=1; packet[13]=2;
    assert([bridge receiveVideo:packet length:14]);
    assert(bridge.pending.length==0 && bridge.videoPacket.length==14);
    bridge.wifiNonce=[NSMutableData dataWithLength:32];
    DMClassicWire recovery; dm_classic_wire_init_video_only(&recovery);
    recovery.reset_video=DMResetVideo;
    const uint8_t reset[]={ 'D','M','B','T','0','0','0','6',8,0,0,0,8,0,0,0,0,0,0,3,232 };
    for (size_t i=0;i<sizeof(reset);i++)
        assert(dm_classic_wire_feed(&recovery,reset+i,1,DMVideo,DMEvent,(__bridge void *)bridge));
    assert(bridge.videoPacket.length==0 && bridge.videoReceived==1000);
    uint8_t session[12]={0x80,0,0,0,0,0,1,64,0,0,2,128};
    for (size_t i=0;i<12;i++) assert([bridge receiveVideo:session+i length:1]);
    assert(bridge.pending.length==12);
    [bridge.pending setLength:0]; bridge.wifiIsUSB=YES; bridge.wifiSocket=42;
    assert([bridge receiveVideo:session length:12]);
    assert(((const uint8_t *)bridge.pending.bytes)[3]&2);
    bridge.wifiIsUSB=NO;
    [bridge.pending setLength:0];
    assert([bridge receiveVideo:session length:12]);
    assert(!(((const uint8_t *)bridge.pending.bytes)[3]&2));
    for (size_t i=0;i<16;i++) assert([bridge receiveVideo:packet+i length:1]);
    assert(bridge.pending.length==28 && bridge.videoReceived==1052);
    assert(!DMResetVideo((__bridge void *)bridge,999));
    [bridge.pending setLength:0];
    NSMutableData *large=[NSMutableData dataWithLength:256*1024+12];
    uint8_t *largeHeader=large.mutableBytes; largeHeader[9]=4; // 256 KiB IDR
    for (NSUInteger offset=0;offset<large.length;) {
        NSUInteger count=MIN((NSUInteger)16384,large.length-offset);
        assert([bridge receiveVideo:largeHeader+offset length:count]); offset+=count;
    }
    assert(bridge.pending.length==large.length && !bridge.videoPacket.length);
    puts("Live fallback: partial codec packet discarded, fresh session/frame delivered, cumulative offset validated");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        assert(DMInputPacketLimit(512,20)==128);
        assert(DMInputPacketLimit(512,182)==182);
        assert(DMInputPacketLimit(512,512)==512);
        assert(DMInputPacketLimit(100,182)==100);
        testLiveVideoRecovery();
        testUSBSelection();
        testStreamingInputFlowControl();
        testAcknowledgedReturns();
        TestWirelessStartupAppearance();
        if (argc==2 && !strcmp(argv[1],"--wire-only")) return 0;
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
        [busyBridge receiveEvent:9]; [busyBridge receiveEvent:9];
        [busyBridge receiveEvent:10]; [busyBridge receiveEvent:10];
        assert(busyBridge.eventMask == 0x380); // PIN reasons survive beyond the old 8-bit mask.
        TestActiveServiceRecovery();
        TestInputReadFairness();
        TestIndicatedReturnsDoNotBlockInput();
        TestDelayedVideoAcknowledgement();
        TestInputSocketWakeup();
        TestStalledCandidateRecovery();
        TestDelayedInputService();
        TestNativeClassicStreams();
        TestVideoAckCadence();
        TestDroppedADB();
        TestColdPeerConnection(NO, NO);
        TestColdPeerConnection(NO, YES);
        TestColdPeerConnection(YES, NO);
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
        assert(alreadyConnected.opens==0 && device.requests==2);
        [alreadyConnected connectionComplete:(IOBluetoothDevice *)device status:kIOReturnSuccess];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        assert(alreadyConnected.opens==1);
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
        DMBleInputTransport *ble=[DMDiscoveryTestTransport new];
        DMStartupManager *manager=[DMStartupManager new];
        DMStartupPeripheral *peer=[DMStartupPeripheral new]; peer.identifier=[NSUUID UUID];
        manager.connected=@[peer]; ble.manager=(CBCentralManager *)manager;
        ble.rejected=[NSMutableSet set];
        [ble scan];
        assert(manager.candidate==nil && manager.scans==1); // Generic service is insufficient.
        [ble centralManager:(CBCentralManager *)manager didDiscoverPeripheral:(CBPeripheral *)peer advertisementData:@{} RSSI:@0];
        assert(manager.candidate==nil);
        [ble centralManager:(CBCentralManager *)manager didDiscoverPeripheral:(CBPeripheral *)peer
            advertisementData:@{CBAdvertisementDataServiceUUIDsKey: @[[CBUUID UUIDWithString:DMInputService]]} RSSI:@0];
        assert(manager.candidate==nil); // Wrong / legacy advertisements are ignored.
        [ble centralManager:(CBCentralManager *)manager didDiscoverPeripheral:(CBPeripheral *)peer
            advertisementData:@{CBAdvertisementDataServiceUUIDsKey: @[[CBUUID UUIDWithNSUUID:[NSUUID UUID]]]} RSSI:@0];
        assert(manager.candidate==nil); // Another pairing's UUID is also ignored.
        ((DMDiscoveryTestTransport *)ble).trustedPeer=peer.identifier;
        manager.scans=0;
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
