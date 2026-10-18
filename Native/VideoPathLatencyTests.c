#include "VideoPathLatency.h"
#include "ClassicBluetoothWire.h"
#include <assert.h>
#include <stdio.h>
static uint64_t observed;
static void sample(void *context, uint64_t timestamp) { observed=timestamp; }
static bool video(void *context, const uint8_t *bytes, size_t length) { assert(0); return false; }
int main(void) {
    DMLatencySamples bt={0}, candidate={0};
    assert(!dm_latency_ready(&bt,&candidate));
    // Large unknown clock offset cancels; slow continuous delivery still loses.
    for (int i=0;i<7;i++) { dm_latency_add(&bt,-1234.0+.080); dm_latency_add(&candidate,-1234.0+.200); }
    assert(dm_latency_slower(&bt,&candidate));
    for (int i=0;i<7;i++) dm_latency_add(&candidate,-1234.0+.030);
    assert(!dm_latency_slower(&bt,&candidate));
    dm_latency_add(&candidate,-1234.0+2); // Single jitter spike is ignored.
    assert(!dm_latency_slower(&bt,&candidate));
    for (int i=0;i<7;i++) dm_latency_add(&candidate,-1234.0+.085);
    assert(!dm_latency_slower(&bt,&candidate)); // Ten ms hysteresis.
    DMClassicWire wire; dm_classic_wire_init_video_only(&wire); wire.latency=sample;
    const uint8_t bytes[]={'D','M','B','T','0','0','0','6',5,0,0,0,8,0,0,0,0,1,2,3,4};
    for (size_t i=0;i<sizeof(bytes);i++) assert(dm_classic_wire_feed(&wire,bytes+i,1,video,NULL,NULL));
    assert(observed==0x01020304 && dm_classic_wire_complete(&wire));
    dm_classic_wire_init_video_only(&wire);
    uint8_t invalid[]={'D','M','B','T','0','0','0','6',5,0,0,0,9};
    assert(!dm_classic_wire_feed(&wire,invalid,sizeof(invalid),video,NULL,NULL));
    puts("Video latency: clock offset, slower/faster paths, jitter, hysteresis and fragmented markers passed");
}
