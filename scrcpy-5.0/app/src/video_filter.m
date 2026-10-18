#include "common.h"
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include <libavutil/frame.h>
#include <stdlib.h>
#include <string.h>
#include "video_filter.h"
#include "util/log.h"
#include "interop/interop.h"

// Process video luma directly: avoid a YUV -> color-managed RGB -> YUV/RGB
// round trip, so toggling cannot change the transfer function or white point.
@interface DMVideoProcessor : NSObject
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) id<MTLComputePipelineState> pipeline;
@property(nonatomic) CVMetalTextureCacheRef cache;
@property(nonatomic, strong) id<MTLComputePipelineState> rgbPipeline;
@property(nonatomic, strong) id<MTLFXSpatialScaler> scaler;
@end

@implementation DMVideoProcessor
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _device = MTLCreateSystemDefaultDevice();
    _queue = [_device newCommandQueue];
    NSString *source =
        @"#include <metal_stdlib>\nusing namespace metal;\n"
         "kernel void enhance(texture2d<float, access::read> src [[texture(0)]], "
         "texture2d<float, access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {"
         " int2 size = int2(src.get_width(), src.get_height());"
         " if (any(p >= uint2(size))) return;"
         " float c = src.read(p).r, sum = 0, weights = 0, blur = 0, blurW = 0, lo = c, hi = c;"
         " for (int y=-2; y<=2; ++y) for (int x=-2; x<=2; ++x) {"
         "   float v = src.read(uint2(clamp(int2(p)+int2(x,y), int2(0), size-1))).r;"
         "   float d = v-c;"
         "   float w = exp(-float(x*x+y*y)/3.0f - d*d/(2.0f*0.035f*0.035f));"
         "   sum += w*v; weights += w;"
         "   float spatial = exp(-float(x*x+y*y)/4.0f); blur += spatial*v; blurW += spatial;"
         "   if (abs(x)<=1 && abs(y)<=1) {"
         "     lo=min(lo,v); hi=max(hi,v);"
         "   }"
         " }"
         // Smooth small compression fluctuations without blending across text.
         " float clean = mix(c, sum/weights, 0.85f);"
         // Sharpen actual edges, rather than amplifying small block/ringing noise.
         " float edge = smoothstep(0.045f, 0.16f, hi-lo);"
         " float detail = clamp((c-blur/blurW)*1.25f*edge, -0.07f, 0.07f);"
         " float result = clamp(clean+detail, lo, hi);"
         " dst.write(float4(result,0,0,1), p);"
         "}"
         "kernel void videoRGB(texture2d<float, access::read> y [[texture(0)]], "
         "texture2d<float> uv [[texture(1)]], texture2d<float, access::write> rgb [[texture(2)]], "
         "constant float4 *params [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {"
         " if (p.x>=y.get_width() || p.y>=y.get_height()) return;"
         " constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);"
         " float l = (y.read(p).r-params[0].x)*params[0].y;"
         " float2 c = (uv.sample(linearSampler,(float2(p)+0.5f)/float2(y.get_width(),y.get_height())).rg-128.0f/255.0f)*params[0].z;"
         " float4 m=params[1];"
         " rgb.write(float4(clamp(float3(l+m.x*c.y,l+m.y*c.x+m.z*c.y,l+m.w*c.x),0.0f,1.0f),1),p);"
         "}";
    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:source options:nil error:&error];
    if (!library) {
        LOGW("Video enhancement shader compilation failed: %s", error.localizedDescription.UTF8String);
        return nil;
    }
    _pipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"enhance"] error:&error];
    _rgbPipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"videoRGB"] error:&error];
    if (!_rgbPipeline || !_pipeline || !_queue || CVMetalTextureCacheCreate(NULL, NULL, _device, NULL, &_cache) != kCVReturnSuccess) {
        LOGW("Video enhancement initialization failed: %s", error.localizedDescription.UTF8String);
        return nil;
    }
    return self;
}
- (void)dealloc { if (_cache) CFRelease(_cache); }
@end

// All calls run on the SDL render thread. Keep the original decoded frame so
// an idle screen can be toggled without waiting for another video packet.
struct sc_video_filter {
    AVFrame *frame;
    void *context;
    SDL_Texture *texture;
    CVPixelBufferRef output;
    CVPixelBufferRef scaled_output;
    bool attempted;
    bool enhance;
    bool spatial;
};

bool
sc_video_filter_supports_spatial(SDL_Renderer *renderer) {
    const char *name = SDL_GetRendererName(renderer);
    return name && !strcmp(name, "metal")
        && [MTLFXSpatialScalerDescriptor supportsDevice:MTLCreateSystemDefaultDevice()];
}

