#import "ScrcpyWindowStyle.m"
#include <assert.h>
static BOOL active(id app, SEL selector) { return YES; }
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        Method getter=class_getInstanceMethod(NSApplication.class,@selector(isActive));
        IMP original=method_setImplementation(getter,(IMP)active);
        NSWindow *phone=[[NSWindow alloc] initWithContentRect:NSMakeRect(200,200,360,400)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        [phone orderFront:nil];
        NSRect frame=phone.frame; NSWindow *key=NSApp.keyWindow;
        DMWindowController *controller=[DMWindowController new];
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
        controller=nil; [phone orderOut:nil];
        method_setImplementation(getter,original);
        puts("Wireless audio button: below-phone placement, start/cancel/stop/retry, route loss, connecting/ended sessions and focus preservation passed");
    }
}
