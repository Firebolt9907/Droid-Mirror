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
static NSData *Wheel(int32_t dx, int32_t dy) {
    uint8_t p[21]={24};
    uint32_t x=CFSwapInt32HostToBig(232), y=CFSwapInt32HostToBig(528);
    memcpy(p+1,&x,4); memcpy(p+5,&y,4);
    p[9]=1; p[10]=208; p[11]=4; p[12]=32;
    x=CFSwapInt32HostToBig((uint32_t)dx); y=CFSwapInt32HostToBig((uint32_t)dy);
    memcpy(p+13,&x,4); memcpy(p+17,&y,4);
    return Envelope([NSData dataWithBytes:p length:21]);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        DMBleInputQueue *queue=[DMBleInputQueue new];
        assert([queue appendRecords:Wheel(10,-120)] && [queue appendRecords:Wheel(-3,20)]);
        NSData *wheel=Drain(queue,488); assert([wheel isEqual:Wheel(7,-100)]);
        if (argc>2) assert([wheel writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES]);
        // Edges are barriers, and partially transmitted commands are immutable.
        assert([queue appendRecords:Wheel(1,2)]);
        assert([queue appendRecords:Touch(0,0,1)]);
        assert([queue appendRecords:Wheel(3,4)]);
        assert(Drain(queue,488).length==26+37+26);
        assert([queue appendRecords:Wheel(INT32_MAX,0)] && [queue appendRecords:Wheel(1,0)]);
        assert(Drain(queue,488).length==52); // No signed overflow while summing.
        assert([queue appendRecords:Wheel(1,2)]);
        NSMutableData *partial=[[queue takePacket:7] mutableCopy];
        assert([queue appendRecords:Wheel(3,4)]); [partial appendData:Drain(queue,5)];
        NSMutableData *expectedWheel=[Wheel(1,2) mutableCopy]; [expectedWheel appendData:Wheel(3,4)];
        assert([partial isEqual:expectedWheel]);
        uint8_t cameraRequest=25;
        NSData *cutoutRequest=Envelope([NSData dataWithBytes:&cameraRequest length:1]);
        assert([queue appendRecords:cutoutRequest]);
        assert([Drain(queue,488) isEqual:cutoutRequest]);
        const uint8_t secureCandidate[] = {26, 1, 1, 2, 3, 4};
        NSData *secureRequest=Envelope([NSData dataWithBytes:secureCandidate length:sizeof(secureCandidate)]);
        assert([queue appendRecords:secureRequest]);
        assert([Drain(queue,3) isEqual:secureRequest]); // Candidate command survives tiny BLE packet boundaries.
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

        // A 1000 Hz producer is reduced by source-time buckets, not by radio
        // completion times. Backpressure must not erase the gesture trajectory.
        __block NSTimeInterval now=0;
        queue=[[DMBleInputQueue alloc] initWithClock:^{ return now; }];
        for (int i=0;i<1000;++i) {
            now=i/1000.0; assert([queue appendRecords:Touch(2,(uint32_t)i,1)]);
        }
        assert(queue.pendingBytes==60*37);
        now=2; NSData *reduced=Drain(queue,488); assert(reduced.length==60*37);
        uint32_t previous=0;
        for (NSUInteger i=0;i<60;++i) {
            uint32_t x; memcpy(&x,(const uint8_t *)reduced.bytes+i*37+15,4); x=CFSwapInt32BigToHost(x);
            assert(x>previous && x-previous<=17); previous=x;
        }
        assert(previous==999); // Newest sample in every source bucket survives.
        assert([queue appendRecords:Touch(2,1000,1)]);
        assert([queue takePacket:488].length==37);
        now=2.001; assert([queue appendRecords:Touch(2,1001,1)]);
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
            uint8_t *sample=raw.mutableBytes; sample[0]=23;
            uint32_t y=CFSwapInt32HostToBig(1000-i*8); memcpy(sample+14,&y,4);
            sample[18]=1; sample[19]=208; sample[20]=4; sample[21]=32; // 464x1056

            uint64_t timestamp=CFSwapInt64HostToBig((uint64_t)(5000+i));
            [raw appendBytes:&timestamp length:8];
            assert([queue appendRecords:Envelope(raw)]);
        }
        NSData *timed=Drain(queue,488); assert(timed.length>=7*45 && timed.length<=9*45);
        uint64_t firstTime=0, lastTime=0;
        for (NSUInteger i=0;i<timed.length/45;++i) {
            const uint8_t *p=(const uint8_t *)timed.bytes+i*45;
            assert(p[0]==0 && p[5]==23);
            uint64_t time; memcpy(&time,p+37,8); time=CFSwapInt64BigToHost(time);
            if (!i) firstTime=time; else assert(time>lastTime && time-lastTime<=33);
            lastTime=time;
        }
        assert(firstTime==1000 && lastTime==1101);
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
        // A BLE fallback signal must wait for an in-progress envelope, then
        // precede ordinary input and remain intact across small ATT packets.
        for (NSUInteger mtu=1;mtu<=32;mtu++) {
            [queue clear]; NSData *first=Text(20,3), *next=Text(10,4);
            assert([queue appendRecords:first]);
            NSMutableData *actual=[[queue takePacket:3] mutableCopy];
            [queue acknowledgeVideo:42]; [queue requestBluetoothVideo:42 nonce:[NSMutableData dataWithLength:32]];
            assert([queue appendRecords:next]); [actual appendData:Drain(queue,mtu)];
            NSMutableData *expected=[first mutableCopy];
            uint8_t fallback[45]={2,0,0,0,40}; fallback[44]=42;
            uint8_t ack[]={1,0,0,0,8,0,0,0,0,0,0,0,42};
            [expected appendBytes:fallback length:45]; [expected appendBytes:ack length:13];
            [expected appendData:next]; assert([actual isEqual:expected]);
        }
        [queue requestBluetoothVideo:42 nonce:[NSMutableData dataWithLength:32]]; [queue clear]; assert(!queue.hasWork);
        puts("BLE queue: 60 Hz sustained motion, source gesture timestamps and clock mapping, ATT packing, TCP fragmentation, ordering, ACK priority and bounds passed");
    }
}
