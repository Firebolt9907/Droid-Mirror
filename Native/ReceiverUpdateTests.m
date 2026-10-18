#import "ReceiverUpdate.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        NSDate *old = [NSDate dateWithTimeIntervalSince1970:100];
        NSDate *new = [NSDate dateWithTimeIntervalSince1970:200];
        assert(DMReceiverNeedsRefresh(old, new, NO));
        assert(!DMReceiverNeedsRefresh(old, new, YES));
        assert(!DMReceiverNeedsRefresh(new, old, NO));
        assert(!DMReceiverNeedsRefresh(new, new, NO));
        assert(!DMReceiverNeedsRefresh(nil, new, NO));
        assert(!DMReceiverNeedsRefresh(old, nil, NO));
        puts("PASS: updated receiver is refreshed on idle launch; active mirrors and unknown build dates are preserved");
    }
}
