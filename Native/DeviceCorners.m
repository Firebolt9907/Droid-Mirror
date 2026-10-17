#import "DeviceCorners.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <signal.h>
#import <objc/runtime.h>

// Pixel 8 fallback, replaced with the connected phone's physical display data.
static CGFloat DMTopCornerRatio = 104.0 / 1080.0;
static CGFloat DMBottomCornerRatio = 102.0 / 1080.0;

CGFloat DMCornerExtentForRadius(CGFloat radius) {
    // Match the 45-degree inset of Android's circular approximation:
    // circle: r(1 - 1/sqrt(2)); superellipse n=3: e(1 - 2^(-1/3)).
    // Tighten the silhouette slightly to avoid over-rounding the mirrored image.
    // The mask, shadow and resize hit areas all share this adjustment.
    return 0.92 * radius * (1 - M_SQRT1_2) / (1 - pow(.5, 1.0 / 3.0));
}

static double DMGeometryNumber(NSString *line, NSString *pattern, NSUInteger capture) {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (!match || capture >= match.numberOfRanges) return NAN;
    return [[line substringWithRange:[match rangeAtIndex:capture]] doubleValue];
}

BOOL DMUpdateDeviceGeometryFromDisplayDump(NSString *dump) {
    for (NSString *line in [dump componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        // Ignore scrcpy's virtual display and encoder dimensions.
        if (![line containsString:@"DisplayDeviceInfo{"] || ![line containsString:@"type INTERNAL"]) continue;
        double width = DMGeometryNumber(line, @",\\s*(\\d+) x (\\d+),", 1);
        double topRadius = DMGeometryNumber(line, @"position=TopLeft, radius=(\\d+)", 1);
        double bottomRadius = DMGeometryNumber(line, @"position=BottomLeft, radius=(\\d+)", 1);
        if (!isfinite(width) || !isfinite(topRadius) || !isfinite(bottomRadius)
            || width < 100 || width > 20000 || topRadius < 0 || bottomRadius < 0
            || topRadius >= width / 2 || bottomRadius >= width / 2) return NO;
        DMTopCornerRatio = topRadius / width;
        DMBottomCornerRatio = bottomRadius / width;
        return YES;
    }
    return NO;
}

void DMRefreshDeviceCornersFromPhone(NSView *screen) {
    NSString *serial = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_SERIAL"];
    if (!serial.length) return;
    __weak NSView *weakScreen = screen;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *adb = NSProcessInfo.processInfo.environment[@"ADB"];
        if (!adb.length || ![NSFileManager.defaultManager isExecutableFileAtPath:adb]) adb = @"/opt/homebrew/bin/adb";
        if (![NSFileManager.defaultManager isExecutableFileAtPath:adb]) return;
        NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"DroidMirror-display-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
        [NSFileManager.defaultManager createFileAtPath:file.path contents:nil attributes:@{NSFilePosixPermissions:@0600}];
        NSFileHandle *output = [NSFileHandle fileHandleForWritingAtPath:file.path];
        if (!output) { [NSFileManager.defaultManager removeItemAtURL:file error:nil]; return; }
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:adb];
        task.arguments = @[@"-s", serial, @"shell", @"dumpsys", @"display"];
        task.standardOutput = output; task.standardError = output;
        dispatch_semaphore_t ended = dispatch_semaphore_create(0);
        task.terminationHandler = ^(NSTask *finished) { dispatch_semaphore_signal(ended); };
        BOOL launched = [task launchAndReturnError:nil];
        BOOL complete = launched && dispatch_semaphore_wait(ended,
            dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) == 0;
        if (launched && !complete && task.running) {
            [task terminate];
            if (dispatch_semaphore_wait(ended, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0 && task.running)
                kill(task.processIdentifier, SIGKILL);
        }
        [output closeFile];
        NSString *dump = complete && task.terminationStatus == 0 ?
            [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil] : nil;
        [NSFileManager.defaultManager removeItemAtURL:file error:nil];
        if (!dump) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSView *surface = weakScreen;
            if (surface && DMUpdateDeviceGeometryFromDisplayDump(dump)) DMApplyDeviceCorners(surface);
        });
    });
}

CGFloat DMPixelCornerRadius(CGFloat streamWidth, BOOL top) {
    return DMCornerExtentForRadius(streamWidth * (top ? DMTopCornerRatio : DMBottomCornerRatio));
}

