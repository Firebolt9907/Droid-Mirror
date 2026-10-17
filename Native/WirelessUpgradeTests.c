#include "ClassicBluetoothWire.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char expected[70000];
static size_t received;
static bool video(void *context, const uint8_t *bytes, size_t length) {
    assert(received + length <= sizeof(expected));
    assert(!memcmp(bytes, expected + received, length));
    received += length;
    return true;
}
static void event(void *context, uint8_t value) { assert(0); }
static void feed(const char *path, size_t skip, size_t chunk) {
    FILE *file = fopen(path,"rb"); assert(file);
    assert(!fseek(file,skip,SEEK_SET));
    DMClassicWire wire; dm_classic_wire_init_video_only(&wire);
    uint8_t buffer[4096]; size_t n;
    while ((n=fread(buffer,1,chunk,file)))
        assert(dm_classic_wire_feed(&wire,buffer,n,video,event,NULL));
    assert(dm_classic_wire_complete(&wire));
    fclose(file);
}
int main(int argc, char **argv) {
    assert(argc == 4);
    FILE *file=fopen(argv[3],"rb"); assert(file);
    assert(fread(expected,1,sizeof(expected),file)==sizeof(expected)); fclose(file);
    for (size_t chunk=1; chunk<=4096; chunk = chunk<16 ? chunk+1 : chunk*2) {
        received=0;
        feed(argv[1],0,chunk); assert(received==2683);
        feed(argv[2],40,chunk); assert(received==sizeof(expected));
    }
    puts("Wireless upgrade: Java-to-C handoff at every tested fragment size preserves exact decoder bytes");
}
