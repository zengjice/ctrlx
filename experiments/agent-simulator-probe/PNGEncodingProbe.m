#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

// Compare readback paths on the same retained, test-owned bitmap.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        CGImageRef fixture = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
        if (source) CFRelease(source);
        if (!fixture) return 1;
        size_t width = CGImageGetWidth(fixture), height = CGImageGetHeight(fixture), stride = (width * 4 + 63) & ~63;
        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
            (id)kIOSurfaceWidth:@(width), (id)kIOSurfaceHeight:@(height),
            (id)kIOSurfaceBytesPerElement:@4, (id)kIOSurfaceBytesPerRow:@(stride),
            (id)kIOSurfacePixelFormat:@(0x42475241)});
        CGColorSpaceRef colors = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef bitmap = CGBitmapContextCreate(IOSurfaceGetBaseAddress(surface), width, height,
            8, stride, colors, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), fixture);
        CGContextRelease(bitmap); CGImageRelease(fixture);
        CIContext *context = [CIContext contextWithMTLDevice:MTLCreateSystemDefaultDevice() options:nil];
        NSMutableArray *rows = [NSMutableArray new];
        for (NSString *mode in @[@"core-image", @"direct-bitmap"]) {
            for (int round = 0; round < 12; round++) {
                @autoreleasepool {
                    double started = NSProcessInfo.processInfo.systemUptime;
                    CGImageRef image = NULL;
                    if ([mode isEqual:@"core-image"]) {
                        CIImage *ci = [CIImage imageWithIOSurface:surface];
                        image = [context createCGImage:ci fromRect:ci.extent];
                    } else {
                        CGDataProviderRef bytes = CGDataProviderCreateWithData(NULL,
                            IOSurfaceGetBaseAddress(surface), IOSurfaceGetAllocSize(surface), NULL);
                        image = CGImageCreate(width, height, 8, 32, stride, colors,
                            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                            bytes, NULL, NO, kCGRenderingIntentDefault);
                        CGDataProviderRelease(bytes);
                    }
                    NSMutableData *png = [NSMutableData new];
                    CGImageDestinationRef output = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
                    CGImageDestinationAddImage(output, image, NULL);
                    BOOL valid = CGImageDestinationFinalize(output);
                    CFRelease(output); CGImageRelease(image);
                    if (!valid) return 1;
                    [rows addObject:@{@"mode":mode, @"round":@(round), @"bytes":@(png.length),
                        @"milliseconds":@((NSProcessInfo.processInfo.systemUptime - started) * 1000)}];
                }
            }
        }
        CGColorSpaceRelease(colors); CFRelease(surface);
        NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:NULL];
        fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout);
        return 0;
    }
}
