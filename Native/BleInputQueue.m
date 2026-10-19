#import "BleInputQueue.h"
#include <math.h>

// Lengths match the bundled scrcpy 5 control serializer. TCP reads may split
// anywhere, so pointer coalescing must happen after complete message assembly.
static uint32_t DMRead32(const uint8_t *p) { uint32_t n; memcpy(&n,p,4); return CFSwapInt32BigToHost(n); }
static uint16_t DMRead16(const uint8_t *p) { uint16_t n; memcpy(&n,p,2); return CFSwapInt16BigToHost(n); }
static NSUInteger DMControlSize(const uint8_t *p, NSUInteger n) {
    if (!n) return 0;
    switch (p[0]) {
        case 0: return 14;
        case 1: case 22: return n < 5 ? 0 : 5 + (NSUInteger)DMRead32(p+1);
        case 2: return 32;
        case 23: return 40; // Timestamped touch, Bluetooth companion protocol.
        case 26: return 6;
        case 3: case 24: return 21;
        case 4: case 8: case 10: case 18: return 2;
        case 25: case 5: case 6: case 7: case 11: case 15: case 17: case 19: case 20: return 1;
        case 9: return n < 14 ? 0 : 14 + (NSUInteger)DMRead32(p+10);
        case 12: {
            if (n < 8) return 0;
            NSUInteger descriptor = 8 + p[7];
            return n < descriptor + 2 ? 0 : descriptor + 2 + DMRead16(p+descriptor);
        }
        case 13: return n < 5 ? 0 : 5 + DMRead16(p+3);
        case 14: return 3;
        case 16: return n < 2 ? 0 : 2 + p[1];
        case 21: return 5;
        default: return NSUIntegerMax;
    }
}
static BOOL DMSamePointerMove(NSData *previous, NSData *next) {
    if (previous.length != next.length || (previous.length != 37 && previous.length != 45)) return NO;
    const uint8_t *a = (const uint8_t *)previous.bytes + 5, *b = (const uint8_t *)next.bytes + 5;
    return (a[0] == 2 || a[0] == 23) && a[0] == b[0] && (a[1] == 2 || a[1] == 7) && a[1] == b[1]
        && memcmp(a+2,b+2,8) == 0 && memcmp(a+18,b+18,14) == 0;
}
@interface DMBleQueuedRecord : NSObject
@property(nonatomic, strong) NSData *bytes;
@property(nonatomic) BOOL motion;
@property(nonatomic) BOOL wheel;
@property(nonatomic) uint64_t motionBucket;
@end
@implementation DMBleQueuedRecord
@end

