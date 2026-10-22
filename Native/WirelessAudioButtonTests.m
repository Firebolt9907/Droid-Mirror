#import "ScrcpyWindowStyle.m"
#include <assert.h>
static BOOL active(id app, SEL selector) { return YES; }
static BOOL inactive(id app, SEL selector) { return NO; }
// Keep menu bar registration out of this standalone UI test process. Exercise
// the production menu, icon and lifecycle using an in-memory status item.
@interface DMAudioTestStatusItem : NSObject
@property(nonatomic, strong) NSButton *button;
@property(nonatomic, strong) NSMenu *menu;
@end
@implementation DMAudioTestStatusItem
@end
static id makeStatusItem(id bar, SEL selector, CGFloat length) {
    DMAudioTestStatusItem *item=[DMAudioTestStatusItem new];
    item.button=[NSButton new];
    return item;
}
static void removeStatusItem(id bar, SEL selector, id item) {}
@interface DMAudioTimeoutController : DMWindowController
@property(nonatomic) NSInteger endedSessions;
@property(nonatomic) NSInteger audioStops;
@end
@implementation DMAudioTimeoutController
- (void)endInactiveSession { self.endedSessions++; }
- (void)togglePhoneAudio:(id)sender { self.audioStops++; }
@end
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        Method getter=class_getInstanceMethod(NSApplication.class,@selector(isActive));
        IMP original=method_setImplementation(getter,(IMP)active);
        Method createStatus=class_getInstanceMethod(NSStatusBar.class,@selector(statusItemWithLength:));
        Method removeStatus=class_getInstanceMethod(NSStatusBar.class,@selector(removeStatusItem:));
        IMP originalCreate=method_setImplementation(createStatus,(IMP)makeStatusItem);
        IMP originalRemove=method_setImplementation(removeStatus,(IMP)removeStatusItem);
        NSWindow *phone=[[NSWindow alloc] initWithContentRect:NSMakeRect(200,200,360,400)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        [phone orderFront:nil];
        NSRect frame=phone.frame; NSWindow *key=NSApp.keyWindow;
        DMAudioTimeoutController *controller=[DMAudioTimeoutController new];
        controller.window=phone; controller.bluetoothStream=YES; controller.sessionActive=YES;
        [controller buildAudioButton];
        assert(!controller.audioWindow.visible);
        [controller applyAudioState:@{@"helper":@123,@"available":@YES}];
        assert(controller.audioWindow.visible && controller.audioWindow.parentWindow==phone);
        assert(NSMaxY(controller.audioWindow.frame)==NSMinY(phone.frame)-10);
        assert([controller.audioButton.title isEqualToString:@"Play phone audio over Wi-Fi"]);
        assert(!controller.audioWindow.canBecomeKeyWindow);
        assert(controller.audioWindow.frame.size.height==36);
        assert(controller.audioContent.spacing==8);
        assert(fabs(NSMidX(controller.audioContent.frame)-NSMidX(controller.audioWindow.contentView.bounds))<1);
        assert(fabs(NSMinX(controller.audioContent.frame)-16)<2);
        assert(fabs(NSMaxX(controller.audioWindow.contentView.bounds)-NSMaxX(controller.audioContent.frame)-16)<2);
        assert(fabs(NSMidY(controller.audioContent.frame)-18)<1);
        NSView *preview=controller.audioWindow.contentView;
        NSBitmapImageRep *bitmap=[preview bitmapImageRepForCachingDisplayInRect:preview.bounds];
        [preview cacheDisplayInRect:preview.bounds toBitmapImageRep:bitmap];
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:@"/tmp/droidmirror-audio-button-preview.png" atomically:YES];
        [controller applyAudioState:@{@"helper":@123,@"available":@YES,@"requested":@YES}];
        assert([controller.audioButton.title isEqualToString:@"Cancel audio connection…"]);
        [controller applyAudioState:@{@"helper":@123,@"available":@YES,@"requested":@YES,@"playing":@YES}];
        assert([controller.audioButton.title isEqualToString:@"Stop phone audio"]);
        [controller applyAudioState:@{@"helper":@123,@"available":@YES,@"failed":@YES}];
        assert([controller.audioButton.title isEqualToString:@"Retry phone audio over Wi-Fi"]);
        [controller applyAudioState:@{@"helper":@123,@"available":@NO}];
        assert(!controller.audioWindow.visible && !controller.audioWindow.parentWindow);
        [controller applyAudioState:@{@"helper":@123,@"available":@YES}];
        NSView *connecting=[NSView new]; connecting.identifier=@"DroidMirrorConnecting";
        [phone.contentView addSubview:connecting]; [controller positionAudioButton];
        assert(!controller.audioWindow.visible);
        [connecting removeFromSuperview]; [controller positionAudioButton];
        assert(controller.audioWindow.visible);
        controller.sessionActive=NO; controller.audioVisible=NO; [controller positionAudioButton];
        [controller applyAudioState:@{@"helper":@123,@"available":@YES}];
        assert(!controller.audioWindow.visible && !controller.audioVisible);
        assert(NSEqualRects(frame,phone.frame) && key==NSApp.keyWindow);
        // Inactivity dismisses the phone without stopping the authenticated
        // session that owns audio. A second timeout must not duplicate the icon.
        controller.sessionActive=YES;
        [controller applyAudioState:@{@"helper":@123,@"requested":@YES,@"playing":@YES}];
        method_setImplementation(getter,(IMP)inactive);
        [controller suspendForBackgroundTimeout];
        assert(controller.backgroundAudioOnly && controller.audioStatusItem);
        assert(!phone.visible && !controller.audioWindow.visible);
        assert(controller.sessionActive && controller.audioRequested && controller.audioPlaying);
        assert(controller.endedSessions==0);
        NSStatusItem *status=controller.audioStatusItem;
        assert([status.button.toolTip containsString:@"casting"]);
        assert(status.menu.numberOfItems==4);
        [controller suspendForBackgroundTimeout];
        assert(controller.audioStatusItem==status);
        [controller showPhoneFromAudio:nil];
        assert(!controller.backgroundAudioOnly && !controller.audioStatusItem && phone.visible);
        assert(controller.audioRequested && controller.endedSessions==0);

        // Stop is explicit; route loss/EOF also ends an otherwise hidden session.
        [controller suspendForBackgroundTimeout];
        [controller stopBackgroundAudio:nil];
        assert(controller.audioStops==1 && controller.endedSessions==1);
        assert(!controller.audioStatusItem && !controller.backgroundAudioOnly);
        [controller suspendForBackgroundTimeout];
        [controller applyAudioState:@{@"helper":@123,@"requested":@NO,@"failed":@YES}];
        assert(controller.endedSessions==2 && !controller.audioStatusItem);
        [controller suspendForBackgroundTimeout];
        assert(controller.endedSessions==3); // Ordinary non-audio timeout unchanged.

        // Connection teardown removes the indicator without sending another stop.
        [controller applyAudioState:@{@"helper":@123,@"requested":@YES}];
        [controller suspendForBackgroundTimeout];
        objc_setAssociatedObject(phone,DMControllerKey,controller,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DroidMirrorSessionChrome(phone,NO);
        assert(!controller.audioStatusItem && !controller.backgroundAudioOnly && !controller.sessionActive);
        objc_setAssociatedObject(phone,DMControllerKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        controller=nil; [phone orderOut:nil];
        method_setImplementation(getter,original);
        method_setImplementation(createStatus,originalCreate);
        method_setImplementation(removeStatus,originalRemove);
        puts("Wireless audio button: below-phone placement, start/cancel/stop/retry, route loss, timeout casting indicator, resume/stop, teardown and focus preservation passed");
    }
}
