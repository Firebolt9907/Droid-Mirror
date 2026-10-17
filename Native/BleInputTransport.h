#import <Foundation/Foundation.h>
@protocol DMBleInputDelegate <NSObject>
- (void)bleInputReady;
- (BOOL)bleInputReceived:(NSData *)bytes;
- (void)bleInputFailed:(NSString *)reason;
@end
@interface DMBleInputTransport : NSObject
@property(nonatomic, weak) id<DMBleInputDelegate> delegate;
@property(atomic, readonly) BOOL ready;
@property(atomic, copy, readonly) NSString *connectionStage;
- (instancetype)initWithPairingKey:(NSData *)key;
- (BOOL)send:(NSData *)bytes;
- (BOOL)acknowledgeVideo:(uint64_t)count;
- (BOOL)requestBluetoothVideo:(uint64_t)count nonce:(NSData *)nonce;
- (void)close;
@end
