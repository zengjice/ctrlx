#pragma once
#import <AVFoundation/AVFoundation.h>
#include "BrowserAudioBuffer.h"
#include "include/cef_audio_handler.h"
#include "include/cef_task.h"
#include <atomic>
#include <functional>
#include <memory>

class BrowserAudioTask final : public CefTask {
 public:
  explicit BrowserAudioTask(std::function<void()> work) : work_(std::move(work)) {}
  void Execute() override { work_(); }
 private:
  std::function<void()> work_;
  IMPLEMENT_REFCOUNTING(BrowserAudioTask);
};

// CEF loopback suppresses native output. Keep a local PCM sink so attaching a
// Viewer midway through playback never needs a reload or a media-state change.
class BrowserAudio final : public CefAudioHandler {
 public:
  BrowserAudio() : buffer_(std::make_shared<BrowserAudioBuffer>()) {}
  bool GetAudioParameters(CefRefPtr<CefBrowser>, CefAudioParameters& params) override {
    params.channel_layout = CEF_CHANNEL_LAYOUT_STEREO;
    params.sample_rate = BrowserAudioBuffer::sampleRate;
    params.frames_per_buffer = 1024;
    return true;
  }
  void OnAudioStreamStarted(CefRefPtr<CefBrowser>, const CefAudioParameters& params, int channels) override {
    accepting_ = false;
    @autoreleasepool {
      std::lock_guard guard(playerLock_);
      if (closed_) return;
      buffer_->Clear();
      error_ = nil;
      if (channels != 2 || params.sample_rate != BrowserAudioBuffer::sampleRate) {
        error_ = @"Unsupported browser audio format."; return;
      }
      accepting_ = true;
      StopPlayer();
      engine_ = [[AVAudioEngine alloc] init];
      AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:BrowserAudioBuffer::sampleRate channels:2];
      auto buffer = buffer_;
      source_ = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *, const AudioTimeStamp *, AVAudioFrameCount frames, AudioBufferList *output) {
        // Core Audio chooses its render quantum. Consume in fixed small blocks.
        float samples[2048];
        for (size_t offset = 0; offset < frames;) {
          size_t count = std::min<size_t>(1024, frames - offset);
          size_t available = buffer->Read(samples, count, false);
          for (size_t c = 0; c < output->mNumberBuffers; ++c) {
            auto target = static_cast<float*>(output->mBuffers[c].mData);
            for (size_t f = 0; f < count; ++f) target[offset + f] = f < available && c < 2 ? samples[f * 2 + c] : 0;
          }
          offset += count;
        }
        return noErr;
      }];
      [engine_ attachNode:source_];
      [engine_ connect:source_ to:engine_.mainMixerNode format:format];
      NSError *error = nil;
      if (![engine_ startAndReturnError:&error]) error_ = error.localizedDescription ?: @"Browser audio output could not start.";
      CefRefPtr<BrowserAudio> owner(this);
      AVAudioEngine *expected = engine_;
      observer_ = [NSNotificationCenter.defaultCenter addObserverForName:AVAudioEngineConfigurationChangeNotification
        object:engine_ queue:nil usingBlock:^(NSNotification *) {
          CefPostTask(TID_UI, new BrowserAudioTask([owner, expected] { owner->RestartPlayer(expected); }));
        }];
    }
  }
  void OnAudioStreamPacket(CefRefPtr<CefBrowser>, const float** data, int frames, int64_t) override {
    if (accepting_ && frames > 0) buffer_->Push(data, frames);
  }
  void OnAudioStreamStopped(CefRefPtr<CefBrowser>) override { Stop(); }
  void OnAudioStreamError(CefRefPtr<CefBrowser>, const CefString&) override {
    accepting_ = false;
    std::lock_guard guard(playerLock_);
    error_ = @"Chromium stopped the page audio stream. Pause and resume playback to try again.";
  }
  void Route(bool remote, bool enabled) { buffer_->Route(remote, enabled); }
  NSData *Read(NSString **error) {
    { std::lock_guard guard(playerLock_); *error = error_; }
    if (*error) return nil;
    std::vector<float> samples(4096 * 2);
    size_t frames = buffer_->Read(samples.data(), 4096, true);
    return [NSData dataWithBytes:samples.data() length:frames * 2 * sizeof(float)];
  }
  void Close() {
    accepting_ = false;
    { std::lock_guard guard(playerLock_); closed_ = true; }
    Stop();
    buffer_->Route(false, false);
  }
  NSDictionary *Status() {
    auto state = buffer_->Status();
    std::lock_guard guard(playerLock_);
    return @{@"captured": @(state.captured), @"local": @(state.local), @"buffered": @(state.buffered),
      @"remote": @(state.remote), @"enabled": @(state.enabled), @"error": error_ ?: @""};
  }
 private:
  void Stop() {
    accepting_ = false;
    std::lock_guard guard(playerLock_);
    StopPlayer();
  }
  void StopPlayer() {
    if (observer_) [NSNotificationCenter.defaultCenter removeObserver:observer_];
    observer_ = nil;
    [engine_ stop]; engine_ = nil; source_ = nil;
  }
  void RestartPlayer(AVAudioEngine *expected) {
    std::lock_guard guard(playerLock_);
    if (closed_ || engine_ != expected || engine_.running) return;
    NSError *error = nil;
    if (![engine_ startAndReturnError:&error]) error_ = error.localizedDescription ?: @"Browser audio output could not restart.";
    else error_ = nil;
  }
  std::shared_ptr<BrowserAudioBuffer> buffer_;
  std::mutex playerLock_;
  AVAudioEngine *engine_ = nil;
  AVAudioSourceNode *source_ = nil;
  id observer_ = nil;
  NSString *error_ = nil;
  bool closed_ = false;
  std::atomic_bool accepting_{false};
  IMPLEMENT_REFCOUNTING(BrowserAudio);
};
