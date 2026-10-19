#import <AVFoundation/AVFoundation.h>
#import "WirelessAudioRing.h"

@interface DMWirelessAudioBuffer : NSObject {
@public DMAudioRing ring;
}
@end
@implementation DMWirelessAudioBuffer
@end

/** The network thread writes PCM; the audio engine pulls a continuous stream. */
@interface DMWirelessAudioPlayback : NSObject
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) AVAudioSourceNode *source;
@property(nonatomic, strong) DMWirelessAudioBuffer *buffer;
@property(nonatomic) uint64_t lastPTS;
@property(nonatomic) NSTimeInterval lastDiagnostic, lastArrival, maxArrivalGap;
@property(nonatomic) uint64_t maxPTSGap;
- (instancetype)initWithBufferMs:(NSUInteger)milliseconds;
- (BOOL)appendPacket:(const uint8_t *)bytes length:(size_t)length;
- (void)stop;
@end

@implementation DMWirelessAudioPlayback
- (instancetype)initWithBufferMs:(NSUInteger)milliseconds {
    if (!(self=[super init])) return nil;
    _engine=[AVAudioEngine new]; _buffer=[DMWirelessAudioBuffer new];
    dm_audio_ring_init(&_buffer->ring,(unsigned)MIN(milliseconds,200));
    DMWirelessAudioBuffer *buffer=_buffer;
    AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    // Retain the ring through the block's lifetime, independently of the owner.
    _source=[[AVAudioSourceNode alloc] initWithFormat:format renderBlock:
        ^OSStatus(BOOL *silence, const AudioTimeStamp *timestamp, AVAudioFrameCount frames, AudioBufferList *output) {
            if (output->mNumberBuffers!=2 || !output->mBuffers[0].mData || !output->mBuffers[1].mData) return kAudio_ParamError;
            *silence=!dm_audio_ring_render(&buffer->ring,output->mBuffers[0].mData,output->mBuffers[1].mData,frames);
            return noErr;
        }];
    [_engine attachNode:_source]; [_engine connect:_source to:_engine.mainMixerNode format:format];
    NSError *error=nil;
    if (![_engine startAndReturnError:&error]) {
        fprintf(stderr,"Audio output unavailable: %s\n",error.localizedDescription.UTF8String);
        return nil;
    }
    return self;
}
- (void)stop { [_engine stop]; }
- (BOOL)appendPacket:(const uint8_t *)bytes length:(size_t)length {
    if (length<12 || length>4104 || length%4 || !_engine.running) return NO;
    uint64_t pts=0;
    for (NSUInteger i=0;i<8;i++) pts=(pts<<8)|bytes[i];
    if (pts>>61 || (_lastPTS && pts<=_lastPTS)) return NO;
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if (_lastArrival) _maxArrivalGap=MAX(_maxArrivalGap,now-_lastArrival);
    if (_lastPTS) _maxPTSGap=MAX(_maxPTSGap,pts-_lastPTS);
    _lastArrival=now; _lastPTS=pts;
    dm_audio_ring_write(&_buffer->ring,bytes+8,(length-8)/4);
    if (now-_lastDiagnostic>5) {
        _lastDiagnostic=now;
        fprintf(stderr,"Audio jitter buffer: queuedMs=%llu underruns=%u trims=%u overflows=%u maxArrivalGapMs=%.1f maxCaptureGapMs=%.1f\n",
            (unsigned long long)((atomic_load(&_buffer->ring.written)-atomic_load(&_buffer->ring.read))/48),
            atomic_load(&_buffer->ring.underruns),atomic_load(&_buffer->ring.trims),atomic_load(&_buffer->ring.overflows),_maxArrivalGap*1000,(double)_maxPTSGap/1000);
        _maxArrivalGap=0; _maxPTSGap=0;
    }
    return YES;
}
@end
