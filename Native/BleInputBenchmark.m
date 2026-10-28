#import "BleInputQueue.h"
#include "BleInputCrypto.h"
#include <assert.h>
#include <math.h>

static uint32_t Read32(const uint8_t *p) { uint32_t v; memcpy(&v,p,4); return CFSwapInt32BigToHost(v); }
static void Write32(uint8_t *p, uint32_t v) { v=CFSwapInt32HostToBig(v); memcpy(p,&v,4); }
static NSData *Record(NSData *payload) {
    uint8_t header[5]={0}; Write32(header+1,(uint32_t)payload.length);
    NSMutableData *data=[NSMutableData dataWithBytes:header length:5]; [data appendData:payload]; return data;
}
static NSUInteger Percentile(NSArray<NSNumber *> *values, double p) {
    NSArray *sorted=[values sortedArrayUsingSelector:@selector(compare:)];
    return sorted.count ? [sorted[MAX(0,(NSInteger)ceil(sorted.count*p)-1)] unsignedIntegerValue] : 0;
}
static NSDictionary *Run(NSUInteger mtu, NSUInteger service, BOOL stall) {
    NSUInteger maximum=MIN((NSUInteger)512,mtu-3);
    if (maximum<=24) return @{ @"mtu":@(mtu), @"supported":@NO,
        @"reason":@"ATT value cannot hold the 24-byte authenticated input envelope plus payload" };
    __block NSTimeInterval clock=0;
    DMBleInputQueue *queue=[[DMBleInputQueue alloc] initWithClock:^{ return clock; }];
    NSMutableData *text=[NSMutableData dataWithLength:4000];
    uint8_t *textBytes=text.mutableBytes; memset(textBytes,'x',text.length); textBytes[0]=1; Write32(textBytes+1,3995);
    assert([queue appendRecords:Record(text)]);
    DMBleInputKeys keys={0}; // Synthetic, process-local benchmark keys only.
    memset(keys.encryption,7,32); memset(keys.authentication,11,32);
    uint64_t sequence=1, pendingSequence=0;
    NSData *pending=nil;
    NSMutableData *received=[NSMutableData data];
    NSMutableArray<NSNumber *> *latency=[NSMutableArray array];
    NSUInteger due=0, high=queue.pendingBytes, packets=0, wire=0, plainBytes=0, records=0, touches=0, end=0;
    for (NSUInteger now=0;now<20000;++now) {
        clock=now/1000.0; end=now;
        if (now<1000) {
            uint8_t touch[32]={2,2}; touch[1]=now==0 ? 0 : now==999 ? 1 : 2;
            Write32(touch+10,(uint32_t)now); touch[18]=1; touch[20]=2;
            assert([queue appendRecords:Record([NSData dataWithBytes:touch length:32])]);
        }
        if (now<3000 && now%100==0) {
            uint8_t key[14]={0}; Write32(key+2,(uint32_t)now);
            assert([queue appendRecords:Record([NSData dataWithBytes:key length:14])]);
        }
        high=MAX(high,queue.pendingBytes);
        if (!(stall && now>=500 && now<1000)) {
            if (pending && now>=due) {
                NSMutableData *plain=[NSMutableData dataWithLength:pending.length-24];
                assert(dm_ble_input_open(&keys,pendingSequence,pending.bytes,pending.length,plain.mutableBytes));
                [received appendData:plain]; pending=nil;
                // Parse the actual reconstructed byte stream, including records
                // spanning ATT packets. Key timestamps measure full delivery.
                while (received.length>=5) {
                    const uint8_t *p=received.bytes;
                    NSUInteger count=Read32(p+1); assert(p[0]==0 && count<=4096);
                    if (received.length<5+count) break;
                    const uint8_t *payload=p+5;
                    if (payload[0]==0) {
                        assert(count==14);
                        NSUInteger created=Read32(payload+2);
                        assert(created==latency.count*100); // Every key, in order.
                        [latency addObject:@(now-created)];
                    } else if (payload[0]==2) { assert(count==32); touches++; }
                    else { assert(payload[0]==1 && count==4000); }
                    records++;
                    [received replaceBytesInRange:NSMakeRange(0,5+count) withBytes:NULL length:0];
                }
            }
            if (!pending) {
                NSData *plain=[queue takePacket:maximum-24];
                if (plain) {
                    NSMutableData *sealed=[NSMutableData dataWithLength:plain.length+24];
                    assert(dm_ble_input_seal(&keys,sequence,plain.bytes,plain.length,sealed.mutableBytes));
                    pendingSequence=sequence++; pending=sealed; due=now+service;
                    packets++; wire+=sealed.length; plainBytes+=plain.length;
                }
            }
        }
        if (now>=3000 && !pending && !queue.hasWork) break;
    }
    assert(!pending && !queue.hasWork && !received.length && latency.count==30);
    return @{ @"mtu":@(mtu), @"supported":@YES, @"modeled_att_operation_ms":@(service), @"stall":@(stall),
        @"modeled_elapsed_ms":@(end), @"key_samples":@(latency.count), @"key_completion_p50_ms":@(Percentile(latency,.5)),
        @"key_completion_p95_ms":@(Percentile(latency,.95)), @"key_completion_p99_ms":@(Percentile(latency,.99)),
        @"queue_high_water_bytes":@(high), @"att_packets":@(packets), @"att_value_bytes":@(wire),
        @"delivered_record_bytes":@(plainBytes), @"delivered_records":@(records), @"delivered_touch_samples":@(touches),
        @"rejected_keys":@0, @"modeled_record_bytes_per_second":@(plainBytes*1000.0/MAX(end,1)) };
}
int main(void) {
    @autoreleasepool {
        NSDictionary *output=@{ @"kind":@"host simulation, not measured BLE radio performance",
            @"assumptions":@"Production binary input queue and seal/open; 4000-byte text burst, 1000 Hz touch for 1 s, key every 100 ms for 3 s; one serialized ATT operation at fixed 8/30 ms, optional readiness stall 500–1000 ms; no RF loss, real device actions, video ACKs, return reads, OS buffering or receiver processing. MTU 23 is rejected as in the production input transport. Touch coalescing is intentional; all 30 keys must survive in order.",
            @"cases":@[Run(23,8,NO),Run(185,8,NO),Run(517,8,NO),Run(517,30,NO),Run(517,8,YES)] };
        NSError *error=nil;
        NSData *json=[NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
        assert(json && !error); puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    }
    return 0;
}
