#pragma once
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#include <algorithm>
#include <cmath>
#include <functional>
#include <string>
#include <cstring>
#include <cerrno>
#include <sys/stat.h>
#include <unistd.h>

constexpr int kBrowserRecordingMaximumSeconds = 600;
constexpr int64_t kBrowserRecordingMaximumBytes = 512LL * 1024 * 1024;

// Used serially off the CEF UI thread. At most one decoded frame is in flight;
// the movie goes directly to a private staging directory beside its destination.
class BrowserRecordingWriter {
 public:
  explicit BrowserRecordingWriter(NSString* output, int fps,
      int64_t maximumBytes = kBrowserRecordingMaximumBytes)
      : output_(output), fps_(fps), maximumBytes_(maximumBytes) {}

  NSString* Prepare() {
    struct stat info{};
    if (lstat(output_.fileSystemRepresentation, &info) == 0 || errno != ENOENT)
      return @"Recording output exists or cannot be accessed; choose a new path.";
    NSString* parent = output_.stringByDeletingLastPathComponent;
    NSString* pattern = [parent stringByAppendingPathComponent:@".ctrlx-browser-recording-XXXXXX"];
    std::string path(pattern.fileSystemRepresentation);
    if (!mkdtemp(path.data())) return @"Cannot create the recording staging directory.";
    directory_ = @(path.data());
    movie_ = [directory_ stringByAppendingPathComponent:@"video.mp4"];
    return nil;
  }

