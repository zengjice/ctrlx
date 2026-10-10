#include "../RemoteBrowserFrame.h"
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>
#include <vector>

static NSString* SourceJPEG(int width, int height, bool noise = false, bool flat = false) {
  std::vector<unsigned char> pixels(width * height * 4);
  uint32_t random = 19;
  for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
    auto index = (y * width + x) * 4;
    for (int channel = 0; channel < 3; ++channel) {
      random ^= random << 13; random ^= random >> 17; random ^= random << 5;
      pixels[index + channel] = flat ? 220 : noise ? random & 255 : (channel == 0 ? x * 255 / width : channel == 1 ? y * 255 / height : 120);
    }
    pixels[index + 3] = 255;
  }
  auto color = CGColorSpaceCreateDeviceRGB();
  auto context = CGBitmapContextCreate(pixels.data(), width, height, 8, width * 4, color, kCGImageAlphaNoneSkipLast);
  CGColorSpaceRelease(color);
  assert(context);
  auto image = CGBitmapContextCreateImage(context);
  NSMutableData* data = [NSMutableData data];
  auto destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, nullptr);
  assert(destination);
  CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @0.85});
  bool finished = CGImageDestinationFinalize(destination);
  assert(finished);
  CFRelease(destination); CGImageRelease(image); CGContextRelease(context);
  return [data base64EncodedStringWithOptions:0];
}

static void CheckSize(NSString* input, int maximum, double aspect, int requested = kRemotePreviewLegacyDimension,
                      NSUInteger budget = kRemotePreviewLegacyMaximumBytes) {
  NSData* output = RemotePreviewFrame(input, 1, requested, budget).jpeg;
  assert(output.length > 0 && output.length <= budget);
  auto source = CGImageSourceCreateWithData((__bridge CFDataRef)output, nullptr);
  assert(source && CFEqual(CGImageSourceGetType(source), CFSTR("public.jpeg")));
  auto image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
  assert(image);
  auto width = CGImageGetWidth(image), height = CGImageGetHeight(image);
  if (std::max(width, height) != maximum || std::abs(double(width) / height - aspect) >= .003)
    std::cerr << "Unexpected image: " << width << "x" << height << ", expected longest side " << maximum << ", requested " << requested << '\n';
  assert(std::max(width, height) == maximum && std::abs(double(width) / height - aspect) < .003);
  CGImageRelease(image); CFRelease(source);
}

int main() {
  @autoreleasepool {
    CheckSize(SourceJPEG(2400, 1600), 1024, 1.5);
    CheckSize(SourceJPEG(1600, 2400), 1024, 1 / 1.5);
    CheckSize(SourceJPEG(320, 200), 320, 1.6);
    CheckSize(SourceJPEG(2400, 1600, false, true), 2400, 1.5, 2560, kRemotePreviewMaximumBytes);
    CheckSize(SourceJPEG(1600, 2400, false, true), 2400, 1 / 1.5, 2560, kRemotePreviewMaximumBytes);
    CheckSize(SourceJPEG(3200, 1600, false, true), 2560, 2, 2560, kRemotePreviewMaximumBytes);
    CheckSize(SourceJPEG(320, 200), 320, 1.6, 2560, kRemotePreviewMaximumBytes);
    CheckSize(SourceJPEG(2400, 1600), 768, 1.5, 768);
    NSString* large = SourceJPEG(3200, 1600, true);
    assert(large.length > 512 * 1024);
    auto bounded = RemotePreviewFrame(large, 1, 2560, kRemotePreviewMaximumBytes);
    assert(bounded.jpeg && bounded.jpeg.length <= kRemotePreviewMaximumBytes && bounded.width == 3200 && bounded.height == 1600);
    auto boundedSource = CGImageSourceCreateWithData((__bridge CFDataRef)bounded.jpeg, nullptr);
    auto boundedImage = CGImageSourceCreateImageAtIndex(boundedSource, 0, nullptr);
    assert(CGImageGetWidth(boundedImage) < 2560 && CGImageGetWidth(boundedImage) >= 256);
    assert(std::abs(double(CGImageGetWidth(boundedImage)) / CGImageGetHeight(boundedImage) - 2) < .01);
    CGImageRelease(boundedImage); CFRelease(boundedSource);
    NSString* fullViewport = SourceJPEG(1400, 1658);
    for (double pixelsPerCSSPixel : {1., 2., 3.}) {
      auto frame = RemotePreviewFrame(fullViewport, pixelsPerCSSPixel);
      assert(frame.jpeg && frame.width == 1400 / pixelsPerCSSPixel && frame.height == 1658 / pixelsPerCSSPixel);
    }
    for (double invalid : {0., -1., std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN(), .01})
      assert(!RemotePreviewFrame(fullViewport, invalid).jpeg);
    assert(!RemotePreviewFrame(nil, 1).jpeg);
    assert(!RemotePreviewFrame(@"not a screenshot", 1).jpeg);
    assert(!RemotePreviewFrame([[@"broken image" dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0], 1).jpeg);
    assert(!RemotePreviewFrame([@"A" stringByPaddingToLength:kRemoteScreenshotResponseBytes + 1 withString:@"A" startingAtIndex:0], 1).jpeg);
    assert(!RemotePreviewFrame(SourceJPEG(17000, 8), 1).jpeg);
    assert(RemotePreviewFrame(SourceJPEG(1024, 1024, true), 1).jpeg);
    for (int invalid : {0, 255, 2561, std::numeric_limits<int>::max()})
      assert(!RemotePreviewFrame(fullViewport, 1, invalid).jpeg);
    assert(!RemotePreviewFrame(fullViewport, 1, 2560, kRemotePreviewMaximumBytes + 1).jpeg);
  }
  std::cout << "PASS: adaptive landscape/portrait, no upscaling, full-viewport CSS dimensions, pixel/zoom scale, budget downscaling and invalid images\n";
}
