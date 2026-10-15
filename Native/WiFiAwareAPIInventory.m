// Read-only runtime metadata inventory. Does not instantiate private classes,
// connect to XPC services, or send radio requests.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSArray *methods(Class cls) {
    unsigned count = 0;
    Method *list = class_copyMethodList(cls, &count);
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++) {
        [result addObject:@{@"selector": NSStringFromSelector(method_getName(list[i])),
                            @"encoding": @(method_getTypeEncoding(list[i]))}];
    }
    free(list);
    return [result sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"selector" ascending:YES]]];
}

static NSArray *protocolMethods(Protocol *protocol, BOOL required, BOOL instance) {
    unsigned count = 0;
    struct objc_method_description *list = protocol_copyMethodDescriptionList(protocol, required, instance, &count);
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++) {
        [result addObject:@{@"selector": NSStringFromSelector(list[i].name),
                           @"encoding": list[i].types ? @(list[i].types) : @"",
                           @"required": @(required), @"instance": @(instance)}];
    }
    free(list);
    return result;
}

int main(void) { @autoreleasepool {
    NSMutableArray *images = [NSMutableArray array];
    for (NSString *path in @[
        @"/System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/WiFiPeerToPeer",
        @"/System/Library/PrivateFrameworks/CoreWiFi.framework/CoreWiFi",
        @"/System/Library/PrivateFrameworks/Apple80211.framework/Apple80211",
        @"/System/Library/PrivateFrameworks/IO80211.framework/IO80211",
        @"/System/Library/Frameworks/WiFiAware.framework/WiFiAware"
    ]) {
        BOOL loaded = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL) != NULL;
        [images addObject:@{@"path": path, @"loaded": @(loaded)}];
    }
    unsigned count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray *inventory = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        const char *image = class_getImageName(cls);
        NSString *path = image ? @(image) : @"";
        BOOL wifiImage = [path containsString:@"WiFi"] || [path containsString:@"80211"];
        NSMutableArray *relatedMethods = [NSMutableArray array];
        if (wifiImage) {
            for (NSDictionary *method in methods(cls)) {
                NSString *selector = method[@"selector"];
                if ([selector containsString:@"NAN"] || [selector containsString:@"Aware"])
                    [relatedMethods addObject:method];
            }
        }
        if (![path containsString:@"WiFiPeerToPeer.framework"] && !relatedMethods.count &&
            ![name containsString:@"Aware"] && ![name containsString:@"NAN"]) continue;
        // Only Wi-Fi-related images; avoid unrelated classes containing 'nan'.
        if (!wifiImage) continue;
        unsigned propertyCount = 0;
        objc_property_t *properties = class_copyPropertyList(cls, &propertyCount);
        NSMutableArray *props = [NSMutableArray array];
        for (unsigned j = 0; j < propertyCount; j++) {
            [props addObject:@{@"name": @(property_getName(properties[j])),
                              @"attributes": @(property_getAttributes(properties[j]))}];
        }
        free(properties);
        [inventory addObject:@{@"class": name, @"image": path,
            @"superclass": class_getSuperclass(cls) ? NSStringFromClass(class_getSuperclass(cls)) : @"",
            @"classMethods": methods(object_getClass(cls)), @"instanceMethods": methods(cls), @"properties": props}];
    }
    free(classes);
    inventory = [[inventory sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"class" ascending:YES]]] mutableCopy];
    Protocol *__unsafe_unretained *protocols = objc_copyProtocolList(&count);
    NSMutableArray *protocolInventory = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++) {
        NSString *name = @(protocol_getName(protocols[i]));
        if (![name hasPrefix:@"WiFiAware"] && ![name hasPrefix:@"WiFiP2P"]) continue;
        NSMutableArray *entries = [NSMutableArray array];
        for (int required = 0; required <= 1; required++)
            for (int instance = 0; instance <= 1; instance++)
                [entries addObjectsFromArray:protocolMethods(protocols[i], required, instance)];
        [protocolInventory addObject:@{@"protocol": name, @"methods": entries}];
    }
    free(protocols);
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{
        @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"images": images, @"classes": inventory,
        @"protocols": [protocolInventory sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"protocol" ascending:YES]]]
    } options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    if (!data) return 1;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    return 0;
} }
