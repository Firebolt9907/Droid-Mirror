#include "WirelessAudioRing.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
static uint64_t generated;
static void produce(DMAudioRing *ring, unsigned frames) {
    uint8_t *pcm=malloc(frames*4);
    for (unsigned i=0;i<frames;i++) {
        int16_t value=(int16_t)(sin((generated++)*2*3.141592653589793*400/48000)*16000);
        for (unsigned channel=0;channel<2;channel++) {
            pcm[i*4+channel*2]=(uint8_t)value;
            pcm[i*4+channel*2+1]=(uint8_t)((uint16_t)value>>8);
        }
    }
    assert(dm_audio_ring_write(ring,pcm,frames)); free(pcm);
}
int main(void) {
    DMAudioRing *ring=calloc(1,sizeof(*ring)); dm_audio_ring_init(ring,50);
    assert(ring->target==5760); // A zero/small video buffer still gets a jitter reserve.
    float left[480],right[480];
    assert(!dm_audio_ring_render(ring,left,right,480));
    produce(ring,1024); assert(!dm_audio_ring_render(ring,left,right,480));
    assert(atomic_load(&ring->read)==0); // Prebuffer doesn't discard initial samples.
    free(ring); ring=calloc(1,sizeof(*ring)); dm_audio_ring_init(ring,50);
    float previous=0; bool started=false;
    // Three minutes of 100 ms delivery bursts on a 10 ms render clock. No
    // hardware-played callbacks: output-device latency cannot inflate this queue.
    for (unsigned tick=0;tick<18000;tick++) {
        if (tick%10==0) produce(ring,4800);
        bool audible=dm_audio_ring_render(ring,left,right,480);
        if (audible) started=true;
        if (started) {
            assert(audible);
            for (unsigned i=0;i<480;i++) {
                assert(fabsf(left[i]-previous)<.06f); assert(left[i]==right[i]); previous=left[i];
            }
        }
        assert(atomic_load(&ring->written)-atomic_load(&ring->read)<=ring->target+4800);
    }
    assert(atomic_load(&ring->underruns)==0 && atomic_load(&ring->trims)==0 && atomic_load(&ring->overflows)==0);
    for (unsigned i=0;i<100;i++) dm_audio_ring_render(ring,left,right,480);
    assert(atomic_load(&ring->underruns)==1 && !ring->playing);
    produce(ring,ring->target); assert(dm_audio_ring_render(ring,left,right,480) && ring->playing);
    assert(atomic_load(&ring->underruns)==1); // A single starvation re-buffers once.
    produce(ring,30000); dm_audio_ring_render(ring,left,right,480);
    assert(atomic_load(&ring->trims)==1 && ring->playing);
    assert(atomic_load(&ring->written)-atomic_load(&ring->read)<=ring->target);
    uint8_t *overflow=calloc(DM_AUDIO_CAPACITY,4);
    assert(!dm_audio_ring_write(ring,overflow,DM_AUDIO_CAPACITY));
    dm_audio_ring_render(ring,left,right,480); assert(!ring->playing && atomic_load(&ring->overflows)==1);
    free(overflow); free(ring);
    puts("Audio ring: three minutes of burst delivery, continuous samples, bounded latency, drift correction, starvation recovery and overflow passed");
}
