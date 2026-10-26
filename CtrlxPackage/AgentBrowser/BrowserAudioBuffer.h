#pragma once
#include <algorithm>
#include <cstdint>
#include <mutex>
#include <vector>

// One page, one destination, at most 170 ms. A slow consumer loses old sound.
class BrowserAudioBuffer {
 public:
  static constexpr size_t channels = 2, capacity = 8192;
  static constexpr int sampleRate = 48000;
  void Route(bool remote, bool enabled) {
    std::lock_guard guard(lock_);
    remote_ = remote; enabled_ = enabled; start_ = count_ = 0;
  }
  void Push(const float** data, size_t frames) {
    std::lock_guard guard(lock_);
    captured_ += frames;
    if (remote_ && !enabled_) return;
    for (size_t f = frames > capacity ? frames - capacity : 0; f < frames; ++f) {
      if (count_ == capacity) { start_ = (start_ + 1) % capacity; --count_; }
      size_t target = (start_ + count_++) % capacity;
      for (size_t c = 0; c < channels; ++c) samples_[target * channels + c] = data[c][f];
    }
  }
  size_t Read(float* output, size_t maximumFrames, bool remote) {
    std::lock_guard guard(lock_);
    if (remote != remote_ || (remote && !enabled_)) return 0;
    size_t frames = std::min(count_, maximumFrames);
    for (size_t f = 0; f < frames; ++f)
      for (size_t c = 0; c < channels; ++c)
        output[f * channels + c] = samples_[((start_ + f) % capacity) * channels + c];
    start_ = (start_ + frames) % capacity; count_ -= frames;
    if (!remote) local_ += frames;
    return frames;
  }
  void Clear() { std::lock_guard guard(lock_); start_ = count_ = 0; }
  struct State { uint64_t captured, local; size_t buffered; bool remote, enabled; };
  State Status() { std::lock_guard guard(lock_); return {captured_, local_, count_, remote_, enabled_}; }
 private:
  std::mutex lock_;
  std::vector<float> samples_ = std::vector<float>(capacity * channels);
  size_t start_ = 0, count_ = 0;
  bool remote_ = false, enabled_ = false;
  uint64_t captured_ = 0, local_ = 0;
};
