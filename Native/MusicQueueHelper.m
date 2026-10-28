#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

// Loaded only in a short-lived /usr/bin/perl child (see AppleMusicQueue.swift).
// No private framework is linked into the host or notification receiver.
static id DMGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}
static void DMSet(id object, NSString *name, id value) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) @throw [NSException exceptionWithName:@"Unavailable" reason:name userInfo:nil];
    ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}
static NSString *DMString(id value, NSUInteger maximum) {
    if (![value isKindOfClass:NSString.class] || [value length] > maximum) return @"";
    return value;
}
static void DMPrint(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (data.length > 524288) data = [@"{\"available\":false}" dataUsingEncoding:NSUTF8StringEncoding];
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
}
static NSDictionary *DMRead(id controller) {
    id response = DMGet(controller, @"response");
    id path = DMGet(response, @"playerPath");
    id client = DMGet(path, @"client");
    if (![DMGet(client, @"bundleIdentifier") isEqual:@"com.apple.Music"]) return nil;
    id queue = DMGet(response, @"playbackQueue");
    NSArray *items = DMGet(queue, @"contentItems");
    if (![items isKindOfClass:NSArray.class] || items.count == 0) return nil;
    NSMutableArray *entries = [NSMutableArray array];
    for (id item in items) {
        if (entries.count == 32) break;
        NSString *key = DMString(DMGet(item, @"identifier"), 512);
        id metadata = DMGet(item, @"metadata");
        if (!key.length) return nil;
        NSString *title = DMString(DMGet(metadata, @"title"), 1024);
        NSString *artist = DMString(DMGet(metadata, @"trackArtistName"), 1024);
        [entries addObject:@{@"key":key, @"title":title, @"artist":artist}];
    }
    NSNumber *pid = [client valueForKey:@"processIdentifier"];
    NSString *queueID = DMString(DMGet(queue, @"queueIdentifier"), 512);
    if (pid.intValue <= 0 || !queueID.length) return nil;
    id metadata = DMGet(items.firstObject, @"metadata");
    double duration = [[metadata valueForKey:@"duration"] doubleValue];
    double position = [[metadata valueForKey:@"elapsedTime"] doubleValue];
    SEL calculate = NSSelectorFromString(@"calculatedPlaybackPositionFromDate:");
    if ([metadata respondsToSelector:calculate]) position = ((double (*)(id, SEL, id))objc_msgSend)(metadata, calculate, NSDate.date);
    NSMutableDictionary *commands = [NSMutableDictionary dictionary];
    NSDictionary *names = @{@"Play":@"play", @"Pause":@"pause", @"NextTrack":@"next", @"PreviousTrack":@"previous",
        @"SeekToPlaybackPosition":@"seek", @"SetShuffleMode":@"shuffle", @"SetRepeatMode":@"repeat", @"PlayItemInPlaybackQueue":@"queue"};
    for (id command in DMGet(response, @"supportedCommands")) {
        NSDictionary *description = DMGet(command, @"dictionaryRepresentation");
        NSString *action = names[description[@"command"]];
        if (action && [[command valueForKey:@"enabled"] boolValue]) commands[action] = [command valueForKey:@"command"];
    }
    int repeat = [[response valueForKey:@"repeatMode"] intValue];
    NSDictionary *playback = @{@"title":entries.firstObject[@"title"], @"artist":entries.firstObject[@"artist"],
        @"album":DMString(DMGet(metadata, @"albumName"), 1024), @"duration":@(isfinite(duration) ? fmax(0, duration) : 0),
        @"position":@(isfinite(position) ? fmax(0, position) : 0),
        @"playing":@((BOOL)([[response valueForKey:@"playbackRate"] floatValue] > 0)),
        @"shuffle":@((BOOL)([[response valueForKey:@"shuffleMode"] intValue] > 1)),
        @"repeat":repeat == 2 ? @"one" : (repeat == 3 ? @"all" : @"off"), @"actions":commands.allKeys};
    NSMutableDictionary *result = [@{@"available":@YES, @"owner":pid, @"queueID":queueID,
        @"current":entries.firstObject[@"key"], @"entries":entries, @"playback":playback, @"commands":commands} mutableCopy];
    NSNumber *catalogID = [metadata valueForKey:@"iTunesStoreIdentifier"];
    if (catalogID.unsignedLongLongValue > 0) result[@"artworkCatalogID"] = catalogID.stringValue;
    id artwork = DMGet(items.firstObject, @"artwork");
    NSData *cover = [artwork isKindOfClass:NSData.class] ? artwork : DMGet(artwork, @"data");
    if ([cover isKindOfClass:NSData.class] && cover.length <= 262144) result[@"artwork"] = [cover base64EncodedStringWithOptions:0];
    return result;
}
static BOOL DMMatches(NSDictionary *request, NSDictionary *queue) {
    if (!queue || [request[@"expires"] doubleValue] <= NSDate.date.timeIntervalSince1970) return NO;
    for (NSString *key in @[@"owner", @"current", @"queueID"]) if (![queue[key] isEqual:request[key]]) return NO;
    NSArray *keys = [queue[@"entries"] valueForKey:@"key"];
    return [keys isEqual:request[@"keys"]] && [keys containsObject:request[@"target"]];
}

