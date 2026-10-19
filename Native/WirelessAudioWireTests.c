#include "ClassicBluetoothWire.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static unsigned states, packets, videoBytes;
static bool video(void *context, const uint8_t *bytes, size_t length) { videoBytes+=(unsigned)length; return true; }
static bool audio(void *context, uint8_t type, const uint8_t *bytes, size_t length) {
    if (type==6) { assert(length==1 && bytes[0]==1); ++states; }
    else { assert(type==7 && length==12 && bytes[7]==42 && bytes[8]==0x12); ++packets; }
    return true;
}
int main(void) {
    const uint8_t stream[]={
        'D','M','B','T','0','0','0','6',
        6,0,0,0,1,1,
        7,0,0,0,12,0,0,0,0,0,0,0,42,0x12,0,0x34,0,
        0,0,0,0,2,9,10
    };
    for (size_t chunk=1;chunk<=sizeof(stream);chunk++) {
        DMClassicWire wire; dm_classic_wire_init_video_only(&wire); wire.audio=audio;
        states=packets=videoBytes=0;
        for (size_t offset=0;offset<sizeof(stream);) {
            size_t take=sizeof(stream)-offset; if (take>chunk) take=chunk;
            assert(dm_classic_wire_feed(&wire,stream+offset,take,video,NULL,NULL)); offset+=take;
        }
        assert(states==1 && packets==1 && videoBytes==2 && dm_classic_wire_complete(&wire));
    }
    // No audio callback is installed on Classic or BLE. They reject audio even
    // when an otherwise valid video-only header is present.
    DMClassicWire wire; dm_classic_wire_init_video_only(&wire);
    assert(!dm_classic_wire_feed(&wire,stream,sizeof(stream),video,NULL,NULL));
    const uint32_t invalid[]={0,1,8,11,13,4105,0xffffffff};
    for (size_t i=0;i<sizeof(invalid)/sizeof(*invalid);i++) {
        uint8_t header[]={'D','M','B','T','0','0','0','6',7,0,0,0,0};
        uint32_t size=invalid[i];
        for (int j=0;j<4;j++) header[9+j]=(uint8_t)(size>>(24-j*8));
        dm_classic_wire_init_video_only(&wire); wire.audio=audio;
        assert(!dm_classic_wire_feed(&wire,header,sizeof(header),video,NULL,NULL));
    }
    puts("Wireless audio: all fragmentation boundaries, decoder isolation, opt-in parser and malformed packet bounds passed");
}