CGPathRef DMCreatePixelScreenPath(CGSize size, BOOL flipped) {
    CGFloat width = size.width, height = size.height;
    CGMutablePathRef path = CGPathCreateMutable();
    if (!isfinite(width) || !isfinite(height) || width <= 0 || height <= 0) return path;
    CGFloat limit = MIN(width, height) / 2;
    CGFloat low = MIN(DMPixelCornerRadius(width, flipped), limit);
    CGFloat high = MIN(DMPixelCornerRadius(width, !flipped), limit);
    // Sample the actual exponent-3 curve, rather than circular corner-radius
    // clipping. Straight edges remain straight; corner extents scale with width.
    const NSUInteger segments = 128;
    CGPathMoveToPoint(path, NULL, low, 0);
    CGPathAddLineToPoint(path, NULL, width - low, 0);
    for (NSUInteger i = 1; i <= segments; ++i) {
        CGPoint point = DMSuperellipseCornerPoint(low, 1 - (CGFloat)i / segments);
        CGPathAddLineToPoint(path, NULL, width - point.x, point.y);
    }
    CGPathAddLineToPoint(path, NULL, width, height - high);
    for (NSUInteger i = 1; i <= segments; ++i) {
        CGPoint point = DMSuperellipseCornerPoint(high, (CGFloat)i / segments);
        CGPathAddLineToPoint(path, NULL, width - point.x, height - point.y);
    }
    CGPathAddLineToPoint(path, NULL, high, height);
    for (NSUInteger i = 1; i <= segments; ++i) {
        CGPoint point = DMSuperellipseCornerPoint(high, 1 - (CGFloat)i / segments);
        CGPathAddLineToPoint(path, NULL, point.x, height - point.y);
    }
    CGPathAddLineToPoint(path, NULL, 0, low);
    for (NSUInteger i = 1; i <= segments; ++i) {
        CGPoint point = DMSuperellipseCornerPoint(low, (CGFloat)i / segments);
        CGPathAddLineToPoint(path, NULL, point.x, point.y);
    }
    CGPathCloseSubpath(path);
    return path;
}

CGPoint DMSuperellipseCornerPoint(CGFloat extent, CGFloat progress) {
    if (progress <= 0) return CGPointMake(0, extent);
    if (progress >= 1) return CGPointMake(extent, 0);
    CGFloat angle = progress * M_PI_2;
    const CGFloat power = 2.0 / 3.0; // Softer/rounder than the previous n=4 profile.
    return CGPointMake(extent * (1 - pow(cos(angle), power)),
                       extent * (1 - pow(sin(angle), power)));
}

// A separate, click-through child gives the blur room outside SDL's clipped
// surface without changing video coordinates or the window's resize hit areas.
static const CGFloat DMPhoneShadowInset = 120;
static void *DMPhoneShadowKey = &DMPhoneShadowKey;

@interface DMPhoneShadowView : NSView
@property(nonatomic) NSRect phoneRect;
@end
@implementation DMPhoneShadowView
- (BOOL)isOpaque { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    NSRect phone = self.phoneRect;
    CGPathRef path = DMCreatePixelScreenPath(phone.size, NO);
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, phone.origin.x, phone.origin.y);
    CGContextSetFillColorWithColor(context, NSColor.blackColor.CGColor);
    // A wide ambient shadow adds depth; a tighter contact shadow defines the edge.
    CGContextSetShadowWithColor(context, CGSizeMake(0, -18), 60,
        [NSColor colorWithWhite:0 alpha:0.38].CGColor);
    CGContextAddPath(context, path);
    CGContextFillPath(context);
    CGContextSetShadowWithColor(context, CGSizeMake(0, -4), 16,
        [NSColor colorWithWhite:0 alpha:0.22].CGColor);
    CGContextAddPath(context, path);
    CGContextFillPath(context);
    CGContextRestoreGState(context);
    CGPathRelease(path);
}
@end

@interface DMPhoneShadowPanel : NSPanel
@end
@implementation DMPhoneShadowPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface DMPhoneShadow : NSObject
@property(nonatomic, weak) NSWindow *host;
@property(nonatomic, strong) DMPhoneShadowPanel *panel;
@property(nonatomic, strong) id closeObserver;
@property(nonatomic) NSSize drawnSize;
@property(nonatomic) NSRect drawnPhoneRect;
@property(nonatomic) CGFloat topRadius;
@property(nonatomic) CGFloat bottomRadius;
- (instancetype)initWithWindow:(NSWindow *)window;
- (void)updateForScreen:(NSView *)screen;
@end

