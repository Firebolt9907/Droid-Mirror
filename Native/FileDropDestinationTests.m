#import "FileDropDestination.h"
#include <assert.h>
@interface DMDropInfo : NSObject
@property(nonatomic, strong) NSPasteboard *draggingPasteboard;
@property(nonatomic) NSDragOperation draggingSourceOperationMask;
@end
@implementation DMDropInfo
@end
int main(void) {
    @autoreleasepool {
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 800)];
        view.wantsLayer = YES;
        __block BOOL active = YES;
        DMInstallFileDrops(view, YES, ^BOOL { return active; });
        assert([view isKindOfClass:NSView.class]);
        assert([view respondsToSelector:@selector(performDragOperation:)]);
        DMFileDropDestination *destination = objc_getAssociatedObject(view, DMFileDropKey);
        DMDropInfo *info = [DMDropInfo new];
        info.draggingPasteboard = [NSPasteboard pasteboardWithUniqueName];
        info.draggingSourceOperationMask = NSDragOperationCopy;
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [@"test" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [info.draggingPasteboard writeObjects:@[[NSURL fileURLWithPath:path]]];
        assert([view draggingEntered:(id)info] == NSDragOperationCopy);
        assert(view.layer.borderWidth == 4);
        active = NO;
        assert([destination entered:(id)info] == NSDragOperationNone);
        active = YES;
        [info.draggingPasteboard clearContents];
        [info.draggingPasteboard writeObjects:@[[NSURL fileURLWithPath:path], [NSURL fileURLWithPath:@"/tmp"]]];
        assert([destination entered:(id)info] == NSDragOperationNone);
        [view dm_fileExited:(id)info];
        assert(destination.label.hidden && view.layer.borderWidth == 0);
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        [info.draggingPasteboard releaseGlobally];
        puts("Native file-drop destination tests passed");
    }
}
