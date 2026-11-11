// Exercise the shared chrome's Bluetooth actions without ADB or a phone.
// clang -fobjc-arc -fblocks -I/opt/homebrew/include -L/opt/homebrew/lib \
//   -lSDL3 -framework Cocoa -framework QuartzCore \
//   Native/BluetoothWindowStyleTests.m -o /tmp/droidmirror-style-tests
#import "ScrcpyWindowStyle.m"
#include <assert.h>

@interface DMScrollTestEvent : NSEvent
@property NSEventPhase inputPhase;
@property NSEventPhase inputMomentum;
@property CGFloat inputDeltaY;
@property CGFloat inputDeltaX;
@property NSTimeInterval inputTimestamp;
@property NSPoint inputPosition;
@end
@implementation DMScrollTestEvent
- (NSEventPhase)phase { return self.inputPhase; }
- (NSEventPhase)momentumPhase { return self.inputMomentum; }
- (BOOL)hasPreciseScrollingDeltas { return YES; }
- (CGFloat)scrollingDeltaX { return self.inputDeltaX; }
- (NSTimeInterval)timestamp { return self.inputTimestamp; }
- (CGFloat)scrollingDeltaY { return self.inputDeltaY; }
- (NSPoint)locationInWindow { return NSEqualPoints(self.inputPosition,NSZeroPoint) ? NSMakePoint(215,430) : self.inputPosition; }
@end

