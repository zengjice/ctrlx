#import <Foundation/Foundation.h>
#import "ScreenshotImage.h"

static void checkImage(size_t width, size_t height, int orientation) {
    size_t stride = (width * 4 + 63) & ~63;
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (id)kIOSurfaceWidth:@(width), (id)kIOSurfaceHeight:@(height),
        (id)kIOSurfaceBytesPerElement:@4, (id)kIOSurfaceBytesPerRow:@(stride),
        (id)kIOSurfacePixelFormat:@(0x42475241)});
    assert(surface && IOSurfaceLock(surface, 0, NULL) == kIOReturnSuccess);
    uint8_t *pixels = IOSurfaceGetBaseAddress(surface);
    memset(pixels, 0xcc, stride * height);
    for (size_t y = 0; y < height; y++) for (size_t x = 0; x < width; x++) {
        uint8_t *p = pixels + y*stride + x*4;
        p[0] = (x*7 + y*3) % 128;
        p[1] = (x*5 + y*11) % 128;
        p[2] = (x*13 + y*17) % 128;
        p[3] = 128 + (x+y) % 128;
    }
    assert(IOSurfaceUnlock(surface, 0, NULL) == kIOReturnSuccess);
    CGImageRef image = CXSimulatorCreateScreenshotImage(surface, orientation);
    assert(image);
    // The image must remain usable after the caller releases its surface reference.
    CFRelease(surface);
    BOOL sideways = orientation == 3 || orientation == 4;
    assert(CGImageGetWidth(image) == (sideways ? height : width));
    assert(CGImageGetHeight(image) == (sideways ? width : height));
    CFDataRef storage = CGDataProviderCopyData(CGImageGetDataProvider(image));
    assert(storage);
    const uint8_t *bytes = CFDataGetBytePtr(storage);
    size_t outputStride = CGImageGetBytesPerRow(image);
    for (size_t y = 0; y < height; y++) for (size_t x = 0; x < width; x++) {
        size_t outX = x, outY = y;
        if (orientation == 2) { outX = width-1-x; outY = height-1-y; }
        else if (orientation == 3) { outX = y; outY = width-1-x; }
        else if (orientation == 4) { outX = height-1-y; outY = x; }
        const uint8_t *p = bytes + outY*outputStride + outX*4;
        assert(p[0] == (x*7 + y*3) % 128);
        assert(p[1] == (x*5 + y*11) % 128);
        assert(p[2] == (x*13 + y*17) % 128);
        assert(p[3] == 128 + (x+y) % 128);
    }
    CFRelease(storage);
    CGImageRelease(image);
}

int main(void) {
    @autoreleasepool {
        assert(CXSimulatorCreateScreenshotImage(NULL, 1) == NULL);
        size_t dimensions[][2] = {{1,2},{2,1},{3,5},{17,9},{1179,3}};
        for (int size = 0; size < 5; size++) for (int orientation = 0; orientation <= 4; orientation++) {
            checkImage(dimensions[size][0], dimensions[size][1], orientation);
        }
        puts("25 orientation/stride/lifetime cases and null-surface rejection passed");
    }
    return 0;
}
