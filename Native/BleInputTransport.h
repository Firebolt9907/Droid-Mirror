#import <Foundation/Foundation.h>
@protocol DMBleInputDelegate <NSObject>
- (void)bleInputReady;
- (BOOL)bleInputReceived:(NSData *)bytes;
- (void)bleInputFailed:(NSString *)reason;
@end
@interface DMBleInputTransport : NSObject
@property(nonatomic, weak) id<DMBleInputDelegate> delegate;
@property(atomic, readonly) BOOL ready;
@property(atomic, readonly) BOOL recovering;
@property(atomic, readonly) BOOL pairingProofRejected;
@property(atomic, copy, readonly) NSString *connectionStage;
- (instancetype)initWithPairingKey:(NSData *)key;
- (BOOL)send:(NSData *)bytes;
- (BOOL)acknowledgeVideo:(uint64_t)count;
- (BOOL)requestBluetoothVideo:(uint64_t)count nonce:(NSData *)nonce;
/// YES while the first capture record waits for the host's Touch ID decision.
@property(atomic, readonly) BOOL awaitingUnlockDecision;
/// Resolves a deferred decision once; later calls cannot change it.
- (void)resolveUnlockDecision:(BOOL)allowed;
- (void)close;
@end