static void
sc_video_filter_clear(struct sc_video_filter *filter) {
    SDL_DestroyTexture(filter->texture);
    filter->texture = NULL;
    if (filter->output) CVPixelBufferRelease(filter->output);
    filter->output = NULL;
    if (filter->scaled_output) CVPixelBufferRelease(filter->scaled_output);
    filter->scaled_output = NULL;
    filter->attempted = false;
}

struct sc_video_filter *
sc_video_filter_new(void) {
    struct sc_video_filter *filter = calloc(1, sizeof(*filter));
    if (!filter) return NULL;
    filter->frame = av_frame_alloc();
    if (!filter->frame) { free(filter); return NULL; }
    return filter;
}

void
sc_video_filter_delete(struct sc_video_filter *filter) {
    if (!filter) return;
    sc_video_filter_clear(filter);
    av_frame_free(&filter->frame);
    if (filter->context) CFRelease(filter->context);
    free(filter);
}

void
sc_video_filter_set_frame(struct sc_video_filter *filter, const AVFrame *frame) {
    if (!filter) return;
    sc_video_filter_clear(filter);
    av_frame_unref(filter->frame);
    if (frame && av_frame_ref(filter->frame, frame) < 0) {
        LOGW("Could not retain frame for sharpening");
    }
}

static CVPixelBufferRef
sc_video_filter_input(const AVFrame *frame) {
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        CVPixelBufferRef input = (CVPixelBufferRef) frame->data[3];
        return input ? CVPixelBufferRetain(input) : NULL;
    }
    if (frame->format != AV_PIX_FMT_YUV420P
            && frame->format != AV_PIX_FMT_YUVJ420P) return NULL;

    bool full = frame->color_range == AVCOL_RANGE_JPEG
             || frame->format == AV_PIX_FMT_YUVJ420P;
    OSType format = full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                        : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CVPixelBufferRef input = NULL;
    NSDictionary *attributes = @{(id) kCVPixelBufferIOSurfacePropertiesKey: @{},
                                 (id) kCVPixelBufferMetalCompatibilityKey: @YES};
    if (CVPixelBufferCreate(NULL, frame->width, frame->height, format,
                           (__bridge CFDictionaryRef) attributes, &input)
            != kCVReturnSuccess) return NULL;
    if (CVPixelBufferLockBaseAddress(input, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(input); return NULL;
    }
    uint8_t *y_plane = CVPixelBufferGetBaseAddressOfPlane(input, 0);
    uint8_t *uv_plane = CVPixelBufferGetBaseAddressOfPlane(input, 1);
    size_t y_stride = CVPixelBufferGetBytesPerRowOfPlane(input, 0);
    size_t uv_stride = CVPixelBufferGetBytesPerRowOfPlane(input, 1);
    for (int y = 0; y < frame->height; ++y) {
        memcpy(y_plane + y * y_stride, frame->data[0] + y * frame->linesize[0],
               frame->width);
    }
    for (int y = 0; y < (frame->height + 1) / 2; ++y) {
        for (int x = 0; x < (frame->width + 1) / 2; ++x) {
            uv_plane[y * uv_stride + 2 * x] = frame->data[1][y * frame->linesize[1] + x];
            uv_plane[y * uv_stride + 2 * x + 1] = frame->data[2][y * frame->linesize[2] + x];
        }
    }
    CVPixelBufferUnlockBaseAddress(input, 0);
    return input;
}

