#include "ClassicBluetoothWire.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef struct { uint8_t video[32768], controls[32768], events[16], setup[32]; size_t video_size, control_size, event_count, setup_size; } Output;
static bool setup(void *context,const uint8_t *bytes,size_t length) {
    Output *out=context;
    if(length>sizeof(out->setup)-out->setup_size) return false;
    memcpy(out->setup+out->setup_size,bytes,length);out->setup_size+=length;return true;
}
static bool video(void *context, const uint8_t *bytes, size_t length) {
    Output *out = context; assert(out->video_size + length <= sizeof(out->video));
    memcpy(out->video + out->video_size, bytes, length); out->video_size += length; return true;
}
static void event(void *context, uint8_t value) { Output *out = context; out->events[out->event_count++] = value; }
static bool control_video(void *context, const uint8_t *bytes, size_t length) {
    Output *out = context; assert(out->control_size + length <= sizeof(out->controls));
    memcpy(out->controls + out->control_size, bytes, length); out->control_size += length; return true;
}
int main(int argc, char **argv) {
    uint8_t ble[52]={'D','M','B','T','0','0','0','5',3,0,0,0,32};
    for(size_t i=0;i<32;++i) ble[13+i]=(uint8_t)i;
    const uint8_t end[]={0,0,0,0,2,50,51}; memcpy(ble+45,end,sizeof(end));
    for(size_t chunk=1;chunk<=sizeof(ble);++chunk) {
        DMClassicWire test;dm_classic_wire_init(&test);Output received={0};
        for(size_t offset=0;offset<sizeof(ble);offset+=chunk) {
            size_t take=sizeof(ble)-offset;if(take>chunk) take=chunk;
            assert(dm_classic_wire_feed_ble(&test,ble+offset,take,video,event,control_video,setup,&received));
        }
        assert(dm_classic_wire_complete(&test) && received.setup_size==32 && received.video_size==2);
        for(size_t i=0;i<32;++i) assert(received.setup[i]==i);
        assert(received.video[0]==50 && received.video[1]==51 && !received.control_size);
    }
    for(size_t size=31;size<=33;size+=2) {
        DMClassicWire test;dm_classic_wire_init(&test);Output received={0};ble[12]=(uint8_t)size;
        assert(!dm_classic_wire_feed_ble(&test,ble,13,video,event,control_video,setup,&received));
    }
    ble[12]=32;ble[7]='4';
    DMClassicWire test;dm_classic_wire_init(&test);Output received={0};
    assert(!dm_classic_wire_feed_ble(&test,ble,13,video,event,control_video,setup,&received));
    const uint8_t stream[] = {'D','M','B','T','0','0','0','3', 0,0,0,0,3, 0,42,43,
                            1,0,0,0,1,4, 0,0,0,0,2,44,45, 1,0,0,0,1,1};
    for (size_t chunk = 1; chunk <= sizeof(stream); chunk++) {
        DMClassicWire wire; dm_classic_wire_init(&wire); Output out = {0};
        for (size_t offset = 0; offset < sizeof(stream); offset += chunk) {
            size_t n = sizeof(stream) - offset; if (n > chunk) n = chunk;
            assert(dm_classic_wire_feed(&wire, stream + offset, n, video, event, &out));
        }
        const uint8_t expected[] = {0,42,43,44,45};
        assert(out.video_size == sizeof(expected) && !memcmp(out.video, expected, sizeof(expected)));
        assert(out.event_count == 2 && out.events[0] == 4 && out.events[1] == 1);
        assert(dm_classic_wire_complete(&wire));
    }
    const uint8_t duplex[] = {'D','M','B','T','0','0','0','4', 2,0,0,0,3, 91,92,93, 1,0,0,0,1,6, 0,0,0,0,1,42};
    for (size_t chunk = 1; chunk <= sizeof(duplex); chunk++) {
        DMClassicWire state; dm_classic_wire_init(&state); Output out = {0};
        // Separate sinks must never forward control replies to the video decoder.
        for (size_t offset = 0; offset < sizeof(duplex); offset += chunk) {
            size_t n = sizeof(duplex) - offset; if (n > chunk) n = chunk;
            assert(dm_classic_wire_feed_control(&state, duplex + offset, n, video, event, control_video, &out));
        }
        assert(out.video_size == 1 && out.video[0] == 42);
        assert(out.control_size == 3 && !memcmp(out.controls, "\x5b\x5c\x5d", 3));
        assert(out.event_count == 1 && out.events[0] == 6);
        assert(dm_classic_wire_complete(&state));
    }
    const uint8_t legacy[] = {0,1,2,3,4,5,6,7,8,9};
    DMClassicWire wire; Output out = {0}; dm_classic_wire_init(&wire);
    assert(dm_classic_wire_feed(&wire, legacy, sizeof(legacy), video, event, &out));
    assert(wire.legacy && out.video_size == sizeof(legacy) && !memcmp(out.video, legacy, sizeof(legacy)));
    const uint8_t malformed[][14] = {
        {'D','M','B','T','0','0','0','3',0,0,0,0,0,0}, // zero video length
        {'D','M','B','T','0','0','0','3',0,0,0,64,1,0}, // over 16 KiB
        {'D','M','B','T','0','0','0','3',1,0,0,0,2,1}, // wrong event length
        {'D','M','B','T','0','0','0','3',1,0,0,0,1,9}, // unknown event
        {'D','M','B','T','0','0','0','2',0,0,0,0,1,0}, // unknown protocol
        {'D','M','B','T','0','0','0','3',2,0,0,0,1,0}, // unknown record type
    };
    for (size_t i=0; i<sizeof(malformed)/sizeof(malformed[0]); i++) {
        dm_classic_wire_init(&wire); out = (Output){0};
        assert(!dm_classic_wire_feed(&wire, malformed[i], sizeof(malformed[i]), video, event, &out));
    }
    dm_classic_wire_init(&wire); out = (Output){0};
    assert(dm_classic_wire_feed(&wire, stream, sizeof(stream)-1, video, event, &out));
    assert(!dm_classic_wire_complete(&wire));
    if (argc == 2) {
        FILE *fixture = fopen(argv[1], "rb"); assert(fixture);
        dm_classic_wire_init(&wire); out = (Output){0};
        uint8_t block[4096]; size_t count;
        while ((count = fread(block, 1, sizeof(block), fixture))) assert(dm_classic_wire_feed(&wire, block, count, video, event, &out));
        fclose(fixture); assert(dm_classic_wire_complete(&wire));
        assert(out.video_size == 20000 && out.event_count == 2 && out.events[0] == 1 && out.events[1] == 4);
        for (size_t i = 0; i < out.video_size; i++) assert(out.video[i] == (uint8_t)i);
        puts("Java sender → C receiver fixture passed");
    }
    puts("ClassicBluetoothWire: every fragment size, event isolation, legacy, malformed records and truncation passed");
}