@implementation DMPhoneShadow
- (instancetype)initWithWindow:(NSWindow *)window {
    if (!(self = [super init])) return nil;
    _host = window;
    _panel = [[DMPhoneShadowPanel alloc] initWithContentRect:NSZeroRect
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    _panel.releasedWhenClosed = NO;
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = NO;
    _panel.ignoresMouseEvents = YES;
    _panel.hidesOnDeactivate = NO;
    _panel.animationBehavior = NSWindowAnimationBehaviorNone;
    _panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorIgnoresCycle;
    _panel.contentView = [[DMPhoneShadowView alloc] initWithFrame:NSZeroRect];
    __weak typeof(self) weakSelf = self;
    _closeObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification
        object:window queue:nil usingBlock:^(__unused NSNotification *note) {
            [weakSelf.panel orderOut:nil];
        }];
    return self;
}

- (void)dealloc {
    if (_closeObserver) [NSNotificationCenter.defaultCenter removeObserver:_closeObserver];
    [_host removeChildWindow:_panel];
    [_panel orderOut:nil];
}

- (void)updateForScreen:(NSView *)screen {
    NSWindow *window = self.host;
    window.hasShadow = NO; // The explicit silhouette supplies both shadow layers.
    if (window.styleMask & NSWindowStyleMaskFullScreen) {
        [window removeChildWindow:self.panel];
        [self.panel orderOut:nil];
        return;
    }
    NSRect phone = [window convertRectToScreen:[screen convertRect:screen.bounds toView:nil]];
    NSScreen *screenForWindow = window.screen;
    NSRect shadowFrame = NSInsetRect(phone, -DMPhoneShadowInset, -DMPhoneShadowInset);
    // A transparent child panel that extends behind the menu bar can expose a
    // straight compositor edge there. Keep the shadow surface in the desktop
    // area and position its silhouette relative to the clipped panel frame.
    NSRect panelFrame = shadowFrame;
    if (screenForWindow) {
        NSRect desktopFrame = screenForWindow.frame;
        desktopFrame.size.height = MAX(0, NSMaxY(screenForWindow.visibleFrame) - NSMinY(desktopFrame));
        panelFrame = NSIntersectionRect(shadowFrame, desktopFrame);
    }
    DMPhoneShadowView *shadowView = (DMPhoneShadowView *)self.panel.contentView;
    shadowView.phoneRect = NSOffsetRect(phone, -NSMinX(panelFrame), -NSMinY(panelFrame));
    [self.panel setFrame:panelFrame display:NO];
    CGFloat top = DMPixelCornerRadius(phone.size.width, YES);
    CGFloat bottom = DMPixelCornerRadius(phone.size.width, NO);
    if (!NSEqualSizes(self.drawnSize, phone.size) || !NSEqualRects(self.drawnPhoneRect, shadowView.phoneRect)
        || self.topRadius != top || self.bottomRadius != bottom) {
        self.drawnSize = phone.size;
        self.drawnPhoneRect = shadowView.phoneRect;
        self.topRadius = top;
        self.bottomRadius = bottom;
        self.panel.contentView.needsDisplay = YES;
    }
    if (self.panel.parentWindow != window) [window addChildWindow:self.panel ordered:NSWindowBelow];
}
@end

void DMApplyDeviceCorners(NSView *screen) {
    if (!screen || NSIsEmptyRect(screen.bounds)) return;
    screen.wantsLayer = YES;
    CALayer *layer = screen.layer;
    CGPathRef path = DMCreatePixelScreenPath(layer.bounds.size, layer.geometryFlipped);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CAShapeLayer *mask = [layer.mask isKindOfClass:CAShapeLayer.class] ? (CAShapeLayer *)layer.mask : [CAShapeLayer layer];
    mask.frame = layer.bounds;
    mask.path = path;
    mask.fillColor = NSColor.blackColor.CGColor;
    mask.contentsScale = screen.window.backingScaleFactor ?: 1;
    layer.cornerRadius = 0; // Remove the previous 16–24-point clipping.
    layer.masksToBounds = YES;
    layer.mask = mask;
    layer.shadowPath = path;
    [CATransaction commit];
    CGPathRelease(path);
    NSWindow *window = screen.window;
    if (window) {
        DMPhoneShadow *shadow = objc_getAssociatedObject(window, DMPhoneShadowKey);
        if (!shadow) {
            shadow = [[DMPhoneShadow alloc] initWithWindow:window];
            objc_setAssociatedObject(window, DMPhoneShadowKey, shadow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [shadow updateForScreen:screen];
    }
}
