#include <assert.h>
#include <stdio.h>
#include "../scrcpy-5.0/app/src/screen.c"

int main(void) {
    CVPixelBufferRef buffer = NULL;
    assert(CVPixelBufferCreate(NULL, 100, 200, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              NULL, &buffer) == kCVReturnSuccess);
    assert(CVPixelBufferLockBaseAddress(buffer, 0) == kCVReturnSuccess);
    unsigned char *y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
    unsigned char *uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
    size_t y_stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
    size_t uv_stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
    for (int row = 0; row < 200; ++row) memset(y + row * y_stride, 16, 100);
    for (int row = 0; row < 100; ++row) memset(uv + row * uv_stride, 128, 100);
    memset(y + 198 * y_stride + 35, 235, 30);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    AVFrame frame = {0}; frame.format = AV_PIX_FMT_VIDEOTOOLBOX;
    frame.width = 100; frame.height = 200; frame.data[3] = (unsigned char *)buffer;
    assert(sc_screen_is_secure_black_frame(&frame));
    CVPixelBufferLockBaseAddress(buffer, 0);
    y[100 * y_stride + 50] = 235;
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    assert(!sc_screen_is_secure_black_frame(&frame));
    CVPixelBufferRelease(buffer);
    puts("PASS: black-screen candidate detector reads VideoToolbox pixel buffers and preserves navigation-pill exceptions");
}
