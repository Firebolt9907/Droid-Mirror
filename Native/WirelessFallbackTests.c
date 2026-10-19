#include "ClassicBluetoothWire.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned char expected[70000];
static size_t received;
static bool video(void *context,const uint8_t *bytes,size_t length) {
    assert(received+length<=sizeof(expected));
    assert(!memcmp(bytes,expected+received,length)); received+=length; return true;
}
static void event(void *context,uint8_t value) { assert(value==6); }
static void feed(DMClassicWire *wire,const char *path,size_t skip,size_t chunk) {
    FILE *file=fopen(path,"rb"); assert(file); assert(!fseek(file,skip,SEEK_SET));
    uint8_t bytes[4096]; size_t count;
    while ((count=fread(bytes,1,chunk,file))) assert(dm_classic_wire_feed(wire,bytes,count,video,event,NULL));
    fclose(file);
}
int main(int argc,char **argv) {
    assert(argc==5); FILE *file=fopen(argv[4],"rb"); assert(file);
    assert(fread(expected,1,sizeof(expected),file)==sizeof(expected)); fclose(file);
    for (size_t chunk=1;chunk<=4096;chunk=chunk<16 ? chunk+1 : chunk*2) {
        DMClassicWire classic,wifi; dm_classic_wire_init_video_only(&classic); dm_classic_wire_init_video_only(&wifi);
        received=0; feed(&classic,argv[1],0,chunk); assert(dm_classic_wire_complete(&classic));
        feed(&wifi,argv[2],40,chunk); assert(!dm_classic_wire_complete(&wifi));
        // Discard the incomplete ADB envelope, retaining the same Classic parser,
        // output socket and scrcpy process. Resume bytes finish its codec frame.
        feed(&classic,argv[3],0,chunk);
        assert(received==sizeof(expected) && dm_classic_wire_complete(&classic));
    }
    DMClassicWire wifi; dm_classic_wire_init_video_only(&wifi);
    const uint8_t heartbeat[]={'D','M','B','T','0','0','0','6',1,0,0,0,1,6};
    assert(dm_classic_wire_feed(&wifi,heartbeat,sizeof(heartbeat),video,event,NULL));
    assert(dm_classic_wire_complete(&wifi));
    const uint8_t invalid[]={1,0,0,0,1,2};
    assert(!dm_classic_wire_feed(&wifi,invalid,sizeof(invalid),video,event,NULL));
    puts("Native fallback: partial Wi-Fi packet discarded, exact same decoder stream resumed over Classic, heartbeat isolation passed");
}
