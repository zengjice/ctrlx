#pragma once
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <cmath>

constexpr size_t kRemoteScreenshotResponseBytes = 8 * 1024 * 1024;
constexpr NSUInteger kRemotePreviewMaximumBytes = 180 * 1024;
constexpr int kRemotePreviewMaximumDimension = 1024;

struct RemoteBrowserPreview {
  NSData* jpeg = nil;
  double width = 0, height = 0;
};

// Scale the image, not Chromium's live viewport. Called off the CEF UI thread.
inline RemoteBrowserPreview RemotePreviewFrame(NSString* encoded, double pixelsPerCSSPixel) {
  if (![encoded isKindOfClass:NSString.class] || encoded.length > kRemoteScreenshotResponseBytes ||
      !std::isfinite(pixelsPerCSSPixel) || pixelsPerCSSPixel <= 0) return {};
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
      (id)kCGImageSourceThumbnailMaxPixelSize: @(kRemotePreviewMaximumDimension)});
  CFRelease(source);
  if (!image) return {};
  NSMutableData* result = [NSMutableData data];
  auto destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)result, CFSTR("public.jpeg"), 1, nullptr);
  bool finished = false;
  if (destination) {
    CGImageDestinationAddImage(destination, image,
        (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @0.5});
    finished = CGImageDestinationFinalize(destination);
    CFRelease(destination);
  }
  CGImageRelease(image);
  return finished && result.length <= kRemotePreviewMaximumBytes
      ? RemoteBrowserPreview{result, cssWidth, cssHeight} : RemoteBrowserPreview{};
}
