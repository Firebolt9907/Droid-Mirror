#import "BleInputTransport.h"
#import "BleInputCrypto.h"
#import "BleInputQueue.h"
#import <CoreBluetooth/CoreBluetooth.h>
#include <time.h>

static NSString *const DMInputService=@"c356a44e-6f2b-4da9-85e5-397991b8a610";
static NSString *const DMInputCharacteristic=@"c356a44e-6f2b-4da9-85e5-397991b8a611";
static NSString *const DMInputReturn=@"c356a44e-6f2b-4da9-85e5-397991b8a613";
static NSString *const DMInputKey=@"c356a44e-6f2b-4da9-85e5-397991b8a614";
static NSString *const DMInputClock=@"c356a44e-6f2b-4da9-85e5-397991b8a615";
static NSString *const DMInputResume=@"c356a44e-6f2b-4da9-85e5-397991b8a616";
static NSString *const DMInputReplay=@"c356a44e-6f2b-4da9-85e5-397991b8a617";
static NSString *const DMInputProof=@"c356a44e-6f2b-4da9-85e5-397991b8a612";
@interface DMBleInputTransport () <CBCentralManagerDelegate, CBPeripheralDelegate> {
    DMBleInputKeys _keys, _returnKeys;
}
@property(nonatomic, strong) CBCentralManager *manager;
@property(nonatomic, strong) CBPeripheral *peripheral;
@property(nonatomic, strong) CBService *inputService;
@property(nonatomic, strong) CBCharacteristic *nonceCharacteristic;
@property(nonatomic) NSTimeInterval discoveryDeadline;
@property(nonatomic, strong) NSData *sessionNonce;
@property(atomic) BOOL recovering;
@property(atomic, readwrite) BOOL pairingProofRejected;
@property(nonatomic) NSTimeInterval recoveryDeadline;
@property(nonatomic) BOOL recoveryDiscoveryStarted;
@property(nonatomic) BOOL recoveryNeedsReturn;
@property(nonatomic) BOOL recoveryStateVerified;
@property(nonatomic) BOOL retryInput;
@property(nonatomic, strong) NSData *inFlightPacket;
@property(nonatomic, strong) CBCharacteristic *resumeCharacteristic;
@property(nonatomic, strong) CBCharacteristic *replayCharacteristic;
@property(nonatomic) NSTimeInterval candidateConnectionDeadline;
@property(nonatomic, strong) NSUUID *deferredCandidate;
@property(nonatomic) NSTimeInterval candidateRetryAfter;
@property(nonatomic) NSTimeInterval nextDiscovery;
@property(nonatomic, strong) CBCharacteristic *input;
@property(nonatomic, strong) CBCharacteristic *returning;
@property(nonatomic, strong) CBCharacteristic *proof;
@property(nonatomic, strong) CBCharacteristic *clockCharacteristic;
@property(nonatomic, strong) NSData *pairingKey;
@property(nonatomic) uint64_t receiveSequence;
@property(nonatomic) BOOL proofVerified;
@property(nonatomic) BOOL readPending;
@property(nonatomic) BOOL returnIndications;
@property(nonatomic) BOOL awaitingReturnSubscription;
@property(nonatomic) BOOL inputTurn;
@property(nonatomic) BOOL writePending;
@property(nonatomic) BOOL motionWakePending;
@property(nonatomic) NSTimeInterval nextRead;
@property(nonatomic, strong) NSData *challenge;
@property(nonatomic, strong) DMBleInputQueue *pending;
@property(nonatomic, strong) NSMutableSet<NSUUID *> *rejected;
@property(nonatomic) uint64_t sequence;
@property(atomic) BOOL ready;
@property(atomic, copy, readwrite) NSString *connectionStage;
@property(atomic) BOOL closed;
@property(nonatomic) NSTimeInterval progress;
@property(nonatomic, strong) dispatch_source_t watchdog;
@property(nonatomic, strong) dispatch_queue_t queue;
@end
@implementation DMBleInputTransport
- (instancetype)initWithPairingKey:(NSData *)key {
    if (key.length != 32 || !(self=[super init])) return nil;
    _connectionStage=@"initializing BLE";
    _pairingKey=[key copy]; _sequence=1; _receiveSequence=1;
    _pending=[DMBleInputQueue new]; _rejected=[NSMutableSet set];
    _queue=dispatch_queue_create("app.droidmirror.ble-control",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    _manager=[[CBCentralManager alloc] initWithDelegate:self queue:_queue];
    __weak DMBleInputTransport *weakSelf=self;
    _watchdog=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_queue);
    dispatch_source_set_timer(_watchdog,dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),200*NSEC_PER_MSEC,20*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_watchdog,^{
        DMBleInputTransport *strongSelf=weakSelf;
        if (!strongSelf || strongSelf.closed) return;
        [strongSelf recoverConnectingCandidateAtTime:NSDate.timeIntervalSinceReferenceDate];
        [strongSelf retryDiscoveryAtTime:NSDate.timeIntervalSinceReferenceDate];
        [strongSelf recoverInputServiceAtTime:NSDate.timeIntervalSinceReferenceDate];
        if (strongSelf.ready) [strongSelf drain];
        [strongSelf checkOperationProgressAtTime:NSDate.timeIntervalSinceReferenceDate];
    });
    dispatch_resume(_watchdog);
    return self;
}
- (void)checkOperationProgressAtTime:(NSTimeInterval)now {
    if (self.closed || self.recovering) return;
    // Encoder startup and shared-radio scheduling can delay an ATT completion
    // after Android has already accepted the authenticated heartbeat.
    // Stay bounded below Android's five-second peer lease; never resend an
    // ambiguous write or reset its authenticated sequence to mask a slow reply.
    if ((self.pending.hasWork || self.writePending || self.readPending) && now-self.progress > 4.0)
        [self reportFailure:[NSString stringWithFormat:@"BLE operation stalled (write=%d read=%d queued=%lu).",
            self.writePending,self.readPending,(unsigned long)self.pending.pendingBytes]];
}
- (void)setStage:(NSString *)stage {
    self.connectionStage=stage;
    fprintf(stderr,"BLE setup: %s\n",stage.UTF8String);
}
// Share authenticated peripheral identities with the background receiver, scoped
// to the derived discovery UUID so changing pairing codes never trusts old peers.
- (NSUUID *)discoveryUUID {
    if (self.pairingKey.length != 32) return nil;
    uint8_t notification[32], bytes[16];
    dm_ble_notification_pairing_key(self.pairingKey.bytes, notification);
    dm_ble_discovery_uuid(notification, bytes);
    memset(notification, 0, sizeof(notification));
    return [[NSUUID alloc] initWithUUIDBytes:bytes];
}
- (NSUserDefaults *)peerPreferences {
    return [[NSUserDefaults alloc] initWithSuiteName:@"app.droidmirror.ble-peers"];
}
- (NSUUID *)rememberedPeer {
    NSUserDefaults *preferences=[self peerPreferences];
    [preferences synchronize];
    NSString *scope=self.discoveryUUID.UUIDString;
    return scope ? [[NSUUID alloc] initWithUUIDString:[preferences stringForKey:scope]] : nil;
}
- (void)rememberAuthenticatedPeer:(NSUUID *)peer {
    if (!self.discoveryUUID) return;
    NSUserDefaults *preferences=[self peerPreferences];
    [preferences setObject:peer.UUIDString forKey:self.discoveryUUID.UUIDString];
    [preferences synchronize];
}
- (BOOL)permitsPeer:(CBPeripheral *)peer advertisement:(NSDictionary *)advertisement {
    NSUUID *discovery=self.discoveryUUID;
    if (!discovery) return NO;
    return [peer.identifier isEqual:self.rememberedPeer] ||
        [advertisement[CBAdvertisementDataServiceUUIDsKey] containsObject:[CBUUID UUIDWithNSUUID:discovery]];
}
- (void)scan {
    if (self.closed || _peripheral || _manager.state != CBManagerStatePoweredOn) return;
    NSUUID *discovery=self.discoveryUUID;
    if (!discovery) return;
    [self setStage:@"looking for the paired phone's BLE service"];
    // Another app/helper can keep the physical BLE link open between sessions.
    // Such a phone may not advertise again; discovery alone never finds it.
    // The merged notification bridge can own the existing phone link before
    // this per-session input service has ever been discovered on that link.
    NSArray *services = @[[CBUUID UUIDWithString:DMInputService],
        [CBUUID UUIDWithString:@"7e57b000-9a6b-4c5d-8e7f-102030405060"]];
    for (CBPeripheral *peer in [_manager retrieveConnectedPeripheralsWithServices:services]) {
        if (![self permitsPeer:peer advertisement:@{}]) continue;
        if ([_rejected containsObject:peer.identifier] ||
                ([peer.identifier isEqual:self.deferredCandidate] && NSDate.timeIntervalSinceReferenceDate < self.candidateRetryAfter)) continue;
        [self centralManager:_manager didDiscoverPeripheral:peer advertisementData:@{} RSSI:@0];
        return;
    }
    [_manager scanForPeripheralsWithServices:@[[CBUUID UUIDWithNSUUID:discovery]] options:nil];
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (self.closed) return;
    if (central.state == CBManagerStatePoweredOn) [self scan];
    else if (central.state != CBManagerStateUnknown && central.state != CBManagerStateResetting)
        [self reportFailure:@"BLE input unavailable. Enable Bluetooth and allow DroidMirror Bluetooth access."];
}
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary *)advertisement RSSI:(NSNumber *)rssi {
    if (self.closed || _peripheral || ![self permitsPeer:peripheral advertisement:advertisement] ||
            [_rejected containsObject:peripheral.identifier] ||
            ([peripheral.identifier isEqual:self.deferredCandidate] && NSDate.timeIntervalSinceReferenceDate < self.candidateRetryAfter)) return;
    [self setStage:@"connecting to a BLE service candidate"];
    _peripheral=peripheral; peripheral.delegate=self;
    self.candidateConnectionDeadline=NSDate.timeIntervalSinceReferenceDate+3.0;
    fprintf(stderr,"BLE candidate: %s\n",peripheral.identifier.UUIDString.UTF8String);
    [central stopScan]; [central connectPeripheral:peripheral options:nil];
}
- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    if (self.closed || peripheral != _peripheral) return;
    self.candidateConnectionDeadline=0;
    self.discoveryDeadline=NSDate.timeIntervalSinceReferenceDate+4.0;
    [self discoverInputService];
}
- (void)recoverConnectingCandidateAtTime:(NSTimeInterval)now {
    if (self.closed || self.ready) return;
    if (!self.peripheral) {
        if (self.candidateRetryAfter && now >= self.candidateRetryAfter) {
            self.candidateRetryAfter=0; self.deferredCandidate=nil;
            [self scan];
        }
        return;
    }
    if (!self.candidateConnectionDeadline || now < self.candidateConnectionDeadline) return;
    // CoreBluetooth may silently retry an obsolete advertising identity without
    // delivering didFailToConnect. Recheck existing system links within this
    // attempt, rather than waiting for the overall timeout and a manual Retry.
    CBPeripheral *stalled=self.peripheral;
    fprintf(stderr,"BLE candidate connection stalled; checking other phone links\n");
    // A slow radio is not an authentication failure. Allow this identity again
    // after a short cooldown if no other candidate works.
    self.deferredCandidate=stalled.identifier;
    self.candidateRetryAfter=now+2.0;
    self.candidateConnectionDeadline=0;
    self.peripheral=nil;
    stalled.delegate=nil;
    [self.manager cancelPeripheralConnection:stalled];
    [self scan];
}
- (void)discoverInputService {
    self.nextDiscovery=0;
    self.inputService=nil; self.nonceCharacteristic=nil;
    self.input=nil; self.proof=nil; self.returning=nil; self.clockCharacteristic=nil;
    self.challenge=nil; self.proofVerified=NO; self.recoveryStateVerified=NO;
    self.resumeCharacteristic=nil; self.replayCharacteristic=nil;
    self.returnIndications=NO; self.awaitingReturnSubscription=NO;
    [self setStage:@"discovering BLE services"];
    [self.peripheral discoverServices:@[[CBUUID UUIDWithString:DMInputService]]];
}
- (void)waitForInputService {
    // Android adds this GATT service asynchronously after accepting Classic.
    // An empty/stale discovery result is not evidence of a bad pairing proof.
    if (NSDate.timeIntervalSinceReferenceDate >= self.discoveryDeadline) {
        if (self.recovering) [self reportFailure:@"BLE service recovery timed out; reconnect the mirror."];
        else [self reject];
        return;
    }
    [self setStage:@"waiting for Android's BLE input service to become available"];
    self.nextDiscovery=NSDate.timeIntervalSinceReferenceDate+0.25;
}
- (void)retryDiscoveryAtTime:(NSTimeInterval)now {
    if (self.closed || self.ready || !self.peripheral || !self.nextDiscovery || now < self.nextDiscovery) return;
    [self discoverInputService];
}
- (void)peripheral:(CBPeripheral *)peripheral didModifyServices:(NSArray<CBService *> *)invalidatedServices {
    if (self.closed || peripheral != self.peripheral) return;
    BOOL inputChanged=NO;
    for (CBService *service in invalidatedServices)
        if ([service.UUID isEqual:[CBUUID UUIDWithString:DMInputService]]) inputChanged=YES;
    if (!inputChanged) return;
    if (self.ready || self.recovering) {
        if (!self.recovering) {
            self.recovering=YES; self.ready=NO; self.recoveryDiscoveryStarted=NO;
            self.recoveryDeadline=NSDate.timeIntervalSinceReferenceDate+4.0;
            self.discoveryDeadline=self.recoveryDeadline;
            [self setStage:@"recovering the active BLE input service"];
        }
        // CoreBluetooth may discard an outstanding ATT completion on invalidation.
        // Reconcile its outcome using fresh, authenticated phone-side state.
        self.recoveryNeedsReturn |= self.readPending || self.returnIndications;
        self.readPending=NO; self.writePending=NO;
        [self recoverInputServiceAtTime:NSDate.timeIntervalSinceReferenceDate];
        return;
    }
    // Drop references immediately so late callbacks from invalidated attributes
    // cannot authenticate an obsolete session. Keep the original startup budget.
    self.inputService=nil; self.nonceCharacteristic=nil;
    self.input=nil; self.proof=nil; self.returning=nil; self.clockCharacteristic=nil;
    self.challenge=nil; self.proofVerified=NO; self.recoveryStateVerified=NO;
    self.resumeCharacteristic=nil; self.replayCharacteristic=nil;
    [self waitForInputService];
}
- (void)recoverInputServiceAtTime:(NSTimeInterval)now {
    if (self.closed || !self.recovering) return;
    if (now >= self.recoveryDeadline) {
        [self reportFailure:@"BLE service recovery timed out; reconnect the mirror."]; return;
    }
    if (self.recoveryDiscoveryStarted) return;
    self.recoveryDiscoveryStarted=YES;
    // Old-handle callbacks are ignored after attributes are invalidated.
    // recoveryDiscoveryStarted prevents duplicate discovery during authentication.
    [self discoverInputService];
}
- (void)reject {
    if (self.recovering) { [self reportFailure:@"BLE service recovery authentication failed; reconnect the mirror."]; return; }
    [self setStage:@"rejecting a BLE candidate with incompatible service or pairing proof"];
    self.nextDiscovery=0;
    self.inputService=nil; self.nonceCharacteristic=nil;
    self.input=nil; self.proof=nil; self.returning=nil; self.clockCharacteristic=nil;
    self.challenge=nil; self.proofVerified=NO; self.recoveryStateVerified=NO;
    self.resumeCharacteristic=nil; self.replayCharacteristic=nil;
    if (_peripheral) { [_rejected addObject:_peripheral.identifier]; [_manager cancelPeripheralConnection:_peripheral]; }
}
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (self.closed || peripheral != _peripheral) return;
    self.candidateConnectionDeadline=0;
    self.nextDiscovery=0; self.inputService=nil; self.nonceCharacteristic=nil;
    [_rejected addObject:peripheral.identifier]; _peripheral=nil; _input=nil; _proof=nil; _returning=nil; _clockCharacteristic=nil; _challenge=nil; _proofVerified=NO; [self scan];
}
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (self.closed || peripheral != _peripheral) return;
    if (self.ready || self.recovering) { [self reportFailure:@"BLE input disconnected; ending the mirror session."]; return; }
    self.candidateConnectionDeadline=0;
    self.nextDiscovery=0; self.inputService=nil; self.nonceCharacteristic=nil;
    _peripheral=nil; _input=nil; _proof=nil; _returning=nil; _clockCharacteristic=nil; _challenge=nil; _proofVerified=NO; [self scan];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (self.closed || peripheral != _peripheral || self.nonceCharacteristic || self.nextDiscovery) return;
    if (!error) for (CBService *service in peripheral.services) {
        if (![service.UUID isEqual:[CBUUID UUIDWithString:DMInputService]]) continue;
        self.inputService=service;
        [self setStage:@"discovering BLE characteristics"];
        [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:DMInputCharacteristic],[CBUUID UUIDWithString:DMInputProof],
            [CBUUID UUIDWithString:DMInputReturn],[CBUUID UUIDWithString:DMInputKey],[CBUUID UUIDWithString:DMInputClock],
            [CBUUID UUIDWithString:DMInputResume],[CBUUID UUIDWithString:DMInputReplay]] forService:service];
        return;
    }
    [self waitForInputService];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (self.closed || peripheral != _peripheral || service != self.inputService || self.nonceCharacteristic || self.nextDiscovery) return;
    CBCharacteristic *key=nil;
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputResume]]) self.resumeCharacteristic=characteristic;
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputReplay]]) self.replayCharacteristic=characteristic;
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputCharacteristic]]) _input=characteristic;
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputProof]]) _proof=characteristic;
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputReturn]]) _returning=characteristic;
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputKey]]) key=characteristic;
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputClock]]) _clockCharacteristic=characteristic;
    }
    if (error || !key || !(_clockCharacteristic.properties & CBCharacteristicPropertyRead) || !(_returning.properties & CBCharacteristicPropertyRead)
            || !(_proof.properties & CBCharacteristicPropertyRead) || !(_proof.properties & CBCharacteristicPropertyWrite)
            || !(_input.properties & CBCharacteristicPropertyWrite)) { [self waitForInputService]; return; }
    // The public nonce derives session keys from the one-time, privately paired root.
    // Proof authenticates the chosen phone before any input is sent.
    self.nonceCharacteristic=key;
    [self setStage:@"reading the BLE session nonce"];
    [peripheral readValueForCharacteristic:key];
}
- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (getenv("DROIDMIRROR_BLE_DEBUG")) fprintf(stderr,"BLE write completion uuid=%s peer=%d input=%d pending=%d next=%llu error=%ld\n",
        characteristic.UUID.UUIDString.UTF8String,peripheral==_peripheral,characteristic==_input,_writePending,
        (unsigned long long)_sequence,(long)error.code);
    if (self.closed || peripheral != _peripheral) return;
    if (characteristic == _input) {
        _writePending=NO;
        if (error) { [self reportFailure:@"BLE input write failed."]; return; }
        self.inFlightPacket=nil;
        _progress=NSDate.timeIntervalSinceReferenceDate; [self drain]; return;
    }
    if (characteristic != _proof) return;
    if (error) { [self reject]; return; }
    [self setStage:@"reading the BLE pairing proof"];
    [peripheral readValueForCharacteristic:characteristic];
}
- (void)readReturn {
    if (self.closed || !self.ready || self.returnIndications || _readPending || _writePending) return;
    self.inputTurn=YES;
    _readPending=YES; _progress=NSDate.timeIntervalSinceReferenceDate;
    [_peripheral readValueForCharacteristic:_returning];
}
- (void)finishAuthentication {
    [self setStage:self.returnIndications ? @"authenticated BLE ready (indicated returns)" : @"authenticated BLE ready"];
    self.ready=YES; self.recovering=NO; self.recoveryDeadline=0;
    self.progress=NSDate.timeIntervalSinceReferenceDate; _nextRead=self.progress+0.5;
    [self reportReady]; [self drain];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (self.closed || peripheral != self.peripheral || characteristic != self.returning || !self.awaitingReturnSubscription) return;
    self.awaitingReturnSubscription=NO;
    if (error || !characteristic.isNotifying) { [self reportFailure:@"BLE return subscription failed."]; return; }
    [self finishAuthentication];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (self.closed || peripheral != _peripheral) return;
    if (characteristic != _nonceCharacteristic && characteristic != _proof && characteristic != _returning && characteristic != _clockCharacteristic && characteristic != _resumeCharacteristic && characteristic != _replayCharacteristic) return;
    if (getenv("DROIDMIRROR_BLE_DEBUG")) fprintf(stderr,"BLE RX %s bytes=%lu ready=%d error=%ld\n",characteristic.UUID.UUIDString.UTF8String,(unsigned long)characteristic.value.length,self.ready,(long)error.code);
    if ((self.ready || self.recovering) && characteristic == _returning && (_readPending || self.returnIndications)) {
        BOOL wasRead=_readPending;
        _readPending=NO;
        if (wasRead) _progress=NSDate.timeIntervalSinceReferenceDate;
        NSData *packet=characteristic.value;
        if (wasRead && !error && !packet.length) { _nextRead=NSDate.timeIntervalSinceReferenceDate+0.5; [self recoverInputServiceAtTime:_progress]; [self drain]; return; }
        uint8_t plain[488];
        if (error || !dm_ble_input_open(&_returnKeys,_receiveSequence,packet.bytes,packet.length,plain)) {
            [self reportFailure:@"Invalid BLE return record."]; return;
        }
        ++_receiveSequence;
        [self deliver:[NSData dataWithBytes:plain length:packet.length-24]];
        _nextRead=0; [self recoverInputServiceAtTime:NSDate.timeIntervalSinceReferenceDate]; [self drain];
        return;
    }
    if (self.recovering && _proofVerified && characteristic == self.resumeCharacteristic) {
        NSData *value=characteristic.value;
        uint8_t expected[32], difference=0;
        if (error || value.length!=40) { [self reportFailure:@"BLE recovery state unavailable; update the companion."]; return; }
        const uint8_t *bytes=value.bytes;
        dm_ble_resume_proof(&_keys,self.challenge.bytes,bytes,expected);
        for (NSUInteger i=0;i<32;++i) difference |= expected[i]^bytes[8+i];
        uint64_t next; memcpy(&next,bytes,8); next=CFSwapInt64BigToHost(next);
        if (difference || !next || (next != self.sequence && (!self.inFlightPacket || next != self.sequence-1))) {
            [self reportFailure:@"Invalid authenticated BLE recovery sequence."]; return;
        }
        self.recoveryStateVerified=YES;
        self.retryInput=next != self.sequence;
        if (!self.retryInput) self.inFlightPacket=nil;
        if (self.recoveryNeedsReturn) [peripheral readValueForCharacteristic:self.replayCharacteristic];
        else [peripheral readValueForCharacteristic:_clockCharacteristic];
        return;
    }
    if (self.recovering && _proofVerified && self.recoveryStateVerified && characteristic == self.replayCharacteristic) {
        NSData *packet=characteristic.value;
        if (error || (packet.length && (packet.length<=24 || packet.length>512))) {
            [self reportFailure:@"BLE recovery return unavailable."]; return;
        }
        if (packet.length) {
            uint64_t sequence; memcpy(&sequence,packet.bytes,8); sequence=CFSwapInt64BigToHost(sequence);
            uint8_t plain[488];
            if ((sequence != _receiveSequence && sequence != _receiveSequence-1) ||
                    !dm_ble_input_open(&_returnKeys,sequence,packet.bytes,packet.length,plain)) {
                [self reportFailure:@"Invalid BLE recovery return sequence."]; return;
            }
            if (sequence == _receiveSequence) {
                ++_receiveSequence;
                [self deliver:[NSData dataWithBytes:plain length:packet.length-24]];
            }
        }
        self.recoveryNeedsReturn=NO;
        [peripheral readValueForCharacteristic:_clockCharacteristic]; return;
    }
    if (self.ready) return;
    if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputClock]] && _proofVerified) {
        if (self.recovering && (!self.recoveryStateVerified || self.recoveryNeedsReturn)) {
            [self reportFailure:@"BLE recovery state was not authenticated."]; return;
        }
        NSData *value=characteristic.value;
        if (error || value.length != 40) { [self reportFailure:@"BLE clock synchronization failed. Update the Android companion."]; return; }
        uint8_t expected[32], difference=0; const uint8_t *bytes=value.bytes;
        dm_ble_clock_proof(&_keys,bytes,expected);
        for (NSUInteger i=0;i<32;++i) difference |= expected[i]^bytes[8+i];
        if (difference) { [self reportFailure:@"Invalid authenticated phone clock."]; return; }
        struct timespec now; clock_gettime(CLOCK_MONOTONIC,&now);
        uint64_t mac=(uint64_t)now.tv_sec*1000+(uint64_t)now.tv_nsec/1000000, phone;
        memcpy(&phone,bytes,8); phone=CFSwapInt64BigToHost(phone);
        [_pending synchronizePhoneClock:phone macClock:mac];
        if (_returning.properties & CBCharacteristicPropertyIndicate) {
            self.returnIndications=YES; self.awaitingReturnSubscription=YES;
            [self setStage:@"subscribing authenticated BLE returns"];
            [peripheral setNotifyValue:YES forCharacteristic:_returning];
        } else [self finishAuthentication];
        return;
    }
    if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputKey]]) {
        if (error || characteristic.value.length != 32) { [self reject]; return; }
        if (self.recovering && ![self.sessionNonce isEqual:characteristic.value]) {
            [self reportFailure:@"Android replaced the BLE session; reconnect the mirror."]; return;
        }
        self.sessionNonce=[characteristic.value copy];
        uint8_t session[32]; dm_ble_session_key(_pairingKey.bytes,characteristic.value.bytes,session);
        dm_ble_input_keys(session,&_keys); dm_ble_output_keys(session,&_returnKeys); memset(session,0,sizeof(session));
        NSMutableData *challenge=[NSMutableData dataWithLength:16]; arc4random_buf(challenge.mutableBytes,16); _challenge=challenge;
        [self setStage:@"writing the BLE authentication challenge"];
        [peripheral writeValue:challenge forCharacteristic:_proof type:CBCharacteristicWriteWithResponse];
        return;
    }
    if (![characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputProof]] || _challenge.length != 16) { [self reject]; return; }
    uint8_t expected[32], difference=0; dm_ble_input_proof(&_keys,_challenge.bytes,expected);
    if (error || characteristic.value.length != sizeof(expected)) { [self reject]; return; }
    const uint8_t *actual=characteristic.value.bytes;
    for (NSUInteger i=0;i<sizeof(expected);++i) difference |= expected[i]^actual[i];
    if (difference) {
        // Keep trying other candidates; only report a code mismatch if startup
        // exhausts its budget without authenticating a phone. Recovery failures
        // belong to the existing session, not the saved pairing code.
        if (!self.recovering) self.pairingProofRejected=YES;
        [self reject]; return;
    }
    self.pairingProofRejected=NO;
    if ([peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithResponse] <= 24) {
        [self reportFailure:@"BLE input MTU is too small for authenticated commands."]; return;
    }
    _proofVerified=YES;
    [self rememberAuthenticatedPeer:peripheral.identifier];
    if (self.recovering) {
        if (!(self.resumeCharacteristic.properties & CBCharacteristicPropertyRead) ||
                !(self.replayCharacteristic.properties & CBCharacteristicPropertyRead)) {
            [self reportFailure:@"BLE service recovery requires an updated Android companion."]; return;
        }
        [self setStage:@"reading authenticated BLE recovery state"];
        [peripheral readValueForCharacteristic:self.resumeCharacteristic];
    } else {
        [self setStage:@"reading the authenticated phone clock"];
        [peripheral readValueForCharacteristic:_clockCharacteristic];
    }
}
- (void)reportReady {
    id<DMBleInputDelegate> delegate=self.delegate;
    dispatch_async(dispatch_get_main_queue(),^{ [delegate bleInputReady]; });
}
- (void)reportFailure:(NSString *)reason {
    id<DMBleInputDelegate> delegate=self.delegate;
    dispatch_async(dispatch_get_main_queue(),^{ [delegate bleInputFailed:reason]; });
}
- (void)deliver:(NSData *)bytes {
    id<DMBleInputDelegate> delegate=self.delegate;
    dispatch_async(dispatch_get_main_queue(),^{
        if (![delegate bleInputReceived:bytes]) [delegate bleInputFailed:@"Invalid BLE control or event stream."];
    });
}
- (BOOL)send:(NSData *)bytes {
    if (self.closed || (!self.ready && !self.recovering) || bytes.length > 128*1024) return NO;
    NSData *copy=[bytes copy];
    dispatch_async(_queue,^{
        if (self.closed) return;
        if (!self.pending.hasWork && !self.writePending && !self.readPending) self.progress=NSDate.timeIntervalSinceReferenceDate;
        if (![self.pending appendRecords:copy]) { [self reportFailure:@"Invalid or excessive BLE input backlog"]; return; }
        [self drain];
    });
    return YES;
}
- (BOOL)acknowledgeVideo:(uint64_t)count {
    if (self.closed || (!self.ready && !self.recovering)) return NO;
    dispatch_async(_queue,^{
        if (self.closed) return;
        if (!self.pending.hasWork && !self.writePending && !self.readPending) self.progress=NSDate.timeIntervalSinceReferenceDate;
        [self.pending acknowledgeVideo:count]; [self drain];
    });
    return YES;
}
- (BOOL)requestBluetoothVideo:(uint64_t)count nonce:(NSData *)nonce {
    if (self.closed || (!self.ready && !self.recovering) || nonce.length!=32) return NO;
    dispatch_async(_queue,^{
        if (self.closed) return;
        if (!self.pending.hasWork && !self.writePending && !self.readPending) self.progress=NSDate.timeIntervalSinceReferenceDate;
        [self.pending requestBluetoothVideo:count nonce:nonce]; [self drain];
    });
    return YES;
}
- (void)drain {
    if (self.closed || !self.ready || _writePending || _readPending) return;
    if (self.retryInput) {
        self.inputTurn=NO;
        self.retryInput=NO; _writePending=YES; _progress=NSDate.timeIntervalSinceReferenceDate;
        // Exact ciphertext only, and only after the phone proved it was not accepted.
        [_peripheral writeValue:self.inFlightPacket forCharacteristic:_input type:CBCharacteristicWriteWithResponse];
        return;
    }
    // Alternate due return reads with ready input. A multi-packet clipboard or
    // event response must not monopolize ATT while keys/mouse wait to be sent.
    BOOL readDue=!self.returnIndications && NSDate.timeIntervalSinceReferenceDate >= _nextRead;
    if (readDue && !self.inputTurn) { [self readReturn]; return; }
    NSUInteger mtu=MIN((NSUInteger)512,[_peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithResponse]);
    NSData *plain=[_pending takePacket:mtu-24];
    if (!plain.length) {
        if (readDue) { [self readReturn]; return; }
        NSTimeInterval delay = _pending.motionDelay;
        if (delay > 0 && !_motionWakePending) {
            _motionWakePending=YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),_queue,^{
                self.motionWakePending=NO; [self drain];
            });
        }
        return;
    }
    NSMutableData *packet=[NSMutableData dataWithLength:plain.length+24];
    if (!dm_ble_input_seal(&_keys,_sequence,plain.bytes,plain.length,packet.mutableBytes)) {
        [self reportFailure:@"BLE input encryption failed."]; return;
    }
    self.inFlightPacket=packet;
    self.inputTurn=NO;
    ++_sequence; _writePending=YES; _progress=NSDate.timeIntervalSinceReferenceDate;
    if (getenv("DROIDMIRROR_BLE_DEBUG")) fprintf(stderr,"BLE input write sequence=%llu bytes=%lu\n",
        (unsigned long long)(_sequence-1),(unsigned long)packet.length);
    [_peripheral writeValue:packet forCharacteristic:_input type:CBCharacteristicWriteWithResponse];
}
- (void)close {
    @synchronized (self) {
        if (self.closed) return;
        self.closed=YES; self.ready=NO;
    }
    dispatch_async(_queue,^{
        if (self.watchdog) { dispatch_source_cancel(self.watchdog); self.watchdog=nil; }
        [self.manager stopScan]; if (self.peripheral) [self.manager cancelPeripheralConnection:self.peripheral];
        self.manager.delegate=nil; self.peripheral.delegate=nil; [self.pending clear];
        self.pairingKey=nil; self.inFlightPacket=nil; self.sessionNonce=nil; memset(&self->_keys,0,sizeof(self->_keys)); memset(&self->_returnKeys,0,sizeof(self->_returnKeys));
    });
}
@end
