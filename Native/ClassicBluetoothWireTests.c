#include "ClassicBluetoothWire.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef struct { uint8_t video[32768], events[16]; size_t video_size, event_count; } Output;
static bool video(void *context, const uint8_t *bytes, size_t length) {
    Output *out = context; assert(out->video_size + length <= sizeof(out->video));
    memcpy(out->video + out->video_size, bytes, length); out->video_size += length; return true;
}
static void event(void *context, uint8_t value) { Output *out = context; out->events[out->event_count++] = value; }
int main(int argc, char **argv) {
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