// Convert to perceptual RGB once, then use Apple's actual MetalFX spatial scaler.
// A fresh output texture per frame avoids overwriting a texture SDL is presenting.
static SDL_Texture *
sc_video_filter_spatial(DMVideoProcessor *processor, CVPixelBufferRef input,
                         const AVFrame *frame, SDL_Renderer *renderer, CVPixelBufferRef *scaled_output) {
    if (![MTLFXSpatialScalerDescriptor supportsDevice:processor.device]) return NULL;
    NSUInteger width = frame->width, height = frame->height;
    if (!processor.scaler || processor.scaler.inputWidth != width || processor.scaler.inputHeight != height) {
        MTLFXSpatialScalerDescriptor *descriptor = [MTLFXSpatialScalerDescriptor new];
        descriptor.inputWidth = width; descriptor.inputHeight = height;
        descriptor.outputWidth = width * 2; descriptor.outputHeight = height * 2;
        descriptor.colorTextureFormat = MTLPixelFormatRGBA8Unorm;
        descriptor.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        processor.scaler = [descriptor newSpatialScalerWithDevice:processor.device];
    }
    id<MTLFXSpatialScaler> scaler = processor.scaler;
    if (!scaler) return NULL;
    CVMetalTextureRef planes[2] = {NULL, NULL};
    bool ok = true;
    for (unsigned p = 0; ok && p < 2; ++p) {
        ok = CVMetalTextureCacheCreateTextureFromImage(NULL, processor.cache, input, NULL,
            p ? MTLPixelFormatRG8Unorm : MTLPixelFormatR8Unorm,
            CVPixelBufferGetWidthOfPlane(input, p), CVPixelBufferGetHeightOfPlane(input, p),
            p, &planes[p]) == kCVReturnSuccess;
    }
    SDL_Texture *texture = NULL;
    if (ok) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = scaler.colorTextureUsage | MTLTextureUsageShaderWrite;
        id<MTLTexture> rgb = [processor.device newTextureWithDescriptor:descriptor];
        NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                                     (id)kCVPixelBufferMetalCompatibilityKey: @YES};
        CVMetalTextureRef output_plane = NULL;
        CVReturn result = CVPixelBufferCreate(NULL, width * 2, height * 2,
            kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, scaled_output);
        if (result == kCVReturnSuccess) {
            NSDictionary *usage = @{(id)kCVMetalTextureUsage: @(scaler.outputTextureUsage | MTLTextureUsageShaderRead)};
            CVMetalTextureCacheCreateTextureFromImage(NULL, processor.cache, *scaled_output,
                (__bridge CFDictionaryRef)usage, MTLPixelFormatBGRA8Unorm, width * 2, height * 2, 0, &output_plane);
        }
        id<MTLTexture> output = output_plane ? CVMetalTextureGetTexture(output_plane) : nil;
        if (rgb && output) {
            bool full = frame->color_range == AVCOL_RANGE_JPEG || frame->format == AV_PIX_FMT_YUVJ420P;
            float params[8] = {full ? 0 : 16.0f/255, full ? 1 : 255.0f/219,
                full ? 1 : 255.0f/224, 0, 1.5748f, -0.187324f, -0.468124f, 1.8556f};
            if (frame->colorspace == AVCOL_SPC_BT470BG || frame->colorspace == AVCOL_SPC_SMPTE170M) {
                params[4]=1.402f; params[5]=-0.344136f; params[6]=-0.714136f; params[7]=1.772f;
            } else if (frame->colorspace == AVCOL_SPC_BT2020_NCL || frame->colorspace == AVCOL_SPC_BT2020_CL) {
                params[4]=1.4746f; params[5]=-0.164553f; params[6]=-0.571353f; params[7]=1.8814f;
            }
            id<MTLCommandBuffer> command = [processor.queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:processor.rgbPipeline];
            [encoder setTexture:CVMetalTextureGetTexture(planes[0]) atIndex:0];
            [encoder setTexture:CVMetalTextureGetTexture(planes[1]) atIndex:1];
            [encoder setTexture:rgb atIndex:2];
            [encoder setBytes:params length:sizeof(params) atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
            [encoder endEncoding];
            scaler.colorTexture = rgb; scaler.outputTexture = output;
            [scaler encodeToCommandBuffer:command];
            [command commit]; [command waitUntilCompleted];
            if (command.status == MTLCommandBufferStatusCompleted) {
                SDL_PropertiesID props = SDL_CreateProperties();
                SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_FORMAT_NUMBER, SDL_PIXELFORMAT_BGRA32);
                SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_WIDTH_NUMBER, width * 2);
                SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_HEIGHT_NUMBER, height * 2);
                SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_COLORSPACE_NUMBER, SDL_COLORSPACE_SRGB);
                SDL_SetPointerProperty(props, SDL_PROP_TEXTURE_CREATE_METAL_PIXELBUFFER_POINTER, *scaled_output);
                texture = SDL_CreateTextureWithProperties(renderer, props);
                SDL_DestroyProperties(props);
            }
            scaler.colorTexture = nil; scaler.outputTexture = nil;
        }
        if (output_plane) CFRelease(output_plane);
    }
    for (unsigned p=0; p<2; ++p) if (planes[p]) CFRelease(planes[p]);
    return texture;
}