int main(void) {
    @autoreleasepool {
        // Processing a queued batch at once must preserve original 16 ms
        // trackpad spacing rather than generating near-zero-time deltas.
        assert(DMTrackpadSourceTicks(1.000,2.000,2000000000)==1000000000);
        assert(DMTrackpadSourceTicks(1.016,2.000,2000000000)==1016000000);
        assert(DMTrackpadSourceTicks(1.032,2.000,2000000000)==1032000000);
        SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "dummy");
        assert(SDL_Init(SDL_INIT_VIDEO));
        SDL_Window *window = SDL_CreateWindow("test", 430, 860, SDL_WINDOW_HIDDEN);
        assert(window);
        DMWindowController *controller = [DMWindowController new];
        controller.bluetoothStream = YES;
        controller.sdlWindow = window;
        controller.screenView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 430, 860)];
        SDL_FlushEvents(SDL_EVENT_FIRST, SDL_EVENT_LAST);
        NSArray *keys = @[@"KEYCODE_BACK", @"KEYCODE_HOME", @"KEYCODE_APP_SWITCH",
                          @"KEYCODE_POWER", @"KEYCODE_VOLUME_DOWN", @"KEYCODE_VOLUME_UP"];
        SDL_Keycode expected[] = {SDLK_B, SDLK_H, SDLK_S, SDLK_P, SDLK_DOWN, SDLK_UP};
        for (NSUInteger i = 0; i < keys.count; ++i) {
            [controller runAndroidKey:keys[i]];
            SDL_Event event;
            for (int j = 0; j < 2; ++j) {
                assert(SDL_PollEvent(&event));
                assert(event.type == (j == 0 ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP));
                assert(event.key.key == expected[i]);
                assert(event.key.mod == SDL_KMOD_LALT);
                assert(event.key.windowID == SDL_GetWindowID(window));
                assert(event.key.down == (j == 0));
            }
            assert(!SDL_PollEvent(&event));
        }
        controller.sessionActive = YES;
        // Decode real AppKit media-key payloads, including repeat and release.
        for (unsigned key = 0; key < 3; ++key) {
            for (unsigned flags = 0x0a00; flags <= 0x0b00; flags += 0x80) {
                NSEvent *media = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                    location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
                    context:nil subtype:8 data1:(key << 16) | flags data2:0];
                assert([controller handleVolumeEvent:media focused:NO] == media);
                BOOL volume = key < 2;
                assert(([controller handleVolumeEvent:media focused:YES] == nil) == volume);
                SDL_Event sent;
                if (volume && flags < 0x0b00) {
                    for (int edge = 0; edge < 2; ++edge) {
                        assert(SDL_PollEvent(&sent));
                        assert(sent.type == (edge ? SDL_EVENT_KEY_UP : SDL_EVENT_KEY_DOWN));
                        assert(sent.key.key == (key == 0 ? SDLK_UP : SDLK_DOWN));
                        assert(sent.key.mod == SDL_KMOD_LALT);
                    }
                }
                assert(!SDL_PollEvent(&sent));
                controller.sessionActive = NO;
                assert([controller handleVolumeEvent:media focused:YES] == media);
                controller.sessionActive = YES;
            }
        }
        // Phone audio on this Mac: volume keys stay with macOS, then forwarding resumes.
        {
            NSEvent *up = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
                context:nil subtype:8 data1:(0u << 16) | 0x0a00 data2:0];
            SDL_Event sent;
            controller.audioRequested = YES;
            assert([controller handleVolumeEvent:up focused:YES] == up);
            assert(!SDL_PollEvent(&sent));
            controller.audioRequested = NO;
            assert([controller handleVolumeEvent:up focused:YES] == nil);
            assert(SDL_PollEvent(&sent) && sent.key.key == SDLK_UP);
            assert(SDL_PollEvent(&sent) && sent.type == SDL_EVENT_KEY_UP);
            assert(!SDL_PollEvent(&sent));
        }
        DMTrackpadEventTimestamp=111000000;
        [controller beginTrackpadTouchAt:NSMakePoint(215,430)];
        SDL_Event sourceEvent;
        assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_MOUSE_BUTTON_DOWN,SDL_EVENT_MOUSE_BUTTON_DOWN)==1
            && sourceEvent.button.timestamp==111000000);
        DMTrackpadEventTimestamp=127000000;
        [controller moveTrackpadTouchX:2 y:3];
        assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_MOUSE_MOTION,SDL_EVENT_MOUSE_MOTION)==1
            && sourceEvent.motion.timestamp==127000000);
        DMTrackpadEventTimestamp=143000000;
        [controller endTrackpadTouch];
        assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_MOUSE_BUTTON_UP,SDL_EVENT_MOUSE_BUTTON_UP)==1
            && sourceEvent.button.timestamp==143000000);
        DMTrackpadEventTimestamp=0;
        [controller resetTrackpadPlaybackAt:NSMakePoint(215,430)];
        assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_MOUSE_WHEEL,SDL_EVENT_MOUSE_WHEEL)==1);
        assert(sourceEvent.wheel.which==SC_DROIDMIRROR_TRACKPAD_RESET_ID && sourceEvent.wheel.x==0 && sourceEvent.wheel.y==0);
        [controller queueWheelX:1 y:-2 at:NSMakePoint(215,430) trackpad:YES];
        assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_MOUSE_WHEEL,SDL_EVENT_MOUSE_WHEEL)==1);
        assert(sourceEvent.wheel.which==SC_DROIDMIRROR_TRACKPAD_MOUSE_ID && sourceEvent.wheel.y==-2);
        // Phase-less precise devices retain relative native momentum playback.
        {
            controller.bluetoothStream=YES;
            DMScrollTestEvent *scroll=[DMScrollTestEvent new];
            scroll.inputPhase=NSEventPhaseNone; scroll.inputDeltaY=8;
            controller.trackpadAxisChosen=NO;
            controller.lastWheelCommand=0;
            [controller handleScrollEvent:scroll];
            assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_MOUSE_WHEEL,SDL_EVENT_MOUSE_WHEEL)==1);
            assert(sourceEvent.wheel.which==SC_DROIDMIRROR_TRACKPAD_MOUSE_ID && sourceEvent.wheel.y==0.5f);
            scroll.inputPhase=NSEventPhaseEnded; scroll.inputDeltaY=0;
            [controller handleScrollEvent:scroll];
            scroll.inputPhase=NSEventPhaseNone; scroll.inputMomentum=NSEventPhaseChanged;
            scroll.inputDeltaY=0.01; // Preserve the subpixel momentum tail.
            controller.lastWheelCommand=0;
            [controller handleScrollEvent:scroll];
            assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_MOUSE_WHEEL,SDL_EVENT_MOUSE_WHEEL)==1);
            assert(sourceEvent.wheel.which==SC_DROIDMIRROR_TRACKPAD_MOUSE_ID && sourceEvent.wheel.y>0);
            scroll.inputMomentum=NSEventPhaseNone; scroll.inputPhase=NSEventPhaseCancelled;
            scroll.inputDeltaY=99;
            controller.lastWheelCommand=0;
            [controller handleScrollEvent:scroll];
            assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_MOUSE_WHEEL,SDL_EVENT_MOUSE_WHEEL)==1);
            assert(sourceEvent.wheel.which==SC_DROIDMIRROR_TRACKPAD_RESET_ID && sourceEvent.wheel.y==0);
            assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_MOUSE_WHEEL,SDL_EVENT_MOUSE_WHEEL)==0);
        }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.12]];
        // Page flicks and upward Home gestures release at finger lift with
        // source-time spacing. Test Home from inside the bottom gesture strip.
        for (int axis=0; axis<2; ++axis) for (int direction=-1; direction<=1; direction+=2) {
            DMScrollTestEvent *scroll=[DMScrollTestEvent new];
            NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
            scroll.inputPosition=NSMakePoint(215,axis==1 ? 2 : 430);
            scroll.inputPhase=NSEventPhaseBegan; scroll.inputTimestamp=now-.100;
            [controller handleScrollEvent:scroll];
            assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_FIRST,SDL_EVENT_LAST)==1 && sourceEvent.wheel.which==SC_DROIDMIRROR_TRACKPAD_RESET_ID);
            controller.lastWheelCommand=0;
            scroll.inputPhase=NSEventPhaseChanged;
            if (axis==0) scroll.inputDeltaX=direction*4; else scroll.inputDeltaY=-4;
            scroll.inputTimestamp=now-.090;
            [controller handleScrollEvent:scroll];
            assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_FIRST,SDL_EVENT_LAST)==1 && sourceEvent.type==SDL_EVENT_MOUSE_BUTTON_DOWN);
            Uint64 downTime=sourceEvent.button.timestamp;
            assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_FIRST,SDL_EVENT_LAST)==1 && sourceEvent.type==SDL_EVENT_MOUSE_MOTION);
            Uint64 firstMoveTime=sourceEvent.motion.timestamp;
            assert(firstMoveTime>downTime && firstMoveTime-downTime>=9000000);
            if (axis==0) scroll.inputDeltaX=direction*10; else scroll.inputDeltaY=-10;
            scroll.inputTimestamp=now-.075;
            [controller handleScrollEvent:scroll];
            assert(controller.wheelScheduled); // Keep the 60 Hz direct-trackpad coalescing limit.
            assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_FIRST,SDL_EVENT_LAST)==0);
            scroll.inputPhase=NSEventPhaseEnded; scroll.inputDeltaX=scroll.inputDeltaY=0;
            scroll.inputTimestamp=now-.065;
            [controller handleScrollEvent:scroll];
            assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_FIRST,SDL_EVENT_LAST)==1 && sourceEvent.type==SDL_EVENT_MOUSE_MOTION);
            if (axis==0) assert(fabs(sourceEvent.motion.x-(215+direction*21))<.01);
            else assert(fabs(sourceEvent.motion.y-(858-21))<.01);
            Uint64 lastMoveTime=sourceEvent.motion.timestamp;
            assert(lastMoveTime-firstMoveTime>=14000000 && lastMoveTime-firstMoveTime<=16000000);
            assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_FIRST,SDL_EVENT_LAST)==1 && sourceEvent.type==SDL_EVENT_MOUSE_BUTTON_UP);
            assert(sourceEvent.button.timestamp-lastMoveTime>=9000000 && sourceEvent.button.timestamp-lastMoveTime<=11000000);
            assert(!controller.touchActive && !controller.wheelScheduled);
            scroll.inputPhase=NSEventPhaseNone; scroll.inputMomentum=NSEventPhaseChanged;
            scroll.inputDeltaX=direction*40;
            [controller handleScrollEvent:scroll];
            assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_FIRST,SDL_EVENT_LAST)==0); // Android owns trackpad inertia on both axes.
            scroll.inputMomentum=NSEventPhaseEnded; scroll.inputDeltaX=0;
            [controller handleScrollEvent:scroll];
            assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_FIRST,SDL_EVENT_LAST)==0);
        }
        // Direct trackpad drags flush at 60 Hz so a mostly horizontal swipe
        // cannot cross the vertical touch slop in one coarse move; wheel
        // playback keeps its 30 Hz pacing.
        controller.directTrackpad=YES;
        [controller beginTrackpadTouchAt:NSMakePoint(215,430)];
        assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_FIRST,SDL_EVENT_LAST)==1 && sourceEvent.type==SDL_EVENT_MOUSE_BUTTON_DOWN);
        controller.lastWheelCommand=NSProcessInfo.processInfo.systemUptime-.020;
        [controller queueWheelX:1 y:0 at:NSMakePoint(215,430) trackpad:YES];
        assert(!controller.wheelScheduled);
        assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_FIRST,SDL_EVENT_LAST)==1 && sourceEvent.type==SDL_EVENT_MOUSE_MOTION);
        [controller endTrackpadTouch];
        assert(SDL_PeepEvents(&sourceEvent,1,SDL_GETEVENT,SDL_EVENT_FIRST,SDL_EVENT_LAST)==1 && sourceEvent.type==SDL_EVENT_MOUSE_BUTTON_UP);
        controller.lastWheelCommand=NSProcessInfo.processInfo.systemUptime-.020;
        [controller queueWheelX:0 y:1 at:NSMakePoint(215,430) trackpad:NO];
        assert(controller.wheelScheduled);
        controller.pendingWheelX=controller.pendingWheelY=0;
        controller.wheelScheduled=NO; ++controller.wheelGeneration;
        controller.directTrackpad=NO;
        controller.bluetoothStream=YES;
        controller.pendingScrollPosition=NSMakePoint(215,430);
        controller.pendingScrollX = 2;
        controller.pendingScrollY = -3;
        [controller flushSwipe];
        SDL_Event event;
        assert(SDL_PollEvent(&event) && event.type == SDL_EVENT_MOUSE_BUTTON_DOWN);
        assert(SDL_PollEvent(&event) && event.type == SDL_EVENT_MOUSE_MOTION);
        assert(event.motion.x > 215 && event.motion.y < 430);
        assert(SDL_PollEvent(&event) && event.type == SDL_EVENT_MOUSE_BUTTON_UP);
        assert(!controller.touchActive && !controller.adbShell);
        assert(!controller.adbShellInput);
        controller.sdlWindow = NULL;
        SDL_DestroyWindow(window);
        SDL_Quit();
        puts("PASS: Bluetooth controls, phase-less momentum and source-timed page/Home flicks with immediate release (60 Hz trackpad, 30 Hz wheel coalescing)");
    }
}
