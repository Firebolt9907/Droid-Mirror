#import "BleInputTransport.m"
#define main DMBridgeProgramMain
#import "ClassicBluetoothBridge.m"
#undef main
#include <assert.h>
@interface AudioLaneTestBridge : DMClassicBridge
@property(nonatomic) BOOL receivedPacket;
@end
@implementation AudioLaneTestBridge
- (void)publishAudioState {}
- (BOOL)receiveAudio:(uint8_t)type bytes:(const uint8_t *)bytes length:(size_t)length {
    assert(type==7 && length==12 && bytes[7]==42 && bytes[8]==1 && self.audioRequested);
    self.receivedPacket=YES; return YES;
}
@end
static void runUntil(BOOL (^done)(void), double seconds) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && deadline.timeIntervalSinceNow>0) CFRunLoopRunInMode(kCFRunLoopDefaultMode,.01,false);
    assert(done());
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        assert(argc==2);
        for (unsigned mode=0;mode<3;mode++) {
        AudioLaneTestBridge *bridge=[AudioLaneTestBridge new];
        bridge.wifiActive=YES; bridge.wifiSocket=-1; bridge.audioSocket=-1;
        bridge.audioState=1; bridge.audioForwardPort=(uint16_t)atoi(argv[1]);
        // ADB-only compatibility, prefer peer audio while video uses ADB,
        // then recover from an unavailable peer audio endpoint through ADB.
        if (mode==1) { bridge.peerAudioPort=bridge.audioForwardPort; bridge.audioForwardPort=1; }
        if (mode==2) bridge.peerAudioPort=1;
        uint8_t key[32]; memset(key,42,sizeof(key)); bridge.pairingKey=[NSData dataWithBytes:key length:32];
        [bridge startAudio];
        runUntil(^BOOL { [bridge pollAudio]; return bridge.receivedPacket; },4);
        assert(bridge.audioDedicated && bridge.audioSocket>=0 && !bridge.audioLocalFailure);
        [bridge stopAudio]; assert(!bridge.audioRequested && bridge.audioSocket==-1);
        }
        puts("Independent audio lane: actual Mac/Java proof handshake, dedicated framing, peer preference with ADB video, unavailable-peer fallback and clean Stop passed");
    }
}
