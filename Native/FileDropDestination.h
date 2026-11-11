// Included by the native SDL chrome and its isolated host tests.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

@interface DMFileDropLabel : NSTextField
@end
@implementation DMFileDropLabel
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

@interface DMFileDropDestination : NSObject
@property(nonatomic, weak) NSView *view;
@property(nonatomic, strong) NSTextField *label;
@property(nonatomic, strong) id observer;
@property(nonatomic) BOOL bridge;
@property(nonatomic, copy) BOOL (^isActive)(void);
@property(nonatomic) BOOL sending;
@property(nonatomic) NSUInteger statusGeneration;
@end

static const void *DMFileDropKey = &DMFileDropKey;
@implementation DMFileDropDestination
- (void)show:(NSString *)message highlight:(BOOL)highlight {
    NSUInteger generation = ++self.statusGeneration;
    self.label.stringValue = message;
    self.label.hidden = NO;
    self.view.layer.borderWidth = highlight ? 4 : 0;
    self.view.layer.borderColor = NSColor.controlAccentColor.CGColor;
    if (!highlight && !self.sending) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (weakSelf.statusGeneration == generation) weakSelf.label.hidden = YES;
        });
    }
}
- (NSArray<NSURL *> *)files:(id<NSDraggingInfo>)sender {
    return [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
}
- (NSDragOperation)entered:(id<NSDraggingInfo>)sender {
    if (!self.isActive() || self.sending) return NSDragOperationNone;
    NSArray<NSURL *> *files = [self files:sender];
    // One bounded operation at a time; never silently discard part of a batch.
    if (files.count != 1 || !(sender.draggingSourceOperationMask & NSDragOperationCopy)) return NSDragOperationNone;
    NSNumber *regular = nil, *symlink = nil;
    [files.firstObject getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
    [files.firstObject getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
    if (!regular.boolValue || symlink.boolValue) return NSDragOperationNone;
    [self show:@"Drop to save in phone Downloads" highlight:YES];
    return NSDragOperationCopy;
}
- (BOOL)perform:(id<NSDraggingInfo>)sender {
    if ([self entered:sender] == NSDragOperationNone) return NO;
    NSURL *url = [self files:sender].firstObject;
    self.sending = YES;
    [self show:@"Sending file…" highlight:NO];
    if (self.bridge) {
        NSUInteger generation = self.statusGeneration;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (weakSelf.statusGeneration == generation) {
                weakSelf.sending = NO;
                [weakSelf show:@"File receiver unavailable; enable Bluetooth and clipboard sync" highlight:NO];
            }
        });
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"app.droidmirror.fileDrop"
            object:nil userInfo:@{@"path": url.path} deliverImmediately:YES];
        return YES;
    }
    NSString *serial = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_SERIAL"];
    if (!serial.length) { self.sending = NO; [self show:@"No connected ADB device" highlight:NO]; return NO; }
    // Argument arrays keep filenames out of a shell. APKs are safely saved, too.
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.environment[@"ADB"] ?: @"/opt/homebrew/bin/adb"];
    task.arguments = @[@"-s", serial, @"push", url.path, @"/sdcard/Download/"];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    self.sending = YES;
    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.sending = NO;
            [weakSelf show:finished.terminationStatus == 0 ? @"Saved to phone Downloads" : @"File transfer failed; check the ADB connection" highlight:NO];
        });
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        self.sending = NO; [self show:@"Could not start adb" highlight:NO]; return NO;
    }
    return YES;
}
- (void)dealloc { if (_observer) [NSDistributedNotificationCenter.defaultCenter removeObserver:_observer]; }
@end

// Override only drag handling on this SDL view. Its mouse/keyboard handling and
// delegate stay intact, and SDL cannot also push/install the same dropped file.
@interface NSView (DMFileDrops)
- (NSDragOperation)dm_fileEntered:(id<NSDraggingInfo>)sender;
- (void)dm_fileExited:(id<NSDraggingInfo>)sender;
- (BOOL)dm_filePerform:(id<NSDraggingInfo>)sender;
@end
@implementation NSView (DMFileDrops)
- (NSDragOperation)dm_fileEntered:(id<NSDraggingInfo>)sender { return [objc_getAssociatedObject(self, DMFileDropKey) entered:sender]; }
- (void)dm_fileExited:(id<NSDraggingInfo>)sender {
    DMFileDropDestination *drop = objc_getAssociatedObject(self, DMFileDropKey);
    self.layer.borderWidth = 0; drop.label.hidden = YES;
}
- (BOOL)dm_filePerform:(id<NSDraggingInfo>)sender { return [objc_getAssociatedObject(self, DMFileDropKey) perform:sender]; }
@end

static void DMInstallFileDrops(NSView *view, BOOL bridge, BOOL (^active)(void)) {
    if (objc_getAssociatedObject(view, DMFileDropKey)) return;
    DMFileDropDestination *drop = [DMFileDropDestination new];
    drop.view = view; drop.bridge = bridge; drop.isActive = active;
    drop.label = [DMFileDropLabel labelWithString:@""];
    drop.label.hidden = YES; drop.label.alignment = NSTextAlignmentCenter;
    drop.label.textColor = NSColor.whiteColor;
    drop.label.backgroundColor = [NSColor.blackColor colorWithAlphaComponent:0.85];
    drop.label.drawsBackground = YES;
    drop.label.frame = NSMakeRect(8, 70, MAX(0, view.bounds.size.width - 16), 42);
    drop.label.autoresizingMask = NSViewWidthSizable;
    [view addSubview:drop.label];
    objc_setAssociatedObject(view, DMFileDropKey, drop, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSString *name = [@"DMFileDrop_" stringByAppendingString:NSStringFromClass(object_getClass(view))];
    Class subclass = NSClassFromString(name);
    if (!subclass) {
        subclass = objc_allocateClassPair(object_getClass(view), name.UTF8String, 0);
        NSArray *targets = @[@"draggingEntered:", @"draggingUpdated:", @"draggingExited:", @"performDragOperation:"];
        NSArray *sources = @[@"dm_fileEntered:", @"dm_fileEntered:", @"dm_fileExited:", @"dm_filePerform:"];
        for (NSUInteger i = 0; i < targets.count; i++) {
            Method method = class_getInstanceMethod(NSView.class, NSSelectorFromString(sources[i]));
            class_addMethod(subclass, NSSelectorFromString(targets[i]), method_getImplementation(method), method_getTypeEncoding(method));
        }
        objc_registerClassPair(subclass);
    }
    object_setClass(view, subclass);
    [view registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    if (bridge) {
        __weak DMFileDropDestination *weakDrop = drop;
        drop.observer = [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"app.droidmirror.fileDropStatus"
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                NSString *message = note.userInfo[@"message"];
                if ([message isKindOfClass:NSString.class]) {
                    weakDrop.sending = [message hasPrefix:@"Preparing"] || [message hasPrefix:@"Sending"] || [message hasPrefix:@"Retrying"];
                    [weakDrop show:message highlight:NO];
                }
            }];
    }
}