  NSString* Append(NSString* encoded, double seconds) {
    if (![encoded isKindOfClass:NSString.class] || encoded.length > 8 * 1024 * 1024)
      return @"Recording frame is missing or too large.";
    NSData* data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    auto source = data.length ? CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr) : nullptr;
    if (!source) return @"Recording frame cannot be decoded.";
    NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
    double width = [properties[(id)kCGImagePropertyPixelWidth] doubleValue];
    double height = [properties[(id)kCGImagePropertyPixelHeight] doubleValue];
    CGImageRef image = nullptr;
    if (width >= 1 && height >= 1 && width <= 16384 && height <= 16384 && width * height <= 64 * 1024 * 1024) {
      image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @1920});
    }
    CFRelease(source);
    if (!image) return @"Recording frame dimensions are unsupported.";
    NSString* error = nil;
    if (!writer_) error = Open(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!error && writer_.status == AVAssetWriterStatusFailed) error = EncoderError();
    if (!error && input_.readyForMoreMediaData) {
      CVPixelBufferRef buffer = nullptr;
      if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor_.pixelBufferPool, &buffer) != kCVReturnSuccess) {
        error = @"Cannot allocate a recording frame.";
      } else {
        CVPixelBufferLockBaseAddress(buffer, 0);
        auto color = CGColorSpaceCreateDeviceRGB();
        auto context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), width_, height_, 8,
            CVPixelBufferGetBytesPerRow(buffer), color, uint32_t(kCGBitmapByteOrder32Little) | uint32_t(kCGImageAlphaNoneSkipFirst));
        CGColorSpaceRelease(color);
        if (context) {
          CGContextSetRGBFillColor(context, 0, 0, 0, 1);
          CGContextFillRect(context, CGRectMake(0, 0, width_, height_));
          double scale = std::min(double(width_) / CGImageGetWidth(image), double(height_) / CGImageGetHeight(image));
          double w = CGImageGetWidth(image) * scale, h = CGImageGetHeight(image) * scale;
          CGContextDrawImage(context, CGRectMake((width_ - w) / 2, (height_ - h) / 2, w, h), image);
          CGContextRelease(context);
        } else error = @"Cannot draw the recording frame.";
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        if (!error) {
          CMTime timestamp = CMTimeMakeWithSeconds(seconds, 60000);
          if (![adaptor_ appendPixelBuffer:buffer withPresentationTime:timestamp]) error = EncoderError();
          else { ++frames_; lastSeconds_ = seconds; }
        }
        CVPixelBufferRelease(buffer);
      }
    }
    CGImageRelease(image);
    bytes_ = FileSize();
    return error;
  }

  int64_t Bytes() const { return bytes_; }
  int Frames() const { return frames_; }
  bool AtSizeLimit() const { return bytes_ >= std::max(int64_t(1), maximumBytes_ - 1024 * 1024); }

  void Finish(double seconds, std::function<void(NSDictionary*)> completion) {
    if (!writer_ || !frames_ || writer_.status != AVAssetWriterStatusWriting) {
      [writer_ cancelWriting];
      completion(Cleanup(@"Recording did not produce a complete video.", false));
      return;
    }
    [writer_ endSessionAtSourceTime:CMTimeMakeWithSeconds(std::max(seconds, lastSeconds_ + 1.0 / fps_), 60000)];
    [input_ markAsFinished];
    [writer_ finishWritingWithCompletionHandler:^{
      @autoreleasepool {
        NSString* error = nil;
        bytes_ = FileSize();
        if (writer_.status != AVAssetWriterStatusCompleted || bytes_ <= 0)
          error = @"Video encoding did not finish; the incomplete movie was discarded.";
        else if (chmod(movie_.fileSystemRepresentation, 0600) ||
            link(movie_.fileSystemRepresentation, output_.fileSystemRepresentation))
          error = @"Recording output exists or cannot be published; existing files were preserved.";
        completion(Cleanup(error, !error));
      }
    }];
  }

 private:
  NSString* output_;
  NSString* directory_ = nil;
  NSString* movie_ = nil;
  AVAssetWriter* writer_ = nil;
  AVAssetWriterInput* input_ = nil;
  AVAssetWriterInputPixelBufferAdaptor* adaptor_ = nil;
  int fps_, width_ = 0, height_ = 0, frames_ = 0;
  int64_t maximumBytes_, bytes_ = 0;
  double lastSeconds_ = 0;

  NSString* EncoderError() const {
    NSError* error = writer_.error;
    NSError* underlying = error.userInfo[NSUnderlyingErrorKey];
    return [NSString stringWithFormat:@"Video encoder failed (%@ %ld; %@ %ld).", error.domain ?: @"unknown",
      (long)error.code, underlying.domain ?: @"unknown", (long)underlying.code];
  }

  NSString* Open(int width, int height) {
    width_ = std::max(2, width / 2 * 2); height_ = std::max(2, height / 2 * 2);
    writer_ = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:movie_] fileType:AVFileTypeMPEG4 error:nil];
    if (!writer_) return @"Cannot create the MP4 encoder.";
    writer_.movieFragmentInterval = CMTimeMake(1, 1);
    // Browser samples have irregular intervals across navigation. Avoid B-frame
    // reordering, which can make fragmented real-time encoding reject timestamps.
    input_ = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
      AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @(width_), AVVideoHeightKey: @(height_),
      AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @4000000,
        AVVideoAllowFrameReorderingKey: @NO,
        AVVideoExpectedSourceFrameRateKey: @(fps_), AVVideoMaxKeyFrameIntervalKey: @(fps_ * 2)}}];
    input_.expectsMediaDataInRealTime = YES;
    adaptor_ = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input_
      sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width_), (id)kCVPixelBufferHeightKey: @(height_),
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES, (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES}];
    if (![writer_ canAddInput:input_]) return @"The MP4 encoder does not support this viewport.";
    [writer_ addInput:input_];
    if (![writer_ startWriting]) return @"Cannot start the MP4 encoder.";
    [writer_ startSessionAtSourceTime:kCMTimeZero];
    return nil;
  }

  int64_t FileSize() const {
    struct stat info{};
    return movie_ && stat(movie_.fileSystemRepresentation, &info) == 0 ? info.st_size : 0;
  }

  NSDictionary* Cleanup(NSString* error, bool saved) {
    NSError* cleanup = nil;
    if (directory_ && ![NSFileManager.defaultManager removeItemAtPath:directory_ error:&cleanup])
      error = @"Recording temporary-file cleanup failed.";
    NSMutableDictionary* result = [@{@"state": saved ? @"completed" : @"failed", @"bytes": @(bytes_), @"frames": @(frames_)} mutableCopy];
    if (error) result[@"error"] = error;
    return result;
  }
};