SDL_Texture *
sc_video_filter_get(struct sc_video_filter *filter, SDL_Renderer *renderer) {
    if (!filter) return NULL;
    SDL_Window *window = SDL_GetRenderWindow(renderer);
    if (!window) return NULL;
    SDL_PropertiesID properties = SDL_GetWindowProperties(window);
    bool enhance = SDL_GetBooleanProperty(properties, SC_VIDEO_FILTER_PROP, false);
    bool spatial = SDL_GetBooleanProperty(properties, SC_SPATIAL_FILTER_PROP, false);
    if (filter->enhance != enhance || filter->spatial != spatial) {
        sc_video_filter_clear(filter);
        filter->enhance = enhance; filter->spatial = spatial;
    }
    if (!enhance && !spatial) return NULL;
    if (filter->attempted) return filter->texture;
    filter->attempted = true;
    const char *name = SDL_GetRendererName(renderer);
    if (!name || strcmp(name, "metal") || !filter->frame->width) return NULL;

    @autoreleasepool {
        if (!filter->context) {
            DMVideoProcessor *processor = [DMVideoProcessor new];
            if (!processor) return NULL;
            filter->context = (__bridge_retained void *) processor;
        }
        DMVideoProcessor *processor = (__bridge DMVideoProcessor *) filter->context;
        CVPixelBufferRef input = sc_video_filter_input(filter->frame);
        if (!input) return NULL;
        OSType format = CVPixelBufferGetPixelFormatType(input);
        if (format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                && format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            CVPixelBufferRelease(input);
            return NULL;
        }
        if (!enhance) {
            filter->texture = sc_video_filter_spatial(processor, input, filter->frame, renderer, &filter->scaled_output);
            CVPixelBufferRelease(input);
            return filter->texture;
        }
        NSDictionary *attributes = @{(id) kCVPixelBufferIOSurfacePropertiesKey: @{},
                                     (id) kCVPixelBufferMetalCompatibilityKey: @YES};
        CVReturn result = CVPixelBufferCreate(NULL, filter->frame->width,
            filter->frame->height, format,
            (__bridge CFDictionaryRef) attributes, &filter->output);
        CVMetalTextureRef planes[4] = {NULL, NULL, NULL, NULL};
        bool ok = result == kCVReturnSuccess;
        for (unsigned i = 0; ok && i < 4; ++i) {
            unsigned plane = i % 2;
            CVPixelBufferRef buffer = i < 2 ? input : filter->output;
            NSDictionary *usage = @{(id) kCVMetalTextureUsage:
                @(i == 2 ? MTLTextureUsageShaderWrite : MTLTextureUsageShaderRead)};
            ok = CVMetalTextureCacheCreateTextureFromImage(NULL, processor.cache,
                buffer, (__bridge CFDictionaryRef) usage,
                plane ? MTLPixelFormatRG8Unorm : MTLPixelFormatR8Unorm,
                CVPixelBufferGetWidthOfPlane(buffer, plane),
                CVPixelBufferGetHeightOfPlane(buffer, plane), plane,
                &planes[i]) == kCVReturnSuccess;
        }
        if (ok) {
            id<MTLCommandBuffer> command = [processor.queue commandBuffer];
            id<MTLComputeCommandEncoder> compute = [command computeCommandEncoder];
            [compute setComputePipelineState:processor.pipeline];
            [compute setTexture:CVMetalTextureGetTexture(planes[0]) atIndex:0];
            [compute setTexture:CVMetalTextureGetTexture(planes[2]) atIndex:1];
            [compute dispatchThreads:MTLSizeMake(filter->frame->width, filter->frame->height, 1)
                threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [compute endEncoding];
            // Chroma passes through byte-for-byte; the SDL YUV conversion and
            // source color metadata remain identical to the bypass path.
            id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
            [blit copyFromTexture:CVMetalTextureGetTexture(planes[1])
                       toTexture:CVMetalTextureGetTexture(planes[3])];
            [blit endEncoding];
            [command commit];
            [command waitUntilCompleted];
            ok = command.status == MTLCommandBufferStatusCompleted;
        }
        if (ok) {
            SDL_PropertiesID props = SDL_CreateProperties();
            SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_FORMAT_NUMBER, SDL_PIXELFORMAT_NV12);
            SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_WIDTH_NUMBER, filter->frame->width);
            SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_HEIGHT_NUMBER, filter->frame->height);
            SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_COLORSPACE_NUMBER,
                sc_interop_to_sdl_color_space(filter->frame->colorspace, filter->frame->color_range));
            SDL_SetPointerProperty(props, SDL_PROP_TEXTURE_CREATE_METAL_PIXELBUFFER_POINTER, filter->output);
            filter->texture = SDL_CreateTextureWithProperties(renderer, props);
            SDL_DestroyProperties(props);
        }
        if (filter->texture && spatial) {
            SDL_Texture *scaled = sc_video_filter_spatial(processor, filter->output, filter->frame, renderer, &filter->scaled_output);
            if (scaled) { SDL_DestroyTexture(filter->texture); filter->texture = scaled; }
        }
        for (unsigned i = 0; i < 4; ++i) if (planes[i]) CFRelease(planes[i]);
        CVMetalTextureCacheFlush(processor.cache, 0);
        CVPixelBufferRelease(input);
        if (!filter->texture) LOGW("Video enhancement unavailable; displaying original frame");
        return filter->texture;
    }
}
