#import <AppKit/AppKit.h>
// Conservative classification: phased or precise events retain the trackpad path.
static inline BOOL DMIsMouseWheel(NSEventPhase phase, BOOL precise, NSEventPhase momentum) {
    return phase == NSEventPhaseNone && momentum == NSEventPhaseNone && !precise;
}
