#import "BleInputQueue.h"
#include <assert.h>

static NSData *Envelope(NSData *payload) {
    uint8_t type=0; uint32_t size=CFSwapInt32HostToBig((uint32_t)payload.length);
    NSMutableData *record=[NSMutableData dataWithBytes:&type length:1];
    [record appendBytes:&size length:4]; [record appendData:payload]; return record;
}
static NSData *Text(NSUInteger length, uint8_t value) {
    NSMutableData *raw=[NSMutableData dataWithLength:length];
    uint8_t *p=raw.mutableBytes; memset(p,value,length); p[0]=1;
    uint32_t size=CFSwapInt32HostToBig((uint32_t)length-5); memcpy(p+1,&size,4);
    return Envelope(raw);
}
static NSData *Touch(uint8_t action, uint32_t x, uint64_t pointer) {
    uint8_t p[32]={2,action}; pointer=CFSwapInt64HostToBig(pointer); memcpy(p+2,&pointer,8);
    x=CFSwapInt32HostToBig(x); memcpy(p+10,&x,4); p[18]=1; p[20]=2; p[22]=255; p[31]=1;
    return Envelope([NSData dataWithBytes:p length:32]);
}
static NSData *Drain(DMBleInputQueue *queue, NSUInteger size) {
    NSMutableData *out=[NSMutableData data];
    while (queue.hasWork) { NSData *part=[queue takePacket:size]; assert(part.length); [out appendData:part]; }
    return out;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        DMBleInputQueue *queue=[DMBleInputQueue new];
        NSData *first=Text(1000,7), *second=Text(31,9);
        assert([queue appendRecords:first] && [queue appendRecords:second]);
        NSMutableData *sent=[NSMutableData dataWithData:[queue takePacket:100]];
        [queue acknowledgeVideo:10]; [queue acknowledgeVideo:20];
        [sent appendData:Drain(queue,100)];
        assert([[sent subdataWithRange:NSMakeRange(0,first.length)] isEqual:first]);
        const uint8_t *wire=sent.bytes; assert(wire[first.length]==1);
        uint64_t ack; memcpy(&ack,wire+first.length+5,8); assert(CFSwapInt64BigToHost(ack)==20);
        assert([[sent subdataWithRange:NSMakeRange(first.length+13,second.length)] isEqual:second]);

        // Ready small records share one ATT payload instead of one round trip each.
        for (int i=0;i<10;++i) assert([queue appendRecords:Text(20,(uint8_t)i)]);
        assert([queue takePacket:488].length==250 && !queue.hasWork);

        // A 1000 Hz producer emits at most 60 positions per second. Every
        // position sent is the freshest available; a new down/up/key is a barrier.
        __block NSTimeInterval now=0;
        queue=[[DMBleInputQueue alloc] initWithClock:^{ return now; }];
        NSUInteger emitted=0;
        for (int i=0;i<1000;++i) {
            now=i/1000.0; assert([queue appendRecords:Touch(2,(uint32_t)i,1)]);
            NSData *packet=[queue takePacket:488];
            if (packet) {
                ++emitted; uint32_t x; memcpy(&x,(const uint8_t *)packet.bytes+15,4);
                assert(CFSwapInt32BigToHost(x)==(uint32_t)i);
            }
            assert(queue.pendingBytes<=37);
        }
        assert(emitted>=58 && emitted<=60 && queue.motionDelay>0);
        now+=0.020; assert([queue takePacket:488].length==37);
        assert(!queue.hasWork);
        assert([queue appendRecords:Touch(2,1001,1)]);
        assert(![queue takePacket:488]);
        NSData *up=Touch(1,1002,1); assert([queue appendRecords:up]);
        NSData *edges=[queue takePacket:488]; assert(edges.length==74);
        assert([[edges subdataWithRange:NSMakeRange(37,37)] isEqual:up]);

        // TCP boundaries can split every byte, including across control messages.
        [queue clear]; NSMutableData *raw=[NSMutableData data];
        NSData *down=Touch(0,0,1), *move=Touch(2,50,1);
        [raw appendData:[down subdataWithRange:NSMakeRange(5,32)]];
        [raw appendData:[move subdataWithRange:NSMakeRange(5,32)]];
        [raw appendData:[up subdataWithRange:NSMakeRange(5,32)]];
        for (NSUInteger i=0;i<raw.length;++i)
            assert([queue appendRecords:Envelope([raw subdataWithRange:NSMakeRange(i,1)])]);
        NSMutableData *expected=[down mutableCopy]; [expected appendData:move]; [expected appendData:up];
        assert([Drain(queue,7) isEqual:expected]);

        // Preserve general gesture timing through coalescing and arbitrary
        // delivery delay. There is no navigation classifier or key substitution.
        [queue clear]; [queue synchronizePhoneClock:1000 macClock:5000];
        NSMutableData *timedRaw=[NSMutableData data];
        for (int i=0;i<102;++i) {
            NSData *touch=Touch(i==0 ? 0 : i==101 ? 1 : 2,(uint32_t)i,1);
            NSMutableData *raw=[[touch subdataWithRange:NSMakeRange(5,32)] mutableCopy];
            ((uint8_t *)raw.mutableBytes)[0]=23;
            uint64_t timestamp=CFSwapInt64HostToBig((uint64_t)(5000+i));
            [raw appendBytes:&timestamp length:8];
            assert([queue appendRecords:Envelope(raw)]);
        }
        NSData *timed=Drain(queue,488); assert(timed.length==135);
        uint64_t times[3];
        for (NSUInteger i=0;i<3;++i) {
            const uint8_t *p=(const uint8_t *)timed.bytes+i*45;
            assert(p[0]==0 && p[5]==23);
            memcpy(&times[i],p+37,8); times[i]=CFSwapInt64BigToHost(times[i]);
        }
        assert(times[0]==1000 && times[1]==1100 && times[2]==1101);
        if (argc==2) assert([timed writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES]);
        (void)timedRaw;

        // Do not coalesce moves across keys or distinct pointer/button states.
        [queue clear]; NSData *key=Text(20,3);
        for (NSData *r in @[move,key,Touch(2,70,1),Touch(2,80,2),up]) assert([queue appendRecords:r]);
        assert(Drain(queue,488).length==4*37+key.length);
        // A streamed clipboard/text body may contain bytes that resemble a
        // touch message. Those bytes must never be classified as mouse input.
        [queue clear];
        NSMutableData *largeRaw=[NSMutableData dataWithLength:5014];
        uint8_t *large=largeRaw.mutableBytes; large[0]=9;
        uint32_t textLength=CFSwapInt32HostToBig(5000); memcpy(large+10,&textLength,4);
        assert([queue appendRecords:Envelope([largeRaw subdataWithRange:NSMakeRange(0,14)])]);
        NSData *lookalike=[move subdataWithRange:NSMakeRange(5,32)];
        memcpy(large+14,lookalike.bytes,32); memcpy(large+46,lookalike.bytes,32);
        for (NSUInteger offset=14;offset<largeRaw.length;) {
            NSUInteger length=MIN((NSUInteger)32,largeRaw.length-offset);
            assert([queue appendRecords:Envelope([largeRaw subdataWithRange:NSMakeRange(offset,length)])]);
            offset+=length;
        }
        NSData *largeWire=Drain(queue,488); const uint8_t *encoded=largeWire.bytes;
        NSMutableData *restored=[NSMutableData data];
        for (NSUInteger offset=0;offset<largeWire.length;) {
            uint32_t size; memcpy(&size,encoded+offset+1,4); size=CFSwapInt32BigToHost(size);
            assert(encoded[offset]==0 && size<=largeWire.length-offset-5);
            [restored appendBytes:encoded+offset+5 length:size]; offset+=size+5;
        }
        assert([restored isEqual:largeRaw]);
        assert(![queue appendRecords:[NSData dataWithBytes:"\0\0" length:2]]);
        NSMutableData *invalid=[Touch(2,1,1) mutableCopy]; ((uint8_t *)invalid.mutableBytes)[5]=255;
        assert(![queue appendRecords:invalid] && !queue.hasWork);
        for (int i=0;i<31;++i) assert([queue appendRecords:Text(4096,0)]);
        assert(![queue appendRecords:Text(4096,0)]);
        [queue clear]; assert(!queue.hasWork && queue.pendingBytes==0);
        puts("BLE queue: 60 Hz sustained motion, source gesture timestamps and clock mapping, ATT packing, TCP fragmentation, ordering, ACK priority and bounds passed");
    }
}
