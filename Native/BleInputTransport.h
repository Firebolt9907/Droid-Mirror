#import <Foundation/Foundation.h>
@protocol DMBleInputDelegate <NSObject>
- (void)bleInputReady;
- (void)bleInputFailed:(NSString *)reason;
@end
@interface DMBleInputTransport : NSObject
@property(nonatomic, weak) id<DMBleInputDelegate> delegate;
@property(nonatomic, readonly) BOOL ready;
- (instancetype)initWithSessionKey:(NSData *)key;
- (BOOL)send:(NSData *)bytes;
- (void)close;
@end
