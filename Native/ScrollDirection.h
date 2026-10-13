#import <AppKit/AppKit.h>

BOOL DMScrollIsTouchBased(NSEvent *event);
BOOL DMBeginScrollDirectionEvent(NSEvent *event);
void DMEndScrollDirectionEvent(BOOL previous);
void DMInstallScrollDirection(Class controllerClass);
