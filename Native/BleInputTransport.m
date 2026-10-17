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
static NSString *const DMInputProof=@"c356a44e-6f2b-4da9-85e5-397991b8a612";
@interface DMBleInputTransport () <CBCentralManagerDelegate, CBPeripheralDelegate> {
    DMBleInputKeys _keys, _returnKeys;
}
@property(nonatomic, strong) CBCentralManager *manager;
@property(nonatomic, strong) CBPeripheral *peripheral;
@property(nonatomic, strong) CBCharacteristic *input;
@property(nonatomic, strong) CBCharacteristic *returning;
@property(nonatomic, strong) CBCharacteristic *proof;
@property(nonatomic, strong) CBCharacteristic *clockCharacteristic;
@property(nonatomic, strong) NSData *pairingKey;
@property(nonatomic) uint64_t receiveSequence;
@property(nonatomic) BOOL proofVerified;
@property(nonatomic) BOOL readPending;
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
    _queue=dispatch_queue_create("app.droidmirror.ble-control",DISPATCH_QUEUE_SERIAL);
    _manager=[[CBCentralManager alloc] initWithDelegate:self queue:_queue];
    __weak DMBleInputTransport *weakSelf=self;
    _watchdog=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_queue);
    dispatch_source_set_timer(_watchdog,dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),200*NSEC_PER_MSEC,20*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_watchdog,^{
        DMBleInputTransport *strongSelf=weakSelf;
        if (!strongSelf || strongSelf.closed) return;
        if (strongSelf.ready) [strongSelf drain];
        if ((strongSelf.pending.hasWork || strongSelf.writePending || strongSelf.readPending) && NSDate.timeIntervalSinceReferenceDate-strongSelf.progress > 2.0)
            [strongSelf reportFailure:[NSString stringWithFormat:@"BLE operation stalled (write=%d read=%d queued=%lu).",
                strongSelf.writePending,strongSelf.readPending,(unsigned long)strongSelf.pending.pendingBytes]];
    });
    dispatch_resume(_watchdog);
    return self;
}
- (void)setStage:(NSString *)stage {
    self.connectionStage=stage;
    fprintf(stderr,"BLE setup: %s\n",stage.UTF8String);
}
- (void)scan {
    if (self.closed || _peripheral || _manager.state != CBManagerStatePoweredOn) return;
    [self setStage:@"scanning for the phone's BLE service"];
    // Another app/helper can keep the physical BLE link open between sessions.
    // Such a phone may not advertise again; discovery alone never finds it.
    // The merged notification bridge can own the existing phone link before
    // this per-session input service has ever been discovered on that link.
    NSArray *services = @[[CBUUID UUIDWithString:DMInputService],
        [CBUUID UUIDWithString:@"7e57b000-9a6b-4c5d-8e7f-102030405060"]];
    for (CBPeripheral *peer in [_manager retrieveConnectedPeripheralsWithServices:services]) {
        if ([_rejected containsObject:peer.identifier]) continue;
        [self centralManager:_manager didDiscoverPeripheral:peer advertisementData:@{} RSSI:@0];
        return;
    }
    [_manager scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:DMInputService]] options:nil];
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (self.closed) return;
    if (central.state == CBManagerStatePoweredOn) [self scan];
    else if (central.state != CBManagerStateUnknown && central.state != CBManagerStateResetting)
        [self reportFailure:@"BLE input unavailable. Enable Bluetooth and allow DroidMirror Bluetooth access."];
}
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary *)advertisement RSSI:(NSNumber *)rssi {
    if (self.closed || _peripheral || [_rejected containsObject:peripheral.identifier]) return;
    [self setStage:@"connecting to a BLE service candidate"];
    _peripheral=peripheral; peripheral.delegate=self;
    [central stopScan]; [central connectPeripheral:peripheral options:nil];
}
- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    if (self.closed || peripheral != _peripheral) return;
    [self setStage:@"discovering BLE services"];
    [peripheral discoverServices:@[[CBUUID UUIDWithString:DMInputService]]];
}
- (void)reject {
    [self setStage:@"rejecting a BLE candidate with incompatible service or pairing proof"];
    if (_peripheral) { [_rejected addObject:_peripheral.identifier]; [_manager cancelPeripheralConnection:_peripheral]; }
}
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (self.closed || peripheral != _peripheral) return;
    [_rejected addObject:peripheral.identifier]; _peripheral=nil; _input=nil; _proof=nil; _returning=nil; _clockCharacteristic=nil; _challenge=nil; _proofVerified=NO; [self scan];
}
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (self.closed || peripheral != _peripheral) return;
    if (self.ready) { [self reportFailure:@"BLE input disconnected; ending the mirror session."]; return; }
    _peripheral=nil; _input=nil; _proof=nil; _returning=nil; _clockCharacteristic=nil; _challenge=nil; _proofVerified=NO; [self scan];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (self.closed || peripheral != _peripheral) return;
    [self setStage:@"discovering BLE characteristics"];
    if (error || !peripheral.services.count) { [self reject]; return; }
    for (CBService *service in peripheral.services)
        [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:DMInputCharacteristic],[CBUUID UUIDWithString:DMInputProof],
            [CBUUID UUIDWithString:DMInputReturn],[CBUUID UUIDWithString:DMInputKey],[CBUUID UUIDWithString:DMInputClock]] forService:service];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (self.closed || peripheral != _peripheral) return;
    CBCharacteristic *key=nil;
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputCharacteristic]]) _input=characteristic;
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputProof]]) _proof=characteristic;
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputReturn]]) _returning=characteristic;
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputKey]]) key=characteristic;
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputClock]]) _clockCharacteristic=characteristic;
    }
    if (error || !key || !(_clockCharacteristic.properties & CBCharacteristicPropertyRead) || !(_returning.properties & CBCharacteristicPropertyRead)
            || !(_proof.properties & CBCharacteristicPropertyRead) || !(_proof.properties & CBCharacteristicPropertyWrite)
            || !(_input.properties & CBCharacteristicPropertyWrite)) { [self reject]; return; }
    // The public nonce derives session keys from the one-time, privately paired root.
    // Proof authenticates the chosen phone before any input is sent.
    [self setStage:@"reading the BLE session nonce"];
    [peripheral readValueForCharacteristic:key];
}
- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (self.closed || peripheral != _peripheral) return;
    if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputCharacteristic]]) {
        _writePending=NO;
        if (error) { [self reportFailure:@"BLE input write failed."]; return; }
        _progress=NSDate.timeIntervalSinceReferenceDate; [self drain]; return;
    }
    if (![characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputProof]]) return;
    if (error) { [self reject]; return; }
    [self setStage:@"reading the BLE pairing proof"];
    [peripheral readValueForCharacteristic:characteristic];
}
- (void)readReturn {
    if (self.closed || !self.ready || _readPending || _writePending) return;
    _readPending=YES; _progress=NSDate.timeIntervalSinceReferenceDate;
    [_peripheral readValueForCharacteristic:_returning];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (self.closed || peripheral != _peripheral) return;
    if (getenv("DROIDMIRROR_BLE_DEBUG")) fprintf(stderr,"BLE RX %s bytes=%lu ready=%d error=%ld\n",characteristic.UUID.UUIDString.UTF8String,(unsigned long)characteristic.value.length,self.ready,(long)error.code);
    if (self.ready && [characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputReturn]]) {
        _readPending=NO; _progress=NSDate.timeIntervalSinceReferenceDate;
        NSData *packet=characteristic.value;
        if (!error && !packet.length) { _nextRead=NSDate.timeIntervalSinceReferenceDate+0.5; [self drain]; return; }
        uint8_t plain[488];
        if (error || !dm_ble_input_open(&_returnKeys,_receiveSequence,packet.bytes,packet.length,plain)) {
            [self reportFailure:@"Invalid BLE return record."]; return;
        }
        ++_receiveSequence;
        [self deliver:[NSData dataWithBytes:plain length:packet.length-24]];
        _nextRead=0; [self drain];
        return;
    }
    if (self.ready) return;
    if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputClock]] && _proofVerified) {
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
        [self setStage:@"authenticated BLE ready"];
        self.ready=YES; _nextRead=NSDate.timeIntervalSinceReferenceDate+0.5;
        [self reportReady]; [self drain]; return;
    }
    if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputKey]]) {
        if (error || characteristic.value.length != 32) { [self reject]; return; }
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
    if (difference) { [self reject]; return; }
    if ([peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithResponse] <= 24) {
        [self reportFailure:@"BLE input MTU is too small for authenticated commands."]; return;
    }
    _proofVerified=YES; [self setStage:@"reading the authenticated phone clock"];
    [peripheral readValueForCharacteristic:_clockCharacteristic];
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
    if (self.closed || !self.ready || bytes.length > 128*1024) return NO;
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
    if (self.closed || !self.ready) return NO;
    dispatch_async(_queue,^{
        if (self.closed) return;
        if (!self.pending.hasWork && !self.writePending && !self.readPending) self.progress=NSDate.timeIntervalSinceReferenceDate;
        [self.pending acknowledgeVideo:count]; [self drain];
    });
    return YES;
}
- (BOOL)requestBluetoothVideo:(uint64_t)count nonce:(NSData *)nonce {
    if (self.closed || !self.ready || nonce.length!=32) return NO;
    dispatch_async(_queue,^{
        if (self.closed) return;
        if (!self.pending.hasWork && !self.writePending && !self.readPending) self.progress=NSDate.timeIntervalSinceReferenceDate;
        [self.pending requestBluetoothVideo:count nonce:nonce]; [self drain];
    });
    return YES;
}
- (void)drain {
    if (self.closed || !self.ready || _writePending || _readPending) return;
    // Only one GATT operation at a time. A due return read gets a turn even
    // during sustained mouse traffic; video ACKs precede the next input envelope.
    if (NSDate.timeIntervalSinceReferenceDate >= _nextRead) { [self readReturn]; return; }
    NSUInteger mtu=MIN((NSUInteger)512,[_peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithResponse]);
    NSData *plain=[_pending takePacket:mtu-24];
    if (!plain.length) {
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
    ++_sequence; _writePending=YES; _progress=NSDate.timeIntervalSinceReferenceDate;
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
        self.pairingKey=nil; memset(&self->_keys,0,sizeof(self->_keys)); memset(&self->_returnKeys,0,sizeof(self->_returnKeys));
    });
}
@end
