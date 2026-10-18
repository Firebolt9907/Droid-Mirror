#import "MouseWheelRouting.h"
#include <assert.h>
int main(void) {
    NSEventPhase phases[]={NSEventPhaseNone,NSEventPhaseBegan,NSEventPhaseChanged,NSEventPhaseEnded,NSEventPhaseCancelled,NSEventPhaseMayBegin,NSEventPhaseStationary};
    for (NSUInteger i=0;i<sizeof(phases)/sizeof(*phases);++i)
        for (NSUInteger j=0;j<sizeof(phases)/sizeof(*phases);++j)
            for (int precise=0;precise<2;++precise)
                assert(DMIsMouseWheel(phases[i],precise,phases[j]) == (i==0 && j==0 && !precise));
    puts("Wheel routing: only phase-less, non-precise mouse wheel events use local playback; trackpad phases, precision and momentum excluded");
}
