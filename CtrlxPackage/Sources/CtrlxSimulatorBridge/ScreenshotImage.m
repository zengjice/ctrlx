#import "ScreenshotImage.h"
#import "CtrlxSimulatorBridge.h"
#import <Accelerate/Accelerate.h>
#import <ImageIO/ImageIO.h>

static void CXReleaseScreenshotSurface(void *info, const void *data, size_t size) {
    IOSurfaceRef surface = (IOSurfaceRef)info;
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    CFRelease(surface);
}

static void CXReleaseScreenshotPixels(void *info, const void *data, size_t size) {
    free(info);
}

CGImageRef CXSimulatorCreateScreenshotImage(IOSurfaceRef surface, int orientation) {
    if (!surface || IOSurfaceGetPixelFormat(surface) != 0x42475241 ||
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) return NULL;
    size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface);
    size_t stride = IOSurfaceGetBytesPerRow(surface);
    void *pixels = IOSurfaceGetBaseAddress(surface);
    CGDataProviderRef provider;
    if (orientation >= 2 && orientation <= 4) {
        size_t outWidth = orientation >= 3 ? height : width;
        size_t outHeight = orientation >= 3 ? width : height;
        size_t outStride = (outWidth * 4 + 63) & ~63;
        void *rotated = malloc(outStride * outHeight);
        if (!rotated) { IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL); return NULL; }
        vImage_Buffer source = {pixels, height, width, stride};
        vImage_Buffer destination = {rotated, outHeight, outWidth, outStride};
        Pixel_8888 background = {0,0,0,0};
        uint8_t rotation = orientation == 2 ? kRotate180DegreesClockwise :
            orientation == 3 ? kRotate90DegreesCounterClockwise : kRotate90DegreesClockwise;
        vImage_Error error = vImageRotate90_ARGB8888(&source, &destination, rotation, background, kvImageNoFlags);
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        if (error != kvImageNoError) { free(rotated); return NULL; }
        width = outWidth; height = outHeight; stride = outStride;
        provider = CGDataProviderCreateWithData(rotated, rotated, stride * height, CXReleaseScreenshotPixels);
        if (!provider) { free(rotated); return NULL; }
    } else {
        CFRetain(surface);
        provider = CGDataProviderCreateWithData(surface, pixels, stride * height, CXReleaseScreenshotSurface);
        if (!provider) { CXReleaseScreenshotSurface(surface, pixels, stride * height); return NULL; }
    }
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(width, height, 8, 32, stride, color,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(color);
    CGDataProviderRelease(provider);
    return image;
}

NSDictionary *CXSimulatorCreatePreview(IOSurfaceRef surface, int orientation, NSUInteger maximumDimension) {
    if (maximumDimension < 256 || maximumDimension > 2560 || orientation < 1 || orientation > 4
        || IOSurfaceGetWidth(surface) > 8192 || IOSurfaceGetHeight(surface) > 8192) return nil;
    CGImageRef source = CXSimulatorCreateScreenshotImage(surface, orientation);
    if (!source) return nil;
    size_t sourceWidth = CGImageGetWidth(source), sourceHeight = CGImageGetHeight(source);
    size_t dimension = MIN(maximumDimension, MAX(sourceWidth, sourceHeight));
    NSDictionary *result = nil;
    while (dimension > 0) {
        double scale = (double)dimension / MAX(sourceWidth, sourceHeight);
        size_t width = MAX(1, (size_t)(sourceWidth * scale)), height = MAX(1, (size_t)(sourceHeight * scale));
        CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, color,
            kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
        CGColorSpaceRelease(color);
        if (!context) break;
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), source);
        CGImageRef image = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        NSMutableData *jpeg = [NSMutableData data];
        CGImageDestinationRef output = image ? CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL) : NULL;
        BOOL success = NO;
        if (output) {
            CGImageDestinationAddImage(output, image, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality:@0.82});
            success = CGImageDestinationFinalize(output);
            CFRelease(output);
        }
        if (image) CGImageRelease(image);
        if (!success) break;
        if (jpeg.length <= 512 * 1024) {
            result = @{@"data":[jpeg base64EncodedStringWithOptions:0], @"width":@(width), @"height":@(height)};
            break;
        }
        if (dimension <= 256) break;
        dimension = MAX(256, dimension * 3 / 4);
    }
    CGImageRelease(source);
    return result;
}
