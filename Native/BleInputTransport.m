#import "BleInputTransport.h"
#import "BleInputCrypto.h"
#import <CoreBluetooth/CoreBluetooth.h>

static NSString *const DMInputService=@"c356a44e-6f2b-4da9-85e5-397991b8a610";
static NSString *const DMInputCharacteristic=@"c356a44e-6f2b-4da9-85e5-397991b8a611";
static NSString *const DMInputProof=@"c356a44e-6f2b-4da9-85e5-397991b8a612";
@interface DMBleInputTransport () <CBCentralManagerDelegate, CBPeripheralDelegate> {
    DMBleInputKeys _keys;
}
@property(nonatomic, strong) CBCentralManager *manager;
@property(nonatomic, strong) CBPeripheral *peripheral;
@property(nonatomic, strong) CBCharacteristic *input;
@property(nonatomic, strong) NSData *challenge;
@property(nonatomic, strong) NSMutableData *pending;
@property(nonatomic, strong) NSMutableSet<NSUUID *> *rejected;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL closed;
@property(nonatomic) NSTimeInterval progress;
@property(nonatomic, strong) NSTimer *watchdog;
@end
@implementation DMBleInputTransport
- (instancetype)initWithSessionKey:(NSData *)key {
    if (key.length != 32 || !(self=[super init])) return nil;
    dm_ble_input_keys(key.bytes, &_keys); _sequence=1;
    _pending=[NSMutableData data]; _rejected=[NSMutableSet set];
    _manager=[[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
    __weak DMBleInputTransport *weakSelf=self;
    _watchdog=[NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
        DMBleInputTransport *strongSelf=weakSelf;
        if (!strongSelf || strongSelf.closed) { [timer invalidate]; return; }
        if (strongSelf.pending.length && NSDate.timeIntervalSinceReferenceDate-strongSelf.progress > 2.0)
            [strongSelf.delegate bleInputFailed:@"BLE input transmission stalled."];
    }];
    return self;
}
- (void)scan {
    if (!_closed && _manager.state == CBManagerStatePoweredOn)
        [_manager scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:DMInputService]] options:nil];
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (_closed) return;
    if (central.state == CBManagerStatePoweredOn) [self scan];
    else if (central.state != CBManagerStateUnknown && central.state != CBManagerStateResetting)
        [_delegate bleInputFailed:@"BLE input unavailable. Enable Bluetooth and allow DroidMirror Bluetooth access."];
}
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary *)advertisement RSSI:(NSNumber *)rssi {
    if (_closed || _peripheral || [_rejected containsObject:peripheral.identifier]) return;
    _peripheral=peripheral; peripheral.delegate=self;
    [central stopScan]; [central connectPeripheral:peripheral options:nil];
}
- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    if (!_closed) [peripheral discoverServices:@[[CBUUID UUIDWithString:DMInputService]]];
}
- (void)reject {
    if (_peripheral) { [_rejected addObject:_peripheral.identifier]; [_manager cancelPeripheralConnection:_peripheral]; }
}
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (_closed) return;
    [_rejected addObject:peripheral.identifier]; _peripheral=nil; _input=nil; [self scan];
}
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (_closed) return;
    if (_ready) { [_delegate bleInputFailed:@"BLE input disconnected; ending the mirror session."]; return; }
    _peripheral=nil; _input=nil; [self scan];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (_closed) return;
    if (error || !peripheral.services.count) { [self reject]; return; }
    for (CBService *service in peripheral.services)
        [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:DMInputCharacteristic],[CBUUID UUIDWithString:DMInputProof]] forService:service];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (_closed) return;
    CBCharacteristic *proof=nil;
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputCharacteristic]]) _input=characteristic;
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputProof]]) proof=characteristic;
    }
    if (error || !proof || !(proof.properties & CBCharacteristicPropertyRead) || !(proof.properties & CBCharacteristicPropertyWrite) || !(_input.properties & CBCharacteristicPropertyWriteWithoutResponse)) { [self reject]; return; }
    NSMutableData *challenge=[NSMutableData dataWithLength:16];arc4random_buf(challenge.mutableBytes,16);_challenge=challenge;
    [peripheral writeValue:challenge forCharacteristic:proof type:CBCharacteristicWriteWithResponse];
}
- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (_closed || ![characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputProof]]) return;
    if (error) { [self reject]; return; }
    [peripheral readValueForCharacteristic:characteristic];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (_closed || _ready || ![characteristic.UUID isEqual:[CBUUID UUIDWithString:DMInputProof]]) return;
    if (_challenge.length != 16) { [self reject]; return; }
    uint8_t expected[32], difference=0; dm_ble_input_proof(&_keys, _challenge.bytes, expected);
    if (error || characteristic.value.length != sizeof(expected)) { [self reject]; return; }
    const uint8_t *actual=characteristic.value.bytes;
    for(NSUInteger i=0;i<sizeof(expected);++i) difference |= expected[i]^actual[i];
    if (difference) { [self reject]; return; }
    if ([peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse] <= 24) {
        [_delegate bleInputFailed:@"BLE input MTU is too small for authenticated commands."]; return;
    }
    _ready=YES; [_delegate bleInputReady]; [self drain];
}
- (BOOL)send:(NSData *)bytes {
    if (_closed || !_ready || bytes.length > 128*1024-_pending.length) return NO;
    if (!_pending.length) _progress=NSDate.timeIntervalSinceReferenceDate;
    [_pending appendData:bytes]; [self drain]; return YES;
}
- (void)drain {
    while (!_closed && _ready && _pending.length && _peripheral.canSendWriteWithoutResponse) {
        NSUInteger mtu=MIN((NSUInteger)512,[_peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse]);
        NSUInteger count=MIN(_pending.length,mtu-24);
        NSMutableData *packet=[NSMutableData dataWithLength:count+24];
        if (!dm_ble_input_seal(&_keys,_sequence,_pending.bytes,count,packet.mutableBytes)) {
            [_delegate bleInputFailed:@"BLE input encryption failed."]; return;
        }
        ++_sequence; [_pending replaceBytesInRange:NSMakeRange(0,count) withBytes:NULL length:0];
        [_peripheral writeValue:packet forCharacteristic:_input type:CBCharacteristicWriteWithoutResponse];
        _progress=NSDate.timeIntervalSinceReferenceDate;
    }
}
- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral { [self drain]; }
- (void)close {
    if (_closed) return; _closed=YES; _ready=NO;
    [_watchdog invalidate]; _watchdog=nil;
    [_manager stopScan]; if (_peripheral) [_manager cancelPeripheralConnection:_peripheral];
    _manager.delegate=nil; _peripheral.delegate=nil; [_pending setLength:0];
    memset(&_keys,0,sizeof(_keys));
}
@end
