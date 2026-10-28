#define DM_MUSIC_QUEUE_TEST 1
#import "MusicQueueHelper.m"
int main(void) { @autoreleasepool {
    NSDictionary *queue = @{@"owner":@123, @"current":@"now", @"queueID":@"queue",
                            @"entries":@[@{@"key":@"now"}, @{@"key":@"next"}]};
    NSMutableDictionary *request = [@{@"owner":@123, @"current":@"now", @"queueID":@"queue",
        @"keys":@[@"now", @"next"], @"target":@"next", @"expires":@(NSDate.date.timeIntervalSince1970 + 8)} mutableCopy];
    NSCAssert(DMMatches(request, queue), @"exact live queue must match");
    for (NSString *key in @[@"owner", @"current", @"queueID", @"target"]) {
        id original = request[key]; request[key] = @"replacement";
        NSCAssert(!DMMatches(request, queue), @"changed identity must fail"); request[key] = original;
    }
    request[@"keys"] = @[@"next", @"now"];
    NSCAssert(!DMMatches(request, queue), @"reordered entries must fail");
    request[@"keys"] = @[@"now", @"next"]; request[@"expires"] = @0;
    NSCAssert(!DMMatches(request, queue), @"expired selection must fail");
    NSCAssert(!DMMatches(request, nil), @"missing Music owner must fail");
    for (NSString *control in @[@"next", @"previous", @"play", @"pause"]) {
        NSDictionary *options = DMCommandOptions(request, control);
        NSCAssert(options && options.count == 0, @"transport must not select/restart the current item");
    }
    NSDictionary *selection = DMCommandOptions(request, @"queue");
    NSCAssert([selection[@"kMRMediaRemoteOptionContentItemID"] isEqual:@"next"] &&
              [selection[@"kMRMediaRemoteOptionPlaybackQueueOffset"] isEqual:@1], @"queue selection retains its target");
    request[@"position"] = @42;
    NSCAssert([DMCommandOptions(request, @"seek") isEqual:@{@"kMRMediaRemoteOptionPlaybackPosition":@42}], @"seek only supplies position");
    request[@"enabled"] = @YES;
    NSCAssert([DMCommandOptions(request, @"shuffle") isEqual:@{@"kMRMediaRemoteOptionShuffleMode":@3}], @"shuffle only supplies mode");
    request[@"mode"] = @"one";
    NSCAssert([DMCommandOptions(request, @"repeat") isEqual:@{@"kMRMediaRemoteOptionRepeatMode":@2}], @"repeat-one only supplies mode");
    puts("PASS: native queue owner, revision, order, membership and expiration checks");
} }
