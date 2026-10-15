#import "BleInputQueue.h"

@implementation DMBleInputQueue {
    NSMutableArray<NSData *> *_records;
    NSData *_active;
    NSUInteger _offset, _pendingBytes;
    BOOL _ackPending;
    uint64_t _latestAck;
}
- (instancetype)init {
    if ((self = [super init])) _records = [NSMutableArray array];
    return self;
}
- (NSUInteger)pendingBytes { return _pendingBytes; }
- (BOOL)hasWork { return _pendingBytes || _ackPending; }
- (BOOL)appendRecords:(NSData *)bytes {
    if (!bytes.length || _pendingBytes >= 128 * 1024 || bytes.length > 128 * 1024 - _pendingBytes) return NO;
    const uint8_t *data = bytes.bytes;
    NSMutableArray<NSData *> *records = [NSMutableArray array];
    for (NSUInteger offset = 0; offset < bytes.length;) {
        if (bytes.length - offset < 5 || data[offset] != 0) return NO;
        uint32_t length; memcpy(&length, data + offset + 1, 4); length = CFSwapInt32BigToHost(length);
        if (!length || length > 4096 || length > bytes.length - offset - 5) return NO;
        [records addObject:[bytes subdataWithRange:NSMakeRange(offset, length + 5)]];
        offset += length + 5;
    }
    [_records addObjectsFromArray:records]; _pendingBytes += bytes.length;
    return YES;
}
- (void)acknowledgeVideo:(uint64_t)count { _latestAck = count; _ackPending = YES; }
- (NSData *)takePacket:(NSUInteger)maximum {
    if (!maximum) return nil;
    if (!_active) {
        if (_ackPending) {
            uint8_t header[] = {1, 0, 0, 0, 8};
            uint64_t count = CFSwapInt64HostToBig(_latestAck);
            NSMutableData *ack = [NSMutableData dataWithBytes:header length:sizeof(header)];
            [ack appendBytes:&count length:sizeof(count)];
            _active = ack; _pendingBytes += ack.length; _ackPending = NO;
        } else if (_records.count) {
            _active = _records.firstObject; [_records removeObjectAtIndex:0];
        } else return nil;
        _offset = 0;
    }
    NSUInteger length = MIN(maximum, _active.length - _offset);
    NSData *packet = [_active subdataWithRange:NSMakeRange(_offset, length)];
    _offset += length; _pendingBytes -= length;
    if (_offset == _active.length) { _active = nil; _offset = 0; }
    return packet;
}
- (void)clear { [_records removeAllObjects]; _active = nil; _offset = _pendingBytes = 0; _ackPending = NO; }
@end