static NSDictionary *DMCommandOptions(NSDictionary *request, NSString *control) {
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    // Item selectors are meaningful only for explicit queue selection. Passing
    // the current item to NextTrack can make Music replay that item instead.
    if ([control isEqual:@"queue"]) {
        NSArray *keys = request[@"keys"];
        NSUInteger index = [keys indexOfObject:request[@"target"]];
        if (!keys || index == NSNotFound) return nil;
        options[@"kMRMediaRemoteOptionContentItemID"] = request[@"target"];
        options[@"kMRMediaRemoteOptionPlaybackQueueOffset"] = @(index);
    } else if ([control isEqual:@"seek"]) {
        double position = [request[@"position"] doubleValue];
        if (!isfinite(position) || position < 0 || position > 604800) return nil;
        options[@"kMRMediaRemoteOptionPlaybackPosition"] = @(position);
    } else if ([control isEqual:@"shuffle"]) {
        options[@"kMRMediaRemoteOptionShuffleMode"] = [request[@"enabled"] boolValue] ? @3 : @1;
    } else if ([control isEqual:@"repeat"]) {
        NSDictionary *modes = @{@"off":@1, @"one":@2, @"all":@3};
        if (!modes[request[@"mode"]]) return nil;
        options[@"kMRMediaRemoteOptionRepeatMode"] = modes[request[@"mode"]];
    } else if (![@[@"play", @"pause", @"next", @"previous"] containsObject:control]) {
        return nil;
    }
    return options;
}

