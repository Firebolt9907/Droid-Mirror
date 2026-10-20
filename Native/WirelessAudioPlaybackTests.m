#import "WirelessAudioPlayback.h"
#include <assert.h>
@interface TestAudioEngine : NSObject
@property(nonatomic, getter=isRunning) BOOL running;
@end
@implementation TestAudioEngine
- (void)stop { self.running=NO; }
@end
static void pts(uint8_t *bytes,uint64_t value) {
    for (NSUInteger i=0;i<16;i++) bytes[i]=(uint8_t)(value>>(56-8*i));
}
int main(void) {
    @autoreleasepool {
        DMWirelessAudioPlayback *audio=[DMWirelessAudioPlayback new];
        TestAudioEngine *engine=[TestAudioEngine new]; engine.running=YES;
        audio.engine=(id)engine; audio.buffer=[DMWirelessAudioBuffer new];
        dm_audio_ring_init(&audio.buffer->ring,50);
        uint8_t packet[4104]={0}; pts(packet,1000000);
        for (NSUInteger i=8;i<sizeof(packet);i+=4) { packet[i+1]=0x80; packet[i+2]=0xff; packet[i+3]=0x7f; }
        assert([audio appendPacket:packet length:sizeof(packet)]);
        assert(![audio appendPacket:packet length:sizeof(packet)]); // Duplicate PTS.
        assert(![audio appendPacket:packet length:13]);
        for (NSUInteger i=1;i<16;i++) { pts(packet,1000000+i*21333); assert([audio appendPacket:packet length:sizeof(packet)]); }
        float left[480],right[480];
        assert(dm_audio_ring_render(&audio.buffer->ring,left,right,480));
        assert(left[300]==-1.0f && right[300]>.999f);
        // Samples are consumed by the render cursor, independent of downstream
        // output latency and delayed main-thread/hardware completion callbacks.
        assert(atomic_load(&audio.buffer->ring.read)>0);
        [audio stop]; assert(!engine.running);
        assert(![audio appendPacket:packet length:sizeof(packet)]);
        puts("Wireless audio playback: stereo conversion, monotonic PTS, continuous render cursor and stop passed");
    }
}
