#import <Foundation/Foundation.h>

// BLE-queue confined. ACKs may overtake input only at an envelope boundary.
@interface DMBleInputQueue : NSObject
@property(nonatomic, readonly) NSUInteger pendingBytes;
@property(nonatomic, readonly) BOOL hasWork;
@property(nonatomic, readonly) NSTimeInterval motionDelay;
@property(nonatomic) BOOL latestMotionOnly;
- (instancetype)initWithClock:(NSTimeInterval (^)(void))clock;
- (void)synchronizePhoneClock:(uint64_t)phone macClock:(uint64_t)mac;
- (BOOL)appendRecords:(NSData *)bytes;
- (void)acknowledgeVideo:(uint64_t)count;
- (void)requestBluetoothVideo:(uint64_t)count nonce:(NSData *)nonce;
- (NSData *)takePacket:(NSUInteger)maximum;
- (void)clear;
@end
