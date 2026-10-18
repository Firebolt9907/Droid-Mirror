#import <Foundation/Foundation.h>

// Private, per-device cache path supplied by the host to both helper processes.
static inline NSString *DMPhoneAppearancePath(void) {
    return NSProcessInfo.processInfo.environment[@"DROIDMIRROR_APPEARANCE_CACHE"];
}
static inline NSDictionary *DMReadPhoneAppearance(void) {
    NSString *path = DMPhoneAppearancePath();
    if (!path.length) return @{};
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length > 65536) return @{};
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
static inline void DMCachePhoneAppearance(NSDictionary *update) {
    NSString *path = DMPhoneAppearancePath();
    if (!path.length) return;
    NSMutableDictionary *value = [DMReadPhoneAppearance() mutableCopy];
    for (NSString *key in @[@"displayDump", @"wallpaper", @"deviceName"])
        if ([update[key] isKindOfClass:NSString.class] && [update[key] length]) value[key] = update[key];
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (data.length <= 65536) {
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];
    }
}