#ifndef DM_MUSIC_QUEUE_TEST
__attribute__((constructor)) static void DMQueueMain(void) {
    @autoreleasepool { @try {
        // The parent supplies bounded JSON on stdin, never shell code.
        NSMutableData *input = [NSMutableData data];
        uint8_t buffer[1024]; size_t length;
        while ((length = fread(buffer, 1, sizeof(buffer), stdin))) {
            [input appendBytes:buffer length:length];
            if (input.length > 16384) { DMPrint(@{@"available":@NO}); return; }
        }
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
        if (![request isKindOfClass:NSDictionary.class]) { DMPrint(@{@"available":@NO}); return; }
        NSString *action = request[@"action"];
        if (![@[@"read", @"select", @"control", @"validate"] containsObject:action]) { DMPrint(@{@"available":@NO}); return; }
        if (!dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)) {
            DMPrint(@{@"available":@NO}); return;
        }
        Class controllerClass = NSClassFromString(@"MRNowPlayingController");
        Class requestClass = NSClassFromString(@"MRPlaybackQueueRequest");
        SEL rangeSelector = NSSelectorFromString(@"defaultPlaybackQueueRequestWithRange:");
        if (![requestClass respondsToSelector:rangeSelector]) { DMPrint(@{@"available":@NO}); return; }
        id controller = DMGet(controllerClass, @"localRouteController");
        id configuration = DMGet(controller, @"configuration");
        // Phone playback can own global Now Playing. Resolve Music explicitly.
        id musicDestination = [DMGet(configuration, @"destination") copy];
        Class clientClass = NSClassFromString(@"MRClient");
        SEL clientInitializer = NSSelectorFromString(@"initWithBundleIdentifier:");
        id allocatedClient = [clientClass alloc];
        if (![allocatedClient respondsToSelector:clientInitializer]) { DMPrint(@{@"available":@NO}); return; }
        id musicClient = ((id (*)(id, SEL, id))objc_msgSend)(allocatedClient, clientInitializer, @"com.apple.Music");
        DMSet(musicDestination, @"setClient:", musicClient);
        DMSet(configuration, @"setDestination:", musicDestination);
        id queueRequest = ((id (*)(id, SEL, NSRange))objc_msgSend)(requestClass, rangeSelector, NSMakeRange(0, 32));
        DMSet(configuration, @"setPlaybackQueueRequest:", queueRequest);
        SEL wantsQueue = NSSelectorFromString(@"setRequestPlaybackQueue:");
        if (![configuration respondsToSelector:wantsQueue]) { DMPrint(@{@"available":@NO}); return; }
        ((void (*)(id, SEL, BOOL))objc_msgSend)(configuration, wantsQueue, YES);
        DMSet(controller, @"setConfiguration:", configuration);
        SEL begin = NSSelectorFromString(@"beginLoadingUpdates");
        if (![controller respondsToSelector:begin]) { DMPrint(@{@"available":@NO}); return; }
        ((void (*)(id, SEL))objc_msgSend)(controller, begin);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.5];
        NSDictionary *queue = nil;
        while (deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            queue = DMRead(controller);
            if (queue) {
                // Artwork can arrive just after the text metadata.
                if ([action isEqual:@"read"] && !queue[@"artwork"]) {
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
                    queue = DMRead(controller) ?: queue;
                }
                break;
            }
        }
        if ([action isEqual:@"read"]) { DMPrint(queue ?: @{@"available":@NO}); return; }
        if (!DMMatches(request, queue)) { DMPrint(@{@"accepted":@NO}); return; }
        if ([action isEqual:@"validate"]) { DMPrint(@{@"accepted":@YES}); return; }
        // Bind the command to the exact resolved Music destination, never to
        // whatever application happens to own global Now Playing at send time.
        id destination = DMGet(DMGet(controller, @"response"), @"destination");
        Class nowPlayingClass = NSClassFromString(@"MRNowPlayingRequest");
        SEL initialize = NSSelectorFromString(@"initWithDestination:");
        id allocated = [nowPlayingClass alloc];
        if (!destination || ![allocated respondsToSelector:initialize]) { DMPrint(@{@"accepted":@NO}); return; }
        id target = ((id (*)(id, SEL, id))objc_msgSend)(allocated, initialize, destination);
        SEL send = NSSelectorFromString(@"sendCommand:options:queue:completion:");
        if (![target respondsToSelector:send] || !DMMatches(request, DMRead(controller))) { DMPrint(@{@"accepted":@NO}); return; }
        NSString *control = [action isEqual:@"select"] ? @"queue" : request[@"control"];
        NSNumber *command = queue[@"commands"][control];
        NSDictionary *options = DMCommandOptions(request, control);
        if (!command || !options) { DMPrint(@{@"accepted":@NO}); return; }
        __block BOOL finished = NO;
        __block BOOL accepted = NO;
        void (^completion)(id) = ^(id result) {
            accepted = result == nil || ([result respondsToSelector:NSSelectorFromString(@"error")] && DMGet(result, @"error") == nil);
            finished = YES;
        };
        // Only commands currently advertised by the resolved Music session.
        ((void (*)(id, SEL, unsigned int, id, id, id))objc_msgSend)(target, send, command.unsignedIntValue, options, dispatch_get_main_queue(), completion);
        NSDate *commandDeadline = [NSDate dateWithTimeIntervalSinceNow:0.8];
        while (!finished && commandDeadline.timeIntervalSinceNow > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        DMPrint(@{@"accepted":@((BOOL)(finished && accepted))});
    } @catch (NSException *exception) { DMPrint(@{@"available":@NO, @"accepted":@NO}); } }
}

#endif
