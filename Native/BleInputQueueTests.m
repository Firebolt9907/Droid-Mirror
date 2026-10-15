#import "BleInputQueue.h"
#include <assert.h>

static NSData *Record(NSUInteger length, uint8_t value) {
    NSMutableData *record = [NSMutableData dataWithLength:length + 5];
    uint8_t *bytes = record.mutableBytes; bytes[0] = 0;
    uint32_t size = CFSwapInt32HostToBig((uint32_t)length); memcpy(bytes + 1, &size, 4);
    memset(bytes + 5, value, length); return record;
}
int main(void) {
    @autoreleasepool {
        DMBleInputQueue *queue = [DMBleInputQueue new];
        NSData *first = Record(1000, 7), *second = Record(31, 9);
        assert([queue appendRecords:first] && [queue appendRecords:second]);
        NSMutableData *sent = [NSMutableData dataWithData:[queue takePacket:100]];
        [queue acknowledgeVideo:10]; [queue acknowledgeVideo:20];
        while (sent.length < first.length) [sent appendData:[queue takePacket:100]];
        assert([sent isEqual:first]); // No ACK may split an active input envelope.
        NSData *ack = [queue takePacket:488];
        assert(ack.length == 13 && ((const uint8_t *)ack.bytes)[0] == 1);
        uint64_t count; memcpy(&count, (const uint8_t *)ack.bytes + 5, 8);
        assert(CFSwapInt64BigToHost(count) == 20); // Latest cumulative ACK overtakes queued input.
        assert([[queue takePacket:488] isEqual:second]);
        assert(!queue.hasWork && !queue.pendingBytes);

        // Sustain input and ACK pressure, including ATT-sized splits of the ACK.
        NSMutableData *wire = [NSMutableData data], *expected = [NSMutableData data];
        for (NSUInteger i = 0; i < 200; ++i) {
            NSData *record = Record(32, (uint8_t)i);
            assert([queue appendRecords:record]); [expected appendData:record];
            [queue acknowledgeVideo:i];
            [wire appendData:[queue takePacket:7]];
        }
        while (queue.hasWork) [wire appendData:[queue takePacket:7]];
        const uint8_t *bytes = wire.bytes;
        NSMutableData *inputs = [NSMutableData data]; NSUInteger acknowledgements = 0;
        uint64_t last = 0;
        for (NSUInteger offset = 0; offset < wire.length;) {
            assert(wire.length - offset >= 5);
            uint32_t size; memcpy(&size, bytes + offset + 1, 4); size = CFSwapInt32BigToHost(size);
            assert(size <= wire.length - offset - 5);
            if (bytes[offset] == 0) [inputs appendBytes:bytes + offset length:size + 5];
            else {
                assert(bytes[offset] == 1 && size == 8);
                memcpy(&count, bytes + offset + 5, 8); count = CFSwapInt64BigToHost(count);
                assert(count >= last); last = count; ++acknowledgements;
            }
            offset += size + 5;
        }
        assert([inputs isEqual:expected] && acknowledgements > 5 && last == 199);
        assert(![queue appendRecords:[NSData dataWithBytes:"\0\0" length:2]]);
        assert(![queue appendRecords:Record(4097, 0)] && !queue.hasWork);
        for (int i = 0; i < 31; ++i) assert([queue appendRecords:Record(4096, 0)]);
        assert(![queue appendRecords:Record(4096, 0)]);
        [queue clear]; assert(!queue.hasWork && queue.pendingBytes == 0);
        puts("BLE queue: ACK priority, complete envelopes, burst ordering, coalescing and bounds passed");
    }
}
