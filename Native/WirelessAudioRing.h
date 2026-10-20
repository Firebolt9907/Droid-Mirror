#ifndef DM_WIRELESS_AUDIO_RING_H
#define DM_WIRELESS_AUDIO_RING_H
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#define DM_AUDIO_RATE 48000
#define DM_AUDIO_CAPACITY 48000
#define DM_AUDIO_FADE 240
#define DM_AUDIO_MIN_RESERVE_MS 240
#define DM_AUDIO_MAX_RESERVE_MS 360
// One network producer, one audio-render consumer. No locks, allocation, dispatch
// or device-completion callbacks on the real-time audio thread.
typedef struct {
    _Atomic uint64_t written, read;
    _Atomic unsigned underruns, trims, overflows;
    _Atomic bool overflow;
    unsigned target;
    bool playing;
    double fraction;
    unsigned fade;
    float previous[2], fadeFrom[2];
    float samples[DM_AUDIO_CAPACITY * 2];
} DMAudioRing;
static inline void dm_audio_ring_init(DMAudioRing *ring, unsigned milliseconds) {
    memset(ring,0,sizeof(*ring));
    atomic_init(&ring->written,0); atomic_init(&ring->read,0);
    atomic_init(&ring->underruns,0); atomic_init(&ring->trims,0); atomic_init(&ring->overflows,0);
    atomic_init(&ring->overflow,false);
    // A jitter reserve is necessary even when the video buffer is set to zero.
    ring->target=(milliseconds<DM_AUDIO_MIN_RESERVE_MS ? DM_AUDIO_MIN_RESERVE_MS
        : milliseconds>DM_AUDIO_MAX_RESERVE_MS ? DM_AUDIO_MAX_RESERVE_MS : milliseconds)*48;
}
static inline bool dm_audio_ring_write(DMAudioRing *ring, const uint8_t *pcm, size_t frames) {
    uint64_t write=atomic_load_explicit(&ring->written,memory_order_relaxed);
    uint64_t read=atomic_load_explicit(&ring->read,memory_order_acquire);
    if (frames>DM_AUDIO_CAPACITY-(write-read)) {
        atomic_fetch_add_explicit(&ring->overflows,1,memory_order_relaxed);
        atomic_store_explicit(&ring->overflow,true,memory_order_release);
        return false;
    }
    for (size_t i=0;i<frames;i++) for (unsigned channel=0;channel<2;channel++) {
        size_t offset=i*4+channel*2;
        int16_t sample=(int16_t)((uint16_t)pcm[offset]|((uint16_t)pcm[offset+1]<<8));
        ring->samples[((write+i)%DM_AUDIO_CAPACITY)*2+channel]=(float)sample/32768.0f;
    }
    atomic_store_explicit(&ring->written,write+frames,memory_order_release);
    return true;
}
static inline void dm_audio_ring_fade(DMAudioRing *ring) {
    ring->fade=DM_AUDIO_FADE;
    ring->fadeFrom[0]=ring->previous[0]; ring->fadeFrom[1]=ring->previous[1];
}
static inline bool dm_audio_ring_render(DMAudioRing *ring, float *left, float *right, size_t frames) {
    uint64_t read=atomic_load_explicit(&ring->read,memory_order_relaxed);
    uint64_t write=atomic_load_explicit(&ring->written,memory_order_acquire);
    if (atomic_exchange_explicit(&ring->overflow,false,memory_order_acq_rel)) {
        read=write; ring->playing=false; ring->fraction=0;
    }
    uint64_t available=write-read;
    if (available>ring->target+DM_AUDIO_RATE/5) {
        // Trim only the consumer's cursor, never stop/restart the audio engine.
        read=write-ring->target; available=ring->target; ring->fraction=0;
        atomic_fetch_add_explicit(&ring->trims,1,memory_order_relaxed);
        dm_audio_ring_fade(ring);
    }
    if (!ring->playing && available>=ring->target) {
        ring->playing=true; ring->fraction=0; dm_audio_ring_fade(ring);
    }
    bool audible=false;
    // Small rate corrections absorb independent phone/Mac audio clock drift.
    double step=available>ring->target+960 ? 1.005 : available+960<ring->target ? .995 : 1.0;
    for (size_t i=0;i<frames;i++) {
        float output[2]={0,0};
        if (ring->playing && write-read>=2) {
            for (unsigned channel=0;channel<2;channel++) {
                float a=ring->samples[(read%DM_AUDIO_CAPACITY)*2+channel];
                float b=ring->samples[((read+1)%DM_AUDIO_CAPACITY)*2+channel];
                output[channel]=a+(b-a)*ring->fraction;
            }
            ring->fraction+=step;
            unsigned advance=(unsigned)ring->fraction;
            read+=advance; ring->fraction-=advance; audible=true;
        } else if (ring->playing) {
            ring->playing=false; ring->fraction=0; dm_audio_ring_fade(ring);
            atomic_fetch_add_explicit(&ring->underruns,1,memory_order_relaxed);
            // Repeated delivery gaps must not cause the same small rebuffer
            // forever. Grow only after real starvation, bounded to 360 ms.
            unsigned increased=ring->target+60*48;
            ring->target=increased>DM_AUDIO_MAX_RESERVE_MS*48 ? DM_AUDIO_MAX_RESERVE_MS*48 : increased;
        }
        if (ring->fade) {
            float amount=1.0f-(float)ring->fade/DM_AUDIO_FADE;
            for (unsigned channel=0;channel<2;channel++)
                output[channel]=ring->fadeFrom[channel]+(output[channel]-ring->fadeFrom[channel])*amount;
            --ring->fade; audible=true;
        }
        left[i]=output[0]; right[i]=output[1];
        ring->previous[0]=output[0]; ring->previous[1]=output[1];
    }
    atomic_store_explicit(&ring->read,read,memory_order_release);
    return audible;
}
#endif