@implementation DMBleInputQueue {
    NSMutableArray<DMBleQueuedRecord *> *_records;
    NSMutableData *_input;
    NSData *_active;
    NSUInteger _offset, _pendingBytes, _remainingControl;
    BOOL _ackPending;
    NSData *_fallback;
    uint64_t _latestAck;
    NSTimeInterval (^_clock)(void);
    NSTimeInterval _lastMotion;
    uint64_t _lastMotionBucket;
    BOOL _clockReady;
    int64_t _phoneClockOffset;
}
- (instancetype)init {
    return [self initWithClock:^{ return NSProcessInfo.processInfo.systemUptime; }];
}
- (instancetype)initWithClock:(NSTimeInterval (^)(void))clock {
    if ((self = [super init])) {
        _records = [NSMutableArray array]; _input = [NSMutableData data];
        _clock = [clock copy]; _lastMotion = -1;
    }
    return self;
}
- (NSUInteger)pendingBytes { return _pendingBytes + _input.length; }
- (BOOL)hasWork { return _pendingBytes || _ackPending || _fallback; }
- (NSTimeInterval)motionDelay {
    if (_active || _ackPending || _fallback || !_records.count || !_records.firstObject.motion || _lastMotion < 0) return 0;
    // Flush the final position before a release/key/other state transition.
    if (_records.count > 1 || _records.firstObject.motionBucket != _lastMotionBucket) return 0;
    return MAX(0, _lastMotion + 1.0 / 60.0 - _clock());
}
- (BOOL)appendRecords:(NSData *)bytes {
    if (!bytes.length || self.pendingBytes >= 128 * 1024 || bytes.length > 128 * 1024 - self.pendingBytes) return NO;
    const uint8_t *data = bytes.bytes;
    NSMutableData *input = [_input mutableCopy];
    for (NSUInteger offset = 0; offset < bytes.length;) {
        if (bytes.length - offset < 5 || data[offset] != 0) return NO;
        uint32_t length = DMRead32(data + offset + 1);
        if (!length || length > 4096 || length > bytes.length - offset - 5) return NO;
        [input appendBytes:data + offset + 5 length:length]; offset += length + 5;
    }
    NSMutableArray<DMBleQueuedRecord *> *records = [NSMutableArray array];
    NSUInteger consumed = 0, remaining = _remainingControl;
    while (consumed < input.length) {
        const uint8_t *raw = (const uint8_t *)input.bytes + consumed;
        NSUInteger available = input.length - consumed;
        NSUInteger length;
        BOOL messageStart = remaining == 0;
        if (remaining) {
            length = MIN(remaining, available); remaining -= length;
        } else {
            length = DMControlSize(raw, available);
            if (length > 256 * 1024) return NO;
            if (!length) break;
            if (length > available) {
                if (length <= 4096) break;
                // Large clipboard/UHID records retain streaming behavior: do
                // not accumulate the entire body before forwarding it.
                remaining = length - available; length = available;
            }
        }
        for (NSUInteger offset = 0; offset < length; offset += 4096) {
            NSUInteger count = MIN((NSUInteger)4096, length - offset);
            uint8_t type = 0; uint32_t size = CFSwapInt32HostToBig((uint32_t)count);
            NSMutableData *record = [NSMutableData dataWithBytes:&type length:1];
            [record appendBytes:&size length:4]; [record appendBytes:raw+offset length:count];
            DMBleQueuedRecord *queued = [DMBleQueuedRecord new]; queued.bytes = record;
            queued.wheel = messageStart && length == 21 && raw[0] == 24;
            queued.motion = messageStart && ((length == 32 && raw[0] == 2) || (length == 40 && raw[0] == 23))
                && (raw[1] == 2 || raw[1] == 7);
            uint64_t sourceTime = (uint64_t)(_clock() * 1000);
            if (messageStart && length == 40 && raw[0] == 23) {
                if (!_clockReady) return NO;
                uint64_t timestamp; memcpy(&timestamp, raw + 32, 8); timestamp = CFSwapInt64BigToHost(timestamp); sourceTime = timestamp;
                if (timestamp > INT64_MAX || (int64_t)timestamp + _phoneClockOffset < 0) return NO;
                timestamp = CFSwapInt64HostToBig((uint64_t)((int64_t)timestamp + _phoneClockOffset));
                memcpy((uint8_t *)record.mutableBytes + 37, &timestamp, 8);
            }
            queued.motionBucket = (sourceTime / 1000) * 60 + (sourceTime % 1000) * 60 / 1000;
            [records addObject:queued];

        }
        consumed += length;
    }
    [input replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0]; _input = input; _remainingControl = remaining;
    for (DMBleQueuedRecord *record in records) {
        // Replace unsent moves only within one 60 Hz source-time bucket.
        // Retain samples from earlier buckets even during BLE backpressure.
        // Keep the same pointer/state requirement; DOWN/UP, keys, scrolling and other pointers are barriers.
        if (_records.count && _records.lastObject.motion && record.motion && _records.lastObject.motionBucket == record.motionBucket && DMSamePointerMove(_records.lastObject.bytes, record.bytes)) {
            _pendingBytes -= _records.lastObject.bytes.length; [_records removeLastObject];
        }
        if (_records.count && _records.lastObject.wheel && record.wheel) {
            const uint8_t *a = (const uint8_t *)_records.lastObject.bytes.bytes + 5;
            const uint8_t *b = (const uint8_t *)record.bytes.bytes + 5;
            if (!memcmp(a+1,b+1,12)) {
                int64_t dx=(int32_t)DMRead32(a+13)+(int64_t)(int32_t)DMRead32(b+13);
                int64_t dy=(int32_t)DMRead32(a+17)+(int64_t)(int32_t)DMRead32(b+17);
                if (dx>=INT32_MIN && dx<=INT32_MAX && dy>=INT32_MIN && dy<=INT32_MAX) {
                    NSMutableData *merged=[_records.lastObject.bytes mutableCopy];
                    uint32_t x=CFSwapInt32HostToBig((uint32_t)(int32_t)dx), y=CFSwapInt32HostToBig((uint32_t)(int32_t)dy);
                    memcpy((uint8_t *)merged.mutableBytes+18,&x,4); memcpy((uint8_t *)merged.mutableBytes+22,&y,4);
                    _records.lastObject.bytes=merged; continue;
                }
            }
        }
        [_records addObject:record]; _pendingBytes += record.bytes.length;
    }
    return YES;
}
- (void)synchronizePhoneClock:(uint64_t)phone macClock:(uint64_t)mac {
    _phoneClockOffset = (int64_t)phone - (int64_t)mac; _clockReady = YES;
}
- (void)acknowledgeVideo:(uint64_t)count { _latestAck = count; _ackPending = YES; }
- (void)requestBluetoothVideo:(uint64_t)count nonce:(NSData *)nonce {
    NSParameterAssert(nonce.length==32);
    uint8_t header[]={2,0,0,0,40}; uint64_t offset=CFSwapInt64HostToBig(count);
    NSMutableData *record=[NSMutableData dataWithBytes:header length:5];
    [record appendData:nonce]; [record appendBytes:&offset length:8]; _fallback=record;
}
- (NSData *)takePacket:(NSUInteger)maximum {
    if (!maximum) return nil;
    NSMutableData *packet = [NSMutableData data];
    while (packet.length < maximum) {
        if (!_active) {
            if (_fallback) {
                _active=_fallback; _pendingBytes+=_active.length; _fallback=nil;
            } else if (_ackPending) {
                uint8_t header[] = {1, 0, 0, 0, 8};
                uint64_t count = CFSwapInt64HostToBig(_latestAck);
                NSMutableData *ack = [NSMutableData dataWithBytes:header length:sizeof(header)];
                [ack appendBytes:&count length:sizeof(count)];
                _active = ack; _pendingBytes += ack.length; _ackPending = NO;
            } else if (_records.count) {
                if (self.motionDelay > 0) break;
                DMBleQueuedRecord *record = _records.firstObject;
                _active = record.bytes; if (record.motion) { _lastMotion = _clock(); _lastMotionBucket = record.motionBucket; }
                [_records removeObjectAtIndex:0];
            } else break;
            _offset = 0;
        }
        NSUInteger length = MIN(maximum - packet.length, _active.length - _offset);
        [packet appendBytes:(const uint8_t *)_active.bytes + _offset length:length];
        _offset += length; _pendingBytes -= length;
        if (_offset == _active.length) { _active = nil; _offset = 0; }
    }
    return packet.length ? packet : nil;
}
- (void)clear { [_records removeAllObjects]; [_input setLength:0]; _active = nil; _offset = _pendingBytes = _remainingControl = 0; _ackPending = NO; _fallback=nil; _lastMotion = -1; }
@end
