#import "../BrowserRecordingWriter.h"
#include <cassert>
#include <future>

static NSString* Frame(int width, int height, double red) {
  auto color = CGColorSpaceCreateDeviceRGB();
  auto context = CGBitmapContextCreate(nullptr, width, height, 8, 0, color, kCGImageAlphaNoneSkipLast);
  CGColorSpaceRelease(color);
  CGContextSetRGBFillColor(context, red, 0.3, 0.7, 1);
  CGContextFillRect(context, CGRectMake(0, 0, width, height));
  auto image = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  NSMutableData* data = [NSMutableData data];
  auto destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, nullptr);
  CGImageDestinationAddImage(destination, image, nullptr);
  assert(CGImageDestinationFinalize(destination));
  CFRelease(destination); CGImageRelease(image);
  return [data base64EncodedStringWithOptions:0];
}

static NSDictionary* Finish(BrowserRecordingWriter& writer, double seconds) {
  std::promise<NSDictionary*> result;
  auto future = result.get_future();
  writer.Finish(seconds, [&result](NSDictionary* value) { result.set_value(value); });
  assert(future.wait_for(std::chrono::seconds(15)) == std::future_status::ready);
  return future.get();
}

int main() {
  @autoreleasepool {
    char temporary[] = "/tmp/ctrlx-recording-tests-XXXXXX";
    assert(mkdtemp(temporary));
    NSString* root = @(temporary);
    auto path = [&](NSString* name) { return [root stringByAppendingPathComponent:name]; };
    NSString* image = Frame(640, 480, 0.5);
    {
      BrowserRecordingWriter writer(path(@"test.mp4"), 10);
      assert(!writer.Prepare());
      for (int i = 0; i < 20; ++i) {
        // A real viewport resize must not change encoder dimensions or affect the page.
        assert(!writer.Append(i < 10 ? image : Frame(300, 700, 0.9), i / 10.0));
        usleep(10000);
      }
      NSDictionary* result = Finish(writer, 2.0);
      assert([result[@"state"] isEqual:@"completed"] && [result[@"bytes"] intValue] > 0);
      assert([result[@"frames"] intValue] > 1);
      struct stat info{};
      assert(stat(path(@"test.mp4").fileSystemRepresentation, &info) == 0 && (info.st_mode & 0777) == 0600);
      AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path(@"test.mp4")] options:nil];
      assert(CMTimeGetSeconds(asset.duration) >= 1.9 && CMTimeGetSeconds(asset.duration) <= 2.2);
      auto track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
      assert(track.naturalSize.width == 640 && track.naturalSize.height == 480);
    }
    {
      BrowserRecordingWriter irregular(path(@"irregular.mp4"), 10);
      assert(!irregular.Prepare());
      NSString* large = Frame(1920, 1344, 0.5);
      NSString* resized = Frame(300, 700, 0.9);
      for (int i = 0; i < 80; ++i) {
        // Navigation pauses capture; subsequent frames retain wall-clock timing.
        double seconds = i / 10.0 + .005 * (i % 7) + (i >= 10 ? .4 : 0);
        assert(!irregular.Append(i < 10 ? large : resized, seconds));
        usleep(10000);
      }
      assert([Finish(irregular, 8.5)[@"state"] isEqual:@"completed"]);
      AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path(@"irregular.mp4")] options:nil];
      assert(CMTimeGetSeconds(asset.duration) >= 8.4 && CMTimeGetSeconds(asset.duration) <= 8.6);
      auto track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
      assert(track.naturalSize.width == 1920 && track.naturalSize.height == 1344);
    }
    {
      BrowserRecordingWriter existing(path(@"test.mp4"), 10);
      assert(existing.Prepare());
      BrowserRecordingWriter empty(path(@"empty.mp4"), 10);
      assert(!empty.Prepare());
      assert([Finish(empty, 1)[@"state"] isEqual:@"failed"]);
      assert(![NSFileManager.defaultManager fileExistsAtPath:path(@"empty.mp4")]);
    }
    {
      BrowserRecordingWriter invalid(path(@"invalid.mp4"), 10);
      assert(!invalid.Prepare());
      assert(invalid.Append(@"not an image", 0));
      assert([Finish(invalid, 1)[@"state"] isEqual:@"failed"]);
      assert(![NSFileManager.defaultManager fileExistsAtPath:path(@"invalid.mp4")]);
    }
    {
      assert(symlink("missing-target", path(@"link.mp4").fileSystemRepresentation) == 0);
      BrowserRecordingWriter symlinkWriter(path(@"link.mp4"), 10);
      assert(symlinkWriter.Prepare());
    }
    {
      BrowserRecordingWriter race(path(@"race.mp4"), 10);
      assert(!race.Prepare());
      assert(!race.Append(image, 0));
      assert([@"existing" writeToFile:path(@"race.mp4") atomically:YES encoding:NSUTF8StringEncoding error:nil]);
      assert([Finish(race, 1)[@"state"] isEqual:@"failed"]);
      assert([[NSString stringWithContentsOfFile:path(@"race.mp4") encoding:NSUTF8StringEncoding error:nil] isEqual:@"existing"]);
    }
    {
      BrowserRecordingWriter small(path(@"limited.mp4"), 10, 1024);
      assert(!small.Prepare());
      for (int i = 0; i < 40 && !small.AtSizeLimit(); ++i) {
        assert(!small.Append(image, i / 10.0));
        usleep(10000);
      }
      assert(small.AtSizeLimit());
      assert([Finish(small, 4)[@"state"] isEqual:@"completed"]);
    }
    for (NSString* item in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil])
      assert(![item hasPrefix:@".ctrlx-browser-recording-"]);
    for (int i = 0; i < 50; ++i) {
      BrowserRecordingWriter repeat(path([NSString stringWithFormat:@"重复录制-%d.mp4", i]), 10);
      assert(!repeat.Prepare());
      assert([Finish(repeat, 0)[@"state"] isEqual:@"failed"]);
    }
    assert([NSFileManager.defaultManager removeItemAtPath:root error:nil]);
    puts("Browser recording writer: video/resize/duration, permissions, existing/empty/invalid/symlink/racing paths, size finalization and cleanup passed.");
  }
}
