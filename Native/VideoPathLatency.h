#ifndef DM_VIDEO_PATH_LATENCY_H
#define DM_VIDEO_PATH_LATENCY_H
#include <stdbool.h>
#include <stddef.h>
// Values are local arrival time minus the phone's monotonic send timestamp.
// Their difference cancels clock offset. Keep a short median to reject jitter.
typedef struct { double values[7]; size_t count, next; } DMLatencySamples;
static inline void dm_latency_add(DMLatencySamples *samples, double value) {
    samples->values[samples->next++ % 7]=value;
    if (samples->count<7) ++samples->count;
}
static inline double dm_latency_median(const DMLatencySamples *samples) {
    double sorted[7];
    for (size_t i=0;i<samples->count;i++) {
        double v=samples->values[i]; size_t j=i;
        while (j && sorted[j-1]>v) { sorted[j]=sorted[j-1]; --j; }
        sorted[j]=v;
    }
    return samples->count ? sorted[samples->count/2] : 0;
}
static inline bool dm_latency_ready(const DMLatencySamples *bluetooth, const DMLatencySamples *candidate) {
    return bluetooth->count>=3 && candidate->count>=3;
}
static inline bool dm_latency_slower(const DMLatencySamples *bluetooth, const DMLatencySamples *candidate) {
    return dm_latency_ready(bluetooth,candidate) && dm_latency_median(candidate)>dm_latency_median(bluetooth)+0.010;
}
#endif
