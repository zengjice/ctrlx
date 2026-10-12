#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <algorithm>
#include <cmath>

constexpr size_t kRemoteScreenshotResponseBytes = 8 * 1024 * 1024;
constexpr NSUInteger kRemotePreviewLegacyMaximumBytes = 180 * 1024;
constexpr NSUInteger kRemotePreviewMaximumBytes = 512 * 1024;
constexpr int kRemotePreviewLegacyDimension = 1024;
constexpr int kRemotePreviewMaximumDimension = 2560;

struct RemoteBrowserPreview {
  NSData* jpeg = nil;
  double width = 0, height = 0;
};

// Scale the image, not Chromium's live viewport. Called off the CEF UI thread.
inline RemoteBrowserPreview RemotePreviewFrame(NSString* encoded, double pixelsPerCSSPixel,
                                              int maximumDimension = kRemotePreviewLegacyDimension,
                                              NSUInteger maximumBytes = kRemotePreviewLegacyMaximumBytes) {
  if (![encoded isKindOfClass:NSString.class] || encoded.length > kRemoteScreenshotResponseBytes ||
      !std::isfinite(pixelsPerCSSPixel) || pixelsPerCSSPixel <= 0 ||
      maximumDimension < 256 || maximumDimension > kRemotePreviewMaximumDimension ||
      (maximumBytes != kRemotePreviewLegacyMaximumBytes && maximumBytes != kRemotePreviewMaximumBytes)) return {};
  NSData* bytes = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
  if (!bytes.length) return {};
  auto source = CGImageSourceCreateWithData((__bridge CFDataRef)bytes,
      (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache: @NO});
  if (!source) return {};
  NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
  double width = [properties[(id)kCGImagePropertyPixelWidth] doubleValue];
  double height = [properties[(id)kCGImagePropertyPixelHeight] doubleValue];
  double cssWidth = width / pixelsPerCSSPixel, cssHeight = height / pixelsPerCSSPixel;
  if (width < 1 || height < 1 || width > 16384 || height > 16384 || width * height > 64 * 1024 * 1024) {
    CFRelease(source); return {};
  }
  if (!std::isfinite(cssWidth) || !std::isfinite(cssHeight) || cssWidth < 1 || cssHeight < 1 ||
      cssWidth > 8192 || cssHeight > 8192) {
    CFRelease(source); return {};
  }
  auto image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
      (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
      (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
      (id)kCGImageSourceThumbnailMaxPixelSize: @(maximumDimension)});
  CFRelease(source);
  if (!image) return {};
  // Keep text quality instead of repeatedly lowering JPEG quality. The bounded
  // size ladder resamples one decoded image, never Chromium's live surface.
  while (image) {
    NSMutableData* result = [NSMutableData data];
    auto destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)result, CFSTR("public.jpeg"), 1, nullptr);
    bool finished = false;
    if (destination) {
      CGImageDestinationAddImage(destination, image,
          (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality:
              maximumBytes == kRemotePreviewLegacyMaximumBytes ? @0.5 : @0.82});
      finished = CGImageDestinationFinalize(destination);
      CFRelease(destination);
    }
    if (!finished || result.length <= maximumBytes) {
      CGImageRelease(image);
      return finished ? RemoteBrowserPreview{result, cssWidth, cssHeight} : RemoteBrowserPreview{};
    }
    size_t imageWidth = CGImageGetWidth(image), imageHeight = CGImageGetHeight(image);
    size_t dimension = std::max(imageWidth, imageHeight);
    if (dimension <= 256) break;
    double scale = std::max(size_t(256), dimension * 3 / 4) / double(dimension);
    size_t nextWidth = std::max(size_t(1), size_t(std::round(imageWidth * scale)));
    size_t nextHeight = std::max(size_t(1), size_t(std::round(imageHeight * scale)));
    auto color = CGColorSpaceCreateDeviceRGB();
    auto context = CGBitmapContextCreate(nullptr, nextWidth, nextHeight, 8, 0, color, kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(color);
    if (!context) break;
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, nextWidth, nextHeight), image);
    auto smaller = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGImageRelease(image);
    image = smaller;
  }
  if (image) CGImageRelease(image);
  return {};
}
