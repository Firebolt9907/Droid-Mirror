#import <Foundation/Foundation.h>
@protocol DMBleInputDelegate <NSObject>
- (void)bleInputReady;
- (BOOL)bleInputReceived:(NSData *)bytes;
- (void)bleInputFailed:(NSString *)reason;
@end
@interface DMBleInputTransport : NSObject
@property(nonatomic, weak) id<DMBleInputDelegate> delegate;
@property(atomic, readonly) BOOL ready;
- (instancetype)initWithPairingKey:(NSData *)key;
- (BOOL)send:(NSData *)bytes;
- (BOOL)acknowledgeVideo:(uint64_t)count;
- (void)close;
@end
